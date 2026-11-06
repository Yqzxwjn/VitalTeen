"""state 构造测试。

其中 ``TestNoPrematureConclusion`` 守的是一条**设计不变量**，不是功能：
state 里只允许出现测量与候选集，不允许出现已经拍板的结论。理由见模块文档第一条 ——
把结论和证据一起喂给模型，测到的是它的顺从程度而不是判断力。
"""

from __future__ import annotations

import pytest

from app.contracts import DecisionRequest
from app.state import (
    MAX_STATE_CHARS,
    StateTooLongError,
    build_state,
    build_state_lenient,
    render_state_text,
)


class TestContext:
    def test_carries_user_context(self, sample_request: DecisionRequest) -> None:
        state = build_state(sample_request)
        assert state["年龄"] == 14
        assert state["性别"] == "男"
        assert state["学段"] == "初中三年级"
        assert state["国标组别"] == "初中-男"

    def test_carries_technical_context(self, sample_request: DecisionRequest) -> None:
        """机位与后端会改变「哪些特征根本不可用」，因此是判断依据而不是装饰。"""
        state = build_state(sample_request)
        assert state["拍摄机位"] == "侧视"
        assert state["姿态后端"] == "ML Kit"

    def test_absence_of_world_landmarks_is_stated_explicitly(
        self, sample_request: DecisionRequest
    ) -> None:
        """缺失的世界坐标必须显式说明，而不是留空。

        留空会让模型以为只是没写；显式说明「不可用」才能让它不至于凭想象
        推断高度或位移类特征。
        """
        state = build_state(sample_request)
        assert "不可用" in state["米制世界坐标"]

        with_world = sample_request.model_copy(
            update={
                "context": sample_request.context.model_copy(update={"has_world_landmarks": True})
            }
        )
        assert build_state(with_world)["米制世界坐标"] == "可用"

    def test_view_and_backend_are_translated_to_chinese(
        self, request_factory
    ) -> None:
        request = request_factory(
            context={
                "sex": "female",
                "age": 16,
                "grade": "高中二年级",
                "standard_group": "高中-女",
                "action_code": "SQUAT",
                "camera_view": "frontal",
                "pose_backend": "mediapipe",
                "has_world_landmarks": True,
            }
        )
        state = build_state(request)
        assert state["拍摄机位"] == "正视"
        assert state["姿态后端"] == "MediaPipe"
        assert state["性别"] == "女"


class TestMeasurements:
    def test_set_summary_is_present(self, sample_request: DecisionRequest) -> None:
        state = build_state(sample_request)
        assert state["完成次数"] == 10
        assert state["有效次数"] == 8

    def test_derived_metrics_are_rendered(self, sample_request: DecisionRequest) -> None:
        state = build_state(sample_request)
        assert "2.9 秒" in state["平均单次用时"]
        assert "88.5 度" in state["平均活动幅度"]
        assert "0.04" in state["平均左右对称指数"]

    def test_optional_metrics_are_omitted_when_absent(self, request_factory) -> None:
        """缺失的指标直接不出现，而不是写成 0 —— 那会变成一条假数据。"""
        request = request_factory(
            set={
                "rep_count": 5,
                "valid_rep_count": 5,
                "tempo_mean_ms": None,
                "rom_mean_deg": None,
                "symmetry_index_mean": None,
                "fault_stats": [],
            }
        )
        state = build_state(request)
        assert "平均单次用时" not in state
        assert "平均活动幅度" not in state
        assert "平均左右对称指数" not in state

    def test_quality_line_reports_all_five_dimensions(
        self, sample_request: DecisionRequest
    ) -> None:
        quality = build_state(sample_request)["数据质量"]
        for fragment in ("0.93", "0.98", "28.4", "180", "0.91"):
            assert fragment in quality

    def test_zero_rep_count_does_not_divide_by_zero(self, request_factory) -> None:
        """「一个都没做出来」是合法输入，不应导致崩溃。"""
        request = request_factory(
            set={"rep_count": 0, "valid_rep_count": 0, "fault_stats": []}
        )
        state = build_state(request)
        assert state["完成次数"] == 0


class TestFaultEvidence:
    def test_fault_stats_render_count_and_share(self, sample_request: DecisionRequest) -> None:
        stats = build_state(sample_request)["错误统计"]
        assert "KNEE_VALGUS" in stats
        assert "命中 3 次" in stats
        assert "30%" in stats
        assert "第 2、5、7 次" in stats

    def test_empty_fault_stats_says_so_explicitly(self, request_factory) -> None:
        """「没有错误」与「没有数据」必须能区分开。"""
        request = request_factory(
            set={"rep_count": 5, "valid_rep_count": 5, "fault_stats": []}
        )
        assert "未触发任何错误候选" in build_state(request)["错误统计"]

    def test_rep_details_include_measurements(self, sample_request: DecisionRequest) -> None:
        details = build_state(sample_request)["逐次明细"]
        assert "第 2 次" in details
        assert "frontal_knee_angle_max" in details
        assert "13.6" in details
        assert "10.0" in details

    def test_reps_without_faults_are_labelled(self, request_factory) -> None:
        request = request_factory(
            reps=[{"index": 1, "duration_ms": 2800, "metrics": {}, "faults": [], "confidence": 0.9}]
        )
        assert "未触发错误" in build_state(request)["逐次明细"]

    def test_no_reps_means_no_details_section(self, request_factory) -> None:
        assert "逐次明细" not in build_state(request_factory(reps=[]))


class TestCandidates:
    def test_candidates_are_listed_in_order(self, sample_request: DecisionRequest) -> None:
        candidates = build_state(sample_request)["候选错误"]
        assert candidates.index("KNEE_VALGUS") < candidates.index("INSUFFICIENT_DEPTH")

    def test_empty_candidate_set_is_stated(self, request_factory) -> None:
        assert build_state(request_factory(candidates=[]))["候选错误"] == "（无）"


class TestNoPrematureConclusion:
    """设计不变量：state 提供证据与候选，不提供已拍板的结论。"""

    def test_no_severity_or_primary_fault_keys(self, sample_request: DecisionRequest) -> None:
        """不能出现「主问题」「严重度」这类已经做完判断的字段 ——
        那些是决策层的输出，不是它的输入。"""
        state = build_state(sample_request)
        forbidden = ("主问题", "严重度", "评级", "得分")
        offending = [key for key in state if any(word in key for word in forbidden)]
        assert not offending, f"state 中出现了预先拍板的结论字段：{offending}"

    def test_fault_names_are_not_translated_to_verdicts(
        self, sample_request: DecisionRequest
    ) -> None:
        """错误码以英文代码形式出现，不用中文名 —— 中文名本身带有判断色彩
        （「下蹲深度不足」已经是在下结论了）。"""
        rendered = render_state_text(build_state(sample_request))
        assert "下蹲深度不足" not in rendered
        assert "INSUFFICIENT_DEPTH" in rendered

    def test_no_plan_or_recommendation_in_state(self, sample_request: DecisionRequest) -> None:
        """建议由决策层的 choice 原语产出，不能预先塞进 state。"""
        rendered = render_state_text(build_state(sample_request))
        for word in ("建议", "方案", "推荐"):
            assert word not in rendered


class TestLengthBudget:
    def test_realistic_request_fits_budget(self, sample_request: DecisionRequest) -> None:
        rendered = render_state_text(build_state(sample_request))
        assert len(rendered) <= MAX_STATE_CHARS

    def test_oversized_request_raises(self, request_factory) -> None:
        """超长必须抛错而不是发出去 —— Laya 会静默截断，而截断方向会改变答案。"""
        many_reps = [
            {
                "index": i,
                "duration_ms": 2900,
                "metrics": {"knee_angle_bottom_deg": 92.3 + i},
                "faults": [
                    {
                        "code": "KNEE_VALGUS",
                        "confidence": 0.8,
                        "evidence_frames": [i],
                        "deviations": [
                            {
                                "feature": "frontal_knee_angle_max",
                                "measured": 13.6 + i,
                                "threshold": 10.0,
                                "delta_signed": 3.6,
                                "severity_0_1": 0.5,
                            }
                        ],
                    }
                ],
                "confidence": 0.9,
            }
            for i in range(1, 41)
        ]
        request = request_factory(set={"rep_count": 40, "valid_rep_count": 40}, reps=many_reps)
        with pytest.raises(StateTooLongError, match="超过预算"):
            build_state(request)


class TestLenientBuilder:
    def test_normal_request_is_not_degraded(self, sample_request: DecisionRequest) -> None:
        state, degraded = build_state_lenient(sample_request)
        assert degraded is False
        assert "说明" not in state

    def test_oversized_request_degrades_by_dropping_rep_details(
        self, request_factory
    ) -> None:
        """降级有顺序：先丢逐次明细（组级统计已能反映主要问题），并**如实标注**。"""
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
        request = request_factory(set={"rep_count": 40, "valid_rep_count": 40}, reps=many_reps)
        state, degraded = build_state_lenient(request)
        assert degraded is True
        assert "逐次明细" not in state
        assert "说明" in state
        assert len(render_state_text(state)) <= MAX_STATE_CHARS

    def test_group_statistics_survive_degradation(self, request_factory) -> None:
        """降级丢掉的是明细，不是组级统计 —— 后者才是判断的主要依据。"""
        many_reps = [
            {
                "index": i,
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
                                "severity_0_1": 0.4,
                            }
                        ],
                    }
                ],
                "confidence": 0.9,
            }
            for i in range(1, 61)
        ]
        request = request_factory(
            set={
                "rep_count": 60,
                "valid_rep_count": 60,
                # fault_stats 必须显式给出：覆盖 set 会整块替换该字段，
                # 漏掉它就成了「一个错误都没有」，测试会在错误的输入上「通过」。
                "fault_stats": [
                    {"code": "KNEE_VALGUS", "reps": list(range(1, 31)), "count": 30}
                ],
            },
            reps=many_reps,
        )
        state, degraded = build_state_lenient(request)
        # 断言必须是无条件的：写成 `if degraded:` 会让「降级没触发」也静默通过，
        # 那样这条测试在错误的输入上依然显示绿色。
        assert degraded is True, "60 次带偏离明细的动作应当触发降级"
        assert "逐次明细" not in state
        assert "KNEE_VALGUS" in state["错误统计"]


class TestRenderText:
    def test_multiline_values_are_indented(self) -> None:
        rendered = render_state_text({"键": "第一行\n第二行"})
        assert rendered.startswith("键：")
        assert "  第一行" in rendered
        assert "  第二行" in rendered

    def test_single_line_values_are_inline(self) -> None:
        assert render_state_text({"年龄": 14}) == "年龄：14"

    def test_rendering_is_human_readable(self, sample_request: DecisionRequest) -> None:
        """可读性不是装饰：决策出问题时第一个要看的就是这段文本，
        它读不了，调试就无从下手。"""
        rendered = render_state_text(build_state(sample_request))
        assert "动作：" in rendered
        assert "候选错误：" in rendered
        assert len(rendered.splitlines()) >= 10
