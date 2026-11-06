"""动作定义层端到端测试。

这里是第一条把「关键点 → 特征 → 状态机 → 相位切分 → 错误判定」完整串起来跑的
测试链路。之前各层是分开测的，而这类系统的 bug 恰恰最容易藏在校验节点之间的缝隙里
（相位切分偏一帧、rep 起点算错、阈值偏移没应用……）。

姿态序列由 :func:`squat_sequence` 按「弯曲程度 t」插值合成，t=0 为直立、
t=1 为大腿平行地面的深蹲。**断言的是行为（有没有计数、有没有切出相位、
规则有没有命中），不是具体角度** —— 角度值由几何层自己的测试保证。
"""

from __future__ import annotations

import pytest

from vitalteen_domain import (
    N_LANDMARKS,
    FeatureExtractor,
    FeatureValue,
    FrameFeatures,
    L,
    Landmark,
    PoseFrame,
    Threshold,
    ThresholdTable,
)
from vitalteen_domain.exercises import Calibrator, TrackingConfig, build_squat
from vitalteen_domain.exercises.base import ActionRunner, RepTracker
from vitalteen_domain.state_machine import StateMachine, Transition
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

WIDTH, HEIGHT = 720, 1280

#: 直立与深蹲两个端点姿态（侧视，归一化坐标）。
_STANDING_JOINTS = {
    "LEFT_HIP": (0.500, 0.450),
    "LEFT_KNEE": (0.500, 0.680),
    "LEFT_ANKLE": (0.500, 0.900),
}
_DEEP_JOINTS = {
    "LEFT_HIP": (0.440, 0.700),
    "LEFT_KNEE": (0.520, 0.700),
    "LEFT_ANKLE": (0.520, 0.900),
}


def _lerp(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def squat_pose(bend: float, timestamp_ms: int = 0, visibility: float = 1.0) -> PoseFrame:
    """合成一帧侧视深蹲姿态。``bend`` 为 0（直立）到 1（大腿平行地面）的插值系数。

    左右肢体在 x 上几乎重合（侧视特征），脚尖指向图像右侧。
    """
    hip = _lerp(_STANDING_JOINTS["LEFT_HIP"], _DEEP_JOINTS["LEFT_HIP"], bend)
    knee = _lerp(_STANDING_JOINTS["LEFT_KNEE"], _DEEP_JOINTS["LEFT_KNEE"], bend)
    ankle = _lerp(_STANDING_JOINTS["LEFT_ANKLE"], _DEEP_JOINTS["LEFT_ANKLE"], bend)

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), (0.505, 0.1))
    for idx, (hx, hy) in ((L.LEFT_HIP, hip), (L.RIGHT_HIP, hip)):
        pts[idx] = (hx, hy)
    for idx, (kx, ky) in ((L.LEFT_KNEE, knee), (L.RIGHT_KNEE, knee)):
        pts[idx] = (kx, ky)
    for idx, (ax, ay) in ((L.LEFT_ANKLE, ankle), (L.RIGHT_ANKLE, ankle)):
        pts[idx] = (ax, ay)
    # 肩随髋下沉，保持躯干前倾为 0（本测试不构造前倾缺陷）
    shoulder_y = hip[1] - 0.23
    pts[L.LEFT_SHOULDER] = (hip[0] - 0.002, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (hip[0] + 0.002, shoulder_y)
    # 脚：脚跟在后、脚尖在前，均贴地
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
            Landmark(x=pts[i][0], y=pts[i][1], z=0.0, visibility=visibility)
            for i in range(N_LANDMARKS)
        ),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


def squat_sequence(
    *,
    standing: int = 6,
    descent: int = 20,
    bottom: int = 10,
    ascent: int = 20,
    peak: float = 1.0,
    calibration_frames: int = 0,
) -> list[PoseFrame]:
    """合成一次深蹲的完整帧序列。

    ``peak`` 控制最深处的弯曲程度：小于约 0.8 时到不了底部相位，
    可用于构造「不是一次深蹲」的序列。
    """
    frames: list[PoseFrame] = []
    ts = 0
    for _ in range(standing + calibration_frames):
        frames.append(squat_pose(0.0, ts))
        ts += 33
    for i in range(1, descent + 1):
        frames.append(squat_pose(peak * i / descent, ts))
        ts += 33
    for _ in range(bottom):
        frames.append(squat_pose(peak, ts))
        ts += 33
    for i in range(ascent, 0, -1):
        frames.append(squat_pose(peak * i / ascent, ts))
        ts += 33
    for _ in range(standing):
        frames.append(squat_pose(0.0, ts))
        ts += 33
    return frames


def make_thresholds(**overrides: float) -> ThresholdTable:
    """构造一张已核定的测试阈值表。

    **刻意不用 ``shared/thresholds/`` 里那份真实阈值表** —— 那份全是
    ``pending_review``，只能出提示、不能扣分，无法验证可扣分路径。
    """
    values: dict[str, float] = {
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
                version="test_v1",
            )
            for key, value in values.items()
        ],
        version="test_v1",
    )


def calibrated_runner(
    *,
    config: TrackingConfig | None = None,
    **threshold_overrides: float,
) -> ActionRunner:
    """构造一个已完成标定、阈值已核定的深蹲 runner。

    ``config`` 必须能传进来：工程参数（如 ``max_rep_frames``）会改变行为，
    测试若用不到自己传的那份配置，就会出现「测试以为设了限制、实际没生效」
    这种最难查的假绿。
    """
    cfg = config or TrackingConfig()
    extractor = FeatureExtractor(camera_view="sagittal")
    calibrator = Calibrator(min_frames=cfg.calibration_frames)
    for _ in range(cfg.calibration_frames):
        calibrator.feed(extractor.extract(squat_pose(0.0)))
    calibration = calibrator.calibration
    assert calibration is not None, "标定应当已就绪"
    return ActionRunner(
        build_squat(calibration, config=cfg),
        thresholds=make_thresholds(**threshold_overrides),
        calibration=calibration,
        config=cfg,
    )


# --------------------------------------------------------------------------
# Calibrator
# --------------------------------------------------------------------------


class TestCalibrator:
    def test_not_ready_before_min_frames(self) -> None:
        extractor = FeatureExtractor(camera_view="sagittal")
        calibrator = Calibrator(min_frames=10)
        frame = squat_pose(0.0)
        for _ in range(9):
            assert calibrator.feed(extractor.extract(frame)) is None
            assert not calibrator.is_ready

    def test_ready_after_min_frames_with_standing_baseline(self) -> None:
        extractor = FeatureExtractor(camera_view="sagittal")
        calibrator = Calibrator(min_frames=10)
        result = None
        for _ in range(10):
            result = calibrator.feed(extractor.extract(squat_pose(0.0)))
        assert result is not None
        assert result.frames == 10
        # 直立姿态的膝角应接近 180 度
        assert result.knee_angle == pytest.approx(180.0, abs=1.0)
        assert result.trunk_lean == pytest.approx(0.0, abs=1.0)
        assert result.heel_rise_ratio == pytest.approx(0.0, abs=1e-3)

    def test_skips_frames_with_unavailable_features(self) -> None:
        """特征不可用的帧不是「膝角为 0 的帧」，而是「不知道膝角」——不得计入基线。"""
        extractor = FeatureExtractor(camera_view="sagittal")
        calibrator = Calibrator(min_frames=5)
        occluded = squat_pose(0.0, visibility=0.1)
        for _ in range(20):
            assert calibrator.feed(extractor.extract(occluded)) is None
        assert not calibrator.is_ready

    def test_every_collected_baseline_appears_in_the_result(self) -> None:
        """**采到 ≠ 放进去。**

        :meth:`Calibrator.feed` 是按 ``required`` 逐量累加样本的，而结果
        ``Calibration`` 是**手写**的一项一项拼出来的（它比 ``required`` 多两个
        总是要的膝角与躯干倾角，其余每一项都可空）。漏拼一项的表现极隐蔽：
        标定照样走完、``is_ready`` 为真、屏幕上一切正常，而**读那一项的人**
        在别处抛 —— ``build_rope`` 里的 ``calibration.foot_height`` 缺席即抛，
        抛点在会话建 runner 的那一刻，也就是用户做完一组、标定刚结束的时候。

        2026-10-05 就是在 Dart 侧这样漏掉 ``footHeight`` 的：
        ``_collect_baseline`` 里有它、Dart 的「都采得到」那条也绿（它只问
        ``isReady``）。Python 这一侧当时是对的，这条测试把两边钉在同一个
        不变量上。
        """
        extractor = FeatureExtractor(camera_view="oblique45")
        calibrator = Calibrator(
            min_frames=5,
            required=frozenset({"knee_angle", "trunk_lean", "foot_height"}),
        )
        for i in range(5):
            calibrator.feed(extractor.extract(squat_pose(0.0, i * 33)))

        calibration = calibrator.calibration
        assert calibration is not None, "标定应当已就绪"
        for name in sorted(calibrator.required):
            assert getattr(calibration, name) is not None, (
                f"声明要采 {name}，但标定结果里是 None —— 拼 Calibration 时漏了一项"
            )

    def test_reset_clears_state(self) -> None:
        extractor = FeatureExtractor(camera_view="sagittal")
        calibrator = Calibrator(min_frames=3)
        for _ in range(3):
            calibrator.feed(extractor.extract(squat_pose(0.0)))
        assert calibrator.is_ready
        calibrator.reset()
        assert not calibrator.is_ready
        assert calibrator.calibration is None


# --------------------------------------------------------------------------
# ActionRunner —— 端到端
# --------------------------------------------------------------------------


class TestSquatEndToEnd:
    def test_counts_one_full_rep(self) -> None:
        runner = calibrated_runner()
        sealed = [runner.feed(f) for f in squat_sequence(calibration_frames=20)]
        assert runner.rep_count == 1, (
            f"应当计 1 次，实际 {runner.rep_count}（丢弃 {runner.discarded_reps}）"
        )
        assert sum(1 for w in sealed if w is not None) == 1

    def test_segments_all_three_phases(self) -> None:
        """底部相位必须被切出来 —— 所有质量规则都挂在它上面。"""
        runner = calibrated_runner()
        window = None
        for frame in squat_sequence(calibration_frames=20):
            maybe = runner.feed(frame)
            if maybe is not None:
                window = maybe
        assert window is not None, "没有封存任何 rep"
        bounds = window.phase_bounds
        for phase in (Phase.DESCENT, Phase.BOTTOM, Phase.ASCENT):
            assert phase in bounds, f"缺少相位 {phase}，实际切出 {sorted(str(p) for p in bounds)}"
            start, end = bounds[phase]
            assert 0 <= start <= end < len(window.frames), f"{phase} 的区间越界：{start}..{end}"

    def test_phase_bounds_are_ordered(self) -> None:
        runner = calibrated_runner()
        window = None
        for frame in squat_sequence(calibration_frames=20):
            maybe = runner.feed(frame)
            if maybe is not None:
                window = maybe
        assert window is not None
        b = window.phase_bounds
        assert b[Phase.DESCENT][1] <= b[Phase.BOTTOM][0]
        assert b[Phase.BOTTOM][1] <= b[Phase.ASCENT][0]

    def test_shallow_attempt_is_not_counted(self) -> None:
        """弯不到底部就直起来 —— 不是一次深蹲，既不计数也不评错误。"""
        runner = calibrated_runner()
        for frame in squat_sequence(peak=0.6, calibration_frames=20):
            runner.feed(frame)
        assert runner.rep_count == 0
        assert runner.discarded_reps >= 1

    def test_shallow_bottom_reaches_rules_as_insufficient_depth(self) -> None:
        """到达底部但蹲得不够深 —— 应当计数，并被判为深度不足。

        这是本设计的关键分界：**分段（算不算一次）与判定（蹲得好不好）互不干扰**。
        """
        runner = calibrated_runner()
        for frame in squat_sequence(peak=0.85, calibration_frames=20):
            runner.feed(frame)
        assert runner.rep_count == 1, f"到达底部的动作应当计数（丢弃 {runner.discarded_reps}）"
        summary = runner.finish_set()
        codes = {s.code for s in summary.fault_stats}
        assert "INSUFFICIENT_DEPTH" in codes, f"应判深度不足，实际命中 {codes}"

    def test_clean_rep_has_no_depth_fault(self) -> None:
        runner = calibrated_runner()
        for frame in squat_sequence(calibration_frames=20):
            runner.feed(frame)
        summary = runner.finish_set()
        codes = {s.code for s in summary.fault_stats}
        assert "INSUFFICIENT_DEPTH" not in codes, f"标准深蹲被误判：{codes}"

    def test_rep_index_starts_at_one_and_increments(self) -> None:
        runner = calibrated_runner()
        windows = []
        for frame in squat_sequence(calibration_frames=20) * 2:
            maybe = runner.feed(frame)
            if maybe is not None:
                windows.append(maybe)
        assert [w.index for w in windows] == [1, 2]

    def test_overlong_rep_is_abandoned(self) -> None:
        """无限期挂着的未完成 rep 必须被丢弃，否则内存与状态都会卡死。"""
        runner = calibrated_runner(config=TrackingConfig(max_rep_frames=20))
        # 一直保持在下蹲中途，从不回到站立
        for i in range(80):
            runner.feed(squat_pose(0.5, i * 33))
        assert runner.rep_count == 0
        assert runner.discarded_reps >= 1

    def test_no_rep_while_standing_idle(self) -> None:
        runner = calibrated_runner()
        for i in range(120):
            runner.feed(squat_pose(0.0, i * 33))
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "一直站着不应产生丢弃计数"


# --------------------------------------------------------------------------
# rep 缓冲的记账规则（手工状态机，与任何动作定义无关）
# --------------------------------------------------------------------------


def _frame(index: int, go: float) -> FrameFeatures:
    """只带一个 ``go`` 信号的 :class:`FrameFeatures`。

    测记账规则时，合成姿态那一整套几何只是噪声。
    """
    return FrameFeatures(
        timestamp_ms=index * 33,
        values={
            "go": FeatureValue(
                code="go",
                value=go,
                unit="ratio",
                coord_space="dimensionless",
                valid=True,
            )
        },
    )


class TestRepBufferBookkeeping:
    def test_bottom_entered_on_the_rep_start_frame_counts(self) -> None:
        """**等待期分支管的是「缓冲区不保留历史」，不该顺手把「这一帧进过底部」也吞掉。**

        跳绳是第一个 ``resting_state`` 的下一步就是 ``bottom_state`` 的动作
        （``GROUND → AIR``），而那个转移恰好落在 rep 起点那一帧上：漏记的话每一次
        封存都走「没到过底部」的分支 —— **整组一次都不计数、全部计进
        ``discarded_reps``**，而 HUD 上的状态词一路都是对的，屏幕上什么错都不报。

        A ⇄ B（B 是底部）与任何动作定义无关：记账规则属于引擎，它的守卫不该寄生在
        某个动作的测试里。
        """
        machine = StateMachine(
            initial_state="A",
            transitions=[
                Transition("A", "B", lambda s: (s.get("go") or 0.0) > 0.5),
                Transition("B", "A", lambda s: (s.get("go") or 0.0) <= 0.5),
            ],
            min_dwell_frames=1,
            vote_window=1,
            vote_required=1,
        )
        tracker = RepTracker(
            machine,
            resting_state="A",
            bottom_state="B",
            config=TrackingConfig(max_rep_frames=100),
            state_to_phase={},
        )

        # 前两帧静止（A），第三帧起「起跳」进 B，第八帧起落回 A。
        for i in range(7):
            tracker.feed(_frame(i, 1.0 if i >= 2 else 0.0))
        for i in range(7, 12):
            tracker.feed(_frame(i, 0.0))

        assert tracker.discarded_reps == 0, "这一次真的到过 B"
        assert len(tracker.completed) == 1
        assert len(tracker.completed[0].frames) == 6, (
            "窗口从进 B 的那一帧（1 起算的第 3 帧）到落回 A 的那一帧（第 8 帧）"
        )
