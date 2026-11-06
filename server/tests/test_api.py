"""HTTP 接口层测试。

这里验证的是**入口行为**：鉴权、请求校验、错误码、以及「不泄露内部细节」。
决策逻辑本身由 ``test_service.py`` 覆盖，因此大部分用例注入一个规则兜底模式的
服务即可（它不依赖任何外部进程，结果完全确定）。

``TestBindSafety`` 守的是安全底线：一个会返回未成年人身体姿态判定结果的服务，
不允许在局域网上裸奔。
"""

from __future__ import annotations

from typing import Any

import pytest

from app.api import ApiConfig, build_service, create_app
from app.contracts import DecisionResponse
from app.laya import LayaConfigError
from app.service import DecisionService


def rule_only_app(**config_overrides: Any):
    """构造一个不依赖模型的接口层 —— 结果确定，测试不会因为环境而随机红。"""
    config = ApiConfig(**config_overrides)
    return create_app(config, service=DecisionService(laya=None))


class StubService:
    """会抛异常的服务桩，用于验证错误处理不泄露内部细节。"""

    is_model_configured = True

    def model_reachable(self) -> bool:
        return False

    def decide(self, request: Any, *, available_equipment: Any = ()) -> Any:
        raise RuntimeError("内部实现细节：数据库连接串 postgres://user:pw@host/db 已泄露")


# --------------------------------------------------------------------------
# 探活
# --------------------------------------------------------------------------


class TestHealth:
    def test_returns_ok(self) -> None:
        response = rule_only_app().test_client().get("/health")
        assert response.status_code == 200
        body = response.get_json()
        assert body["status"] == "ok"
        assert body["model_configured"] is False

    def test_deep_probe_is_opt_in(self) -> None:
        """默认不做深探测。

        一个会卡住的健康检查比没有健康检查更糟 —— 监控探针会因为模型不可达而超时，
        于是「模型挂了」被误报成「整个服务挂了」。
        """
        client = rule_only_app().test_client()
        assert client.get("/health").get_json()["model_reachable"] is None
        assert client.get("/health?deep=1").get_json()["model_reachable"] is False

    def test_health_never_requires_auth(self) -> None:
        """探活接口加鉴权只会让监控和负载均衡没法工作，而它不返回任何用户数据。"""
        client = rule_only_app(api_key="s3cret").test_client()
        assert client.get("/health").status_code == 200


# --------------------------------------------------------------------------
# 决策接口
# --------------------------------------------------------------------------


class TestDecide:
    def test_valid_request_returns_a_valid_response(self, raw_payload: dict[str, Any]) -> None:
        response = rule_only_app().test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 200
        parsed = DecisionResponse.model_validate(response.get_json())
        assert parsed.request_id == raw_payload["request_id"]
        assert parsed.status == "ok"

    def test_single_candidate_does_not_break(self, raw_payload: dict[str, Any]) -> None:
        """单候选时不存在「选择」这回事，但接口必须照常工作。

        这个场景曾经让 ``choice`` 原语因「选项少于 2 个」直接抛错并返回 500。
        """
        raw_payload["candidates"] = [{"code": "KNEE_VALGUS"}]
        response = rule_only_app().test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 200
        body = response.get_json()
        assert body["primary_fault"]["code"] == "KNEE_VALGUS"

    def test_equipment_reaches_the_service(self, raw_payload: dict[str, Any]) -> None:
        """器材通过查询参数传入，缺省视为徒手 —— 学生大多在家练。"""
        response = rule_only_app().test_client().post(
            "/v1/decide?equipment=弹力带&equipment=垫子", json=raw_payload
        )
        assert response.status_code == 200

    def test_missing_required_field_returns_400_with_field_detail(
        self, raw_payload: dict[str, Any]
    ) -> None:
        """逐字段回报 —— 端侧能直接定位，这是把校验放在入口的全部意义。"""
        del raw_payload["context"]["age"]
        response = rule_only_app().test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 400
        detail = response.get_json()["detail"]
        assert any("age" in item["field"] for item in detail), detail

    def test_unknown_field_returns_400(self, raw_payload: dict[str, Any]) -> None:
        raw_payload["surprise"] = 1
        assert rule_only_app().test_client().post("/v1/decide", json=raw_payload).status_code == 400

    def test_candidate_overflow_returns_400(self, raw_payload: dict[str, Any]) -> None:
        """候选集上限是硬约束（Laya 超过约 20 个选项后准确率急剧下降），
        越界必须在入口被拦下，而不是进了模型再表现异常。"""
        raw_payload["candidates"] = [{"code": f"F_{i}"} for i in range(25)]
        response = rule_only_app().test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 400

    def test_non_json_body_returns_400(self) -> None:
        response = rule_only_app().test_client().post(
            "/v1/decide", data="not json", content_type="text/plain"
        )
        assert response.status_code == 400
        assert "JSON" in response.get_json()["detail"]

    def test_abstain_is_a_200_not_an_error(self, raw_payload: dict[str, Any]) -> None:
        """弃权是服务给出的**有效结论**，不是请求失败 —— 用 200 承载，用 body 表达。"""
        raw_payload["pose_quality"] = {
            "mean_visibility": 0.1,
            "coverage_ok_ratio": 0.1,
            "fps_mean": 28.4,
            "gap_max_ms": 180,
            "view_confidence": 0.9,
        }
        response = rule_only_app().test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 200
        assert response.get_json()["status"] == "abstain"


class TestErrorHandling:
    def test_internal_error_does_not_leak_details(self, raw_payload: dict[str, Any]) -> None:
        """500 响应不能带上异常信息。

        异常文本里经常夹着连接串、文件路径、内部主机名 —— 这些一旦回给客户端，
        就从「一个 bug」变成了「一次信息泄露」。
        """
        app = create_app(ApiConfig(), service=StubService())  # type: ignore[arg-type]
        response = app.test_client().post("/v1/decide", json=raw_payload)
        assert response.status_code == 500
        body = response.get_json()
        assert body["error"] == "internal_error"
        assert "postgres" not in response.get_data(as_text=True)
        assert "内部实现细节" not in response.get_data(as_text=True)

    def test_unknown_route_returns_json_404(self) -> None:
        response = rule_only_app().test_client().get("/nope")
        assert response.status_code == 404
        assert response.get_json()["error"] == "not_found"

    def test_wrong_method_returns_json_405(self) -> None:
        response = rule_only_app().test_client().get("/v1/decide")
        assert response.status_code == 405
        assert response.get_json()["error"] == "method_not_allowed"


# --------------------------------------------------------------------------
# 鉴权
# --------------------------------------------------------------------------


class TestAuth:
    def test_open_when_no_key_configured(self, raw_payload: dict[str, Any]) -> None:
        assert rule_only_app().test_client().post("/v1/decide", json=raw_payload).status_code == 200

    def test_missing_header_is_rejected(self, raw_payload: dict[str, Any]) -> None:
        client = rule_only_app(api_key="s3cret").test_client()
        assert client.post("/v1/decide", json=raw_payload).status_code == 401

    def test_wrong_key_is_rejected(self, raw_payload: dict[str, Any]) -> None:
        client = rule_only_app(api_key="s3cret").test_client()
        response = client.post(
            "/v1/decide", json=raw_payload, headers={"Authorization": "Bearer wrong"}
        )
        assert response.status_code == 401

    def test_correct_key_is_accepted(self, raw_payload: dict[str, Any]) -> None:
        client = rule_only_app(api_key="s3cret").test_client()
        response = client.post(
            "/v1/decide", json=raw_payload, headers={"Authorization": "Bearer s3cret"}
        )
        assert response.status_code == 200

    def test_auth_is_checked_before_body_validation(self, raw_payload: dict[str, Any]) -> None:
        """未鉴权的请求不该拿到「你的字段哪里错了」这种信息。"""
        client = rule_only_app(api_key="s3cret").test_client()
        response = client.post("/v1/decide", json={"garbage": True})
        assert response.status_code == 401


# --------------------------------------------------------------------------
# 安全底线
# --------------------------------------------------------------------------


class TestBindSafety:
    def test_non_loopback_without_key_refuses_to_start(self) -> None:
        with pytest.raises(LayaConfigError, match="API key"):
            ApiConfig(host="0.0.0.0").check_bind_safety()

    def test_non_loopback_with_key_is_allowed(self) -> None:
        ApiConfig(host="0.0.0.0", api_key="s3cret").check_bind_safety()

    @pytest.mark.parametrize("host", ["127.0.0.1", "localhost", "::1"])
    def test_loopback_needs_no_key(self, host: str) -> None:
        ApiConfig(host=host).check_bind_safety()

    def test_default_host_is_loopback(self) -> None:
        assert ApiConfig().host == "127.0.0.1"


class TestConfig:
    def test_reads_environment(self) -> None:
        config = ApiConfig.from_env(
            {
                "VITALTEEN_HOST": "0.0.0.0",
                "VITALTEEN_PORT": "9000",
                "VITALTEEN_API_KEY": "k",
                "LAYA_BASE_URL": "http://10.0.0.5:8000",
                "LAYA_TIMEOUT_S": "2.5",
            }
        )
        assert config.host == "0.0.0.0"
        assert config.port == 9000
        assert config.api_key == "k"
        assert config.laya_base_url == "http://10.0.0.5:8000"
        assert config.laya_timeout_s == pytest.approx(2.5)

    def test_empty_api_key_becomes_none(self) -> None:
        """空字符串不是 key —— 否则「没配」会被当成「配了个空密码」而放行。"""
        assert ApiConfig.from_env({"VITALTEEN_API_KEY": ""}).api_key is None

    def test_defaults_are_loopback_and_modelless_safe(self) -> None:
        config = ApiConfig.from_env({})
        assert config.host == "127.0.0.1"
        assert config.api_key is None


class TestServiceWiring:
    def test_bad_laya_config_falls_back_to_rule_only(self) -> None:
        """决策模型配置不合法时**不阻断启动**，服务以规则兜底模式运行。

        答辩现场若模型没起来，整个后端仍然可用 —— 响应里会写明结论来自规则。
        """
        config = ApiConfig(laya_base_url="http://10.0.0.5:8000", laya_api_key=None)
        service = build_service(config)
        assert service.is_model_configured is False

    def test_valid_laya_config_creates_a_client(self) -> None:
        service = build_service(ApiConfig())
        assert service.is_model_configured is True

    def test_health_reports_model_configuration(self) -> None:
        client = create_app(ApiConfig(), service=build_service(ApiConfig())).test_client()
        assert client.get("/health").get_json()["model_configured"] is True
