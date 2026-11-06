"""HTTP 接口层。

手机端与 Web 大屏通过这里访问决策服务。

## 不要重复 laya-serve 的错误

调研发现 ``laya-serve`` 出厂监听 ``0.0.0.0:8000`` 且**不带任何鉴权** ——
局域网内任何人都能调用它。本服务在客户端一侧已经拒绝过「指向非回环地址却不给
API key」的配置（见 :class:`~app.laya.LayaClient`），自己的接口层当然不能犯同样的
毛病：

- 默认只绑 ``127.0.0.1``
- 绑非回环地址时**必须**配置 ``VITALTEEN_API_KEY``，否则拒绝启动
- 配了 key 之后 ``/v1/decide`` 需要 ``Authorization: Bearer <key>``

``/health`` 不要求鉴权：探活接口是给监控和负载均衡用的，加鉴权只会让它们没法工作，
而它不返回任何用户数据。

## 请求体校验在入口完成

契约校验失败返回 **400 且带上具体字段错误**，不要让它进到业务逻辑里再炸 ——
端侧拿到「哪个字段错了」远比拿到一个 500 有用。这也是请求体用 Pydantic 模型
而不是字典的原因之一。
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Any

from flask import Flask, Response, jsonify, request
from pydantic import ValidationError

from .contracts import DecisionRequest
from .laya import LayaClient, LayaConfigError
from .service import DecisionService

logger = logging.getLogger(__name__)

DEFAULT_PORT = 8080
_LOOPBACK = frozenset({"127.0.0.1", "localhost", "::1", ""})


@dataclass(frozen=True, slots=True)
class ApiConfig:
    """接口层配置。全部可用环境变量覆盖。"""

    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    api_key: str | None = None

    laya_base_url: str = "http://127.0.0.1:8000"
    laya_api_key: str | None = None
    laya_timeout_s: float = 5.0
    laya_options_field: str = "options"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> ApiConfig:
        source = os.environ if env is None else env
        return cls(
            host=source.get("VITALTEEN_HOST", "127.0.0.1"),
            port=int(source.get("VITALTEEN_PORT", DEFAULT_PORT)),
            api_key=source.get("VITALTEEN_API_KEY") or None,
            laya_base_url=source.get("LAYA_BASE_URL", "http://127.0.0.1:8000"),
            laya_api_key=source.get("LAYA_API_KEY") or None,
            laya_timeout_s=float(source.get("LAYA_TIMEOUT_S", "5.0")),
            laya_options_field=source.get("LAYA_OPTIONS_FIELD", "options"),
        )

    def check_bind_safety(self) -> None:
        """绑非回环地址却没有 API key 时拒绝启动。

        Raises:
            LayaConfigError: 配置不安全。**刻意在启动期抛出而不是运行期**——
                一个暴露在局域网上、没有鉴权、还会返回未成年人身体数据的服务，
                不能等到被人访问了才发现。
        """
        if self.host not in _LOOPBACK and not self.api_key:
            raise LayaConfigError(
                f"host={self.host!r} 监听非回环地址，但未配置 VITALTEEN_API_KEY。"
                "本服务会返回用户（多为未成年人）的身体姿态判定结果，"
                "裸奔在局域网上是不可接受的。请配置 API key 或反向代理后再对外监听。"
            )


def build_service(config: ApiConfig) -> DecisionService:
    """按配置装配决策服务。

    Laya 客户端构造失败（例如地址配置不当）时**不阻断启动**：服务会以
    规则兜底模式运行。这是刻意的 —— 答辩现场若决策模型没起来，整个后端仍然可用，
    只是响应里会写明结论来自规则而不是模型。
    """
    try:
        laya: LayaClient | None = LayaClient(
            config.laya_base_url,
            api_key=config.laya_api_key,
            timeout_s=config.laya_timeout_s,
            options_field=config.laya_options_field,
        )
    except LayaConfigError:
        logger.warning("Laya 客户端配置不合法，将以规则兜底模式运行", exc_info=True)
        laya = None
    # 方案库用内置种子库（当前全为 draft，会走「未核定」回退路径并在剂量说明里标注）。
    return DecisionService(laya=laya)


def _json_error(message: str, status: int, **extra: Any) -> tuple[Response, int]:
    payload: dict[str, Any] = {"error": message}
    payload.update(extra)
    return jsonify(payload), status


def _authorised(config: ApiConfig) -> bool:
    if not config.api_key:
        return True
    header = request.headers.get("Authorization", "")
    expected = f"Bearer {config.api_key}"
    # 比较长度再比较内容意义不大（时序攻击在局域网演示场景下不是威胁模型），
    # 但用 hmac.compare_digest 成本极低，没有理由不做。
    import hmac

    return hmac.compare_digest(header, expected)


def create_app(
    config: ApiConfig | None = None,
    *,
    service: DecisionService | None = None,
) -> Flask:
    """建立 Flask 应用。

    Args:
        config: 接口层配置。``None`` 时从环境变量读取。
        service: 注入的决策服务。**测试时注入假服务**，从而把接口层的行为
            （鉴权、校验、错误码）与决策逻辑分开验证。
    """
    cfg = config or ApiConfig.from_env()
    decision_service = service if service is not None else build_service(cfg)

    app = Flask(__name__)
    app.config["VITALTEEN"] = cfg

    @app.get("/health")
    def health() -> tuple[Response, int]:
        """探活。

        ``?deep=1`` 时额外探测决策模型是否可达 —— 默认**不做**深探测：
        一个会卡住的健康检查比没有健康检查更糟。深探测带超时，
        由调用方按需选择。
        """
        payload: dict[str, Any] = {
            "status": "ok",
            "model_configured": decision_service.is_model_configured,
            "model_reachable": None,
        }
        if request.args.get("deep") in {"1", "true", "yes"}:
            payload["model_reachable"] = decision_service.model_reachable()
        return jsonify(payload), 200

    @app.post("/v1/decide")
    def decide() -> tuple[Response, int]:
        if not _authorised(cfg):
            return _json_error("unauthorized", 401)

        payload = request.get_json(silent=True)
        if payload is None:
            return _json_error(
                "invalid_request",
                400,
                detail="请求体不是合法 JSON，或 Content-Type 不是 application/json",
            )

        try:
            decision_request = DecisionRequest.model_validate(payload)
        except ValidationError as exc:
            # 逐字段回报，端侧能直接定位 —— 这是把校验放在入口而不是业务里的全部意义
            return _json_error(
                "invalid_request",
                400,
                detail=[
                    {"field": ".".join(str(p) for p in err["loc"]), "message": err["msg"]}
                    for err in exc.errors()
                ],
            )

        equipment = request.args.getlist("equipment")
        try:
            response = decision_service.decide(
                decision_request, available_equipment=equipment
            )
        except Exception:
            logger.exception("决策过程发生未预期错误：request_id=%s", decision_request.request_id)
            return _json_error("internal_error", 500)

        return jsonify(response.model_dump(mode="json")), 200

    @app.errorhandler(404)
    def not_found(_exc: Exception) -> tuple[Response, int]:
        return _json_error("not_found", 404)

    @app.errorhandler(405)
    def method_not_allowed(_exc: Exception) -> tuple[Response, int]:
        return _json_error("method_not_allowed", 405)

    return app


def main() -> int:
    """启动服务。``python -m app.api``"""
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    cfg = ApiConfig.from_env()
    cfg.check_bind_safety()
    app = create_app(cfg)
    logger.info("决策服务启动于 http://%s:%d（按 Ctrl-C 停止）", cfg.host, cfg.port)
    app.run(host=cfg.host, port=cfg.port, debug=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["ApiConfig", "build_service", "create_app", "main"]
