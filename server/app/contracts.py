"""决策层接口契约（设计文档 §6.2 / §6.3 的可执行版本）。

这份契约是**三方的共同边界**：

- **手机端**（Dart）产出请求体：把领域层算出的特征与规则判定交上来
- **决策服务**（本模块）消费请求体，调用 Laya，产出响应体
- **Web 大屏与报告**消费响应体

因此它必须比普通内部数据类更严格：字段缺失、数值越界、候选集过大都要在**入口**
被拦下，而不是等 Laya 返回了一个莫名其妙的答案再回头猜哪里出了问题。

**候选集大小是被强制的，不是被建议的。** Laya 在选项数超过约 20 后准确率急剧下降
（第三方基准：Banking77 的 77 标签任务仅 0.425，而 Jev 为 0.870）。这个上限写进
校验里，让「不小心把候选集写大了」变成一个启动即失败的显式错误。

**这里不做任何体育判断。** 契约只管结构，阈值与严重度分档来自阈值表
（``shared/thresholds/``），由体育专业成员核定。
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

SCHEMA_VERSION = "1.0"

#: 候选集上限。超过它 Laya 的准确率会急剧退化 —— 这是评估结论，不是保守估计。
MAX_CANDIDATES = 20

#: 矫正方案候选上限。选方案的判断比选错误类型更依赖上下文，留出更窄的窗口。
MAX_PLAN_CANDIDATES = 10

PoseBackend = Literal["mlkit", "mediapipe"]
CameraViewName = Literal["frontal", "sagittal", "oblique45"]
DecisionStatus = Literal["ok", "abstain"]


class _Strict(BaseModel):
    """禁止未声明字段。

    Laya 的字段名发生过破坏性变更（``options`` → ``criteria``），本项目的契约同样
    会演进。多出一个字段时立刻报错，好过静默忽略 —— 静默忽略会让「端侧发了新字段、
    服务端还在用旧逻辑」这种不一致一直藏着，直到某个结果明显不对才被发现。
    """

    model_config = {"extra": "forbid"}


# ==========================================================================
# 请求体
# ==========================================================================


class DecisionContext(_Strict):
    """谁、在什么条件下做的这组动作。

    年龄/性别/国标组别会影响阈值版本与方案适用性；``has_world_landmarks`` 决定
    哪些特征根本不可用 —— 它同时是决策层判断「该不该弃权」的依据。
    """

    sex: Literal["male", "female"]
    age: int = Field(ge=5, le=25)
    grade: str = Field(min_length=1, max_length=20)
    standard_group: str = Field(min_length=1, max_length=20)
    action_code: str = Field(min_length=1, max_length=32)
    action_variant: str = Field(default="standard", max_length=32)
    camera_view: CameraViewName
    pose_backend: PoseBackend
    has_world_landmarks: bool


class PoseQuality(_Strict):
    """姿态数据本身有多可信。用于置信度折算与弃权判断。"""

    mean_visibility: float = Field(ge=0.0, le=1.0)
    coverage_ok_ratio: float = Field(ge=0.0, le=1.0)
    fps_mean: float = Field(gt=0.0)
    gap_max_ms: int = Field(ge=0)
    view_confidence: float = Field(ge=0.0, le=1.0)


class FaultStatIn(_Strict):
    """组级统计中的一个错误码。"""

    code: str = Field(min_length=1, max_length=48)
    reps: list[int] = Field(default_factory=list)
    count: int = Field(ge=0)

    @model_validator(mode="after")
    def _count_matches_reps(self) -> FaultStatIn:
        if self.reps and self.count != len(self.reps):
            raise ValueError(f"{self.code}: count={self.count} 与 reps 长度 {len(self.reps)} 不符")
        return self


class SetIn(_Strict):
    """一组动作的聚合结果。决策层真正关心的粒度就是它。"""

    rep_count: int = Field(ge=0)
    valid_rep_count: int = Field(ge=0)
    tempo_mean_ms: float | None = Field(default=None, ge=0.0)
    rom_mean_deg: float | None = None
    symmetry_index_mean: float | None = Field(default=None, ge=0.0)

    fault_stats: list[FaultStatIn] = Field(default_factory=list)

    @model_validator(mode="after")
    def _valid_not_exceeding_total(self) -> SetIn:
        if self.valid_rep_count > self.rep_count:
            raise ValueError(
                f"valid_rep_count({self.valid_rep_count}) 不能大于 rep_count({self.rep_count})"
            )
        return self


class DeviationIn(_Strict):
    """一次偏离的量化描述。原样来自领域层，决策层只读不改。"""

    feature: str = Field(min_length=1, max_length=48)
    measured: float
    threshold: float
    delta_signed: float
    severity_0_1: float | None = Field(default=None, ge=0.0, le=1.0)


class FaultIn(_Strict):
    """rep 级的一条错误判定。"""

    code: str = Field(min_length=1, max_length=48)
    confidence: float = Field(ge=0.0, le=1.0)
    evidence_frames: list[int] = Field(default_factory=list)
    deviations: list[DeviationIn] = Field(default_factory=list)


class RepIn(_Strict):
    """一次 rep 的完整记录。"""

    index: int = Field(ge=1)
    duration_ms: int = Field(ge=0)
    phases_ms: dict[str, int] = Field(default_factory=dict)
    metrics: dict[str, float | None] = Field(default_factory=dict)
    faults: list[FaultIn] = Field(default_factory=list)

    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    """本次动作的数据可信度。``None`` 表示**未提供**，不是「可信度为零」。

    端侧有时只有组级汇总、拿不到逐次置信度。此时留 ``None`` 比填一个 1.0 诚实 ——
    填 1.0 是在声称「这次动作的数据完全可信」，而那个结论没有任何依据。
    """


class CandidateIn(_Strict):
    """候选错误码。

    **这是一个封闭集**：决策层只能从候选里挑，不得新增候选之外的错误码。
    封闭性是「决策层不做像素级识别」这条职责边界的执行方式 ——
    如果它可以凭空发明一个错误类型，那它就不再是在做判断，而是在做检测。
    """

    code: str = Field(min_length=1, max_length=48)
    triggered_by_rule: str = Field(default="", max_length=200)


class DecisionRequest(_Strict):
    """一次决策请求。"""

    request_id: str = Field(min_length=1, max_length=64)

    schema_version: str = Field(min_length=1, max_length=16)
    """端侧所遵循的契约版本。

    **必填，刻意不给默认值。** 给了默认值，一个陈旧的客户端漏传时会被静默
    当作「当前版本」处理 —— 而它很可能正是版本不匹配的那一个。要求显式声明，
    才能让不匹配变成一条清晰的 400，而不是一次难以定位的解析错误。
    """

    context: DecisionContext
    pose_quality: PoseQuality
    set: SetIn
    reps: list[RepIn] = Field(default_factory=list)
    candidates: list[CandidateIn] = Field(
        default_factory=list,
        # 上限由下面的字段校验器强制（它给出的错误信息更可操作），这里额外把它
        # 同步进 JSON Schema —— 否则端侧照着 schema 生成的模型会漏掉这条约束，
        # 只能等把 25 个候选发到服务端才发现。而这条上限不是建议：
        # Laya 在选项数超过约 20 后准确率急剧下降。
        json_schema_extra={"maxItems": MAX_CANDIDATES},
    )

    #: 本次判定所依据的阈值表版本。**审计必需** —— 没有它，一个历史决策
    #: 无法被复现，因为阈值已经升版了。
    thresholds_version: str = Field(min_length=1, max_length=32)

    @field_validator("candidates")
    @classmethod
    def _candidates_within_limit(cls, value: list[CandidateIn]) -> list[CandidateIn]:
        if len(value) > MAX_CANDIDATES:
            raise ValueError(
                f"候选集有 {len(value)} 项，超过上限 {MAX_CANDIDATES}。"
                "Laya 在选项数超过约 20 后准确率急剧下降，请合并同类错误码或分批决策。"
            )
        seen = [c.code for c in value]
        if len(seen) != len(set(seen)):
            raise ValueError(f"候选集出现重复错误码：{sorted(seen)}")
        return value


# ==========================================================================
# 响应体
# ==========================================================================


class FaultEvidence(_Strict):
    """一条错误的证据摘要。"""

    reps: list[int] = Field(default_factory=list)
    metric: str | None = None
    mean_deviation: float | None = None


class DecisionFault(_Strict):
    """决策层对一条错误给出的判定。"""

    code: str
    name: str
    severity_level: int = Field(ge=1, le=3)
    """1=轻 2=中 3=重。分档切点来自阈值表，未经核定则不应产出本结构。"""

    severity_score: int = Field(ge=0, le=100)
    confidence: float = Field(ge=0.0, le=1.0)
    evidence: FaultEvidence = Field(default_factory=FaultEvidence)


class FaultRef(_Strict):
    """对某个错误码的引用。"""

    code: str
    name: str


class Scores(_Strict):
    """规范性评分。

    **只描述动作质量，永不冒充国标得分。** 国标得分只能在有成绩值时按官方评分表
    计算，两条链路严格分开（设计文档 §5.5）。
    """

    form_score: int = Field(ge=0, le=100)
    rating: str = Field(min_length=1, max_length=8)

    provisional: bool = False
    """该评分是否为**临时算法**产出。

    正式的组级评级需要各错误码的权重 ``w_fault`` 与发生率-扣分曲线，而这些属于
    待体育专业成员核定的阈值（设计文档 §7.3 第 11 条）。在核定之前，服务可以基于
    测量到的偏离幅度算一个参考分，但**必须自报家门** ——
    把临时分当成正式评级展示，等于用一个我们自己编的权重冒充专业标准。
    """


class PlanChoice(_Strict):
    """从矫正方案候选集中选出的方案。"""

    selected_plan_ids: list[str] = Field(default_factory=list, max_length=3)
    selection_reason: str = Field(default="", max_length=500)
    dose_note: str = Field(default="", max_length=300)


class Message(_Strict):
    """面向用户展示的文案。

    只给**模板 ID 与参数**，不让模型生成自由文本 ——
    这既避开了 Laya 不擅长生成长文本的事实，也保证了青少年用户看到的每一句话
    都经过人工审阅，不会出现模型编造的医学建议。
    """

    template_id: str = Field(min_length=1, max_length=64)
    params: dict[str, str | int | float] = Field(default_factory=dict)


class DecisionMeta(_Strict):
    """本次决策的元信息，用于审计与复现。"""

    decision_model_version: str = Field(default="", max_length=64)
    thresholds_version: str = Field(min_length=1, max_length=32)
    latency_ms: int = Field(ge=0)
    shuffled: bool = False
    """候选顺序是否被打乱。

    **只要调用了 Laya，就必须为 True** —— Laya 存在位置偏差（曾有「50 道多选题有
    46 道选 A」的报告），不打乱就无法排除顺序效应。

    规则兜底路径不调用模型，因此为 False；此时 ``decision_model_version`` 会是
    兜底标识，两者的组合能唯一确定本次判定是怎么来的。"""

    shuffle_seed: int | None = None


class DecisionResponse(_Strict):
    """一次决策响应。"""

    request_id: str
    status: DecisionStatus

    abstain_reason: str | None = Field(default=None, max_length=200)
    """``status=abstain`` 时说明原因。宁可弃权也不编造确定性 —— 当数据质量不足以
    支撑判断时，诚实地说「这组数据不足以评价」比给一个看似确定的结论更有价值。"""

    primary_fault: FaultRef | None = None
    faults: list[DecisionFault] = Field(default_factory=list)
    gates: dict[str, bool] = Field(default_factory=dict)
    scores: Scores | None = None
    choice: PlanChoice | None = None
    message: Message | None = None
    meta: DecisionMeta

    @model_validator(mode="after")
    def _abstain_requires_reason(self) -> DecisionResponse:
        if self.status == "abstain" and not self.abstain_reason:
            raise ValueError("status=abstain 时必须说明 abstain_reason")
        if self.status == "ok" and self.abstain_reason:
            raise ValueError("status=ok 时不应带 abstain_reason")
        return self

    @model_validator(mode="after")
    def _primary_fault_must_be_in_faults(self) -> DecisionResponse:
        if self.primary_fault is None:
            return self
        known = {f.code for f in self.faults}
        if self.primary_fault.code not in known:
            raise ValueError(
                f"primary_fault={self.primary_fault.code} 不在 faults 列表中：{sorted(known)}"
            )
        return self


__all__ = [
    "MAX_CANDIDATES",
    "MAX_PLAN_CANDIDATES",
    "SCHEMA_VERSION",
    "CandidateIn",
    "DecisionContext",
    "DecisionFault",
    "DecisionMeta",
    "DecisionRequest",
    "DecisionResponse",
    "DeviationIn",
    "FaultEvidence",
    "FaultIn",
    "FaultRef",
    "FaultStatIn",
    "Message",
    "PlanChoice",
    "PoseQuality",
    "RepIn",
    "Scores",
    "SetIn",
]
