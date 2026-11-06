"""开合跳动作定义测试（``app/test/domain/jj_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住四类结论，每一类都是「不做就会**静默**出错」的：

1. **只开到一半的跳不算一次。** ``OPEN`` 是 ``bottom_state``，而四条分段线全部
   相对本人站立基线 —— 「开了一半」既可能被判成一次计数、也可能被判成一次丢弃，
   差别只在一根线上，而界面上都不会报错。
2. **三条判定的方向各自都对。** 尤其 ``JJ_KNEE_VALGUS``：``frontal_knee_angle_*``
   的约定与 ``knee_angle_*`` **相反**（直腿 0° 而不是 180°），写成 ``BELOW``
   的表现只是「这条判定老是误报」，看不出病因。
3. **两条「幅度不足」类规则跑在整段上。** 把窗口切到只在「已经开到位」时才存在的
   状态上，恰好会让它在最需要它的人身上失明 —— 所以正例与反例都要有。
4. **相位只映射一个状态，而且真的只覆盖那一段。** :meth:`RepWindow.select`
   在相位缺失时静默返回整段，于是「只看落地那一刻」会悄悄变成「看整次动作」。

阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
与真实资产的对照在 Dart 侧「真实阈值表」那组里（那一组要等资产落地）。
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import pytest

from vitalteen_domain import (
    N_LANDMARKS,
    L,
    Landmark,
    PoseFrame,
    Threshold,
    ThresholdTable,
)
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_jj
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.jj import CLOSED, CLOSING, OPEN, OPENING
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_slj.py``：角度在像素空间计算，
#: 非方形画幅会把 x 与 y 缩放成不同倍率。开合跳这边尤其躲不掉 ——
#: ``leg_spread_ratio`` 是「横向距离 ÷ 肩宽」，而肩宽是**欧氏**距离：
#: 非方形画幅下分子被 x 方向缩放、分母被两个方向一起缩放，比值不再等于
#: 合成的分腿幅度，而它不会报错，只会让每一条分段线都落在错的位置上。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_jj.dart`` 逐位相同** ----

_MID_X = 0.50
_SHOULDER_HALF = 0.10
_HIP_HALF = 0.06
_ARM_LEN = 0.10

_SHOULDER_Y = 0.24
_HIP_Y = 0.34
_KNEE_Y = 0.53
_ANKLE_Y = 0.72

#: 站立膝角。与 ``synthetic_jj.dart`` 取同一个值，也与另外两份合成器一致。
JJ_STAND_DEG = 175.0

#: 站立分腿比。**刻意偏窄**（见 ``synthetic_jj.dart`` 的说明）：基线越小，
#: 「相对本人基线」的四条分段线越靠近画面中轴，而判定那三条用的是绝对阈值，
#: 于是「站姿窄的人更容易进 OPEN、却更容易被判幅度不足」在测试里是常态。
JJ_STAND_SPREAD = 0.12

#: 默认配置（``spread_enter_delta`` 0.30 / ``spread_full_delta`` 0.80 /
#: ``spread_hysteresis`` 0.08）下四条线在 :data:`JJ_STAND_SPREAD` 上的位置。
JJ_STAND_LINE = 0.20
JJ_OPEN_LINE = 0.42
JJ_FULL_LINE = 0.92

#: 一次标准开合跳的分腿峰值。
JJ_JUMP_SPREAD = 2.0

#: 只开到一半的分腿峰值：过了 :data:`JJ_OPEN_LINE`、没到 :data:`JJ_FULL_LINE`。
JJ_HALF_SPREAD = 0.60

#: 手臂垂在体侧 / 举过头顶时的肩角。不是 0 与 180 —— 理由见
#: ``synthetic_jj.dart`` 里那两条注释（折进身体里 / 逐位相等的浮点比较）。
JJ_ARM_DOWN_DEG = 8.0
JJ_ARM_UP_DEG = 175.0


def jj_pose(
    timestamp_ms: int = 0,
    *,
    spread: float = JJ_STAND_SPREAD,
    arm_deg: float = JJ_ARM_DOWN_DEG,
    right_arm_deg: float | None = None,
    knee_inward: float = 0.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧开合跳姿态。

    三个自变量都是**精确造出来**的（除 ``knee_inward``，见下）：

    - ``spread``：两条踝横向相距 ``2 × spread × 肩半宽``，于是
      ``leg_spread_ratio`` 逐位等于它。
    - ``arm_deg``：把「髋−肩」的单位向量绕肩点精确旋转得到肘点，肩角于是
      逐位等于它。两侧旋转方向相反（左逆时针、右顺时针），对称的姿态才得到
      对称的肘点 —— 同号旋转会让两条手臂一上一下，而 ``shoulder_angle_min``
      取的是较小那个，于是「手臂举到位了」被判成不足。
    - ``knee_inward``：膝点按「髋踝连线中点往中线挪 ``knee_inward``」摆，
      **只有近似**（0.02 ≈ 11.4°）。所以测试不拿它卡阈值边界。
    """
    if right_arm_deg is None:
        right_arm_deg = arm_deg

    ankle_half = spread * _SHOULDER_HALF

    def hip_of(sign: float) -> tuple[float, float]:
        return (_MID_X + sign * _HIP_HALF, _HIP_Y)

    def ankle_of(sign: float) -> tuple[float, float]:
        return (_MID_X + sign * ankle_half, _ANKLE_Y)

    def knee_of(sign: float) -> tuple[float, float]:
        hip = hip_of(sign)
        ankle = ankle_of(sign)
        return ((hip[0] + ankle[0]) / 2.0 - sign * knee_inward, _KNEE_Y)

    def elbow_of(
        shoulder: tuple[float, float], hip: tuple[float, float], deg: float, sign: float
    ) -> tuple[float, float]:
        dx, dy = hip[0] - shoulder[0], hip[1] - shoulder[1]
        length = math.hypot(dx, dy)
        rad = sign * math.radians(deg)
        vx, vy = dx / length, dy / length
        rx = vx * math.cos(rad) - vy * math.sin(rad)
        ry = vx * math.sin(rad) + vy * math.cos(rad)
        return (shoulder[0] + _ARM_LEN * rx, shoulder[1] + _ARM_LEN * ry)

    def wrist_of(
        shoulder: tuple[float, float], elbow: tuple[float, float]
    ) -> tuple[float, float]:
        return (elbow[0] + (elbow[0] - shoulder[0]), elbow[1] + (elbow[1] - shoulder[1]))

    left_shoulder = (_MID_X - _SHOULDER_HALF, _SHOULDER_Y)
    right_shoulder = (_MID_X + _SHOULDER_HALF, _SHOULDER_Y)
    left_hip = hip_of(-1.0)
    right_hip = hip_of(1.0)
    left_elbow = elbow_of(left_shoulder, left_hip, arm_deg, -1.0)
    right_elbow = elbow_of(right_shoulder, right_hip, right_arm_deg, 1.0)

    left_ankle = ankle_of(-1.0)
    right_ankle = ankle_of(1.0)

    # 其余的点（嘴、眼、耳）堆在头顶上方一点：可见、不参与任何开合跳特征，
    # 但门禁要拿「头在不在画面里」当提示级判据。
    pts: dict[int, tuple[float, float]] = dict.fromkeys(
        range(N_LANDMARKS), (_MID_X, _SHOULDER_Y - 0.06)
    )
    pts[L.LEFT_SHOULDER] = left_shoulder
    pts[L.RIGHT_SHOULDER] = right_shoulder
    pts[L.LEFT_ELBOW] = left_elbow
    pts[L.RIGHT_ELBOW] = right_elbow
    pts[L.LEFT_WRIST] = wrist_of(left_shoulder, left_elbow)
    pts[L.RIGHT_WRIST] = wrist_of(right_shoulder, right_elbow)
    pts[L.LEFT_HIP] = left_hip
    pts[L.RIGHT_HIP] = right_hip
    pts[L.LEFT_KNEE] = knee_of(-1.0)
    pts[L.RIGHT_KNEE] = knee_of(1.0)
    pts[L.LEFT_ANKLE] = left_ankle
    pts[L.RIGHT_ANKLE] = right_ankle
    # 脚跟与脚尖不参与开合跳的任何特征，但给出来更接近真实帧 ——
    # 少一个点就少一处「万一哪天有人加了依赖它」的意外。
    pts[L.LEFT_HEEL] = (left_ankle[0] - 0.02, left_ankle[1] + 0.008)
    pts[L.RIGHT_HEEL] = (right_ankle[0] + 0.02, right_ankle[1] + 0.008)
    pts[L.LEFT_FOOT_INDEX] = (left_ankle[0] + 0.03, left_ankle[1] + 0.008)
    pts[L.RIGHT_FOOT_INDEX] = (right_ankle[0] - 0.03, right_ankle[1] + 0.008)

    landmarks = []
    for i in range(N_LANDMARKS):
        vis = visibility
        if visibility_overrides and i in visibility_overrides:
            vis = visibility_overrides[i]
        landmarks.append(Landmark(x=pts[i][0], y=pts[i][1], z=0.0, visibility=vis))

    return PoseFrame(
        landmarks=tuple(landmarks),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


@dataclass(frozen=True)
class Segment:
    """一个姿态段：连续 ``count`` 帧，三个自变量固定。

    用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（起跳段手臂没举够、
    落地段膝内扣），段读起来与动作一一对应。
    """

    spread: float
    count: int = 14
    arm_deg: float = JJ_ARM_DOWN_DEG
    right_arm_deg: float | None = None
    knee_inward: float = 0.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                jj_pose(
                    start + i * interval_ms,
                    spread=segment.spread,
                    arm_deg=segment.arm_deg,
                    right_arm_deg=segment.right_arm_deg,
                    knee_inward=segment.knee_inward,
                )
            )
    return frames


#: 合腿站立段。开场与收尾都用它。
CLOSED_SEGMENT = Segment(JJ_STAND_SPREAD)

#: 张开到顶峰、双臂举过头顶的那一段。段长给到 14 帧而不是「刚好够提交一次转移」：
#: **[OPEN] 是计数门槛**（``bottom_state``），段短了就变成「这一次没数上」，
#: 而那是另一条测试要证的事。
OPEN_FULL = Segment(JJ_JUMP_SPREAD, arm_deg=JJ_ARM_UP_DEG)

#: 站立基线。**``heel_rise_ratio`` 是 ``None``** —— 正面机位下 ``heel_rise_ratio_L``
#: 声明 ``views: [sagittal, oblique45]``，恒不可用，而开合跳也不判脚跟离地。
STANDING_CALIBRATION = Calibration(
    knee_angle=JJ_STAND_DEG,
    trunk_lean=0.0,
    heel_rise_ratio=None,
    frames=15,
    leg_spread=JJ_STAND_SPREAD,
)

#: 内联阈值表。三条判定的取值只为本测试服务；刻意离合成帧的取值远一点，
#: 免得断在阈值同侧的边界上（分腿峰值 2.0 对阈 1.20、手臂 175° 对阈 150°、
#: 膝内扣约 11.8° 对阈 8°）。
_THRESHOLD_ROWS = {
    "jj.spread_min_ratio": (1.20, "leg_spread_ratio", "ratio"),
    "jj.arm_min_angle": (150.0, "shoulder_angle_min", "deg"),
    "jj.knee_valgus_angle_notice": (8.0, "frontal_knee_angle_max", "deg"),
}


def make_thresholds() -> ThresholdTable:
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="JJ",
                feature_code=feature,
                value=value,
                unit=unit,
                source_type=SourceType.LITERATURE,
                version="test_v1",
            )
            for key, (value, feature, unit) in _THRESHOLD_ROWS.items()
        ],
        version="test_v1",
    )


def jj_config() -> TrackingConfig:
    return TrackingConfig(camera_view="frontal", max_rep_frames=90)


def jj_runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    """构造一个阈值已核定的开合跳 runner。

    ``config`` 必须**同时**喂给 :func:`build_jj` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or jj_config()
    return ActionRunner(
        build_jj(STANDING_CALIBRATION, config=cfg),
        thresholds=make_thresholds(),
        calibration=STANDING_CALIBRATION,
        config=cfg,
    )


def feed_all(runner: ActionRunner, frames: list[PoseFrame]) -> None:
    for frame in frames:
        runner.feed(frame)


def stat_of(summary, code: str):
    for stat in summary.fault_stats:
        if stat.code == code:
            return stat
    return None


#: 正面机位下的特征读取器。
#:
#: **必须显式给正面机位**：``leg_spread_ratio`` 与 ``frontal_knee_angle_max``
#: 都声明 ``views=("frontal",)``，用别的机位读出来的是 ``view_mismatch``
#: 而不是数值 —— 而那是静默的（``get`` 返回 ``None``）。
_FRONTAL = FeatureExtractor(camera_view="frontal")


def feature(frame: PoseFrame, code: str) -> float | None:
    return _FRONTAL.extract(frame).get(code)


def guard_of(definition, src: str, dst: str):
    for transition in definition.transitions:
        if transition.src == src and transition.dst == dst:
            return transition.guard
    raise AssertionError(f"没有 {src} → {dst} 这条边")


# --------------------------------------------------------------------------
# 构造期校验
# --------------------------------------------------------------------------


class TestJjConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """分段线顺序被违反时当场炸，而不是悄悄少一条边。

        这几条线全是可调的工程参数。调乱之后状态机不会报错，只会少一条边
        或者多一条「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
        离病因非常远。
        """
        with pytest.raises(ValueError, match="分段线顺序非法"):
            # 滞回带比起步线还大：CLOSED 与 OPENING 之间没有空间。
            build_jj(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    camera_view="frontal",
                    spread_enter_delta=0.10,
                    spread_hysteresis=0.30,
                ),
            )

        with pytest.raises(ValueError, match="分段线顺序非法"):
            # 到位线比起步线还低：OPEN 一进就成立。
            build_jj(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    camera_view="frontal",
                    spread_enter_delta=0.60,
                    spread_full_delta=0.40,
                ),
            )

    def test_raises_without_leg_spread_baseline(self) -> None:
        """没有分腿基线时抛，而不是拿 0 顶上。

        取 0 的后果不是「差一点」：四条分段线会全部落在 0.1 上下，
        于是几乎任何站姿都在 OPEN 里，每一次抖动都被计成一次开合跳，
        **而且不报错**。
        """
        bare = Calibration(knee_angle=JJ_STAND_DEG, trunk_lean=0.0, heel_rise_ratio=None, frames=15)
        with pytest.raises(ValueError, match="分腿幅度基线"):
            build_jj(bare, config=jj_config())

    def test_default_camera_view_is_frontal(self) -> None:
        """默认机位是正面 —— 换掉它两条判定会静默消失。"""
        assert build_jj(STANDING_CALIBRATION).camera_view == "frontal"

        # 反面：45° 下两个额状面特征都判 ``view_mismatch``，
        # 而特征不可用时规则不命中、也不报错。
        frame = jj_pose(spread=JJ_JUMP_SPREAD)
        oblique = FeatureExtractor(camera_view="oblique45")
        assert oblique.extract(frame).get("leg_spread_ratio") is None
        assert oblique.extract(frame).get("frontal_knee_angle_max") is None


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_spread_ratio_and_arm_angle_are_exact(self) -> None:
        """判定测试要断的是「越没越过阈值」，所以自变量必须算得准。"""
        for spread in (0.0, JJ_STAND_SPREAD, 1.0, JJ_JUMP_SPREAD):
            assert feature(jj_pose(spread=spread), "leg_spread_ratio") == pytest.approx(
                spread, abs=1e-9
            )

        for deg in (JJ_ARM_DOWN_DEG, 90.0, JJ_ARM_UP_DEG):
            frame = jj_pose(arm_deg=deg)
            assert feature(frame, "shoulder_angle_min") == pytest.approx(deg, abs=1e-9)
            # 两侧都造得出来，``min`` 才等于它。
            assert feature(frame, "shoulder_angle_L") == pytest.approx(deg, abs=1e-9)
            assert feature(frame, "shoulder_angle_R") == pytest.approx(deg, abs=1e-9)

    def test_frontal_knee_angle_is_opposite_to_knee_angle(self) -> None:
        """直腿时额状面膝角为 0，内扣时变大 —— 与膝角的方向相反。

        **这条是设计文档 §5.2 那处测量的可执行版本。** 两个「膝角」的约定正好相反：
        直腿时 ``knee_angle_*`` 是 180°、``frontal_knee_angle_*`` 是 0°。
        谁把 ``JJ_KNEE_VALGUS`` 的方向改成 ``BELOW``，下面那条断言会红。

        容差 1e-3° 而不是逐位相等：合成的膝点是「髋踝中点」，在实数上严格共线，
        但 ``(hx+ax)/2 − hx`` 与 ``ax − (hx+ax)/2`` 是两条不同的浮点路径 ——
        实测两个角各偏 1.2e-6°。**这是浮点的表现，不是膝歪了**：
        1e-3 仍然比这里要辨别的信号（内扣 0.02 → 11.4°）小四个数量级。
        """
        straight = jj_pose(spread=JJ_JUMP_SPREAD, knee_inward=0.0)
        assert feature(straight, "frontal_knee_angle_max") == pytest.approx(0.0, abs=1e-3)
        assert feature(straight, "knee_angle_L") == pytest.approx(180.0, abs=1e-3)

        valgus = jj_pose(spread=JJ_JUMP_SPREAD, knee_inward=0.02)
        assert feature(valgus, "frontal_knee_angle_max") > 8.0, (
            "0.02 的膝点内移应当在设计文档 §5.2 的最小可检测差异（约 8°）之上"
        )
        assert feature(valgus, "knee_angle_L") < 180.0


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestJjSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments([CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD)]),
        )

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0
        assert runner.current_state == CLOSED

    def test_half_open_rep_is_discarded_not_counted(self) -> None:
        """只开到一半就合上：计 0、弃 1。

        「开合」这个动作的判定对象是「开」到没到位。只到一半的跳**不算一次**，
        而它也不是无声无息地消失 —— ``discarded_reps`` 记账，界面解释为
        「有 N 次没计入（幅度不够或太快）」。
        """
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [CLOSED_SEGMENT, Segment(JJ_HALF_SPREAD, arm_deg=JJ_ARM_UP_DEG), Segment(JJ_STAND_SPREAD)]
            ),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == CLOSED, "要回到站立态等下一跳"

    def test_transition_guard_bounds(self) -> None:
        """守卫的上下界：开到一半进得去 OPENING，回到基线才回得去 CLOSED。

        上面那条计数测试一旦变绿，就可能是因为「压根没离开 CLOSED」——
        那样它证明的是别的东西。这里直接对守卫求值。
        """
        definition = build_jj(STANDING_CALIBRATION, config=jj_config())

        def at(src: str, dst: str, spread: float) -> bool:
            return guard_of(definition, src, dst)({"leg_spread_ratio": spread})

        assert not at(CLOSED, OPENING, JJ_STAND_SPREAD)
        assert at(CLOSED, OPENING, JJ_HALF_SPREAD)
        assert at(CLOSED, OPENING, JJ_JUMP_SPREAD)

        assert not at(OPENING, OPEN, JJ_HALF_SPREAD)
        assert at(OPENING, OPEN, JJ_JUMP_SPREAD)

        # 开局与封存落到 CLOSED 用的是**同一条线**：CLOSED 只有一个含义。
        assert guard_of(definition, OPENING, CLOSED) is guard_of(definition, CLOSING, CLOSED)

        # 而滞回带保证「刚进 OPENING」的那一帧不会被同一条线立刻推回去。
        assert not at(OPENING, CLOSED, JJ_OPEN_LINE)

    def test_rebound_does_not_get_stuck(self) -> None:
        """回弹不卡死：合到一半又张开，仍然合得拢。

        守卫看不见时间，没有 ``CLOSING → OPEN`` 这条边的话，「落地后弹一下又开」
        会停在 CLOSING 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
        一个错的状态词。
        """
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    CLOSED_SEGMENT,
                    OPEN_FULL,
                    Segment(0.30),  # 合到一半（低于 open_line）
                    OPEN_FULL,  # 又张开
                    Segment(JJ_STAND_SPREAD),  # 终于合拢 → 封存
                ]
            ),
        )

        assert runner.rep_count == 1, "回弹之后仍然要合得拢"
        assert runner.current_state == CLOSED

    def test_standing_still_is_neither_counted_nor_discarded(self) -> None:
        runner = jj_runner()
        feed_all(runner, [jj_pose(i * 33, spread=JJ_STAND_SPREAD) for i in range(60)])

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "站着不动不该被记账成一次丢弃"
        assert runner.current_state == CLOSED

    def test_contact_phase_covers_only_the_closing_segment(self) -> None:
        """相位只覆盖合拢那一段，而不是整次动作。

        与立定跳远那组同一条理由：:meth:`RepWindow.select` 在相位缺失时**静默**
        返回整段，于是「只看落地那一刻」会悄悄变成「看整次动作」——
        而 ``JJ_KNEE_VALGUS`` 就再也不会因为「落地时才内扣」而漏判。
        """
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments([CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD)]),
        )

        window = runner.windows[0]
        contact = window.select(Phase.CONTACT)
        assert contact, "触地相位取出来是空的"
        assert len(contact) < len(window.frames), "相位退化成了整段，等于规则在整次动作上求值"
        # 开合跳只映射这一个相位；别的相位取出来必然退化成整段。
        assert set(window.phase_bounds) == {Phase.CONTACT}
        # 触地段在末尾：它之后只剩「已经在站立态」的收尾帧。
        assert window.phase_bounds[Phase.CONTACT][0] > len(window.frames) // 2

    def test_never_leaving_stand_is_not_a_discard(self) -> None:
        """分腿一直不够（没离开过 CLOSED）时连丢弃都不该有。"""
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments([CLOSED_SEGMENT, Segment(0.30, count=120)]),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "没离开过站立态，就没有「一次」可丢"


# --------------------------------------------------------------------------
# 三条规则
# --------------------------------------------------------------------------


class TestJjRules:
    def test_insufficient_spread_fires_only_on_the_low_jump(self) -> None:
        """峰值不给到位的那个跳**必须进得去 OPEN**，否则它会被 ``bottom_state``
        挡在外面、整段被丢弃，这条规则于是根本没机会求值 —— 而它恰恰是最该对
        这种人说话的那条。

        所以峰值要落在**到位线 0.92 与绝对阈值 1.20 之间**（这里取 1.05）：
        这正是「本人站姿窄（基线小）、相对线偏低，于是跳了但跳得不够开」的那种人。
        """
        low = jj_runner()
        feed_all(
            low,
            frames_from_segments(
                [CLOSED_SEGMENT, Segment(1.05, arm_deg=JJ_ARM_UP_DEG), Segment(JJ_STAND_SPREAD)]
            ),
        )
        assert low.rep_count == 1, "过了 full_line（0.92），算一次"
        assert stat_of(low.finish_set(), "JJ_INSUFFICIENT_SPREAD") is not None

        good = jj_runner()
        feed_all(
            good,
            frames_from_segments([CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD)]),
        )
        assert good.rep_count == 1
        assert stat_of(good.finish_set(), "JJ_INSUFFICIENT_SPREAD") is None, (
            "标准开合跳不该被判幅度不足 —— 否则这条规则是「永远命中」"
        )

    def test_insufficient_arm_fires_only_on_the_low_swing(self) -> None:
        low = jj_runner()
        feed_all(
            low,
            frames_from_segments(
                [CLOSED_SEGMENT, Segment(JJ_JUMP_SPREAD, arm_deg=90.0), Segment(JJ_STAND_SPREAD)]
            ),
        )
        assert low.rep_count == 1
        assert stat_of(low.finish_set(), "JJ_INSUFFICIENT_ARM") is not None

        good = jj_runner()
        feed_all(
            good,
            frames_from_segments([CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD)]),
        )
        assert stat_of(good.finish_set(), "JJ_INSUFFICIENT_ARM") is None

    def test_one_arm_only_measures_as_insufficient(self) -> None:
        """手臂只举了一侧时算不足 —— 取的是两只里较小的那个。

        一侧举到顶、另一侧垂着：如果指标取的是 max（或「哪侧看得清就用哪侧」），
        这一跳会被判合格，而用户明明只举了一只手。
        """
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    CLOSED_SEGMENT,
                    Segment(
                        JJ_JUMP_SPREAD,
                        arm_deg=JJ_ARM_UP_DEG,
                        right_arm_deg=JJ_ARM_DOWN_DEG,
                    ),
                    Segment(JJ_STAND_SPREAD),
                ]
            ),
        )

        assert runner.rep_count == 1
        assert stat_of(runner.finish_set(), "JJ_INSUFFICIENT_ARM") is not None

    def test_knee_valgus_direction_is_not_inverted(self) -> None:
        """落地膝内扣：只命中内扣的那一跳，而且方向不许写反。

        方向写成 ``BELOW`` 时，规则会变成「腿越直越算内扣」：下面那条「合规」
        用例会红，而它在真机上只表现为「这条判定老是误报」。
        """
        valgus = jj_runner()
        feed_all(
            valgus,
            frames_from_segments(
                [CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD, knee_inward=0.02)]
            ),
        )
        assert valgus.rep_count == 1
        assert stat_of(valgus.finish_set(), "JJ_KNEE_VALGUS") is not None

        straight = jj_runner()
        feed_all(
            straight,
            frames_from_segments([CLOSED_SEGMENT, OPEN_FULL, Segment(JJ_STAND_SPREAD)]),
        )
        assert stat_of(straight.finish_set(), "JJ_KNEE_VALGUS") is None, "直腿落地不该被判膝内扣"

    def test_valgus_during_the_open_segment_does_not_fire(self) -> None:
        """内扣只出现在张开段时不命中 —— 这条规则判的是触地那一刻。

        与上一条成对存在。少了它，把相位从 ``CONTACT`` 改成 ``ALL`` 也不会被发现，
        而那样这条规则会因为「最高点那一下膝有点歪」就报错。
        """
        runner = jj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    CLOSED_SEGMENT,
                    Segment(JJ_JUMP_SPREAD, arm_deg=JJ_ARM_UP_DEG, knee_inward=0.02),
                    Segment(JJ_STAND_SPREAD, knee_inward=0.0),
                ]
            ),
        )

        assert runner.rep_count == 1
        assert stat_of(runner.finish_set(), "JJ_KNEE_VALGUS") is None

    def test_all_three_rules_use_absolute_thresholds(self) -> None:
        """三条规则都用绝对阈值 —— 没有一条挂在分腿基线上。

        给 ``jj.spread_min_ratio`` 挂 ``("leg_spread", k)`` 是一个看起来很合理的
        「个体化」，而它会让这条规则**永远不触发**：并腿站立时分腿比接近 0，
        于是阈值也接近 0，而峰值恒大于 0。这条断言把「阈值原样来自表」变成可执行的。
        """
        definition = build_jj(STANDING_CALIBRATION, config=jj_config())
        assert definition.threshold_offsets == {}, "三条判定的阈值都是绝对的，一个偏移都不该有"


class TestJjThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        definition = build_jj(STANDING_CALIBRATION, config=jj_config())
        table = make_thresholds()
        for rule in definition.rules:
            assert table.get(rule.threshold_key).value > 0, f"{rule.code} 的阈值取到了 0 或负数"
