"""端到端集成测试：领域层 → 适配器 → 契约 → 决策服务 → HTTP。

**这是仓库里唯一跨两个包的测试**，也是唯一能覆盖「接缝」的测试。领域层与决策
服务各自都有完整测试，但它们之间的字段映射此前没有任何覆盖 —— 而这类缝正是最
容易出错的地方：序号基准不同（0-based 还是 1-based）、语义理解偏差、单位不一致，
**都不会报错**，只会让判定结果悄悄错掉，且错得很像真的。

测试里的决策请求全部由**真实的领域层流水线**产出（合成关键点序列 → 特征 →
状态机 → 规则引擎 → 适配器），而不是手写字典。手写字典只能验证「契约接受这种
形状」，验证不了「领域层真的产出这种形状」。

依赖 ``domain/`` 包（由 ``pyproject.toml`` 的 pythonpath 提供）。单独 checkout
``server/`` 时该依赖不存在，本模块整体跳过，而不是让整个测试套件变红。
"""

from __future__ import annotations

import pytest

pytest.importorskip("vitalteen_domain", reason="集成测试需要 domain/ 包（单仓多包）")

from vitalteen_domain import (
    N_LANDMARKS,
    FeatureExtractor,
    L,
    Landmark,
    PoseFrame,
)
from vitalteen_domain.exercises import (
    Calibrator,
    TrackingConfig,
    build_squat,
)
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.thresholds import SourceType, Threshold, ThresholdTable

from app.adapter import build_rep_details, build_request
from app.api import ApiConfig, create_app
from app.contracts import DecisionContext, PoseQuality
from app.plans import default_library
from app.service import DecisionService

WIDTH, HEIGHT = 720, 1280
_THRESHOLDS_VERSION = "thr_it_v1"

_STANDING = ((0.500, 0.450), (0.500, 0.680), (0.500, 0.900))
_DEEP = ((0.440, 0.700), (0.520, 0.700), (0.520, 0.900))


def _lerp(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def squat_pose(bend: float, timestamp_ms: int = 0) -> PoseFrame:
    """合成一帧侧视深蹲姿态。``bend`` 从 0（直立）到 1（大腿平行地面）。"""
    hip = _lerp(_STANDING[0], _DEEP[0], bend)
    knee = _lerp(_STANDING[1], _DEEP[1], bend)
    ankle = _lerp(_STANDING[2], _DEEP[2], bend)

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), (0.505, 0.1))
    for idx in (L.LEFT_HIP, L.RIGHT_HIP):
        pts[idx] = hip
    for idx in (L.LEFT_KNEE, L.RIGHT_KNEE):
        pts[idx] = knee
    for idx in (L.LEFT_ANKLE, L.RIGHT_ANKLE):
        pts[idx] = ankle
    shoulder_y = hip[1] - 0.23
    pts[L.LEFT_SHOULDER] = (hip[0] - 0.002, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (hip[0] + 0.002, shoulder_y)
    pts[L.LEFT_HEEL] = (ankle[0] - 0.018, 0.922)
    pts[L.RIGHT_HEEL] = (ankle[0] + 0.002, 0.922)
    pts[L.LEFT_FOOT_INDEX] = (ankle[0] + 0.025, 0.922)
    pts[L.RIGHT_FOOT_INDEX] = (ankle[0] + 0.027, 0.922)
    pts[L.LEFT_ELBOW] = (hip[0] - 0.010, shoulder_y + 0.11)
    pts[L.RIGHT_ELBOW] = (hip[0] + 0.006, shoulder_y + 0.11)
    pts[L.LEFT_WRIST] = (hip[0] - 0.018, shoulder_y + 0.21)
    pts[L.RIGHT_WRIST] = (hip[0] + 0.014, shoulder_y + 0.21)

    return PoseFrame(
        landmarks=tuple(
            Landmark(x=pts[i][0], y=pts[i][1], z=0.0, visibility=1.0) for i in range(N_LANDMARKS)
        ),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


def squat_sequence(*, peak: float = 1.0, standing: int = 6, descent: int = 20,
                   bottom: int = 10, ascent: int = 20, calibration: int = 0) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    ts = 0

    def add(bend: float) -> None:
        nonlocal ts
        frames.append(squat_pose(bend, ts))
        ts += 33

    for _ in range(standing + calibration):
        add(0.0)
    for i in range(1, descent + 1):
        add(peak * i / descent)
    for _ in range(bottom):
        add(peak)
    for i in range(ascent, 0, -1):
        add(peak * i / ascent)
    for _ in range(standing):
        add(0.0)
    return frames


def make_thresholds(**overrides: float) -> ThresholdTable:
    values = {
        "squat.min_depth_knee_angle": 95.0,
        "squat.knee_valgus_angle_notice": 8.0,
        "squat.trunk_lean_max_delta": 15.0,
        "squat.heel_rise_ratio_max_delta": 0.15,
        "squat.asymmetry_index_max": 0.10,
    }
    values.update(overrides)
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="SQUAT",
                feature_code="*",
                value=value,
                unit="test",
                source_type=SourceType.LITERATURE,
                version=_THRESHOLDS_VERSION,
            )
            for key, value in values.items()
        ],
        version=_THRESHOLDS_VERSION,
    )


def run_squat_set(*, peak: float = 1.0) -> ActionRunner:
    """跑完一整组深蹲，返回已封存 rep 的运行器。"""
    config = TrackingConfig()
    extractor = FeatureExtractor(camera_view="sagittal")
    calibrator = Calibrator(min_frames=config.calibration_frames)
    for _ in range(config.calibration_frames):
        calibrator.feed(extractor.extract(squat_pose(0.0)))
    calibration = calibrator.calibration
    assert calibration is not None, "标定应当已就绪"

    runner = ActionRunner(
        build_squat(calibration, config=config),
        thresholds=make_thresholds(),
        calibration=calibration,
        config=config,
    )
    for frame in squat_sequence(peak=peak, calibration=config.calibration_frames):
        runner.feed(frame)
    return runner


def context() -> DecisionContext:
    return DecisionContext(
        sex="male",
        age=14,
        grade="初中三年级",
        standard_group="初中-男",
        action_code="SQUAT",
        action_variant="bodyweight",
        camera_view="sagittal",
        pose_backend="mlkit",
        has_world_landmarks=False,
    )


def quality() -> PoseQuality:
    return PoseQuality(
        mean_visibility=0.93,
        coverage_ok_ratio=0.98,
        fps_mean=30.0,
        gap_max_ms=40,
        view_confidence=0.9,
    )


def assemble(runner: ActionRunner):
    """把一次真实运行的产物组装成决策请求。"""
    return build_request(
        runner.finish_set(),
        request_id="it_0001",
        context=context(),
        pose_quality=quality(),
        thresholds_version=_THRESHOLDS_VERSION,
        windows=runner.windows,
        engine=runner.engine,
    )


# --------------------------------------------------------------------------
# 接缝：领域层产出 → 契约字段
# --------------------------------------------------------------------------


class TestSeam:
    def test_real_pipeline_produces_a_valid_request(self) -> None:
        request = assemble(run_squat_set())
        assert request.request_id == "it_0001"
        assert request.thresholds_version == _THRESHOLDS_VERSION
        assert request.context.action_code == "SQUAT"

    def test_rep_count_matches_sealed_reps(self) -> None:
        runner = run_squat_set()
        request = assemble(runner)
        assert request.set.rep_count == runner.rep_count
        # 领域层只封存到达过底部的动作，「无效 rep」不会被记录，故两者相等
        assert request.set.valid_rep_count == request.set.rep_count

    def test_candidates_are_derived_from_fault_stats(self) -> None:
        """候选集与组级统计必须同源。

        它们一旦不一致，「主问题必须出现在错误列表里」这条响应契约就会破 ——
        这正是先前在决策服务里修过的那类 bug。适配器从同一处派生它们，
        从源头上排除这种可能。
        """
        request = assemble(run_squat_set(peak=0.85))
        assert {c.code for c in request.candidates} == {
            s.code for s in request.set.fault_stats
        }

    def test_rep_indices_are_one_based_and_align(self) -> None:
        """报告里「第 2、5、7 次」能对得上，靠的就是这条对齐。"""
        request = assemble(run_squat_set(peak=0.85))
        for stat in request.set.fault_stats:
            assert all(index >= 1 for index in stat.reps), (
                f"{stat.code} 的 rep 序号出现了 0 或负数：{stat.reps}"
            )
            assert stat.count == len(stat.reps)

    def test_rep_details_are_populated_from_windows(self) -> None:
        request = assemble(run_squat_set(peak=0.85))
        assert request.reps, "逐次明细为空 —— 决策层就看不到问题是偶发还是复现"
        assert [rep.index for rep in request.reps] == list(range(1, len(request.reps) + 1))

    def test_rep_detail_faults_match_the_group_summary(self) -> None:
        """逐次明细里的错误码必须与组级统计一致 ——
        两者用的是同一个引擎实例，不一致说明适配器接错了。"""
        runner = run_squat_set(peak=0.85)
        request = assemble(runner)
        per_rep_codes = {fault.code for rep in request.reps for fault in rep.faults}
        summary_codes = {stat.code for stat in request.set.fault_stats}
        assert per_rep_codes == summary_codes, (per_rep_codes, summary_codes)

    def test_rep_durations_are_plausible(self) -> None:
        """单次用时由首末帧时间戳推出，量级应当合理。

        刻意不钉死具体毫秒数：一次 rep 跨越多少帧取决于状态机的防抖参数
        （投票窗口、最短停留），把它们一调这条测试就红，属于把测试绑在了
        实现细节上。这里只验证「确实是从时间戳算出来的、不是 0 也不是天文数字」。
        """
        request = assemble(run_squat_set())
        assert request.set.tempo_mean_ms is not None
        assert 300 < request.set.tempo_mean_ms < 5000, request.set.tempo_mean_ms

    def test_missing_engine_is_rejected_loudly(self) -> None:
        """给了窗口却不给引擎时，逐次明细会静默为空 —— 必须报错而不是让它空着。"""
        runner = run_squat_set()
        with pytest.raises(ValueError, match="engine"):
            build_request(
                runner.finish_set(),
                request_id="it_0002",
                context=context(),
                pose_quality=quality(),
                thresholds_version=_THRESHOLDS_VERSION,
                windows=runner.windows,
                engine=None,
            )

    def test_rep_details_without_windows_is_empty_not_fabricated(self) -> None:
        assert build_rep_details((), run_squat_set().engine) == []


# --------------------------------------------------------------------------
# 端到端：一次真实的深蹲组走到决策响应
# --------------------------------------------------------------------------


class TestEndToEnd:
    def test_clean_squat_reports_no_depth_fault(self) -> None:
        """标准深蹲（大腿平行地面）不应被判深度不足。

        这条断言穿过整条链路：关键点 → 特征 → 状态机相位切分 → 规则判定 →
        适配器 → 决策服务。链路上任何一环的语义偏差都会让它失败。
        """
        request = assemble(run_squat_set(peak=1.0))
        response = DecisionService(laya=None).decide(request)
        codes = {fault.code for fault in response.faults}
        assert "INSUFFICIENT_DEPTH" not in codes, codes

    def test_shallow_squat_flags_depth_and_scores_lower(self) -> None:
        """浅蹲应当被判深度不足，且评分低于标准动作 —— 两个结论要一致。"""
        shallow = DecisionService(laya=None).decide(assemble(run_squat_set(peak=0.85)))
        clean = DecisionService(laya=None).decide(assemble(run_squat_set(peak=1.0)))

        assert "INSUFFICIENT_DEPTH" in {fault.code for fault in shallow.faults}
        assert shallow.scores is not None and clean.scores is not None
        assert shallow.scores.form_score < clean.scores.form_score

    def test_response_uses_the_thresholds_version_from_the_request(self) -> None:
        """审计链路：阈值版本必须原样贯穿到响应，否则历史决策无法复现。"""
        response = DecisionService(laya=None).decide(assemble(run_squat_set()))
        assert response.meta.thresholds_version == _THRESHOLDS_VERSION

    def test_recommended_plans_target_the_detected_faults(self) -> None:
        """推荐出来的练习必须针对真实检出的错误 —— 而不是随便给了几个动作。"""
        request = assemble(run_squat_set(peak=0.85))
        # 显式注入方案库而不是去读服务内部的私有属性：测试自己要能拿到那份数据，
        # 否则只能靠反射，而反射会把测试绑在实现结构上。
        library = default_library()
        response = DecisionService(laya=None, plans=library).decide(request)
        assert response.choice is not None and response.choice.selected_plan_ids

        wanted = {candidate.code for candidate in request.candidates}
        for plan_id in response.choice.selected_plan_ids:
            plan = library.by_id(plan_id)
            assert not wanted.isdisjoint(plan.target_fault_codes), (
                f"{plan_id} 不针对任何检出的错误：{plan.target_fault_codes} vs {wanted}"
            )


# --------------------------------------------------------------------------
# 全栈：真实流水线 → HTTP
# --------------------------------------------------------------------------


class TestThroughHttp:
    def test_request_built_from_real_pipeline_passes_the_api(self) -> None:
        """把真实流水线产出的请求 POST 到接口 —— 覆盖到契约序列化这一环。

        单元测试里的请求是内存中的模型对象；真机上它是 JSON。
        字段类型、可选值、嵌套结构在序列化时都可能出问题。
        """
        request = assemble(run_squat_set(peak=0.85))
        app = create_app(ApiConfig(), service=DecisionService(laya=None))
        response = app.test_client().post(
            "/v1/decide", json=request.model_dump(mode="json")
        )
        assert response.status_code == 200, response.get_json()
        body = response.get_json()
        assert body["status"] == "ok"
        assert body["primary_fault"] is not None
        assert body["meta"]["thresholds_version"] == _THRESHOLDS_VERSION
        assert body["meta"]["decision_model_version"] == "rule-only"

    def test_abstains_when_the_recording_is_too_poor(self) -> None:
        """整条链路加上质量门之后，坏数据不会产出一个看似确定的结论。"""
        request = assemble(run_squat_set(peak=0.85))
        degraded = request.model_copy(
            update={
                "pose_quality": PoseQuality(
                    mean_visibility=0.1,
                    coverage_ok_ratio=0.1,
                    fps_mean=30.0,
                    gap_max_ms=40,
                    view_confidence=0.9,
                )
            }
        )
        app = create_app(ApiConfig(), service=DecisionService(laya=None))
        body = app.test_client().post(
            "/v1/decide", json=degraded.model_dump(mode="json")
        ).get_json()
        assert body["status"] == "abstain"
        assert body["abstain_reason"]
