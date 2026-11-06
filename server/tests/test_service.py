"""决策服务测试。

**为什么用鸭子类型的假客户端而不是假 HTTP 会话**

Laya 客户端本身已被 ``test_laya.py`` 覆盖（含超时、字段漂移、下标回映射等）。
这里要验证的是**服务层的编排逻辑**：质量门、问题构造、降级路径、评分、
以及「结论到底是谁产出的」这个可追溯性问题。再套一层 HTTP 桩只会让失败信息
变模糊 —— 一个断言失败时，你分不清是编排错了还是桩返回错了。

其中 ``TestFallbackLabelling`` 守的是最重要的一条：**降级路径必须自我标识**。
少了这个标识，事后没人分得清某个建议来自模型还是来自规则，而这两者的可信度与
验证方式完全不同。
"""

from __future__ import annotations

from typing import Any

import pytest

from app.contracts import DecisionRequest
from app.laya import Answer, LayaResult, LayaUnavailableError, QuestionType
from app.plans import CorrectionPlan, Dosage, PlanCategory, PlanLibrary, PlanStatus
from app.service import DecisionService, DecisionSettings
from app.taxonomy import fault_name


class FakeLaya:
    """鸭子类型的假决策客户端。"""

    def __init__(
        self,
        answers: dict[str, Answer] | None = None,
        *,
        raises: Exception | None = None,
        shuffled: bool = True,
        seed: int | None = 42,
    ) -> None:
        self.answers = answers or {}
        self.raises = raises
        self.shuffled = shuffled
        self.seed = seed
        self.calls: list[tuple[dict[str, Any], list[Any]]] = []

    def decide(self, state: Any, questions: Any) -> LayaResult:
        self.calls.append((dict(state), list(questions)))
        if self.raises is not None:
            raise self.raises
        return LayaResult(
            answers=self.answers,
            latency_ms=12,
            shuffled=self.shuffled,
            shuffle_seed=self.seed if self.shuffled else None,
        )


def make_plan(
    plan_id: str,
    faults: tuple[str, ...],
    *,
    status: PlanStatus = PlanStatus.ACTIVE,
    difficulty: int = 2,
) -> CorrectionPlan:
    return CorrectionPlan(
        plan_id=plan_id,
        name_zh=f"练习{plan_id}",
        category=PlanCategory.STRENGTHENING,
        target_fault_codes=faults,
        goal="测试用目标",
        instructions=("第一步",),
        key_cues=("提示",),
        dosage=Dosage(),
        equipment=(),
        difficulty=difficulty,
        age_min=10,
        age_max=20,
        grade_fit=("初中",),
        contraindications=("疼痛时停止",),
        evidence_refs=("测试来源",),
        status=status,
    )


def active_library() -> PlanLibrary:
    return PlanLibrary(
        [
            make_plan("COR_A", ("KNEE_VALGUS", "INSUFFICIENT_DEPTH"), difficulty=1),
            make_plan("COR_B", ("KNEE_VALGUS",), difficulty=2),
            make_plan("COR_C", ("KNEE_VALGUS",), difficulty=3),
        ]
    )


def gates(ok: bool = True) -> dict[str, Answer]:
    return {
        "gate::KNEE_VALGUS": Answer(
            key="gate::KNEE_VALGUS", type=QuestionType.NOUL, noul=0.8 if ok else 0.1
        ),
        "gate::INSUFFICIENT_DEPTH": Answer(
            key="gate::INSUFFICIENT_DEPTH", type=QuestionType.NOUL, noul=0.7 if ok else 0.2
        ),
    }


def primary_answer(code: str, probability: float = 0.8) -> Answer:
    label = f"{fault_name(code)}（{code}）"
    return Answer(
        key="primary_fault",
        type=QuestionType.CHOICE,
        choice=label,
        choice_probabilities={label: probability},
    )


def severity_answer(level: float) -> Answer:
    return Answer(key="severity", type=QuestionType.SCORE, score=level)


def plan_answer(plan: CorrectionPlan) -> Answer:
    label = f"{plan.name_zh}（{plan.plan_id}）"
    return Answer(
        key="plan", type=QuestionType.CHOICE, choice=label, choice_probabilities={label: 0.9}
    )


def service_with(
    *,
    laya: FakeLaya | None = None,
    library: PlanLibrary | None = None,
    settings: DecisionSettings | None = None,
) -> DecisionService:
    return DecisionService(laya=laya, plans=library or active_library(), settings=settings)


# --------------------------------------------------------------------------
# 质量门
# --------------------------------------------------------------------------


class TestQualityGate:
    def test_low_visibility_abstains(self, request_factory) -> None:
        request = request_factory(
            pose_quality={
                "mean_visibility": 0.2,
                "coverage_ok_ratio": 0.98,
                "fps_mean": 28.4,
                "gap_max_ms": 180,
                "view_confidence": 0.9,
            }
        )
        response = service_with().decide(request)
        assert response.status == "abstain"
        assert response.abstain_reason is not None
        assert "可见性" in response.abstain_reason

    def test_low_coverage_abstains(self, request_factory) -> None:
        request = request_factory(
            pose_quality={
                "mean_visibility": 0.9,
                "coverage_ok_ratio": 0.1,
                "fps_mean": 28.4,
                "gap_max_ms": 180,
                "view_confidence": 0.9,
            }
        )
        response = service_with().decide(request)
        assert response.status == "abstain"
        assert response.abstain_reason is not None
        assert "有效帧" in response.abstain_reason

    def test_zero_reps_abstains(self, request_factory) -> None:
        """一次完整动作都没有 —— 没有任何东西可评价，弃权是唯一诚实的回答。"""
        request = request_factory(
            set={"rep_count": 0, "valid_rep_count": 0, "fault_stats": []},
            candidates=[],
        )
        response = service_with().decide(request)
        assert response.status == "abstain"
        assert response.abstain_reason is not None

    def test_abstain_never_reaches_the_model(self, request_factory) -> None:
        fake = FakeLaya()
        request = request_factory(
            pose_quality={
                "mean_visibility": 0.1,
                "coverage_ok_ratio": 0.1,
                "fps_mean": 28.4,
                "gap_max_ms": 180,
                "view_confidence": 0.9,
            }
        )
        service_with(laya=fake).decide(request)
        assert fake.calls == [], "数据质量不足时不应浪费一次模型调用"


# --------------------------------------------------------------------------
# 无问题路径
# --------------------------------------------------------------------------


class TestCleanResponse:
    def test_no_candidates_is_a_valid_conclusion(self, request_factory) -> None:
        """「没发现问题」是结论，不是数据缺失 —— 状态应为 ok 而不是 abstain。"""
        request = request_factory(candidates=[], set={"rep_count": 10, "valid_rep_count": 10})
        response = service_with().decide(request)
        assert response.status == "ok"
        assert response.faults == []
        assert response.primary_fault is None
        assert response.scores is not None
        assert response.scores.form_score == 100

    def test_clean_response_skips_the_model(self, request_factory) -> None:
        fake = FakeLaya()
        service_with(laya=fake).decide(request_factory(candidates=[]))
        assert fake.calls == [], "没有候选错误时无需调用模型"

    def test_clean_response_is_labelled_rule_only(self, request_factory) -> None:
        """**即使配了模型**，这条路径也必须记兜底标识。

        它没调用模型，结论里就没有模型的判断。记成 ``model_version`` 会让下游把
        一份纯规则的结论当成模型产出 —— 端侧正是靠这个字段决定要不要向用户披露
        「本次结论未经决策模型判断」。
        """
        response = service_with(laya=FakeLaya()).decide(request_factory(candidates=[]))
        assert response.meta.decision_model_version == "rule-only"
        assert response.meta.shuffled is False

    def test_clean_template_id_matches_the_other_paths(self, request_factory) -> None:
        """同一种情形只能有一个模板 ID。

        这条路径曾经自己拼出一个 ``msg_squat_clean_v1``，而 ``_build_message``
        给的是 ``msg_squat_clean_teen_v1`` —— 端侧的模板表至多命中其中一个，
        另一个静默落进兜底文案。ID 与 ``shared/messages/teen_v1.json`` 里的键一一对应。
        """
        response = service_with().decide(request_factory(candidates=[]))
        assert response.message is not None
        assert response.message.template_id == "msg_squat_clean_teen_v1"
        assert response.message.params["total"] == 10


# --------------------------------------------------------------------------
# 规则兜底路径
# --------------------------------------------------------------------------


class TestRuleOnlyPath:
    def test_decides_without_a_model(self, sample_request: DecisionRequest) -> None:
        response = service_with().decide(sample_request)
        assert response.status == "ok"
        assert len(response.faults) == 2

    def test_primary_fault_is_the_most_frequent(self, sample_request: DecisionRequest) -> None:
        """膝内扣命中 3 次、深度不足 2 次 —— 主问题应取前者。"""
        response = service_with().decide(sample_request)
        assert response.primary_fault is not None
        assert response.primary_fault.code == "KNEE_VALGUS"

    def test_severity_score_comes_from_measurements(
        self, sample_request: DecisionRequest
    ) -> None:
        """62% 与 34% 的偏离幅度直接落成分值，可复现、可解释。"""
        faults = {f.code: f for f in service_with().decide(sample_request).faults}
        assert faults["KNEE_VALGUS"].severity_score == 62
        assert faults["INSUFFICIENT_DEPTH"].severity_score == 34

    def test_gates_report_not_ok_for_triggered_faults(
        self, sample_request: DecisionRequest
    ) -> None:
        gates_out = service_with().decide(sample_request).gates
        assert gates_out["KNEE_VALGUS_ok"] is False
        assert gates_out["INSUFFICIENT_DEPTH_ok"] is False


# --------------------------------------------------------------------------
# Laya 路径
# --------------------------------------------------------------------------


class TestLayaPath:
    def make_fake(self) -> FakeLaya:
        library = active_library()
        return FakeLaya(
            {
                "primary_fault": primary_answer("INSUFFICIENT_DEPTH"),
                "severity": severity_answer(3.0),
                "plan": plan_answer(library.by_id("COR_B")),
                **gates(ok=False),
            }
        )

    def test_model_pick_is_honoured(self, sample_request: DecisionRequest) -> None:
        """规则排序会说膝内扣优先，但模型选了深度不足 —— 应当采纳模型的。"""
        response = service_with(laya=self.make_fake()).decide(sample_request)
        assert response.primary_fault is not None
        assert response.primary_fault.code == "INSUFFICIENT_DEPTH"

    def test_model_severity_level_is_applied_to_primary(
        self, sample_request: DecisionRequest
    ) -> None:
        response = service_with(laya=self.make_fake()).decide(sample_request)
        faults = {fault.code: fault for fault in response.faults}
        assert faults["INSUFFICIENT_DEPTH"].severity_level == 3

    def test_measurement_based_score_is_not_overwritten(
        self, sample_request: DecisionRequest
    ) -> None:
        """模型的判断力用在「选哪个」，不用在「多少分」—— 后者取测量值。

        ``score`` 是 Laya 最弱的原语（第三方基准 SST-5 仅 0.372），
        而 severity_0_1 是按超阈幅度算出来的，可复现、可解释。
        """
        response = service_with(laya=self.make_fake()).decide(sample_request)
        faults = {fault.code: fault for fault in response.faults}
        assert faults["KNEE_VALGUS"].severity_score == 62

    def test_unmappable_pick_falls_back_to_rule_ordering(
        self, sample_request: DecisionRequest
    ) -> None:
        """模型给了个认不出的选项时退回规则排序，而不是让主问题空着 ——
        主问题是整份报告的标题，空着比不精确更糟。"""
        fake = FakeLaya(
            {
                "primary_fault": Answer(
                    key="primary_fault",
                    type=QuestionType.CHOICE,
                    choice="完全不存在的选项",
                    choice_probabilities={"完全不存在的选项": 0.9},
                )
            }
        )
        response = service_with(laya=fake).decide(sample_request)
        assert response.primary_fault is not None
        assert response.primary_fault.code == "KNEE_VALGUS"

    def test_bare_code_is_also_accepted(self, sample_request: DecisionRequest) -> None:
        """模型直接回代码而不是带中文名的标签时也要能识别。"""
        fake = FakeLaya(
            {
                "primary_fault": Answer(
                    key="primary_fault",
                    type=QuestionType.CHOICE,
                    choice="INSUFFICIENT_DEPTH",
                    choice_probabilities={"INSUFFICIENT_DEPTH": 0.6},
                )
            }
        )
        response = service_with(laya=fake).decide(sample_request)
        assert response.primary_fault is not None
        assert response.primary_fault.code == "INSUFFICIENT_DEPTH"

    def test_noul_gates_drive_gate_dict(self, sample_request: DecisionRequest) -> None:
        fake = self.make_fake()
        gates_out = service_with(laya=fake).decide(sample_request).gates
        assert gates_out == {"KNEE_VALGUS_ok": False, "INSUFFICIENT_DEPTH_ok": False}

    def test_missing_gate_answer_defaults_to_not_ok(
        self, sample_request: DecisionRequest
    ) -> None:
        """模型没回答某项门控时不猜 —— 回到「该错误已被规则触发」这个事实。"""
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        gates_out = service_with(laya=fake).decide(sample_request).gates
        assert gates_out["KNEE_VALGUS_ok"] is False

    def test_confidence_is_scaled_by_data_quality(self, request_factory) -> None:
        """模型很确信但关键点丢了一半，那份确信没有意义。"""
        good = request_factory()
        poor = request_factory(
            pose_quality={
                "mean_visibility": 0.6,
                "coverage_ok_ratio": 0.6,
                "fps_mean": 28.4,
                "gap_max_ms": 180,
                "view_confidence": 0.9,
            }
        )
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS"), **gates(ok=False)})
        service = service_with(laya=fake)
        good_conf = service.decide(good).faults[0].confidence
        poor_conf = service.decide(poor).faults[0].confidence
        assert poor_conf < good_conf


class TestQuestionConstruction:
    def test_questions_cover_all_four_roles(self, sample_request: DecisionRequest) -> None:
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        service_with(laya=fake).decide(sample_request)
        keys = [q.key for q in fake.calls[0][1]]
        assert "primary_fault" in keys
        assert "severity" in keys
        assert "gate::KNEE_VALGUS" in keys
        assert "gate::INSUFFICIENT_DEPTH" in keys
        assert "plan" in keys

    def test_choice_options_pair_name_with_code(self, sample_request: DecisionRequest) -> None:
        """选项标签带代码：中文名便于多语言权重理解，代码保证回映射无歧义。"""
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        service_with(laya=fake).decide(sample_request)
        question = next(q for q in fake.calls[0][1] if q.key == "primary_fault")
        assert "膝内扣（KNEE_VALGUS）" in question.options
        assert "下蹲深度不足（INSUFFICIENT_DEPTH）" in question.options

    def test_state_is_passed_to_the_model(self, sample_request: DecisionRequest) -> None:
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        service_with(laya=fake).decide(sample_request)
        state = fake.calls[0][0]
        assert state["年龄"] == 14
        assert "KNEE_VALGUS" in state["候选错误"]


# --------------------------------------------------------------------------
# 降级：断网时的保命路径
# --------------------------------------------------------------------------


class TestFallbackLabelling:
    """降级路径必须自我标识 —— 这是本模块最重要的一条不变量。"""

    def test_unavailable_model_falls_back_to_rules(self, sample_request: DecisionRequest) -> None:
        fake = FakeLaya(raises=LayaUnavailableError("connection refused"))
        response = service_with(laya=fake).decide(sample_request)
        assert response.status == "ok"
        assert response.faults, "降级后仍应给出判定，不能因为模型不可用就什么都不说"

    def test_fallback_run_is_labelled_as_rule_only(self, sample_request: DecisionRequest) -> None:
        fake = FakeLaya(raises=LayaUnavailableError("timeout"))
        response = service_with(laya=fake).decide(sample_request)
        assert response.meta.decision_model_version == "rule-only"

    def test_model_run_carries_the_model_version(self, sample_request: DecisionRequest) -> None:
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        response = service_with(laya=fake).decide(sample_request)
        assert response.meta.decision_model_version == "laya-multilingual"

    def test_fallback_does_not_claim_shuffling(self, sample_request: DecisionRequest) -> None:
        """没调用模型就没有乱序这回事，不能报一个不存在的种子。"""
        fake = FakeLaya(raises=LayaUnavailableError("timeout"))
        response = service_with(laya=fake).decide(sample_request)
        assert response.meta.shuffled is False
        assert response.meta.shuffle_seed is None

    def test_model_run_reports_shuffling(self, sample_request: DecisionRequest) -> None:
        """调用了模型就必须报乱序与种子 —— 否则事后无法排除位置偏差。"""
        fake = FakeLaya({"primary_fault": primary_answer("KNEE_VALGUS")})
        response = service_with(laya=fake).decide(sample_request)
        assert response.meta.shuffled is True
        assert response.meta.shuffle_seed == 42

    def test_no_laya_configured_is_also_rule_only(self, sample_request: DecisionRequest) -> None:
        """没配模型与模型不可用应产出同一种标识 —— 两者都是「没有模型的判断」。"""
        response = service_with(laya=None).decide(sample_request)
        assert response.meta.decision_model_version == "rule-only"


# --------------------------------------------------------------------------
# 方案择优
# --------------------------------------------------------------------------


class TestPlanSelection:
    def test_plans_are_selected(self, sample_request: DecisionRequest) -> None:
        response = service_with().decide(sample_request)
        assert response.choice is not None
        assert response.choice.selected_plan_ids
        assert len(response.choice.selected_plan_ids) <= 3

    def test_model_pick_comes_first(self, sample_request: DecisionRequest) -> None:
        library = active_library()
        fake = FakeLaya({"plan": plan_answer(library.by_id("COR_C"))})
        response = service_with(laya=fake, library=library).decide(sample_request)
        assert response.choice is not None
        assert response.choice.selected_plan_ids[0] == "COR_C"

    def test_selection_is_deduplicated(self, sample_request: DecisionRequest) -> None:
        library = active_library()
        fake = FakeLaya({"plan": plan_answer(library.by_id("COR_A"))})
        response = service_with(laya=fake, library=library).decide(sample_request)
        assert response.choice is not None
        ids = response.choice.selected_plan_ids
        assert len(ids) == len(set(ids))

    def test_unreviewed_plans_are_disclosed(self, sample_request: DecisionRequest) -> None:
        """内置方案库全是 draft，走的是回退路径 —— 剂量说明必须写明这一点。"""
        service = DecisionService(laya=None)
        response = service.decide(sample_request)
        assert response.choice is not None
        assert "核定" in response.choice.dose_note

    def test_reviewed_plans_do_not_carry_the_caveat(
        self, sample_request: DecisionRequest
    ) -> None:
        response = service_with(library=active_library()).decide(sample_request)
        assert response.choice is not None
        assert "未核定" not in response.choice.dose_note

    def test_no_matching_plan_yields_no_choice(self, request_factory) -> None:
        request = request_factory(candidates=[{"code": "UNKNOWN_FAULT_X"}])
        response = service_with().decide(request)
        assert response.choice is None


# --------------------------------------------------------------------------
# 评分
# --------------------------------------------------------------------------


class TestScoring:
    def test_scores_are_always_provisional(self, sample_request: DecisionRequest) -> None:
        """评级权重还没核定，任何评分都必须自报「这是临时的」。"""
        response = service_with().decide(sample_request)
        assert response.scores is not None
        assert response.scores.provisional is True

    def test_clean_response_is_also_provisional(self, request_factory) -> None:
        response = service_with().decide(request_factory(candidates=[]))
        assert response.scores is not None
        assert response.scores.provisional is True

    def test_worse_deviation_scores_lower(self, request_factory) -> None:
        def build(severity: float) -> int:
            request = request_factory(
                reps=[
                    {
                        "index": 1,
                        "duration_ms": 2900,
                        "metrics": {},
                        "faults": [
                            {
                                "code": "KNEE_VALGUS",
                                "confidence": 0.8,
                                "evidence_frames": [],
                                "deviations": [
                                    {
                                        "feature": "f",
                                        "measured": 12.0,
                                        "threshold": 10.0,
                                        "delta_signed": 2.0,
                                        "severity_0_1": severity,
                                    }
                                ],
                            }
                        ],
                        "confidence": 0.9,
                    }
                ],
                candidates=[{"code": "KNEE_VALGUS"}],
                set={
                    "rep_count": 1,
                    "valid_rep_count": 1,
                    "fault_stats": [{"code": "KNEE_VALGUS", "reps": [1], "count": 1}],
                },
            )
            scores = service_with().decide(request).scores
            assert scores is not None
            return scores.form_score

        assert build(0.1) > build(0.9)

    def test_score_stays_in_range(self, sample_request: DecisionRequest) -> None:
        scores = service_with().decide(sample_request).scores
        assert scores is not None
        assert 0 <= scores.form_score <= 100
        assert scores.rating


# --------------------------------------------------------------------------
# 文案与元信息
# --------------------------------------------------------------------------


class TestMessageAndMeta:
    def test_message_uses_a_template_id_not_free_text(
        self, sample_request: DecisionRequest
    ) -> None:
        """青少年看到的每句话都必须来自人工审阅的模板，不能是模型现场编的。"""
        message = service_with().decide(sample_request).message
        assert message is not None
        assert message.template_id.startswith("msg_squat_")
        assert "膝内扣" in str(message.params.get("primary"))

    def test_meta_carries_thresholds_version(self, sample_request: DecisionRequest) -> None:
        """没有阈值版本就无法复现一个历史决策 —— 阈值可能已经升版。"""
        assert service_with().decide(sample_request).meta.thresholds_version == "thr_2026-10_v1"

    def test_latency_is_recorded(self, sample_request: DecisionRequest) -> None:
        assert service_with().decide(sample_request).meta.latency_ms >= 0

    def test_oversized_request_degrades_and_says_so(self, request_factory) -> None:
        many_reps = [
            {
                "index": i,
                "duration_ms": 2900,
                "metrics": {"knee_angle_bottom_deg": 90.0 + i},
                "faults": [
                    {
                        "code": "KNEE_VALGUS",
                        "confidence": 0.8,
                        "evidence_frames": [i],
                        "deviations": [
                            {
                                "feature": "frontal_knee_angle_max",
                                "measured": 12.0 + i,
                                "threshold": 10.0,
                                "delta_signed": 2.0,
                                "severity_0_1": 0.4,
                            }
                        ],
                    }
                ],
                "confidence": 0.9,
            }
            for i in range(1, 41)
        ]
        request = request_factory(
            set={"rep_count": 40, "valid_rep_count": 40},
            reps=many_reps,
        )
        message = service_with().decide(request).message
        assert message is not None
        assert "note" in message.params, "降级后必须在文案参数里说明，不能悄悄丢信息"


class TestSettings:
    def test_custom_visibility_threshold(self, request_factory) -> None:
        request = request_factory(
            pose_quality={
                "mean_visibility": 0.7,
                "coverage_ok_ratio": 0.9,
                "fps_mean": 28.4,
                "gap_max_ms": 180,
                "view_confidence": 0.9,
            }
        )
        assert service_with().decide(request).status == "ok"
        strict = DecisionSettings(min_mean_visibility=0.8)
        assert service_with(settings=strict).decide(request).status == "abstain"

    def test_zero_plans_setting_disables_recommendations(
        self, sample_request: DecisionRequest
    ) -> None:
        settings = DecisionSettings(max_plans=0)
        response = service_with(settings=settings).decide(sample_request)
        assert response.choice is None or response.choice.selected_plan_ids == []

    @pytest.mark.parametrize(
        ("threshold", "expected"),
        [
            # 样例请求的关键点可见性是 0.93：门限低于它放行、高于它弃权。
            (0.0, "ok"),
            (0.9, "ok"),
            (0.95, "abstain"),
            (1.0, "abstain"),
        ],
    )
    def test_visibility_threshold_boundary(
        self, request_factory, threshold: float, expected: str
    ) -> None:
        request = request_factory()
        service = service_with(settings=DecisionSettings(min_mean_visibility=threshold))
        assert service.decide(request).status == expected
