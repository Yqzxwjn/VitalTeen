"""VitalTeen 决策服务。

职责（对应开发计划里的 M3 模块）：

- 消费手机端产出的**结构化特征与规则判定**（不是视频，也不是关键点）
- 调用 Laya 决策模型完成 ``choice`` / ``score`` / ``noul`` 三种判断
- 从矫正方案库中择优，产出面向用户的文案与报告

**它不做什么**：不接触像素、不计算几何量、不发明阈值、不做医学诊断。
边界见 ``docs/domain-layer-design.md`` §6.1。

分层：

- :mod:`app.contracts` —— 三方共同遵守的请求/响应契约（可校验、可导出 JSON Schema）
- :mod:`app.laya` —— Laya 决策模型客户端，编码了三条来自实测的防御
"""

from __future__ import annotations

from .contracts import (
    MAX_CANDIDATES,
    MAX_PLAN_CANDIDATES,
    SCHEMA_VERSION,
    CandidateIn,
    DecisionContext,
    DecisionFault,
    DecisionMeta,
    DecisionRequest,
    DecisionResponse,
    FaultEvidence,
    FaultIn,
    FaultRef,
    FaultStatIn,
    Message,
    PlanChoice,
    PoseQuality,
    RepIn,
    Scores,
    SetIn,
)
from .laya import (
    Answer,
    LayaClient,
    LayaConfigError,
    LayaError,
    LayaProtocolError,
    LayaResult,
    LayaUnavailableError,
    Question,
    QuestionType,
)
from .plans import (
    CorrectionPlan,
    Dosage,
    PlanCategory,
    PlanLibrary,
    PlanStatus,
    default_library,
)
from .service import DecisionService, DecisionSettings
from .state import (
    MAX_STATE_CHARS,
    StateTooLongError,
    build_state,
    build_state_lenient,
    render_state_text,
)
from .taxonomy import fault_name, is_known

__version__ = "0.1.0"

__all__ = [
    "MAX_CANDIDATES",
    "MAX_PLAN_CANDIDATES",
    "MAX_STATE_CHARS",
    "SCHEMA_VERSION",
    "Answer",
    "CandidateIn",
    "CorrectionPlan",
    "DecisionContext",
    "DecisionFault",
    "DecisionMeta",
    "DecisionRequest",
    "DecisionResponse",
    "DecisionService",
    "DecisionSettings",
    "Dosage",
    "FaultEvidence",
    "FaultIn",
    "FaultRef",
    "FaultStatIn",
    "LayaClient",
    "LayaConfigError",
    "LayaError",
    "LayaProtocolError",
    "LayaResult",
    "LayaUnavailableError",
    "Message",
    "PlanCategory",
    "PlanChoice",
    "PlanLibrary",
    "PlanStatus",
    "PoseQuality",
    "Question",
    "QuestionType",
    "RepIn",
    "Scores",
    "SetIn",
    "StateTooLongError",
    "__version__",
    "build_state",
    "build_state_lenient",
    "default_library",
    "fault_name",
    "is_known",
    "render_state_text",
]
