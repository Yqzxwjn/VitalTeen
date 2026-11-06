"""跳绳动作定义测试。

与 ``app/test/domain/rope_test.dart`` 一一对应。这里钉住六类结论，每一类都是
「不做就会**静默**出错」的：

1. **防抖参数必须是引擎允许的最小那一组（2/2/1）。** 引擎默认的 5/4/3 在跳绳上
   不是「稳一点」，而是**让状态机永远落在人后面** —— 下面那条「同一批帧，换默认
   参数就一次都数不出来」的用例量的就是这件事，而它在屏幕上什么错都不报。
2. **``CUSHION`` 是结构上必需的，不是多绕一步。** 两态环（``GROUND ⇄ AIR``）下
   封存发生在脚尖刚碰到地面的那一帧，落地缓冲整个落在 rep 窗口之外 ——
   于是「屈膝 170° 判缓冲不足」那条用例会**变成永远不命中**。
   封存窗口的帧数断言是这条结论的直接证据。
3. **``CUSHION → GROUND`` 必须同时看脚尖与膝角。** 只看脚尖的话触地那一帧就
   成立（回到第 2 条）；只看膝角的话腾空时腿本来就是伸直的、这条在半空恒真。
   下面那条「落地后一直蹲着不站直」的用例专判后半句：它必须**卡在 CUSHION
   直到超时被丢弃**，而不是在刚触地时草草封存。
4. **三条规则各自只在违规时命中，且两个方向都断言。** 只断言「违规时命中」的话，
   一条永远命中的规则也是绿的；只断言「合规时不命中」的话，一条永远不命中的
   规则也是绿的。
5. **站立基线缺席就抛，不取 0。** 取 0 的话三条分段线全部落在「贴着画面下缘」上，
   每一帧都会被读成腾空 —— 状态机在 ``AIR`` 与 ``CUSHION`` 之间空转。
6. **``rope.buffer_max_knee_angle`` 必须低于「膝回到站立线」那条分段线。**
   封存的门槛保证了每一次被计数的 rep 膝角一定回到过站立线附近，而缓冲不足规则
   量的正是这一段里的**最小值**。阈值高过那条线的话，「合规」的人反而被判命中。

阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据。
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import pytest

from vitalteen_domain import (
    N_LANDMARKS,
    FeatureExtractor,
    L,
    Landmark,
    PoseFrame,
    Threshold,
    ThresholdTable,
)
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_rope
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.rope import AIR, CUSHION, GROUND
from vitalteen_domain.rules import Phase
from vitalteen_domain.state_machine import Guard, Signals
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_jj.py``：角度与比值在像素空间计算。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_rope.dart`` 逐位相同** ----

#: 站立时脚尖所在的高度。它是这个合成器的地面，也是「离地」的零点。
#: 取 0.80 而不是贴着画面下缘：脚尖下方留出五分之一画幅。
_GROUND_Y = 0.80

#: 踝高于脚尖多少（脚背那一截）。脚尖是接触点，踝在它上方。
_ANKLE_RISE = 0.06

#: 大腿长与小腿长。两侧等长，于是膝角有一个闭式解。
_LEG_LEN = 0.13

#: 躯干长（归一化画幅单位）。特征用它当分母，所以它必须是真的躯干长。
_TORSO_LEN = 0.20

#: 左右同侧点的横向缝隙。侧视下本来就几乎重合，留一条缝让分母不退化。
ROPE_SIDE_GAP = 0.01

#: 站立、双腿伸直、躯干竖直、两脚等高的那一帧。
ROPE_STAND_DEG = 178.0

#: 腾空高度：比站立时高这么多（归一化画幅单位）才算跳起来。
#: 0.06 = 躯干长的 30%，换算成比值是 +0.30 —— 远在起跳线（+0.10）之上。
ROPE_AIRBORNE = 0.06

#: 落地缓冲那一段的离地高度：比值上 +0.04，**低于**落地线（+0.05）、
#: **高于**稳定线（+0.02），于是它只能落进 ``CUSHION``。
ROPE_CUSHION_LIFT = 0.008

#: 缓冲结束、站回地面时的离地高度（比值上 +0.01，低于稳定线 +0.02）。
ROPE_SETTLED_LIFT = 0.002

#: 落地缓冲的屈膝角。
ROPE_FLEXED_DEG = 150.0


def rope_foot_height_ratio(
    *, lift: float = 0.0, toe_gap: float = 0.0, scale: float = 1.0
) -> float:
    """``foot_height_ratio`` 的闭式值。

    **这个量依赖 ``scale``**，与别的合成器不同，而且这不是缺陷 —— 是这个特征的
    定义：分子是「画面下缘到脚尖」的像素距离，而画面下缘不跟着人缩放
    （缩放以画面中心为原点）。真机上它就是「离镜头远近」。
    """
    toe_mid_y = _GROUND_Y + toe_gap / 2.0 - lift
    toe_px = WIDTH * (0.5 + (toe_mid_y - 0.5) * scale)
    torso_px = WIDTH * _TORSO_LEN * scale
    return (HEIGHT - toe_px) / torso_px


def rope_foot_gap_ratio(*, toe_gap: float = 0.0) -> float:
    """``foot_gap_ratio`` 的闭式值。**与 ``scale`` 无关**。"""
    return toe_gap / _TORSO_LEN


def rope_pose(
    timestamp_ms: int = 0,
    *,
    lift: float = 0.0,
    knee_deg: float = ROPE_STAND_DEG,
    toe_gap: float = 0.0,
    trunk_deg: float = 0.0,
    scale: float = 1.0,
    side_gap_scale: float = 1.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧跳绳姿态。

    **关键的一条构造不变量：屈膝不动脚尖。** 地面接触点钉死，屈膝只抬降髋部
    （``hip = 脚尖 − 踝高 − 2·大腿长·cos((180° − 膝角)/2)``）。理由是跳绳的
    分段信号是**脚尖在画面里的高度**：要是屈膝也把脚尖抬高，「这一跳离了地没有」
    与「这一跳屈了膝没有」就会互相污染 —— 一次落地缓冲会被读成一次起跳，
    而真机上这两件事是独立的（腿弯下去，脚还踩在地上）。

    四个自变量都是**精确造出来**的（除 ``scale`` 对脚尖高度比的影响，见
    :func:`rope_foot_height_ratio`）。
    """
    assert 30.0 <= knee_deg <= 180.0, f"膝角超出合成几何的范围：{knee_deg}"

    gap = ROPE_SIDE_GAP * side_gap_scale

    knee_rad = math.radians(knee_deg)
    hip_to_ankle = 2.0 * _LEG_LEN * math.cos((math.pi - knee_rad) / 2.0)

    left_toe_y = _GROUND_Y - lift
    right_toe_y = left_toe_y + toe_gap
    # 踝与脚尖在同一个水平位置上：跳绳的两个判定都只看脚尖的**高度**。
    left_ankle_y = left_toe_y - _ANKLE_RISE
    right_ankle_y = right_toe_y - _ANKLE_RISE

    # 髋在踝的正上方、相距 ``hip_to_ankle``。屈膝越深，髋越低 —— 这正是落地
    # 缓冲在真人身上发生的事（脚踩地，身体沉下去）。
    left_hip_y = left_ankle_y - hip_to_ankle
    right_hip_y = right_ankle_y - hip_to_ankle
    hip_y = (left_hip_y + right_hip_y) / 2.0
    hip_x = 0.50

    # 膝点在髋-踝的中垂线上，向画面右侧（人面朝的方向）鼓出去。两段等长，
    # 于是它到两端的距离都等于 ``_LEG_LEN``（膝角逐位精确）。
    left_knee_x = hip_x + _LEG_LEN * math.sin((math.pi - knee_rad) / 2.0)
    right_knee_x = left_knee_x + gap
    left_knee_y = (left_hip_y + left_ankle_y) / 2.0
    right_knee_y = (right_hip_y + right_ankle_y) / 2.0

    # 躯干：从髋起、按 ``trunk_deg`` 倾斜、长度恰好是躯干长。
    trunk_rad = math.radians(trunk_deg)
    shoulder_x = hip_x + _TORSO_LEN * math.sin(trunk_rad)
    shoulder_y = hip_y - _TORSO_LEN * math.cos(trunk_rad)

    # 头接着躯干往远离髋的那一头长。不参与跳绳的任何特征。
    head_x = shoulder_x + 0.08 * math.sin(trunk_rad)
    head_y = shoulder_y - 0.08 * math.cos(trunk_rad)

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), (head_x, head_y))
    pts[L.LEFT_SHOULDER] = (shoulder_x, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (shoulder_x + gap, shoulder_y)
    pts[L.LEFT_ELBOW] = (shoulder_x + 0.02, shoulder_y + 0.07)
    pts[L.RIGHT_ELBOW] = (shoulder_x + gap + 0.02, shoulder_y + 0.07)
    pts[L.LEFT_WRIST] = (shoulder_x + 0.03, shoulder_y + 0.14)
    pts[L.RIGHT_WRIST] = (shoulder_x + gap + 0.03, shoulder_y + 0.14)
    pts[L.LEFT_HIP] = (hip_x, left_hip_y)
    pts[L.RIGHT_HIP] = (hip_x + gap, right_hip_y)
    pts[L.LEFT_KNEE] = (left_knee_x, left_knee_y)
    pts[L.RIGHT_KNEE] = (right_knee_x, right_knee_y)
    pts[L.LEFT_ANKLE] = (hip_x, left_ankle_y)
    pts[L.RIGHT_ANKLE] = (hip_x + gap, right_ankle_y)
    # 脚跟：踮着脚跳的人脚跟是抬起来的。跳绳没有任何特征用它。
    pts[L.LEFT_HEEL] = (hip_x - 0.03, left_toe_y - 0.01)
    pts[L.RIGHT_HEEL] = (hip_x + gap - 0.03, right_toe_y - 0.01)
    pts[L.LEFT_FOOT_INDEX] = (hip_x + 0.03, left_toe_y)
    pts[L.RIGHT_FOOT_INDEX] = (hip_x + gap + 0.03, right_toe_y)

    # 以画面中心为原点缩放，**所有点与落点一起缩** —— 中间那个 ``fill`` 不缩的话
    # 头顶那堆点会留在原地，包围盒的上边缘不听缩放（门禁的 `fill_ratio` 读它，
    # 于是「离得太远」那一档会时灵时不灵）。
    def at(point: tuple[float, float]) -> tuple[float, float]:
        return (
            0.5 + (point[0] - 0.5) * scale,
            0.5 + (point[1] - 0.5) * scale,
        )

    landmarks = []
    for i in range(N_LANDMARKS):
        vis = visibility
        if visibility_overrides and i in visibility_overrides:
            vis = visibility_overrides[i]
        x, y = at(pts[i])
        landmarks.append(Landmark(x=x, y=y, z=0.0, visibility=vis))

    return PoseFrame(
        landmarks=tuple(landmarks),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


@dataclass(frozen=True)
class Segment:
    """一个姿态段：连续 ``count`` 帧，四个自变量固定。

    用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（落地那一下没屈膝、
    整段有一只脚悬着），段读起来与动作一一对应。
    """

    count: int = 4
    lift: float = 0.0
    knee_deg: float = ROPE_STAND_DEG
    toe_gap: float = 0.0
    trunk_deg: float = 0.0
    scale: float = 1.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                rope_pose(
                    start + i * interval_ms,
                    lift=segment.lift,
                    knee_deg=segment.knee_deg,
                    toe_gap=segment.toe_gap,
                    trunk_deg=segment.trunk_deg,
                    scale=segment.scale,
                )
            )
    return frames


def standing_frames(
    count: int, *, start_ms: int = 0, interval_ms: int = 33, scale: float = 1.0
) -> list[PoseFrame]:
    """连续站着不动。标定用的就是它，也是分段测试的收势。"""
    return [
        rope_pose(start_ms + i * interval_ms, scale=scale) for i in range(count)
    ]


def rep_frames(
    *,
    start_ms: int = 0,
    lift: float = ROPE_AIRBORNE,
    knee_deg: float = ROPE_FLEXED_DEG,
    toe_gap: float = 0.0,
    trunk_deg: float = 0.0,
    scale: float = 1.0,
    stand_count: int = 4,
) -> list[PoseFrame]:
    """一次标准跳绳：站 → 腾空 → 落地缓冲 → 站回地面。

    回到 ``GROUND`` 的那一帧封存一次 rep。

    每段 4 帧不是凑数：状态机每次转移都要**在状态内**重新凑满 ``vote_window``
    帧的票（跳绳把它调到 2），而转移本身还要晚一帧才提交 —— 一段只有 1 帧的话，
    机器还没离开上一个状态，那一段就过完了。
    """
    return frames_from_segments(
        [
            Segment(count=stand_count, scale=scale),
            Segment(
                lift=lift,
                knee_deg=175.0,
                toe_gap=toe_gap,
                trunk_deg=trunk_deg,
                scale=scale,
            ),
            Segment(
                lift=ROPE_CUSHION_LIFT,
                knee_deg=knee_deg,
                toe_gap=toe_gap,
                trunk_deg=trunk_deg,
                scale=scale,
            ),
            Segment(
                lift=ROPE_SETTLED_LIFT,
                toe_gap=toe_gap,
                trunk_deg=trunk_deg,
                scale=scale,
            ),
        ],
        start_ms=start_ms,
    )


# ---- 基线与阈值 ----

#: 站立基线。跳绳只读其中的 ``foot_height``，但另外两个仍然是 ``Calibrator``
#: 的必采项（它们在任何机位下都算得出），所以照实填上。
STANDING_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
    foot_height=rope_foot_height_ratio(),
)

#: 内联阈值表。取值刻意离合成帧的读数远一点，免得断在阈值同侧的边界上
#: （缓冲：合规屈到 140°、违规只屈到 170°，阈 150°；前倾：4° 对 20°，阈 10°；
#: 单脚：等高对差 0.04，阈 0.10）。三个都是正数。
_THRESHOLD_ROWS = {
    "rope.buffer_max_knee_angle": (150.0, "knee_angle_L", "deg"),
    "rope.trunk_lean_max_delta": (10.0, "trunk_lean", "deg"),
    "rope.foot_gap_max_ratio": (0.10, "foot_gap_ratio", "ratio"),
}


def make_thresholds() -> ThresholdTable:
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="ROPE",
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


def rope_config() -> TrackingConfig:
    """与产品一致：跳绳走 45° 主链路，**并且带上它自己那四个工程参数**。

    这一份必须与 ``rope.build_rope`` 里那一份逐值相同，而且必须**同时**喂给
    :func:`build_rope` 与 :class:`ActionRunner` —— Python 侧的动作定义不携带
    config（与 Dart 的刻意分歧，见 ``base.py`` 里 ``ActionDefinition`` 的说明）。
    只喂一边不会报错，只会让另一半静默用回引擎默认值 —— 而引擎默认值在跳绳上
    恰好是「一次都数不出来」（见 :meth:`TestRopeConstruction.test_engine_defaults_lag_a_whole_phase_behind`）。

    **这里的重复是有代价的，别把它当成可以省掉的一行**：Python 侧每个动作的测试
    都各自重述自己的工程参数（``test_su.py`` 的 ``su_config``、``test_jj.py`` 同理），
    那些数的**出处是动作模块**。它们真的被接上产品这件事由端侧的会话测试与
    Dart 侧守卫 —— 那边 ``ActionDefinition.config`` 是定义的一部分，接不上会当场红。
    """
    return TrackingConfig(
        camera_view="oblique45",
        max_rep_frames=60,
        min_dwell_frames=1,
        vote_window=2,
        vote_required=2,
    )


def definition(*, config: TrackingConfig | None = None):
    return build_rope(STANDING_CALIBRATION, config=config or rope_config())


def runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    cfg = config or rope_config()
    return ActionRunner(
        build_rope(STANDING_CALIBRATION, config=cfg),
        thresholds=make_thresholds(),
        calibration=STANDING_CALIBRATION,
        config=cfg,
    )


def feed_all(r: ActionRunner, frames: list[PoseFrame]) -> None:
    for frame in frames:
        r.feed(frame)


def stat_of(summary, code: str):
    for stat in summary.fault_stats:
        if stat.code == code:
            return stat
    return None


def guard_of(definition_, src: str, dst: str) -> Guard:
    for transition in definition_.transitions:
        if transition.src == src and transition.dst == dst:
            return transition.guard
    raise AssertionError(f"没有 {src} → {dst} 这条边")


#: 产品机位下的特征读取器。**必须显式给这个机位**：两个脚尖特征都声明
#: ``views=("sagittal", "oblique45")``，别的机位读出来的是静默的 ``None``。
_PRODUCT_VIEW = FeatureExtractor(camera_view="oblique45")


def feature(frame: PoseFrame, code: str) -> float | None:
    return _PRODUCT_VIEW.extract(frame).get(code)


def signals(**kwargs: float | None) -> Signals:
    return dict(kwargs)


# --------------------------------------------------------------------------
# 构造期校验
# --------------------------------------------------------------------------


class TestRopeConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """两条线调乱之后状态机不会报错，只会少一条边 —— 表现是「计数偶尔不对」。"""
        with pytest.raises(Exception):
            definition(
                config=TrackingConfig(
                    camera_view="oblique45",
                    rope_takeoff_ratio=0.05,
                    rope_land_ratio=0.08,
                )
            )
        with pytest.raises(Exception):
            definition(
                config=TrackingConfig(
                    camera_view="oblique45",
                    rope_land_ratio=0.03,
                    rope_settle_ratio=0.04,
                )
            )

    def test_missing_foot_height_baseline_raises(self) -> None:
        """缺席就抛，不取 0 —— 取 0 的话每一帧都会被读成腾空。"""
        without = Calibration(
            knee_angle=175.0, trunk_lean=0.0, heel_rise_ratio=0.0, frames=15
        )
        with pytest.raises(ValueError):
            build_rope(without)

    def test_engine_defaults_lag_a_whole_phase_behind(self) -> None:
        """**本文件里最值钱的一条断言。**

        引擎默认的 5/4/3 让每个状态都要攒满 5 帧票才可能转移，而一次跳绳的腾空段
        在 20 fps 下只有 4–6 帧：状态机永远落在人后面。把它钉在这里，是为了让
        「顺手把参数改回默认」这件事红在测试上 —— 而这正是 Python 侧最容易踩的
        地方：那一组数只在 ``rope.py`` 里，runner 不带它就是引擎默认值。
        """
        frames = rep_frames()

        tuned = runner()
        feed_all(tuned, frames)
        assert tuned.rep_count == 1

        lagging = runner(
            config=TrackingConfig(camera_view="oblique45", max_rep_frames=60)
        )
        feed_all(lagging, frames)
        assert lagging.rep_count == 0
        # 而且机器**落在人的后面**：这批帧喂完时人早就站回地面了。
        assert lagging.current_state != GROUND

    def test_only_the_trunk_rule_hangs_on_a_baseline(self) -> None:
        d = definition()
        assert set(d.threshold_offsets.keys()) == {"rope.trunk_lean_max_delta"}

    def test_phase_map_is_deliberately_empty(self) -> None:
        """落地缓冲只有 2–5 帧；切成相位窗口会让最该判的那些人失明。"""
        d = definition()
        assert d.state_to_phase == {}
        assert all(rule.phase == Phase.ALL for rule in d.rules)

    def test_default_camera_view_is_oblique45(self) -> None:
        d = definition()
        assert d.camera_view == "oblique45"

        frame = rope_pose(knee_deg=ROPE_FLEXED_DEG)
        oblique = FeatureExtractor(camera_view="oblique45")
        for code in (
            "knee_angle_L",
            "trunk_lean",
            "foot_height_ratio",
            "foot_gap_ratio",
        ):
            assert oblique.extract(frame).get(code) is not None, code
        # 正视下两个脚尖特征都读不出来：脚尖的「高度」在正面就是镜头方向本身。
        # 判据缺一个 = 少一条规则，而它不报错。
        frontal = FeatureExtractor(camera_view="frontal")
        for code in ("foot_height_ratio", "foot_gap_ratio"):
            assert frontal.extract(frame).get(code) is None, code


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_standing_foot_height_ratio_is_one(self) -> None:
        frame = rope_pose()
        assert feature(frame, "foot_height_ratio") == pytest.approx(
            rope_foot_height_ratio(), abs=1e-9
        )
        assert rope_foot_height_ratio() == pytest.approx(1.0, abs=1e-9)

    def test_knee_flexion_does_not_move_the_toe(self) -> None:
        """**整个合成器的构造不变量**：真机上「腿弯下去」与「脚还踩在地上」

        是同时发生的。屈膝若也抬高脚尖，一次落地缓冲会被读成一次起跳。
        """
        for deg in (178.0, 150.0, 120.0):
            frame = rope_pose(knee_deg=deg, lift=0.03)
            assert feature(frame, "knee_angle_L") == pytest.approx(deg, abs=1e-9)
            assert feature(frame, "knee_angle_R") == pytest.approx(deg, abs=1e-9)
            assert feature(frame, "foot_height_ratio") == pytest.approx(
                rope_foot_height_ratio(lift=0.03), abs=1e-9
            )

    def test_lift_changes_only_the_toe_height(self) -> None:
        standing = rope_pose(trunk_deg=5.0, knee_deg=160.0)
        airborne = rope_pose(lift=ROPE_AIRBORNE, trunk_deg=5.0, knee_deg=160.0)
        for code in ("knee_angle_L", "trunk_lean"):
            assert feature(airborne, code) == pytest.approx(feature(standing, code), abs=1e-9)
        assert (
            feature(airborne, "foot_height_ratio") - feature(standing, "foot_height_ratio")
            == pytest.approx(ROPE_AIRBORNE / _TORSO_LEN, abs=1e-9)
        )

    def test_foot_gap_ratio_is_exact(self) -> None:
        for gap in (0.0, 0.02, 0.04):
            frame = rope_pose(toe_gap=gap)
            assert feature(frame, "foot_gap_ratio") == pytest.approx(
                rope_foot_gap_ratio(toe_gap=gap), abs=1e-9
            )
        assert rope_foot_gap_ratio(toe_gap=0.04) == pytest.approx(0.20, abs=1e-9)

    def test_trunk_lean_is_exact_on_both_sides(self) -> None:
        """符号只对「哪一侧」有意义，所以两侧都要造得出来（规则取绝对值）。"""
        for deg in (-20.0, -4.0, 0.0, 4.0, 20.0):
            frame = rope_pose(trunk_deg=deg)
            assert feature(frame, "trunk_lean") == pytest.approx(deg, abs=1e-9)

    def test_scale_shifts_only_the_toe_height_ratio(self) -> None:
        """**这个不对称是这个特征的定义，不是合成器的缺陷。**

        另外三个量与 ``scale`` 无关，只有 ``foot_height_ratio`` 跟着走 ——
        它的分子是「画面下缘到脚尖」，而画面下缘不跟着人缩放。
        """
        near = rope_pose(scale=1.5, knee_deg=160.0, toe_gap=0.02)
        far = rope_pose(knee_deg=160.0, toe_gap=0.02)
        for code in ("knee_angle_L", "trunk_lean", "foot_gap_ratio"):
            assert feature(near, code) == pytest.approx(feature(far, code), abs=1e-9)
        assert feature(near, "foot_height_ratio") == pytest.approx(
            rope_foot_height_ratio(toe_gap=0.02, scale=1.5), abs=1e-9
        )
        assert feature(near, "foot_height_ratio") < feature(far, "foot_height_ratio")


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestRopeSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        r = runner()
        feed_all(r, rep_frames())
        assert r.rep_count == 1
        assert r.discarded_reps == 0
        assert r.current_state == GROUND

    def test_sealed_window_contains_the_landing_cushion(self) -> None:
        """窗口从离开 GROUND 的那一帧起、到重新进入 GROUND 的那一帧止。

        腾空 4 + 落地缓冲 4 + 落地 1 = 9 帧。**两态环下这里会少掉一半**：
        封存发生在脚尖刚碰到地面的那一帧 —— 而缓冲不足规则量的正是被切掉的那一段。
        """
        r = runner()
        feed_all(r, rep_frames())
        assert len(r.windows) == 1
        frames = r.windows[0].frames
        assert len(frames) == 9
        assert frames[-1].get("knee_angle_L") == pytest.approx(ROPE_STAND_DEG, abs=1e-6)
        assert min(f.get("knee_angle_L") for f in frames) == pytest.approx(
            ROPE_FLEXED_DEG, abs=1e-6
        )

    def test_air_never_falls_straight_back_to_ground(self) -> None:
        """``AIR`` 出去的第一条边不能是「回到 GROUND」—— 那一步一旦被简化掉，

        封存点会提前到脚尖刚触地，窗口长度静默缩水。
        """
        d = definition()
        assert [t.dst for t in d.transitions if t.src == AIR] == [CUSHION]

    def test_standing_still_is_neither_counted_nor_discarded(self) -> None:
        r = runner()
        feed_all(r, standing_frames(60))
        assert r.rep_count == 0
        assert r.discarded_reps == 0
        assert r.current_state == GROUND

    def test_heel_raise_below_the_takeoff_line_does_not_count(self) -> None:
        """脚尖只抬到起跳线之下：机器始终没离开 GROUND，没有段落可弃。"""
        r = runner()
        feed_all(
            r,
            standing_frames(4)
            + frames_from_segments(
                [Segment(count=6, lift=0.015, knee_deg=176.0)], start_ms=4 * 33
            )
            + standing_frames(6, start_ms=10 * 33),
        )
        assert r.rep_count == 0
        assert r.discarded_reps == 0
        assert r.current_state == GROUND

    def test_landing_and_staying_crouched_times_out(self) -> None:
        """**专判「膝角回到站立线」那半句守卫。**

        脚尖早在触地那一帧就贴回地面了，所以只靠脚尖的话这一次会在触地后两三帧内
        封存 —— 而「落地就不起来了」恰恰是缓冲不足规则最该说的那一类人。
        """
        r = runner()
        feed_all(
            r,
            standing_frames(4)
            + frames_from_segments(
                [
                    Segment(count=5, lift=ROPE_AIRBORNE, knee_deg=176.0),
                    # 脚尖已经贴回稳定线以下，但膝角一直停在 150°。
                    Segment(
                        count=70,
                        lift=ROPE_SETTLED_LIFT,
                        knee_deg=ROPE_FLEXED_DEG,
                    ),
                ],
                start_ms=4 * 33,
            ),
        )
        assert r.rep_count == 0
        assert r.discarded_reps == 1

    def test_jumping_again_before_the_cushion_ends_still_counts(self) -> None:
        """``CUSHION → AIR`` 那条回退边的用途：连跳的人不会被卡在缓冲里等超时。"""
        r = runner()
        feed_all(
            r,
            standing_frames(4)
            + frames_from_segments(
                [
                    Segment(count=5, lift=ROPE_AIRBORNE, knee_deg=176.0),
                    Segment(count=3, lift=ROPE_CUSHION_LIFT, knee_deg=ROPE_FLEXED_DEG),
                    Segment(count=5, lift=ROPE_AIRBORNE, knee_deg=176.0),
                    Segment(count=4, lift=ROPE_CUSHION_LIFT, knee_deg=ROPE_FLEXED_DEG),
                    Segment(count=4, lift=ROPE_SETTLED_LIFT),
                ],
                start_ms=4 * 33,
            ),
        )
        assert r.rep_count == 1
        assert r.discarded_reps == 0

    def test_transition_guard_bounds(self) -> None:
        """上面那些分段测试变绿也可能是因为「压根没离开 GROUND」，这里直接对守卫求值。"""
        d = definition()
        base = STANDING_CALIBRATION.foot_height
        assert base is not None
        stand_line = STANDING_CALIBRATION.knee_angle - 8.0

        def air(ratio: float) -> bool:
            return guard_of(d, GROUND, AIR)(signals(foot_height_ratio=ratio))

        def landed(ratio: float) -> bool:
            return guard_of(d, AIR, CUSHION)(signals(foot_height_ratio=ratio))

        def recovered(ratio: float, knee: float) -> bool:
            return guard_of(d, CUSHION, GROUND)(
                signals(foot_height_ratio=ratio, knee_angle_L=knee, knee_angle_R=knee)
            )

        assert air(base + 0.10) is False
        assert air(base + 0.1001) is True
        assert landed(base + 0.05) is False
        assert landed(base + 0.0499) is True
        assert recovered(base + 0.02, STANDING_CALIBRATION.knee_angle) is False
        assert recovered(base + 0.0199, stand_line) is False
        assert recovered(base + 0.0199, stand_line + 0.1) is True

        # CUSHION 的两条出边互斥：相隔 (takeoff − settle)。
        middle = base + 0.03
        assert air(middle) is False
        assert recovered(middle, STANDING_CALIBRATION.knee_angle) is False

        # 取不到量时四条守卫全不成立 —— 不能拿 0 顶替（0 正是「贴着画面下缘」）。
        for src, dst in (
            (GROUND, AIR),
            (AIR, CUSHION),
            (CUSHION, GROUND),
            (CUSHION, AIR),
        ):
            assert guard_of(d, src, dst)({}) is False, f"{src}->{dst}"

        # 膝角缺一帧也不许封存：只看脚尖的话触地那一帧就会封存。
        assert (
            guard_of(d, CUSHION, GROUND)(signals(foot_height_ratio=base + 0.01))
            is False
        )


# --------------------------------------------------------------------------
# 三条规则
# --------------------------------------------------------------------------


class TestRopeRules:
    def test_low_buffer_fires_only_on_the_stiff_rep(self) -> None:
        """阈值必须**低于**「膝回到站立线」（175 − 8 = 167°），否则第二次封存被卡住。"""
        stiff = runner()
        feed_all(stiff, rep_frames(knee_deg=170.0))
        assert stiff.rep_count == 1
        assert stat_of(stiff.finish_set(), "ROPE_LOW_BUFFER") is not None

        soft = runner()
        feed_all(soft, rep_frames(knee_deg=140.0))
        assert soft.rep_count == 1
        assert stat_of(soft.finish_set(), "ROPE_LOW_BUFFER") is None

    def test_trunk_lean_fires_only_on_the_leaning_rep(self) -> None:
        leaning = runner()
        feed_all(leaning, rep_frames(trunk_deg=20.0))
        assert leaning.rep_count == 1
        assert stat_of(leaning.finish_set(), "ROPE_TRUNK_LEAN") is not None

        upright = runner()
        feed_all(upright, rep_frames(trunk_deg=4.0))
        assert stat_of(upright.finish_set(), "ROPE_TRUNK_LEAN") is None

        # 符号不是体育含义：往另一侧趴同样要命中（规则用 use_abs）。
        other = runner()
        feed_all(other, rep_frames(trunk_deg=-20.0))
        assert stat_of(other.finish_set(), "ROPE_TRUNK_LEAN") is not None

        # 而「比本人站着时多前倾了多少」—— 站着本来就带前倾的人不该被判错。
        sloucher_cal = Calibration(
            knee_angle=175.0,
            trunk_lean=7.0,
            heel_rise_ratio=0.0,
            frames=15,
            foot_height=rope_foot_height_ratio(),
        )
        cfg = TrackingConfig(camera_view="oblique45")
        sloucher = ActionRunner(
            build_rope(sloucher_cal, config=cfg),
            thresholds=make_thresholds(),
            calibration=sloucher_cal,
            config=cfg,
        )
        feed_all(sloucher, rep_frames(trunk_deg=12.0))
        assert stat_of(sloucher.finish_set(), "ROPE_TRUNK_LEAN") is None

    def test_single_leg_fires_only_on_the_uneven_rep(self) -> None:
        """阈值是**绝对**比值（不挂基线）：站稳的人两脚尖本来等高。

        0.04 的高度差 = 比值 0.20。它同时把站立基线压低了 0.10（中点跟着走），
        但两条分段线记的是增量，所以这一次照样起跳、照样计数。
        """
        one_legged = runner()
        feed_all(one_legged, rep_frames(toe_gap=0.04))
        assert one_legged.rep_count == 1
        assert stat_of(one_legged.finish_set(), "ROPE_SINGLE_LEG") is not None

        both = runner()
        feed_all(both, rep_frames())
        assert stat_of(both.finish_set(), "ROPE_SINGLE_LEG") is None

    def test_a_clean_rep_has_no_faults(self) -> None:
        r = runner()
        feed_all(r, rep_frames())
        assert r.rep_count == 1
        assert r.finish_set().fault_stats == ()


# --------------------------------------------------------------------------
# 阈值表的三个键
# --------------------------------------------------------------------------


class TestRopeThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        table = make_thresholds()
        for rule in definition().rules:
            value = table.get(rule.threshold_key).value
            assert math.isfinite(value) and value > 0

    def test_buffer_threshold_stays_below_the_stand_line(self) -> None:
        """**本动作独有的一条阈值-分段关系。**

        ``CUSHION → GROUND`` 的守卫保证每一次被计数的 rep 膝角都回到过
        ``站立膝角 − standing_hysteresis_deg``；而 ``ROPE_LOW_BUFFER`` 取的是
        窗口内膝角的**最小值**。阈值高过那条线的话，**每一次** rep 的最小值都会
        超过它 —— 包括那些老老实实屈膝到 140° 的人。
        """
        # 「膝回到站立线」那条分段线由 `standing_hysteresis_deg` 决定，跳绳没有
        # 覆盖它，所以取的就是引擎默认值。
        stand_line = (
            STANDING_CALIBRATION.knee_angle - TrackingConfig().standing_hysteresis_deg
        )
        limit = make_thresholds().get("rope.buffer_max_knee_angle").value
        assert limit < stand_line
