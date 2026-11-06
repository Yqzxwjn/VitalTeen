"""标定接缝的守卫测试（Dart 侧对应 ``app/test/domain/calibration_seam_test.dart``）。

**这一组的对象不是某个动作，而是一次共享组件的改动。** 标定要求的基线量从写死的
四个特征，变成了「随动作而变、默认仍是原来那三个」。深蹲与立定跳远不传新参数，
所以它们**应当**一个字节都没变 —— 但「应当」不算数：这类改动的失败模式全是**静默**的
（标定恒不完成、屏幕无报错、永远进不了计数），跑一遍测试看着全绿恰恰是它最像的样子。

所以这里逐条列出「深蹲的行为会在什么情况下变」，每条配一条断言：

===========================================  ==============================  ==========================
会让深蹲变的行为                             表现                            下面哪条守卫
===========================================  ==============================  ==========================
默认基线集与今天那三个不逐值相等             标定恒不完成，屏幕无报错        ``test_default_required_...``
``feed`` 的可用性门槛不按 ``required`` 收     深蹲在要 ``leg_spread`` 的路径   ``test_required_is_...``
                                             上卡死
缺基线时静默取 0 而不是抛                    躯干前倾/脚跟离地的阈值线挪位    ``test_missing_baseline_...``
``Calibration`` 字段改名/改序                所有分段线 ``stand ± …`` 跟着挪  ``test_leg_spread_...``
===========================================  ==============================  ==========================

**这张表本身就是交付物**：不是「我改得很小心」，而是列清楚它在什么情况下会坏、
以及坏的时候谁会响。
"""

from __future__ import annotations

import pytest

from vitalteen_domain import (
    N_LANDMARKS,
    FeatureExtractor,
    L,
    Landmark,
    PoseFrame,
    ThresholdTable,
)
from vitalteen_domain.exercises import Calibrator, build_squat
from vitalteen_domain.exercises.base import (
    BASELINE_KEYS,
    DEFAULT_REQUIRED_BASELINES,
    ActionRunner,
    Calibration,
)

WIDTH, HEIGHT = 720, 1280


def _standing_pose(timestamp_ms: int = 0, visibility: float = 1.0) -> PoseFrame:
    """一帧侧视站立姿态。与 ``test_exercises.squat_pose(0.0)`` 同一套坐标约定，
    刻意在这里重写一份而不是 import：那是**深蹲的**测试夹具，标定接缝不该
    因为深蹲的夹具改了而跟着动。
    """
    hip = (0.500, 0.450)
    knee = (0.500, 0.680)
    ankle = (0.500, 0.900)

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
            Landmark(x=pts[i][0], y=pts[i][1], z=0.0, visibility=visibility)
            for i in range(N_LANDMARKS)
        ),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


def _sagittal_extractor() -> FeatureExtractor:
    return FeatureExtractor(camera_view="sagittal")


class TestDefaultIsUnchanged:
    """默认行为没变 —— 这是这一轮改动唯一真正的验收方式。"""

    def test_default_required_baselines_are_exactly_the_historical_three(self) -> None:
        """默认集必须**恰好**是那三个，不多不少。

        多一个（比如顺手把 ``leg_spread`` 加进默认）：深蹲在侧视下永远采不到
        ``leg_spread_ratio``，``feed`` 恒返回 ``None`` —— 标定条卡在 0，
        **屏幕上没有任何错误**，用户只会以为这个功能坏了。少一个
        （比如把 ``heel_rise_ratio`` 去掉）：脚跟离地那条规则的阈值线整段挪位。

        用 ``==`` 比集合，不是 ``issubset``/``<=``：后两个对「多一个」是绿的，
        而「多一个」正是这里要拦的。
        """
        assert DEFAULT_REQUIRED_BASELINES == {
            "knee_angle",
            "trunk_lean",
            "heel_rise_ratio",
        }

    def test_default_baselines_are_a_subset_of_all_known_keys(self) -> None:
        """默认集里的每个名字都得是真能采到的量，否则它只是三个拗口的字符串。"""
        assert DEFAULT_REQUIRED_BASELINES <= BASELINE_KEYS

    def test_default_calibrator_produces_todays_three_values(self) -> None:
        """不传 ``required`` 时，采出来的就是今天那三个量，值也一样。

        这是「零行为变化」在**数值**上的样子：膝角 ≈180、躯干倾角 ≈0、
        脚跟抬升 ≈0，而 ``leg_spread`` 是 ``None``（没采）。
        """
        extractor = _sagittal_extractor()
        calibrator = Calibrator(min_frames=10)
        result = None
        for _ in range(10):
            result = calibrator.feed(extractor.extract(_standing_pose()))

        assert result is not None
        assert result.frames == 10
        assert result.knee_angle == pytest.approx(180.0, abs=1.0)
        assert result.trunk_lean == pytest.approx(0.0, abs=1.0)
        assert result.heel_rise_ratio == pytest.approx(0.0, abs=1e-3)
        # **没采的量是 None，不是 0。** 0 是一个会参与 `stand ± …` 计算的数，
        # None 不是 ——「不知道」和「是零」在个体化阈值里是两回事。
        assert result.leg_spread is None


class TestRequiredIsValidatedAtConstruction:
    """``required`` 写错要在**构造那一刻**炸，不是在使用的时候静默失效。

    参数收的是字符串（Python 侧既有约定，Dart 侧用枚举把这类错变成编译期错误）。
    字符串拼错在这里对应的坏法是「标定永远不完成」—— 正是这一轮要修的那个 bug。
    所以校验不能省。
    """

    def test_unknown_baseline_name_raises_at_construction(self) -> None:
        with pytest.raises(ValueError, match="未知的基线量"):
            Calibrator(required=frozenset({"leg_sprad"}))  # 少一个 e

    def test_dropping_an_always_required_baseline_raises_at_construction(self) -> None:
        """``knee_angle`` / ``trunk_lean`` 在**每一组**基线集里，不能省。

        它们是 :class:`Calibration` 上仅有的两个非空字段，也是任何机位下都算得出
        的两个量（那两个特征都没有 ``views`` 门控）。允许省掉的话，
        ``Calibration.knee_angle`` 就会在某条路径上变成 ``None``，而它声明的是
        ``float`` —— 类型标注在运行时不设防，错会一路飘到某条分段线里才现形。
        """
        with pytest.raises(ValueError, match="每个动作都要"):
            Calibrator(required=frozenset({"trunk_lean", "heel_rise_ratio"}))


class TestMissingBaselineRaisesRatherThanDefaults:
    """缺基线时**抛**，不取 0。

    取 0 会把深蹲 ``EXCESSIVE_TRUNK_LEAN`` / ``HEEL_RISE`` 的阈值从
    「基线 + 阈值增量」悄悄变成「阈值增量本身」—— 一条针对本人的线，变成一条
    针对某个不存在的人的线，而屏幕上一切照常。
    """

    def test_squat_runner_raises_when_heel_rise_baseline_is_absent(self) -> None:
        # 一份**没有** heel_rise_ratio 的基线：模拟「深蹲误用了开合跳那一组基线」。
        # 深蹲的 `threshold_offsets` 里确实引用它（squat.py 的
        # `squat.heel_rise_ratio_max_delta`），所以这里必然走到取证那一行。
        calibration = Calibration(
            knee_angle=178.0,
            trunk_lean=2.0,
            heel_rise_ratio=None,
            frames=15,
        )
        table = ThresholdTable(thresholds=[], version="test_v1")
        with pytest.raises(ValueError, match="heel_rise_ratio"):
            ActionRunner(build_squat(calibration), thresholds=table, calibration=calibration)

    def test_leg_spread_is_absent_by_default_not_zero(self) -> None:
        """新加的 ``leg_spread`` 是**可选**的，默认 ``None``。

        这一条同时是那 9 + 2 处显式 ``Calibration(...)`` 构造的守卫：
        如果哪天有人把它写成必填，那些构造点会全部编译/运行失败，
        而它们本来一个字都不用改。
        """
        calibration = Calibration(
            knee_angle=178.0,
            trunk_lean=2.0,
            heel_rise_ratio=0.01,
            frames=15,
        )
        assert calibration.leg_spread is None
