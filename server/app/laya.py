"""Laya 决策模型客户端。

Laya 是 Convai Innovations 2026 年 9 月开源的 System 1 决策模型（Apache 2.0）：
纯编码器、非自回归、**不生成文本**，一次前向给出结构化决策。三个原语：

- ``choice`` —— 从候选里选一个，并给出每项的概率
- ``score``  —— 在有序量表上打分，并给出分布
- ``noul``   —— 判断某命题为真的概率（0–1）。名字来自 "bernoulli"，不是 "null"

**这不是一个通用的 HTTP 封装，它编码了三个来自实测的防御。**

1. **必须用多语言权重。** 英文版 ``laya`` 对中文输入基本失效（第三方实测中文准确率
   仅 47.7%，而英文短题 95.8%）。本客户端不负责选权重 —— 那是 ``laya-serve`` 的
   ``LAYA_MODELS`` 环境变量的职责，但这条约束写在这里，因为选错权重的代价是
   「系统看起来很确定地在胡说」。
2. **候选顺序必须打乱。** 官方承认存在位置偏差（曾有「50 道多选题有 46 道选 A」的
   报告）。不打乱的评测结果里混着顺序效应，无法归因。
3. **必须容忍字段名漂移。** Laya 开源后两周内从 0.1.1 迭代到 0.3.x，决策问题的
   选项字段由 ``options`` 改成了 ``criteria``。本模块因此**请求侧可配置、响应侧
   宽容解析** —— 请求格式在我们自己手里，响应格式在厂商手里。

字段名这类不稳定的东西集中在本文件，不扩散到决策服务与契约层。
"""

from __future__ import annotations

import random
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any
from urllib.parse import urlparse

import requests

DEFAULT_BASE_URL = "http://127.0.0.1:8000"
DECISION_PATH = "/v1/systemone"
HEALTH_PATH = "/health"

#: ``laya-serve`` 暴露的就是 Jev 线协议，因此路径固定为 ``/v1/systemone``。
#: 这个常量存在是为了让「将来协议改了」只需改一处。
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1", ""})


class LayaError(RuntimeError):
    """Laya 客户端错误的基类。"""


class LayaConfigError(LayaError):
    """配置有问题，且这个问题在发起请求前就能确定。

    单独成类是为了让它**不可被降级逻辑捕获** —— 配置错误不会因为重试而变好，
    把它混进「模型暂时不可用」的降级路径里，会让一个配置疏漏表现为
    「系统一直在用兜底逻辑」，而且没人会发现。
    """


class LayaUnavailableError(LayaError):
    """模型暂时不可达（连不上、超时、服务端 5xx）。

    调用方应当捕获它并降级到规则兜底路径 —— 这是答辩现场断网时的保命链路，
    因此它必须是一个**明确、可捕获**的类型，而不是让 requests 的异常自由传播。
    """


class LayaProtocolError(LayaError):
    """服务可达，但响应不符合预期结构。多半是版本漂移。"""


class QuestionType(StrEnum):
    """决策原语。"""

    CHOICE = "choice"
    SCORE = "score"
    NOUL = "noul"


@dataclass(frozen=True, slots=True)
class Question:
    """一个决策问题。

    Args:
        key: 本次调用内的键名，用于从结果里取回答案。
        instructions: 自然语言描述这个问题在问什么。
        options: 候选项（``choice``）或有序量表的档位标签（``score``）。
            ``noul`` 不需要选项。
    """

    key: str
    type: QuestionType
    instructions: str
    options: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.type is QuestionType.NOUL:
            if self.options:
                raise ValueError(f"问题 {self.key} 是 noul 类型，不应带选项")
            return
        if len(self.options) < 2:
            raise ValueError(
                f"问题 {self.key}（{self.type}）至少需要 2 个选项，实际 {len(self.options)}"
            )
        if len(set(self.options)) != len(self.options):
            raise ValueError(f"问题 {self.key} 的选项有重复：{self.options}")


@dataclass(frozen=True, slots=True)
class Answer:
    """一个问题的答案。

    三种原语的答案字段互斥，取用时看对应字段即可。:attr:`empty` 为真表示服务
    没有返回这个键（协议漂移或部分失败）—— 这**不是**「答案是 0」，调用方必须
    区别对待。
    """

    key: str
    type: QuestionType

    choice: str | None = None
    choice_probabilities: Mapping[str, float] = field(default_factory=dict)

    score: float | None = None
    score_distribution: Mapping[str, float] = field(default_factory=dict)

    noul: float | None = None

    @property
    def empty(self) -> bool:
        """服务是否根本没返回这个键。"""
        return (
            self.choice is None
            and self.score is None
            and self.noul is None
            and not self.choice_probabilities
            and not self.score_distribution
        )

    def confidence(self) -> float | None:
        """本次回答的置信度。

        - ``choice``：选中项的概率
        - ``noul``：概率离 0.5 越远越确信，映射到 [0, 1]
        - ``score``：量表分布中最高档的占比

        返回 ``None`` 表示无法从响应中得出置信度 —— **不要把它当成 0 或 1**。
        出厂状态的 Laya 校准很差（中文 ECE 0.314，且错误回答的置信度可达 0.91），
        因此这个数在温度校准之前只适合排序，不适合当阈值门控。
        """
        if self.type is QuestionType.CHOICE and self.choice is not None:
            return self.choice_probabilities.get(self.choice)
        if self.type is QuestionType.NOUL and self.noul is not None:
            return abs(self.noul - 0.5) * 2.0
        if self.type is QuestionType.SCORE and self.score_distribution:
            return max(self.score_distribution.values())
        return None


@dataclass(frozen=True, slots=True)
class LayaResult:
    """一次决策调用的完整结果。"""

    answers: Mapping[str, Answer]
    latency_ms: int
    shuffled: bool
    shuffle_seed: int | None
    routing: Mapping[str, Any] | None = None
    usage: Mapping[str, Any] | None = None

    def get(self, key: str) -> Answer | None:
        return self.answers.get(key)


def _coerce_label(value: Any, options: Sequence[str]) -> str | None:
    """把服务返回的选项值统一成选项标签。

    服务可能返回标签文本，也可能返回下标（版本而异）。两种都接受：
    下标按**打乱后**的顺序解释，因此调用方拿到的永远是原始标签。
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return options[value] if 0 <= value < len(options) else None
    if isinstance(value, str):
        if value in options:
            return value
        if value.isdigit():
            index = int(value)
            return options[index] if 0 <= index < len(options) else None
    return None


def _coerce_distribution(value: Any, options: Sequence[str]) -> dict[str, float]:
    """把分布统一成「标签 → 概率」。无法识别的键直接丢弃。"""
    if not isinstance(value, Mapping):
        return {}
    out: dict[str, float] = {}
    for raw_key, raw_prob in value.items():
        label = _coerce_label(raw_key, options)
        if label is None:
            continue
        try:
            out[label] = float(raw_prob)
        except (TypeError, ValueError):
            continue
    return out


class LayaClient:
    """与 ``laya-serve`` 通信的客户端。

    Args:
        base_url: 服务地址。默认本机 —— ``laya-serve`` 出厂监听 ``0.0.0.0:8000``
            且**不带鉴权**，指向非回环地址却不给 API key 是配置事故，构造时直接拒绝。
        api_key: 若服务配了 ``LAYA_API_KEY``，这里要给对应的值。
        timeout_s: 单次决策超时。**刻意默认得很短**：决策是按组调用的，
            一次调用卡住会拖住整个演示流程。超时即降级到规则兜底，好过让界面转圈。
        options_field: 选项字段名。默认 ``"options"``；若装到的是把该字段改名为
            ``"criteria"`` 的版本，改这里即可，不必改调用方。
        session: 注入的 HTTP 会话，供测试使用。
        shuffle: 是否打乱候选顺序。**默认开启且不建议关闭** ——
            关闭后无法排除位置偏差，评测结果不可归因。测试中为便于断言可关闭。
        rng_seed: 乱序的随机种子。给定时乱序可复现（审计需要）；不给则每次不同。
    """

    def __init__(
        self,
        base_url: str = DEFAULT_BASE_URL,
        *,
        api_key: str | None = None,
        timeout_s: float = 5.0,
        options_field: str = "options",
        session: requests.Session | None = None,
        shuffle: bool = True,
        rng_seed: int | None = None,
    ) -> None:
        host = urlparse(base_url).hostname
        if host not in _LOOPBACK_HOSTS and not api_key:
            raise LayaConfigError(
                f"base_url={base_url!r} 指向非本机地址，但没有提供 api_key。"
                "laya-serve 出厂不带鉴权，把无鉴权的决策服务暴露在局域网上会让"
                "任何人都能调用它。请配置 api_key 或反向代理后再指向非回环地址。"
            )
        if timeout_s <= 0:
            raise LayaConfigError(f"timeout_s 必须为正数，实际为 {timeout_s}")

        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout_s = timeout_s
        self.options_field = options_field
        self.shuffle = shuffle
        self._rng_seed = rng_seed
        self._session = session or requests.Session()

    # ---- 对外接口 ----

    def health(self) -> bool:
        """探活。用于启动时自检与演示前的链路检查。"""
        try:
            response = self._session.get(f"{self.base_url}{HEALTH_PATH}", timeout=self.timeout_s)
        except requests.RequestException:
            return False
        return 200 <= response.status_code < 300

    def decide(
        self,
        state: Mapping[str, Any],
        questions: Sequence[Question],
    ) -> LayaResult:
        """发起一次决策。

        Args:
            state: 决策所依据的状态。本项目里是**文本化后的姿态特征与规则判定**
                —— Laya 看不到视频，也看不到关键点，它只消费这里的内容。
            questions: 要问的问题。候选集大小由契约层限制。

        Raises:
            LayaUnavailableError: 连不上、超时、服务端 5xx。**调用方应降级到规则兜底。**
            LayaProtocolError: 响应结构不符，多半是版本漂移。
            LayaConfigError: 配置问题（构造时已校验，运行期不会再抛）。
        """
        seed = (
            self._rng_seed
            if self._rng_seed is not None
            else random.SystemRandom().randrange(2**31)
        )
        rng = random.Random(seed)

        payload_questions: dict[str, dict[str, Any]] = {}
        shuffled_options: dict[str, tuple[str, ...]] = {}
        for question in questions:
            entry: dict[str, Any] = {
                "type": str(question.type),
                "instructions": question.instructions,
            }
            if question.options:
                options = list(question.options)
                if self.shuffle:
                    rng.shuffle(options)
                shuffled_options[question.key] = tuple(options)
                entry[self.options_field] = options
            payload_questions[question.key] = entry

        body = {"state": dict(state), "questions": payload_questions}

        started = time.monotonic()
        try:
            response = self._session.post(
                f"{self.base_url}{DECISION_PATH}",
                json=body,
                headers=self._headers(),
                timeout=self.timeout_s,
            )
        except requests.Timeout as exc:
            raise LayaUnavailableError(f"决策请求超时（{self.timeout_s}s）：{exc}") from exc
        except requests.RequestException as exc:
            raise LayaUnavailableError(f"决策服务不可达：{exc}") from exc
        latency_ms = int((time.monotonic() - started) * 1000)

        if response.status_code >= 500:
            raise LayaUnavailableError(f"决策服务返回 {response.status_code}")
        if not 200 <= response.status_code < 300:
            raise LayaProtocolError(f"决策服务返回 {response.status_code}：{response.text[:200]}")

        try:
            payload = response.json()
        except ValueError as exc:
            raise LayaProtocolError(f"响应不是合法 JSON：{exc}") from exc
        if not isinstance(payload, Mapping):
            raise LayaProtocolError(f"响应顶层应为对象，实际为 {type(payload).__name__}")

        answers = self._parse_answers(payload, questions, shuffled_options)
        return LayaResult(
            answers=answers,
            latency_ms=latency_ms,
            shuffled=self.shuffle,
            shuffle_seed=seed if self.shuffle else None,
            routing=payload.get("routing") if isinstance(payload.get("routing"), Mapping) else None,
            usage=payload.get("usage") if isinstance(payload.get("usage"), Mapping) else None,
        )

    # ---- 内部 ----

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _parse_answers(
        self,
        payload: Mapping[str, Any],
        questions: Sequence[Question],
        shuffled_options: Mapping[str, Sequence[str]],
    ) -> dict[str, Answer]:
        """宽容解析响应。

        **刻意宽容**：字段名与嵌套结构随版本变过，而响应格式我们控制不了。
        缺失的键不抛错、只标记为空 —— 一次演示中的部分失败应当降级，不是崩溃。
        但请求侧的格式由我们自己定义，因此那边是严格的。
        """
        raw_answers = payload.get("answers")
        if not isinstance(raw_answers, Mapping):
            raise LayaProtocolError(
                "响应缺少 answers 字段。多半是 Laya 版本变更导致线协议不同 —— "
                "请检查 laya-serve 的版本并对照其文档更新 _parse_answers。"
            )

        out: dict[str, Answer] = {}
        for question in questions:
            raw = raw_answers.get(question.key)
            if not isinstance(raw, Mapping):
                out[question.key] = Answer(key=question.key, type=question.type)
                continue
            options = shuffled_options.get(question.key, question.options)
            out[question.key] = self._parse_one(question, raw, options)
        return out

    def _parse_one(
        self, question: Question, raw: Mapping[str, Any], options: Sequence[str]
    ) -> Answer:
        if question.type is QuestionType.NOUL:
            value = raw.get("noul")
            try:
                probability = float(value) if value is not None else None
            except (TypeError, ValueError):
                probability = None
            return Answer(key=question.key, type=question.type, noul=probability)

        if question.type is QuestionType.CHOICE:
            selected = _coerce_label(raw.get("choice"), options)
            probabilities = _coerce_distribution(
                raw.get("probabilities") or raw.get("choices"), options
            )
            return Answer(
                key=question.key,
                type=question.type,
                choice=selected,
                choice_probabilities=probabilities,
            )

        value = raw.get("score")
        try:
            score = float(value) if value is not None else None
        except (TypeError, ValueError):
            score = None
        distribution = _coerce_distribution(
            raw.get("distribution") or raw.get("probabilities"), options
        )
        return Answer(
            key=question.key, type=question.type, score=score, score_distribution=distribution
        )


__all__ = [
    "DECISION_PATH",
    "DEFAULT_BASE_URL",
    "HEALTH_PATH",
    "Answer",
    "LayaClient",
    "LayaConfigError",
    "LayaError",
    "LayaProtocolError",
    "LayaResult",
    "LayaUnavailableError",
    "Question",
    "QuestionType",
]
