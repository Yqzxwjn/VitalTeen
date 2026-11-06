"""决策服务：把结构化请求变成可展示的判定。

这是整个后端的中枢，串起四件事：

1. **质量门** —— 数据不足以支撑判断时弃权，而不是硬给一个结论
2. **状态构造** —— 把请求变成 Laya 能读的文本（见 :mod:`app.state`）
3. **决策调用** —— ``choice`` 选主问题、``score`` 评严重度、``noul`` 出逐项门控
4. **方案择优** —— 从矫正方案库中选出适配当前问题与年龄的练习

## 降级路径必须自我标识

Laya 不可达（断网、服务没起来、超时）时走规则兜底：用组级统计直接推出主问题与
严重度，用方案库的确定性排序选出练习。这条路径让答辩现场断网也能演示。

但它产出的结论**不是模型的判断**，因此在 ``meta.decision_model_version`` 里
明确写成兜底标识。少了这个标识，事后没人分得清某个建议来自模型还是来自规则 ——
而这两者的可信度、可解释性、可以通过的验证方式完全不同。

## 评分是临时的，而且它自己知道

正式组级评级需要各错误码的权重与发生率-扣分曲线，这些属于待核定阈值
（设计文档 §7.3 第 11 条）。在核定之前，本服务基于**测量到的偏离幅度**算一个
参考分，并把 ``Scores.provisional`` 置为 True。

用一个自己编的权重冒充专业标准，是这类系统最不该犯的错。
"""

from __future__ import annotations

import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from .contracts import (
    DecisionFault,
    DecisionMeta,
    DecisionRequest,
    DecisionResponse,
    FaultEvidence,
    FaultRef,
    Message,
    PlanChoice,
    Scores,
)
from .laya import LayaClient, LayaResult, LayaUnavailableError, Question, QuestionType
from .plans import CorrectionPlan, PlanLibrary, default_library
from .state import build_state_lenient
from .taxonomy import fault_name


@dataclass(frozen=True, slots=True)
class DecisionSettings:
    """决策服务的**工程参数**（非体育阈值）。

    这些数字是技术选择，工程师可以调；它们不参与扣分，也不该出现在
    ``shared/thresholds/`` 里。改它们只需要看回归测试。

    Attributes:
        min_mean_visibility: 关键点平均可见性下限。低于它说明画面质量不足以
            支撑几何判定，直接弃权。
        min_coverage_ratio: 有效帧占比下限。丢帧太多意味着动作序列不完整，
            按它算出的最深膝角可能根本没采到。
        max_plans: 一次最多给几个矫正练习。给太多等于没给建议 ——
            用户需要的是「先做这三个」，不是一份清单。
        severity_labels: 严重度量表档位。对应 Laya 的 ``score`` 原语。
        severity_level_breakpoints: 把 0–1 的偏离幅度切成 1/2/3 档的切点。
            仅用于**没有模型输出时**的兜底推算。
        model_version: 记录了实际使用的决策模型标识，用于审计。
            应在部署时按真实配置设置，不要留默认值上生产。
        fallback_model_version: 规则兜底路径的标识。
        score_worst_weight: 临时评分里**最严重那一条**的权重。
        score_mean_weight: 临时评分里**其余各条平均**的权重。
        rating_cutoffs: 评级阶梯的下界，从高到低。``score >= cutoffs[0]`` 即
            ``rating_labels[0]``。
        rating_labels: 评级词，比 ``rating_cutoffs`` 多一个（最后一档没有下界）。

    **这里的每个数字都会随包发到手机端**（``shared/decision/rule_settings.json``）——
    端侧在连不上决策服务时用同一套参数在本机算出同一份报告。改这里的值必须重新
    导出并同步，否则手机断网时给出的结论会与服务端不一致，而那种不一致不会报错。
    """

    min_mean_visibility: float = 0.5
    min_coverage_ratio: float = 0.6
    max_plans: int = 3
    severity_labels: tuple[str, ...] = ("轻", "中", "重")
    severity_level_breakpoints: tuple[float, float] = (0.34, 0.67)
    model_version: str = "laya-multilingual"
    fallback_model_version: str = "rule-only"
    score_worst_weight: float = 0.6
    score_mean_weight: float = 0.4
    rating_cutoffs: tuple[int, ...] = (90, 80, 70, 60)
    rating_labels: tuple[str, ...] = ("优", "良", "中", "及格", "需改进")

    def __post_init__(self) -> None:
        """把配错的参数挡在启动期。

        用 ``raise`` 而不是 ``assert``：``python -O`` 会把 assert 整个去掉，
        而这几个约束破了，产物是**一份看起来正常、其实评级全错**的报告。
        """
        low, high = self.severity_level_breakpoints
        if not 0.0 < low < high < 1.0:
            raise ValueError(
                f"severity_level_breakpoints 必须严格递增且落在 (0,1)：{self.severity_level_breakpoints}"
            )
        if self.max_plans < 0:
            raise ValueError(f"max_plans 不能为负：{self.max_plans}")
        if len(self.rating_labels) != len(self.rating_cutoffs) + 1:
            raise ValueError(
                "rating_labels 必须比 rating_cutoffs 多一个（最后一档没有下界）："
                f"{len(self.rating_labels)} vs {len(self.rating_cutoffs)}"
            )
        if any(
            earlier <= later
            for earlier, later in zip(self.rating_cutoffs, self.rating_cutoffs[1:])
        ):
            raise ValueError(f"rating_cutoffs 必须严格递减：{self.rating_cutoffs}")
        total = self.score_worst_weight + self.score_mean_weight
        if not 0.0 < total <= 1.0 + 1e-9:
            raise ValueError(
                f"评分权重之和必须落在 (0,1]：{self.score_worst_weight} + {self.score_mean_weight}"
            )


class DecisionService:
    """决策服务。

    Args:
        laya: Laya 客户端。**为 ``None`` 时全部走规则兜底** ——
            这是开发期与降级演练的合法配置，不是错误状态。
        plans: 矫正方案库。
        settings: 工程参数。
    """

    def __init__(
        self,
        *,
        laya: LayaClient | None = None,
        plans: PlanLibrary | None = None,
        settings: DecisionSettings | None = None,
    ) -> None:
        self._laya = laya
        self._plans = plans if plans is not None else default_library()
        self._settings = settings or DecisionSettings()

    @property
    def is_model_configured(self) -> bool:
        """是否配置了决策模型。未配置时全部结论来自规则兜底。"""
        return self._laya is not None

    def model_reachable(self) -> bool:
        """探测决策模型是否可达。未配置时返回 ``False``。

        接口层通过它做深探测，无需知道内部持有什么客户端 ——
        暴露私有属性会让接口层与决策服务的内部结构绑死。
        """
        return self._laya.health() if self._laya is not None else False

    # ------------------------------------------------------------------
    # 对外接口
    # ------------------------------------------------------------------

    def decide(
        self,
        request: DecisionRequest,
        *,
        available_equipment: Sequence[str] = (),
    ) -> DecisionResponse:
        """产出一条决策。

        Args:
            available_equipment: 用户手头可用的器材。默认空 —— 假定在家徒手，
                因为学生大多数时候确实是在家练。
        """
        started = time.monotonic()

        problem = self._quality_problem(request)
        if problem is not None:
            return self._abstain(request, problem, started)

        # 规则引擎一个候选都没触发：动作没问题，无需调用模型。
        if not request.candidates:
            return self._clean_response(request, started)

        state, state_degraded = build_state_lenient(request)
        plan_candidates = self._plan_candidates(request, available_equipment)

        if self._laya is None:
            return self._rule_only(request, plan_candidates, state_degraded, started)

        try:
            return self._via_laya(request, state, plan_candidates, state_degraded, started)
        except LayaUnavailableError:
            # 断网或服务未启动。答辩现场靠这条路径保命 —— 降级不是失败，
            # 但必须让下游知道结论来自规则而不是模型。
            return self._rule_only(request, plan_candidates, state_degraded, started)

    # ------------------------------------------------------------------
    # 质量门
    # ------------------------------------------------------------------

    def _quality_problem(self, request: DecisionRequest) -> str | None:
        """数据质量是否足以支撑判断。返回弃权理由，或 ``None`` 表示可以判断。"""
        quality = request.pose_quality
        if quality.mean_visibility < self._settings.min_mean_visibility:
            return f"关键点可见性过低（{quality.mean_visibility:.2f}），画面质量不足以判断动作"
        if quality.coverage_ok_ratio < self._settings.min_coverage_ratio:
            return f"有效帧占比过低（{quality.coverage_ok_ratio:.2f}），动作序列不完整"
        if request.set.rep_count == 0:
            return "本组未记录到任何完整动作"
        return None

    def _abstain(self, request: DecisionRequest, reason: str, started: float) -> DecisionResponse:
        return DecisionResponse(
            request_id=request.request_id,
            status="abstain",
            abstain_reason=reason,
            meta=self._meta(request, started, model=self._settings.fallback_model_version),
        )

    def _clean_response(self, request: DecisionRequest, started: float) -> DecisionResponse:
        """没有触发任何候选错误 —— 这是一条**有效结论**，不是数据缺失。"""
        return DecisionResponse(
            request_id=request.request_id,
            status="ok",
            faults=[],
            gates={},
            scores=Scores(
                form_score=100, rating=self._settings.rating_labels[0], provisional=True
            ),
            # 与常规路径**共用同一个拼装函数**。这里早先自己拼 template_id，
            # 拼出 `msg_squat_clean_v1`，而 `_build_message` 给的是
            # `msg_squat_clean_teen_v1` —— 同一种情形两个 ID，端侧的模板表
            # 至多命中其中一个，另一个静默落进兜底文案。合成一处就不会再分叉。
            message=self._build_message(request, None, False),
            # 本条路径在构造 state **之前**就返回了，从未调用过决策模型，
            # 因此必须与 `_abstain` / `_rule_only` 一样记兜底标识。
            # 记成 `model_version` 会让一份纯规则的结论被下游当成模型判断 ——
            # 端侧正是靠这个字段决定要不要披露「未经模型判断」。
            meta=self._meta(request, started, model=self._settings.fallback_model_version),
        )

    # ------------------------------------------------------------------
    # 方案候选
    # ------------------------------------------------------------------

    def _plan_candidates(
        self, request: DecisionRequest, available_equipment: Sequence[str]
    ) -> tuple[tuple[CorrectionPlan, ...], bool]:
        """按候选错误码与年龄检索方案。返回 ``(方案, 是否含未核定)``。"""
        codes = [candidate.code for candidate in request.candidates]
        return self._plans.for_faults_with_review_fallback(
            codes,
            age=request.context.age,
            available_equipment=available_equipment,
            limit=self._settings.max_plans,
        )

    # ------------------------------------------------------------------
    # Laya 路径
    # ------------------------------------------------------------------

    def _via_laya(
        self,
        request: DecisionRequest,
        state: Mapping[str, object],
        plan_candidates: tuple[tuple[CorrectionPlan, ...], bool],
        state_degraded: bool,
        started: float,
    ) -> DecisionResponse:
        plans, plans_unreviewed = plan_candidates
        labels = {
            candidate.code: f"{fault_name(candidate.code)}（{candidate.code}）"
            for candidate in request.candidates
        }
        code_of_label = {label: code for code, label in labels.items()}

        questions = self._build_questions(request, labels, plans)
        assert self._laya is not None  # 由 decide() 保证
        result = self._laya.decide(state, questions)

        primary_code = self._pick_primary(request, result, code_of_label)
        faults = self._build_faults(request, result)
        gates = self._build_gates(request, result)

        # 主问题的严重度档位采用模型的判断：它对「整体有多严重」的回答比逐项测量
        # 更贴近人的感知。逐项的 severity_score 仍来自测量值，不被覆盖 ——
        # 那是可复现、可解释的数字，不该被模型的不稳定输出替换掉。
        model_level = self._severity_level(request, result, primary_code)
        faults = [
            # DecisionFault 是 Pydantic 模型而非 dataclass，
            # 复制走 model_copy(update=...) 而不是 dataclasses.replace。
            fault.model_copy(update={"severity_level": model_level})
            if fault.code == primary_code
            else fault
            for fault in faults
        ]

        return DecisionResponse(
            request_id=request.request_id,
            status="ok",
            primary_fault=(
                FaultRef(code=primary_code, name=fault_name(primary_code))
                if primary_code
                else None
            ),
            faults=faults,
            gates=gates,
            scores=self._provisional_scores(faults),
            choice=self._build_choice(result, plans, plans_unreviewed),
            message=self._build_message(request, primary_code, state_degraded),
            meta=self._meta(
                request,
                started,
                model=self._settings.model_version,
                result=result,
            ),
        )

    def _build_questions(
        self,
        request: DecisionRequest,
        labels: Mapping[str, str],
        plans: Sequence[CorrectionPlan],
    ) -> list[Question]:
        """构造问题集。

        **选项标签带上代码**（``膝内扣（KNEE_VALGUS）``）而不是只用中文名：
        中文名便于多语言权重理解，代码保证回映射无歧义。只写中文名的话，
        两个错误码若翻译相近就会张冠李戴；只写代码则白白浪费了模型的语言能力。
        """
        questions: list[Question] = []

        if request.candidates:
            # 只有一个候选时不存在「选择」这回事：主问题已被规则引擎唯一确定，
            # 再问模型一次既浪费一次调用，又违反 choice 原语的选项数下限（2）。
            # 此时 _pick_primary 会自然退回规则结论。
            if len(request.candidates) >= 2:
                questions.append(
                    Question(
                        key="primary_fault",
                        type=QuestionType.CHOICE,
                        instructions="以下哪一个是最需要优先纠正的问题？",
                        options=tuple(labels[c.code] for c in request.candidates),
                    )
                )
            questions.append(
                Question(
                    key="severity",
                    type=QuestionType.SCORE,
                    instructions="该问题在本次动作中的严重程度属于哪一档？",
                    options=self._settings.severity_labels,
                )
            )
            for candidate in request.candidates:
                questions.append(
                    Question(
                        key=f"gate::{candidate.code}",
                        type=QuestionType.NOUL,
                        instructions=(
                            f"本次动作在「{fault_name(candidate.code)}」这一项上"
                            "是否达到规范要求？"
                        ),
                    )
                )

        # 同理：只有一个方案时无从选择，直接采用它即可。
        if len(plans) >= 2:
            questions.append(
                Question(
                    key="plan",
                    type=QuestionType.CHOICE,
                    instructions="以下哪一个矫正练习最适合该用户当前的首要问题？",
                    options=tuple(f"{plan.name_zh}（{plan.plan_id}）" for plan in plans),
                )
            )
        return questions

    def _pick_primary(
        self,
        request: DecisionRequest,
        result: LayaResult,
        code_of_label: Mapping[str, str],
    ) -> str | None:
        """确定主问题。

        模型给出的选项无法回映射时**退回规则排序**，而不是丢弃主问题 ——
        主问题是整份报告的标题，空着比不精确更糟。
        """
        answer = result.get("primary_fault")
        if answer is not None and answer.choice is not None:
            code = code_of_label.get(answer.choice)
            if code is None and answer.choice in code_of_label.values():
                code = answer.choice
            if code is not None:
                return code
        return self._rule_primary(request)

    def _rule_primary(self, request: DecisionRequest) -> str | None:
        """规则排序的主问题：**候选集内**命中次数最多者。

        必须限定在候选集内。候选集是封闭的（设计文档 §6.1）—— 决策层不得产出
        候选之外的错误码。``fault_stats`` 与 ``candidates`` 由不同代码路径产出，
        一旦不一致（例如端侧只升级了一半），让主问题落到候选集之外会直接违反
        响应契约：``primary_fault`` 必须出现在 ``faults`` 里，而 ``faults`` 是
        按候选集构造的。

        并列时 ``max`` 返回首个极大元素，顺序由候选集决定，因此结果确定可复现。
        """
        if not request.candidates:
            return None
        allowed = {candidate.code for candidate in request.candidates}
        stats = [stat for stat in request.set.fault_stats if stat.code in allowed]
        if not stats:
            # 组级统计与候选集完全不相交：退回候选集首项，至少保证契约成立。
            return request.candidates[0].code
        return max(stats, key=lambda stat: stat.count).code

    def _build_faults(
        self, request: DecisionRequest, result: LayaResult
    ) -> list[DecisionFault]:
        """组装错误列表。

        ``severity_score`` **取自测量值而不是模型输出**：``score`` 是 Laya 最弱的
        原语（第三方基准 SST-5 仅 0.372），让它直接给 0–100 的分值不稳定；
        而 ``severity_0_1`` 是领域层按超阈幅度算出来的，可复现、可解释。
        模型的判断力用在它擅长的地方（选哪一个是主问题），不用在它不擅长的地方。
        """
        severity = self._max_severity_by_code(request)
        reps_by_code = {
            stat.code: list(stat.reps) for stat in request.set.fault_stats
        }

        faults: list[DecisionFault] = []
        for candidate in request.candidates:
            code = candidate.code
            score_0_1 = self._severity_for(request, code, severity)
            faults.append(
                DecisionFault(
                    code=code,
                    name=fault_name(code),
                    severity_level=self._level_of(score_0_1),
                    severity_score=round(score_0_1 * 100),
                    confidence=self._confidence_for(request, result, code),
                    evidence=FaultEvidence(reps=reps_by_code.get(code, [])),
                )
            )
        return faults

    def _build_gates(
        self, request: DecisionRequest, result: LayaResult
    ) -> dict[str, bool]:
        """逐项达标门控（``noul`` 原语）。

        键名用 ``{CODE}_ok`` 而不是设计文档示例里的 ``depth_ok`` 这类短名：
        短名需要再维护一张错误码到短名的映射表，多一份会漂移的东西，
        而按代码拼出来的键天然与候选集一一对应。
        """
        gates: dict[str, bool] = {}
        for candidate in request.candidates:
            answer = result.get(f"gate::{candidate.code}")
            if answer is None or answer.noul is None:
                # 模型没给这一项：不猜。回到「该错误是否被触发」这个事实。
                gates[f"{candidate.code}_ok"] = False
                continue
            gates[f"{candidate.code}_ok"] = answer.noul >= 0.5
        return gates

    def _confidence_for(
        self, request: DecisionRequest, result: LayaResult, code: str
    ) -> float:
        """某条错误的置信度：模型对该门控的把握 × 数据质量。

        两个因子都不可省：模型很确信但关键点丢了一半，那确信没有意义。
        """
        answer = result.get(f"gate::{code}")
        model_conf = answer.confidence() if answer is not None else None
        if model_conf is None:
            model_conf = 0.5  # 未知时的中性值，不偏向任何一侧
        quality = min(request.pose_quality.mean_visibility, request.pose_quality.coverage_ok_ratio)
        return round(max(0.0, min(1.0, model_conf * quality)), 4)

    def _severity_level(
        self, request: DecisionRequest, result: LayaResult, primary_code: str | None
    ) -> int:
        """主问题的严重度档位。优先用模型输出，无法解析则退回测量值。"""
        answer = result.get("severity")
        if answer is not None and answer.score is not None:
            level = round(answer.score)
            if 1 <= level <= len(self._settings.severity_labels):
                return level
        if primary_code is None:
            return 1
        severity = self._max_severity_by_code(request)
        return self._level_of(self._severity_for(request, primary_code, severity))

    def _build_choice(
        self,
        result: LayaResult,
        plans: Sequence[CorrectionPlan],
        plans_unreviewed: bool,
    ) -> PlanChoice | None:
        """方案择优。

        模型在候选里挑**一个**最合适的，其余位置按方案库的确定性排序补齐 ——
        ``choice`` 原语一次只选一个，而用户需要的是一个三件事的小组合。
        补齐的那些不是模型的判断，但它们是按「覆盖多少目标错误」排出来的，
        排序依据可解释。
        """
        if not plans:
            return None

        ids = [plan.plan_id for plan in plans]
        answer = result.get("plan")
        selected: list[str] = []
        if answer is not None and answer.choice is not None:
            chosen = self._plan_id_from_label(answer.choice, plans)
            if chosen is not None:
                selected.append(chosen)
        for plan_id in ids:
            if len(selected) >= self._settings.max_plans:
                break
            if plan_id not in selected:
                selected.append(plan_id)

        if plans_unreviewed:
            dose_note = (
                "下列练习的**动作要领**有运动科学依据，但组次剂量尚未经体育专业成员核定，"
                "请以体育教师的意见为准。"
            )
        else:
            dose_note = "剂量见方案库；如在校期间出现疼痛请立即停止并告知教师。"

        return PlanChoice(
            selected_plan_ids=selected,
            selection_reason=self._selection_reason(plans, plans_unreviewed),
            dose_note=dose_note,
        )

    @staticmethod
    def _plan_id_from_label(label: str, plans: Sequence[CorrectionPlan]) -> str | None:
        for plan in plans:
            if plan.plan_id == label or f"{plan.name_zh}（{plan.plan_id}）" == label:
                return plan.plan_id
        return None

    @staticmethod
    def _selection_reason(plans: Sequence[CorrectionPlan], unreviewed: bool) -> str:
        goals = "；".join(plan.goal for plan in plans[:2])
        prefix = "（方案未核定，仅供参考）" if unreviewed else ""
        return f"{prefix}以覆盖当前主要问题为优先：{goals}" if goals else prefix or "按覆盖面排序"

    def _build_message(
        self,
        request: DecisionRequest,
        primary_code: str | None,
        state_degraded: bool,
    ) -> Message:
        """面向用户的文案。

        只输出**模板 ID 与参数**，不生成自由文本 ——
        青少年看到的每一句话都必须是人工审阅过的模板，不能是模型现场编的。
        """
        params: dict[str, str | int | float] = {
            "total": request.set.rep_count,
            "valid": request.set.valid_rep_count,
        }
        if primary_code is not None:
            params["primary"] = fault_name(primary_code)
            stat = next(
                (s for s in request.set.fault_stats if s.code == primary_code), None
            )
            if stat is not None:
                params["primary_count"] = stat.count
        if state_degraded:
            params["note"] = "部分明细因长度限制未纳入判断"

        template = (
            f"msg_{request.context.action_code.lower()}_"
            f"{(primary_code or 'clean').lower()}_teen_v1"
        )
        return Message(template_id=template, params=params)

    # ------------------------------------------------------------------
    # 规则兜底路径
    # ------------------------------------------------------------------

    def _rule_only(
        self,
        request: DecisionRequest,
        plan_candidates: tuple[tuple[CorrectionPlan, ...], bool],
        state_degraded: bool,
        started: float,
    ) -> DecisionResponse:
        """不调用模型的完整判定。

        主问题与严重度全部来自组级统计，数值上可能与模型路径不同 ——
        这不是缺陷，是两条路径本就不同。用 ``decision_model_version`` 区分它们，
        使任何一条历史记录都能追溯到它由谁产出。
        """
        plans, plans_unreviewed = plan_candidates
        severity = self._max_severity_by_code(request)
        reps_by_code = {stat.code: list(stat.reps) for stat in request.set.fault_stats}

        faults = [
            DecisionFault(
                code=candidate.code,
                name=fault_name(candidate.code),
                severity_level=self._level_of(
                    self._severity_for(request, candidate.code, severity)
                ),
                severity_score=round(
                    self._severity_for(request, candidate.code, severity) * 100
                ),
                confidence=round(
                    min(
                        request.pose_quality.mean_visibility,
                        request.pose_quality.coverage_ok_ratio,
                    ),
                    4,
                ),
                evidence=FaultEvidence(reps=reps_by_code.get(candidate.code, [])),
            )
            for candidate in request.candidates
        ]

        primary_code = self._rule_primary(request)
        gates = {f"{fault.code}_ok": False for fault in faults}

        selected = [plan.plan_id for plan in plans]
        choice = (
            PlanChoice(
                selected_plan_ids=selected,
                selection_reason=self._selection_reason(plans, plans_unreviewed),
                dose_note=(
                    "本建议由规则引擎按覆盖面排序产出（决策模型当时不可用）；"
                    "剂量待体育专业成员核定。"
                ),
            )
            if plans
            else None
        )

        return DecisionResponse(
            request_id=request.request_id,
            status="ok",
            primary_fault=(
                FaultRef(code=primary_code, name=fault_name(primary_code))
                if primary_code
                else None
            ),
            faults=faults,
            gates=gates,
            scores=self._provisional_scores(faults),
            choice=choice,
            message=self._build_message(request, primary_code, state_degraded),
            meta=self._meta(
                request,
                started,
                model=self._settings.fallback_model_version,
            ),
        )

    # ------------------------------------------------------------------
    # 共用计算
    # ------------------------------------------------------------------

    @staticmethod
    def _max_severity_by_code(request: DecisionRequest) -> dict[str, float | None]:
        """每个错误码在整组中的最大偏离幅度（0–1）；无偏离数据时为 ``None``。

        取最大而不是平均：报告应反映最坏情况，一次严重的膝内扣不该被九次轻微
        动作平摊掉。

        **``None`` 与 ``0.0`` 必须区分开。** 端侧可能只上报组级统计而不带逐次明细，
        此时偏离幅度是**未知**而不是零。把未知填成 0 会让一条确实存在的错误拿到
        零严重度，进而算出「形式评分 100 分、评级优」这种明显荒谬的结论 ——
        这正是设计文档铁律二禁止的降级填充。
        """
        worst: dict[str, float | None] = {}
        for rep in request.reps:
            for fault in rep.faults:
                for deviation in fault.deviations:
                    if deviation.severity_0_1 is None:
                        continue
                    current = worst.get(fault.code)
                    worst[fault.code] = (
                        deviation.severity_0_1
                        if current is None
                        else max(current, deviation.severity_0_1)
                    )
        for stat in request.set.fault_stats:
            worst.setdefault(stat.code, None)
        return worst

    def _severity_for(
        self, request: DecisionRequest, code: str, severity: Mapping[str, float | None]
    ) -> float:
        """某个错误码的严重程度（0–1）。

        优先用**偏离幅度** —— 它是领域层按超阈程度算出来的，可复现、可解释。

        缺少逐次明细时退回**出现率**：「10 次里犯了 3 次」本身就是一个严重程度
        信号，比当作 0 诚实得多，也比编一个数字有依据。这是**可以接受的近似**，
        而不是降级填充 —— 它用的是真实上报的数据，只是换了维度。

        两条数据都没有时才返回 0；那种情况下该错误码本就不该出现在候选集里。
        """
        value = severity.get(code)
        if value is not None:
            return value
        stat = next((s for s in request.set.fault_stats if s.code == code), None)
        if stat is None or request.set.rep_count <= 0:
            return 0.0
        return min(1.0, stat.count / request.set.rep_count)

    def _level_of(self, severity_0_1: float | None) -> int:
        """把 0–1 的偏离幅度切成 1/2/3 档。"""
        if severity_0_1 is None:
            return 1
        low, high = self._settings.severity_level_breakpoints
        if severity_0_1 < low:
            return 1
        if severity_0_1 < high:
            return 2
        return 3

    def _provisional_scores(self, faults: Sequence[DecisionFault]) -> Scores | None:
        """临时规范性评分。

        公式刻意简单且只用测量值：以最严重的问题为主（0.6 权重）、
        其余问题的平均为辅（0.4 权重）。权重来自待核定的评级表，
        因此结果标记为 ``provisional``。

        体育专业成员给出正式的 ``w_fault`` 与扣分曲线后，这里整体替换。
        """
        if not faults:
            return Scores(form_score=100, rating=self._settings.rating_labels[0], provisional=True)

        severities = [f.severity_score / 100 for f in faults]
        worst = max(severities)
        mean = sum(severities) / len(severities)
        penalty = (
            self._settings.score_worst_weight * worst + self._settings.score_mean_weight * mean
        )
        score = round(max(0.0, min(1.0, 1.0 - penalty)) * 100)
        return Scores(form_score=score, rating=self._rating_of(score), provisional=True)

    def _rating_of(self, score: int) -> str:
        """临时评级阶梯。正式切分属于待核定阈值（设计文档 §7.3 第 11 条）。

        切点与评级词都在 :class:`DecisionSettings` 里，因为手机端断网时要用同一套
        （见那里的类文档）。
        """
        for cutoff, label in zip(self._settings.rating_cutoffs, self._settings.rating_labels):
            if score >= cutoff:
                return label
        return self._settings.rating_labels[-1]

    def _meta(
        self,
        request: DecisionRequest,
        started: float,
        *,
        model: str,
        result: LayaResult | None = None,
    ) -> DecisionMeta:
        return DecisionMeta(
            decision_model_version=model,
            thresholds_version=request.thresholds_version,
            latency_ms=int((time.monotonic() - started) * 1000),
            shuffled=result.shuffled if result is not None else False,
            shuffle_seed=result.shuffle_seed if result is not None else None,
        )


__all__ = ["DecisionService", "DecisionSettings"]
