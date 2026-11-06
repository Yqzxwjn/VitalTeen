"""矫正方案库测试。

这里有两条**治理性质**的断言，比功能断言更重要：

1. ``for_faults`` 默认不返回 ``draft`` 方案 —— 未核定的训练处方不得推送给用户。
2. 内置方案库的每一条都必须有禁忌说明 —— 面向青少年的训练建议，宁可保守。

功能断言保证代码能跑；治理断言保证代码**跑对方向**。
"""

from __future__ import annotations

from typing import Any

import pytest

from app.plans import (
    CorrectionPlan,
    Dosage,
    PlanCategory,
    PlanLibrary,
    PlanStatus,
    default_library,
)


def make_plan(**overrides: Any) -> CorrectionPlan:
    base: dict[str, Any] = {
        "plan_id": "COR_TEST",
        "name_zh": "测试方案",
        "category": PlanCategory.STRENGTHENING,
        "target_fault_codes": ("KNEE_VALGUS",),
        "goal": "用于测试",
        "instructions": ("第一步", "第二步"),
        "key_cues": ("提示语",),
        "dosage": Dosage(),
        "equipment": (),
        "difficulty": 2,
        "age_min": 12,
        "age_max": 18,
        "grade_fit": ("初中",),
        "contraindications": ("出现疼痛时停止",),
        "evidence_refs": ("测试来源",),
        "status": PlanStatus.DRAFT,
    }
    base.update(overrides)
    return CorrectionPlan(**base)


def active_plan(plan_id: str, faults: tuple[str, ...], **overrides: Any) -> CorrectionPlan:
    return make_plan(
        plan_id=plan_id,
        target_fault_codes=faults,
        status=PlanStatus.ACTIVE,
        **overrides,
    )


# --------------------------------------------------------------------------
# Dosage
# --------------------------------------------------------------------------


class TestDosage:
    def test_default_is_unratified(self) -> None:
        """默认剂量是「未核定」，不是「不需要」——两者含义完全不同。"""
        dosage = Dosage()
        assert dosage.is_ratified is False
        assert dosage.describe() == "剂量待体育专业成员核定"

    def test_reps_style_description(self) -> None:
        dosage = Dosage(sets=3, reps=12, freq_per_week=3, duration_weeks=6)
        assert dosage.is_ratified is True
        assert dosage.describe() == "3 组 × 12 次，每周 3 次，持续 6 周"

    def test_hold_style_description(self) -> None:
        dosage = Dosage(sets=3, hold_seconds=30, freq_per_week=3)
        assert dosage.describe() == "3 组 × 每组 30 秒，每周 3 次"

    def test_sets_only_still_ratified(self) -> None:
        dosage = Dosage(sets=2, freq_per_week=5)
        assert dosage.is_ratified is True

    def test_partial_dosage_is_not_ratified(self) -> None:
        """只填了组数没有周频，说明还没核定完，不能当成已核定展示。"""
        assert Dosage(sets=3, reps=10).is_ratified is False


# --------------------------------------------------------------------------
# CorrectionPlan 校验
# --------------------------------------------------------------------------


class TestPlanValidation:
    @pytest.mark.parametrize("difficulty", [0, 6, -1])
    def test_difficulty_out_of_range_is_rejected(self, difficulty: int) -> None:
        with pytest.raises(ValueError, match="difficulty"):
            make_plan(difficulty=difficulty)

    def test_age_range_must_be_ordered(self) -> None:
        with pytest.raises(ValueError, match="age_min"):
            make_plan(age_min=18, age_max=12)

    def test_must_target_at_least_one_fault(self) -> None:
        with pytest.raises(ValueError, match="目标错误码"):
            make_plan(target_fault_codes=())

    def test_active_plan_requires_evidence(self) -> None:
        """没有文献支撑的方案不能作为建议推送 —— 因此不允许进入 active。"""
        with pytest.raises(ValueError, match="证据来源"):
            make_plan(status=PlanStatus.ACTIVE, evidence_refs=())

    def test_draft_plan_may_lack_evidence(self) -> None:
        plan = make_plan(status=PlanStatus.DRAFT, evidence_refs=())
        assert plan.evidence_refs == ()


class TestPlanQueries:
    def test_covers(self) -> None:
        plan = make_plan(target_fault_codes=("KNEE_VALGUS", "ASYMMETRY"))
        assert plan.covers("KNEE_VALGUS") is True
        assert plan.covers("HEEL_RISE") is False

    @pytest.mark.parametrize(
        ("age", "expected"), [(11, False), (12, True), (15, True), (18, True), (19, False)]
    )
    def test_suitable_for_age_boundaries(self, age: int, expected: bool) -> None:
        assert make_plan(age_min=12, age_max=18).suitable_for_age(age) is expected

    def test_plan_without_equipment_is_always_available(self) -> None:
        assert make_plan(equipment=()).requires_equipment(()) is True

    def test_plan_with_equipment_needs_all_of_it(self) -> None:
        plan = make_plan(equipment=("弹力带", "垫子"))
        assert plan.requires_equipment(("弹力带", "垫子")) is True
        assert plan.requires_equipment(("弹力带",)) is False
        assert plan.requires_equipment(()) is False


# --------------------------------------------------------------------------
# PlanLibrary
# --------------------------------------------------------------------------


class TestPlanLibrary:
    def test_duplicate_plan_id_is_rejected(self) -> None:
        """plan_id 会写进历史决策记录，重复会让「当时推荐了哪一套」无法追溯。"""
        with pytest.raises(ValueError, match="重复"):
            PlanLibrary([make_plan(plan_id="X"), make_plan(plan_id="X")])

    def test_unknown_plan_id_raises(self) -> None:
        library = PlanLibrary([make_plan(plan_id="X")])
        with pytest.raises(KeyError, match="不存在"):
            library.by_id("NOPE")

    def test_by_id_returns_plan(self) -> None:
        library = PlanLibrary([make_plan(plan_id="X", name_zh="某方案")])
        assert library.by_id("X").name_zh == "某方案"

    def test_len_and_all(self) -> None:
        library = PlanLibrary([make_plan(plan_id="A"), make_plan(plan_id="B")])
        assert len(library) == 2
        assert {p.plan_id for p in library.all()} == {"A", "B"}

    def test_pending_review_lists_drafts_only(self) -> None:
        library = PlanLibrary(
            [
                make_plan(plan_id="D1"),
                make_plan(plan_id="A1", status=PlanStatus.ACTIVE),
                make_plan(plan_id="D2"),
            ]
        )
        assert {p.plan_id for p in library.pending_review()} == {"D1", "D2"}


class TestForFaultsGovernance:
    def test_draft_plans_are_excluded_by_default(self) -> None:
        """未核定的训练处方不得推送给用户 —— 这是默认行为，不是可选项。"""
        library = PlanLibrary([make_plan(plan_id="D1", target_fault_codes=("KNEE_VALGUS",))])
        assert library.for_faults(["KNEE_VALGUS"], age=14) == ()

    def test_draft_plans_included_when_explicitly_requested(self) -> None:
        """研究、评审与演示场景可以显式打开 —— 但必须显式。"""
        library = PlanLibrary([make_plan(plan_id="D1", target_fault_codes=("KNEE_VALGUS",))])
        result = library.for_faults(["KNEE_VALGUS"], age=14, include_unreviewed=True)
        assert [p.plan_id for p in result] == ["D1"]

    def test_deprecated_plans_are_never_returned(self) -> None:
        """废弃方案连「未核定」的通道也不能走 —— 它的问题不是没核定，是不能再用了。"""
        library = PlanLibrary(
            [
                make_plan(
                    plan_id="OLD",
                    target_fault_codes=("KNEE_VALGUS",),
                    status=PlanStatus.DEPRECATED,
                )
            ]
        )
        assert library.for_faults(["KNEE_VALGUS"], age=14, include_unreviewed=True) == ()

    def test_active_plans_are_returned(self) -> None:
        library = PlanLibrary([active_plan("A1", ("KNEE_VALGUS",))])
        assert [p.plan_id for p in library.for_faults(["KNEE_VALGUS"], age=14)] == ["A1"]


class TestForFaultsFiltering:
    def test_filters_by_age(self) -> None:
        library = PlanLibrary(
            [
                active_plan("YOUNG", ("KNEE_VALGUS",), age_min=10, age_max=13),
                active_plan("OLD", ("KNEE_VALGUS",), age_min=16, age_max=18),
            ]
        )
        assert [p.plan_id for p in library.for_faults(["KNEE_VALGUS"], age=12)] == ["YOUNG"]
        assert [p.plan_id for p in library.for_faults(["KNEE_VALGUS"], age=17)] == ["OLD"]
        assert library.for_faults(["KNEE_VALGUS"], age=14) == ()

    def test_filters_by_available_equipment(self) -> None:
        """默认假定没有任何器材 —— 学生在家做，不能推荐需要弹力带的动作。"""
        library = PlanLibrary(
            [
                active_plan("BODYWEIGHT", ("KNEE_VALGUS",), equipment=()),
                active_plan("BAND", ("KNEE_VALGUS",), equipment=("弹力带",)),
            ]
        )
        assert [p.plan_id for p in library.for_faults(["KNEE_VALGUS"], age=14)] == ["BODYWEIGHT"]
        with_band = library.for_faults(["KNEE_VALGUS"], age=14, available_equipment=("弹力带",))
        assert {p.plan_id for p in with_band} == {"BODYWEIGHT", "BAND"}

    def test_no_matching_fault_returns_empty(self) -> None:
        library = PlanLibrary([active_plan("A1", ("KNEE_VALGUS",))])
        assert library.for_faults(["HEEL_RISE"], age=14) == ()

    def test_ranks_by_number_of_target_faults_covered(self) -> None:
        """一次给三个方案时，优先给覆盖面最广的 —— 先解决主要问题。"""
        library = PlanLibrary(
            [
                active_plan("NARROW", ("KNEE_VALGUS",)),
                active_plan("WIDE", ("KNEE_VALGUS", "INSUFFICIENT_DEPTH", "HEEL_RISE")),
                active_plan("MEDIUM", ("KNEE_VALGUS", "HEEL_RISE")),
            ]
        )
        result = library.for_faults(["KNEE_VALGUS", "INSUFFICIENT_DEPTH", "HEEL_RISE"], age=14)
        assert [p.plan_id for p in result] == ["WIDE", "MEDIUM", "NARROW"]

    def test_ordering_is_deterministic_for_equal_coverage(self) -> None:
        """同覆盖面时按难度、再按编号 —— 保证同样的输入永远给同样的建议。"""
        library = PlanLibrary(
            [
                active_plan("B_HARD", ("KNEE_VALGUS",), difficulty=4),
                active_plan("A_EASY", ("KNEE_VALGUS",), difficulty=1),
            ]
        )
        result = library.for_faults(["KNEE_VALGUS"], age=14)
        assert [p.plan_id for p in result] == ["A_EASY", "B_HARD"]

    def test_limit_truncates(self) -> None:
        library = PlanLibrary(
            [active_plan(f"P{i}", ("KNEE_VALGUS",), difficulty=i) for i in range(1, 6)]
        )
        assert len(library.for_faults(["KNEE_VALGUS"], age=14, limit=3)) == 3

    def test_ignores_equipment_not_required_by_plan(self) -> None:
        """用户手里多出器材不该让无器材方案消失。"""
        library = PlanLibrary([active_plan("BW", ("KNEE_VALGUS",), equipment=())])
        result = library.for_faults(["KNEE_VALGUS"], age=14, available_equipment=("弹力带", "垫子"))
        assert [p.plan_id for p in result] == ["BW"]


class TestReviewFallback:
    def test_prefers_reviewed_plans(self) -> None:
        library = PlanLibrary(
            [
                active_plan("A1", ("KNEE_VALGUS",)),
                make_plan(plan_id="D1", target_fault_codes=("KNEE_VALGUS",)),
            ]
        )
        plans, unreviewed = library.for_faults_with_review_fallback(["KNEE_VALGUS"], age=14)
        assert [p.plan_id for p in plans] == ["A1"]
        assert unreviewed is False

    def test_falls_back_and_flags_when_nothing_is_reviewed(self) -> None:
        """全部未核定时给出候选动作，但必须把「未核定」这个事实带回去。

        标志丢了就变成了冒充已核定 —— 这比不给建议更糟。
        """
        library = PlanLibrary([make_plan(plan_id="D1", target_fault_codes=("KNEE_VALGUS",))])
        plans, unreviewed = library.for_faults_with_review_fallback(["KNEE_VALGUS"], age=14)
        assert [p.plan_id for p in plans] == ["D1"]
        assert unreviewed is True

    def test_no_candidates_at_all(self) -> None:
        library = PlanLibrary([make_plan(plan_id="D1", target_fault_codes=("KNEE_VALGUS",))])
        plans, unreviewed = library.for_faults_with_review_fallback(["HEEL_RISE"], age=14)
        assert plans == ()
        assert unreviewed is False


# --------------------------------------------------------------------------
# 种子方案库
# --------------------------------------------------------------------------


class TestDefaultLibrary:
    def test_is_populated(self) -> None:
        assert len(default_library()) >= 12

    def test_all_seed_plans_are_draft(self) -> None:
        """种子库全部未核定。这不是遗漏 —— 未经核定的训练处方不该推送给青少年。"""
        assert len(default_library().pending_review()) == len(default_library())

    def test_plan_ids_are_unique_and_stable(self) -> None:
        ids = [p.plan_id for p in default_library().all()]
        assert len(ids) == len(set(ids))
        assert all(pid.startswith("COR_") for pid in ids), "方案编码需带 COR_ 前缀"

    def test_every_plan_declares_contraindications(self) -> None:
        """安全性不变量：面向青少年的训练建议，每条都必须写明禁忌。

        这条测试守的是产品底线，不是代码正确性 —— 一条没有禁忌说明的训练处方
        在用户手里可能是伤害。
        """
        for plan in default_library().all():
            assert plan.contraindications, f"{plan.plan_id} 缺少禁忌说明"
            assert all(text.strip() for text in plan.contraindications), (
                f"{plan.plan_id} 的禁忌说明含空串"
            )

    def test_every_plan_has_instructions_and_cues(self) -> None:
        for plan in default_library().all():
            assert plan.instructions, f"{plan.plan_id} 缺少动作要领"
            assert plan.key_cues, f"{plan.plan_id} 缺少提示语"
            assert plan.goal.strip(), f"{plan.plan_id} 缺少训练目的"

    def test_seed_fault_codes_match_domain_taxonomy(self) -> None:
        """方案针对的错误码必须来自领域层的分类体系，不能自造。

        领域层的错误码定义在 ``domain/src/vitalteen_domain/exercises/squat.py``
        与 ``rules.py``；这里抽查深蹲的五个已实现错误码都被覆盖到了。
        """
        domain_codes = {
            "KNEE_VALGUS",
            "INSUFFICIENT_DEPTH",
            "EXCESSIVE_TRUNK_LEAN",
            "HEEL_RISE",
            "ASYMMETRY",
        }
        covered = {
            code for plan in default_library().all() for code in plan.target_fault_codes
        }
        missing = domain_codes - covered
        assert not missing, f"以下深蹲错误码没有任何方案覆盖：{sorted(missing)}"

    def test_equipment_free_plans_exist(self) -> None:
        """必须有不依赖器材的方案 —— 学生大多数时候在家练。"""
        free = [p for p in default_library().all() if not p.equipment]
        assert free, "方案库中没有无器材方案，学生在家无法执行"
