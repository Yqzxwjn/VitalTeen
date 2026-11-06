"""Laya 客户端测试。

全部用假的 HTTP 会话，不依赖真实的 ``laya-serve`` —— 客户端的价值恰恰在于
**它如何处理服务的各种坏脾气**（连不上、超时、字段漂移、返回下标而不是标签），
这些用真服务很难稳定复现。

真实服务的联通性由 Phase 0 的手工验证覆盖（见 ``docs/phase0-environment.md``），
不在这里做：单元测试依赖外部进程，跑起来会变成随机红。
"""

from __future__ import annotations

from typing import Any

import pytest
import requests

from app.laya import (
    Answer,
    LayaClient,
    LayaConfigError,
    LayaProtocolError,
    LayaUnavailableError,
    Question,
    QuestionType,
)

OPTIONS = ("膝内扣", "下蹲深度不足", "躯干过度前倾", "脚跟离地", "左右不对称")
QUESTION = Question(
    key="err_type",
    type=QuestionType.CHOICE,
    instructions="该动作属于哪一类错误？",
    options=OPTIONS,
)


class FakeResponse:
    def __init__(self, payload: Any = None, status_code: int = 200, text: str = "") -> None:
        self._payload = payload
        self.status_code = status_code
        self.text = text or (str(payload) if payload is not None else "")

    def json(self) -> Any:
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


class FakeSession:
    """记录调用并按预设返回的假会话。"""

    def __init__(
        self,
        response: FakeResponse | None = None,
        *,
        exc: Exception | None = None,
        get_response: FakeResponse | None = None,
    ) -> None:
        self.response = response if response is not None else FakeResponse({"answers": {}})
        self.exc = exc
        self.get_response = get_response or FakeResponse({}, status_code=200)
        self.posts: list[dict[str, Any]] = []
        self.gets: list[dict[str, Any]] = []

    def post(self, url: str, **kwargs: Any) -> FakeResponse:
        self.posts.append({"url": url, **kwargs})
        if self.exc is not None:
            raise self.exc
        return self.response

    def get(self, url: str, **kwargs: Any) -> FakeResponse:
        self.gets.append({"url": url, **kwargs})
        if self.exc is not None:
            raise self.exc
        return self.get_response


def make_client(session: FakeSession, **overrides: Any) -> LayaClient:
    kwargs: dict[str, Any] = {"session": session, "shuffle": False}
    kwargs.update(overrides)
    return LayaClient(**kwargs)


def choice_response(selected: str, probabilities: dict[str, float] | None = None) -> FakeResponse:
    return FakeResponse(
        {
            "answers": {
                "err_type": {
                    "choice": selected,
                    "probabilities": probabilities or {selected: 0.8},
                }
            }
        }
    )


# --------------------------------------------------------------------------
# 请求构造
# --------------------------------------------------------------------------


class TestRequestShape:
    def test_payload_carries_state_and_questions(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        make_client(session).decide({"膝角": "95度"}, [QUESTION])

        assert len(session.posts) == 1
        post = session.posts[0]
        assert post["url"].endswith("/v1/systemone")
        assert post["json"]["state"] == {"膝角": "95度"}
        entry = post["json"]["questions"]["err_type"]
        assert entry["type"] == "choice"
        assert entry["instructions"] == "该动作属于哪一类错误？"
        assert entry["options"] == list(OPTIONS)

    def test_noul_question_has_no_options(self) -> None:
        session = FakeSession(FakeResponse({"answers": {"pass": {"noul": 0.12}}}))
        question = Question(key="pass", type=QuestionType.NOUL, instructions="该动作是否达标？")
        make_client(session).decide({}, [question])
        assert "options" not in session.posts[0]["json"]["questions"]["pass"]

    def test_options_field_is_configurable(self) -> None:
        """Laya 曾把该字段由 options 改名为 criteria，改配置即可适配，不必改调用方。"""
        session = FakeSession(choice_response("膝内扣"))
        make_client(session, options_field="criteria").decide({}, [QUESTION])
        entry = session.posts[0]["json"]["questions"]["err_type"]
        assert "criteria" in entry
        assert "options" not in entry


class TestQuestionValidation:
    def test_noul_with_options_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="不应带选项"):
            Question(key="x", type=QuestionType.NOUL, instructions="i", options=("a", "b"))

    def test_choice_needs_at_least_two_options(self) -> None:
        with pytest.raises(ValueError, match="至少需要 2 个选项"):
            Question(key="x", type=QuestionType.CHOICE, instructions="i", options=("唯一",))

    def test_duplicate_options_are_rejected(self) -> None:
        with pytest.raises(ValueError, match="重复"):
            Question(key="x", type=QuestionType.CHOICE, instructions="i", options=("a", "a"))


# --------------------------------------------------------------------------
# 乱序：对冲 Laya 的位置偏差
# --------------------------------------------------------------------------


class TestShuffling:
    def test_disabled_shuffle_preserves_canonical_order(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        result = make_client(session, shuffle=False).decide({}, [QUESTION])
        assert session.posts[0]["json"]["questions"]["err_type"]["options"] == list(OPTIONS)
        assert result.shuffled is False
        assert result.shuffle_seed is None

    def test_shuffle_preserves_option_set_but_changes_order(self) -> None:
        """乱序只改顺序，不能改集合 —— 改了集合就等于改了问题。"""
        session = FakeSession(choice_response("膝内扣"))
        make_client(session, shuffle=True, rng_seed=42).decide({}, [QUESTION])
        sent = session.posts[0]["json"]["questions"]["err_type"]["options"]
        assert set(sent) == set(OPTIONS)
        assert len(sent) == len(OPTIONS)
        assert sent != list(OPTIONS), "5 个选项在固定种子下应当产生不同顺序"

    def test_same_seed_is_reproducible(self) -> None:
        """审计需要：给定种子，乱序必须可复现。"""
        first = FakeSession(choice_response("膝内扣"))
        second = FakeSession(choice_response("膝内扣"))
        make_client(first, shuffle=True, rng_seed=7).decide({}, [QUESTION])
        make_client(second, shuffle=True, rng_seed=7).decide({}, [QUESTION])
        assert (
            first.posts[0]["json"]["questions"]["err_type"]["options"]
            == second.posts[0]["json"]["questions"]["err_type"]["options"]
        )

    def test_seed_is_reported_in_the_result(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        result = make_client(session, shuffle=True, rng_seed=123).decide({}, [QUESTION])
        assert result.shuffled is True
        assert result.shuffle_seed == 123

    def test_index_response_maps_back_through_shuffled_order(self) -> None:
        """服务可能返回下标而不是标签，且下标是按打乱后的顺序解释的。"""
        session = FakeSession(FakeResponse({"answers": {"err_type": {"choice": 0}}}))
        client = make_client(session, shuffle=True, rng_seed=42)
        result = client.decide({}, [QUESTION])
        sent = session.posts[0]["json"]["questions"]["err_type"]["options"]
        assert result.get("err_type").choice == sent[0]


# --------------------------------------------------------------------------
# 响应解析
# --------------------------------------------------------------------------


class TestResponseParsing:
    def test_choice_by_label(self) -> None:
        session = FakeSession(choice_response("下蹲深度不足", {"下蹲深度不足": 0.71}))
        answer = make_client(session).decide({}, [QUESTION]).get("err_type")
        assert answer is not None
        assert answer.choice == "下蹲深度不足"
        assert answer.confidence() == pytest.approx(0.71)

    def test_choice_by_index(self) -> None:
        session = FakeSession(FakeResponse({"answers": {"err_type": {"choice": "2"}}}))
        answer = make_client(session).decide({}, [QUESTION]).get("err_type")
        assert answer is not None
        assert answer.choice == OPTIONS[2]

    def test_unrecognized_choice_becomes_none(self) -> None:
        """返回了候选人之外的标签 —— 不猜、不映射，如实记为无法识别。"""
        session = FakeSession(FakeResponse({"answers": {"err_type": {"choice": "不存在的错误"}}}))
        answer = make_client(session).decide({}, [QUESTION]).get("err_type")
        assert answer is not None
        assert answer.choice is None

    def test_noul_probability(self) -> None:
        session = FakeSession(FakeResponse({"answers": {"pass": {"noul": 0.12}}}))
        question = Question(key="pass", type=QuestionType.NOUL, instructions="是否达标？")
        answer = make_client(session).decide({}, [question]).get("pass")
        assert answer is not None
        assert answer.noul == pytest.approx(0.12)
        assert answer.confidence() == pytest.approx(0.76)

    def test_score_with_distribution(self) -> None:
        session = FakeSession(
            FakeResponse(
                {
                    "answers": {
                        "severity": {
                            "score": 2,
                            "distribution": {"轻": 0.2, "中": 0.6, "重": 0.2},
                        }
                    }
                }
            )
        )
        question = Question(
            key="severity",
            type=QuestionType.SCORE,
            instructions="错误严重程度？",
            options=("轻", "中", "重"),
        )
        answer = make_client(session).decide({}, [question]).get("severity")
        assert answer is not None
        assert answer.score == pytest.approx(2.0)
        assert answer.score_distribution["中"] == pytest.approx(0.6)
        assert answer.confidence() == pytest.approx(0.6)

    def test_missing_answer_key_is_flagged_not_crashed(self) -> None:
        """服务没返回某个键时降级，不崩溃 —— 演示中的部分失败不该中断整个流程。"""
        session = FakeSession(FakeResponse({"answers": {}}))
        answer = make_client(session).decide({}, [QUESTION]).get("err_type")
        assert answer is not None
        assert answer.empty is True
        assert answer.choice is None
        assert answer.confidence() is None

    def test_unknown_requested_key_returns_none(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        result = make_client(session).decide({}, [QUESTION])
        assert result.get("nonexistent") is None

    def test_routing_and_usage_are_passed_through(self) -> None:
        session = FakeSession(
            FakeResponse(
                {
                    "answers": {"err_type": {"choice": "膝内扣"}},
                    "routing": {"checkpoint": "laya-multilingual"},
                    "usage": {"input_tokens": 128},
                }
            )
        )
        result = make_client(session).decide({}, [QUESTION])
        assert result.routing == {"checkpoint": "laya-multilingual"}
        assert result.usage == {"input_tokens": 128}

    def test_missing_answers_field_is_a_protocol_error(self) -> None:
        """连 answers 都没有说明线协议根本不同，此时宽容解析只会掩盖问题。"""
        session = FakeSession(FakeResponse({"result": "something else"}))
        with pytest.raises(LayaProtocolError, match="answers"):
            make_client(session).decide({}, [QUESTION])

    def test_non_json_response_is_a_protocol_error(self) -> None:
        session = FakeSession(FakeResponse(None))
        with pytest.raises(LayaProtocolError, match="JSON"):
            make_client(session).decide({}, [QUESTION])

    def test_latency_is_recorded(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        assert make_client(session).decide({}, [QUESTION]).latency_ms >= 0


# --------------------------------------------------------------------------
# 故障与降级
# --------------------------------------------------------------------------


class TestFailureModes:
    def test_connection_error_raises_unavailable(self) -> None:
        """必须是一个明确可捕获的类型 —— 答辩现场断网时靠它触发规则兜底。"""
        session = FakeSession(exc=requests.ConnectionError("connection refused"))
        with pytest.raises(LayaUnavailableError):
            make_client(session).decide({}, [QUESTION])

    def test_timeout_raises_unavailable(self) -> None:
        session = FakeSession(exc=requests.Timeout("timed out"))
        with pytest.raises(LayaUnavailableError, match="超时"):
            make_client(session).decide({}, [QUESTION])

    def test_server_error_raises_unavailable(self) -> None:
        session = FakeSession(FakeResponse({}, status_code=503, text="service unavailable"))
        with pytest.raises(LayaUnavailableError, match="503"):
            make_client(session).decide({}, [QUESTION])

    def test_client_error_raises_protocol_error(self) -> None:
        """4xx 说明我们的请求不合服务的要求（多半是版本漂移），不是暂时不可用 ——
        这类错误重试无用，因此单独分类，不能混进降级路径。"""
        session = FakeSession(FakeResponse({}, status_code=422, text="unprocessable"))
        with pytest.raises(LayaProtocolError, match="422"):
            make_client(session).decide({}, [QUESTION])

    def test_unavailable_is_not_confused_with_config_error(self) -> None:
        assert not issubclass(LayaConfigError, LayaUnavailableError)
        assert not issubclass(LayaUnavailableError, LayaConfigError)


class TestEndpointGuard:
    def test_non_loopback_without_key_is_rejected(self) -> None:
        """laya-serve 出厂不带鉴权。指向局域网上一个无鉴权的决策服务，
        等于把它对所有人开放 —— 这在构造期就该被拒绝，而不是运行时才发现。"""
        with pytest.raises(LayaConfigError, match="api_key"):
            LayaClient("http://192.168.1.10:8000", session=FakeSession())

    def test_non_loopback_with_key_is_accepted_and_sends_header(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        client = LayaClient("http://192.168.1.10:8000", api_key="secret", session=session)
        client.decide({}, [QUESTION])
        assert session.posts[0]["headers"]["Authorization"] == "Bearer secret"

    @pytest.mark.parametrize(
        "url", ["http://127.0.0.1:8000", "http://localhost:8000", "http://[::1]:8000"]
    )
    def test_loopback_needs_no_key(self, url: str) -> None:
        assert LayaClient(url, session=FakeSession()).api_key is None

    def test_non_positive_timeout_is_rejected(self) -> None:
        with pytest.raises(LayaConfigError, match="timeout_s"):
            LayaClient(timeout_s=0, session=FakeSession())

    def test_trailing_slash_is_normalized(self) -> None:
        session = FakeSession(choice_response("膝内扣"))
        LayaClient("http://127.0.0.1:8000/", session=session).decide({}, [QUESTION])
        assert session.posts[0]["url"] == "http://127.0.0.1:8000/v1/systemone"


class TestHealth:
    def test_healthy_service(self) -> None:
        assert make_client(FakeSession(get_response=FakeResponse({}, 200))).health() is True

    def test_unhealthy_status(self) -> None:
        assert make_client(FakeSession(get_response=FakeResponse({}, 500))).health() is False

    def test_unreachable_service(self) -> None:
        assert make_client(FakeSession(exc=requests.ConnectionError())).health() is False


class TestAnswerConfidence:
    def test_empty_answer_has_no_confidence(self) -> None:
        """无法得出置信度时返回 None，而不是 0 或 1 —— 那两种都是编造。"""
        answer = Answer(key="k", type=QuestionType.CHOICE)
        assert answer.confidence() is None
        assert answer.empty is True

    def test_choice_without_probabilities_has_no_confidence(self) -> None:
        answer = Answer(key="k", type=QuestionType.CHOICE, choice="膝内扣")
        assert answer.confidence() is None
