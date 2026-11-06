"""坐位体前屈动作定义测试（``app/test/domain/sit_reach_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住六类结论，每一类都是「不做就会**静默**出错」的：

1. **计数点只能落在 ``SIT_UPRIGHT`` 上。** 落到 ``HOLDING`` 上的话，「这一次腿伸直
   了没有」这个证据正好落在 rep 缓冲的边界上（缓冲从离开 resting_state 开始封存），
   而且**偏向折得快的人**。下面那条「伸到一半又坐直」的用例量到的就是这件事。
2. **两条规则的窗口不一样，而且必须不一样。** ``SRT_KNEE_BENT`` 取 ``Phase.BOTTOM``
   （屈膝要在前伸到底那一刻才说明问题），``SRT_BALLISTIC`` 取 ``Phase.ALL``
   （弹振发生在**前伸的过程中**，抖到位就停住的人保持段可以一点也不抖）。
   窗口写反的表现是同一件事：这条判定时不时冒出来，看不出病因 ——
   所以下面两条各自都有反例（前伸途中屈膝 / 平稳前伸）。
3. **「算不算一次」与「做得好不好」是两条线。** 伸到一半的那些次根本不算
   （走 ``discarded_reps``），而弹振、屈膝的那些次**照样算一次**。
4. **两条判定一个基线都不挂。** 膝角与髋角都是关节夹角，与本人身材无关；
   挂错的表现是阈值整体挪位、判错率变，不报错。
5. **``hip_angle_L`` 是「越小越前折」**，所以这一份的分段线比较方向与仰卧起坐
   那一份**正好相反**（那边是越大越躺平）。照抄仰卧起坐的写法会让四条守卫全部
   反向，而状态机仍然「跑得动」—— 只是计数变成了「折得越浅越算一次」。
6. **标定与定义之间的接缝。** 上面每一条用的都是手写的 ``SEATED_CALIBRATION``，
   于是「45° 机位下这组基线根本采不满」这类错一条都发现不了 —— 而它的表现
   同样是静默的：标定条卡在 0、屏幕上没有任何错误。最后一组真喂一遍坐姿帧。

阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
与真实资产的对照在 Dart 侧「真实阈值表」那组里（Python 侧没有 assets 目录）。
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
from vitalteen_domain.exercises import Calibration, Calibrator, TrackingConfig, build_srt
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.sit_reach import (
    HOLDING,
    REACHING,
    RETURNING,
    SIT_UPRIGHT,
)
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Direction, Phase, Reduce, count_reversals
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**：角度在像素空间计算，非方形画幅会把 x 与 y 缩放成
#: 不同倍率，于是合成出来的髋角不再是「90° 减去前折角」那个闭式值 ——
#: 而它不会报错，只会让分段线与判定一起偏。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_srt.dart`` 逐位相同** ----

#: 垫面的高度。**髋与膝自始至终在它上面**（腿贴着垫子前伸），
#: 所以它同时是这个量纲的零点。
_MAT_Y = 0.70

#: 髋中点的横坐标。臀在整个动作里钉在这里，腿往前（+x）伸出去。
_HIP_X = 0.32

#: 躯干长。``hip_angle_L`` 只用方向、不用长度，但肩与头的位置都要靠它摆。
_TORSO_LEN = 0.20

#: 大腿长与小腿长。与 ``hip_angle_L`` 无关，只决定腿伸出去多远、屈膝时踝抬多高。
_THIGH_LEN = 0.12
_SHIN_LEN = 0.12

#: 左右同侧点的横向缝隙。侧视下本来就几乎重合，留一条缝是为了让分母不退化。
SIDE_GAP = 0.01

#: 坐直（躯干竖直）。
SRT_UPRIGHT_DEG = 0.0

#: 前伸到底。``hip_angle_L`` = 90 − 50 = 40°，落在保持线（55°）明显之下。
SRT_REACH_DEG = 50.0

#: 前伸途中经过的角度。``hip_angle_L`` = 65°：在「离开坐直」那条线（67°）之下、
#: 「开始坐回」那条线（63°）之上 —— 正好落在滞回带里，这是刻意的。
SRT_MID_DEG = 25.0

#: 弹振借力时来回摆的两个姿势 —— **都落在前伸途中**（髋角 65° 与 57°）。
#:
#: 这两条线之间才有空间摆：髋角低到保持线（55°）就是「已经前伸到底」（进
#: ``HOLDING``），高到「离开坐直」那条线（67°）就退回 ``SIT_UPRIGHT`` ——
#: 摆动跨过任一条，状态机都会在相位之间来回跳，那时测的就成了分段本身。
#: 所以摆幅只有 8°，但它仍然远大于 ``REVERSAL_DEADBAND``（2°），够用。
SRT_BALLISTIC_NEAR_DEG = 25.0  # 髋角 65°（与 SRT_MID_DEG 同姿势）
SRT_BALLISTIC_FAR_DEG = 33.0  # 髋角 57°

#: 腿伸直时的膝角。取 175° 而不是 180°：180° 是三点共线的奇异位置。
SRT_STRAIGHT_KNEE_DEG = 175.0

#: 屈膝。国标要求腿伸直，这是走形的常见做法（膝盖一弯，上身就够得更远）。
SRT_BENT_KNEE_DEG = 140.0


def srt_hip_angle_deg(*, torso_lean_deg: float = SRT_UPRIGHT_DEG) -> float:
    """由前折角算出 ``hip_angle_L`` 的闭式值。**测试拿它当期望值**。

    髋→膝恒为 +x 方向（两者都钉在垫面线上），所以这个夹角就是「髋→肩」与 +x 的
    夹角，而「髋→肩」与竖直方向的夹角是 ``torso_lean_deg``。
    """
    return 90.0 - torso_lean_deg


def srt_pose(
    timestamp_ms: int = 0,
    *,
    torso_lean_deg: float = SRT_UPRIGHT_DEG,
    knee_deg: float = SRT_STRAIGHT_KNEE_DEG,
    scale: float = 1.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧坐位体前屈姿态。

    Args:
        torso_lean_deg: 躯干偏离竖直多少度（0 = 坐直、越大越往前折）。**精确**，
            ``hip_angle_L`` 逐位等于 :func:`srt_hip_angle_deg`。
        knee_deg: ``knee_angle_L`` 与 ``knee_angle_R`` 的目标值。**精确**。
        scale: 把人整体按画面中心缩放（1.0 = 原样）。**它不改变任何角度**，
            只改变人占画幅多大。

    膝角 0 与 180 都会让踝退到膝上或与髋膝共线，闭式解的两个端点没有意义 ——
    与其造出一个退化的姿势让下游静默算错，不如在原地响亮地说清楚。
    """
    assert 1.0 < knee_deg < 180.0, (
        f"屈膝角必须落在 (1, 180) 开区间里（收到 {knee_deg}），"
        "两端会让踝退到膝上或三点共线"
    )

    lean = math.radians(torso_lean_deg)
    knee = math.radians(knee_deg)

    # 髋、膝都钉在垫面线上，腿沿 +x 伸出去。
    hip_x, knee_x = _HIP_X, _HIP_X + _THIGH_LEN

    # 踝由膝角反解：膝→踝 与 膝→髋（即 −x）的夹角就是膝角。
    ankle_x = knee_x - _SHIN_LEN * math.cos(knee)
    ankle_y = _MAT_Y - _SHIN_LEN * math.sin(knee)

    # 肩绕髋转：前折角就是从竖直方向往 +x 那一侧转过的角度。
    shoulder_x = hip_x + _TORSO_LEN * math.sin(lean)
    shoulder_y = _MAT_Y - _TORSO_LEN * math.cos(lean)

    # 头接着躯干往远离髋的那一头长一点。它不参与任何特征，但给出来更接近真实帧。
    head = (
        shoulder_x + 0.08 * (shoulder_x - hip_x) / _TORSO_LEN,
        shoulder_y + 0.08 * (shoulder_y - _MAT_Y) / _TORSO_LEN,
    )

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), head)
    pts[L.LEFT_SHOULDER] = (shoulder_x, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (shoulder_x + SIDE_GAP, shoulder_y)
    # 手臂往前下方伸出去一点（够向脚尖），不参与任何特征。
    pts[L.LEFT_ELBOW] = (shoulder_x + 0.06, shoulder_y + 0.04)
    pts[L.RIGHT_ELBOW] = (shoulder_x + 0.06 + SIDE_GAP, shoulder_y + 0.04)
    pts[L.LEFT_WRIST] = (shoulder_x + 0.12, shoulder_y + 0.06)
    pts[L.RIGHT_WRIST] = (shoulder_x + 0.12 + SIDE_GAP, shoulder_y + 0.06)
    pts[L.LEFT_HIP] = (hip_x, _MAT_Y)
    pts[L.RIGHT_HIP] = (hip_x + SIDE_GAP, _MAT_Y)
    pts[L.LEFT_KNEE] = (knee_x, _MAT_Y)
    pts[L.RIGHT_KNEE] = (knee_x + SIDE_GAP, _MAT_Y)
    pts[L.LEFT_ANKLE] = (ankle_x, ankle_y)
    pts[L.RIGHT_ANKLE] = (ankle_x + SIDE_GAP, ankle_y)
    # 脚跟与脚尖不参与坐位体前屈的任何特征，但给出来更接近真实帧。
    pts[L.LEFT_HEEL] = (ankle_x - 0.02, ankle_y - 0.01)
    pts[L.RIGHT_HEEL] = (ankle_x - 0.02 + SIDE_GAP, ankle_y - 0.01)
    pts[L.LEFT_FOOT_INDEX] = (ankle_x + 0.02, ankle_y - 0.01)
    pts[L.RIGHT_FOOT_INDEX] = (ankle_x + 0.02 + SIDE_GAP, ankle_y - 0.01)

    # 以画面中心为原点缩放。**所有点一起缩** —— 漏掉哪一处，那一处在「离得远」的
    # 合成帧里就会留在原地，包围盒不听缩放的话，距离就测不出来了。
    def at(point: tuple[float, float]) -> tuple[float, float]:
        return (0.5 + (point[0] - 0.5) * scale, 0.5 + (point[1] - 0.5) * scale)

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
    """一个姿态段：连续 ``count`` 帧，自变量固定。

    用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（前伸途中膝盖松了、
    那一段在抖），段读起来与动作一一对应。
    """

    torso_lean_deg: float = SRT_UPRIGHT_DEG
    count: int = 14
    knee_deg: float = SRT_STRAIGHT_KNEE_DEG
    scale: float = 1.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                srt_pose(
                    start + i * interval_ms,
                    torso_lean_deg=segment.torso_lean_deg,
                    knee_deg=segment.knee_deg,
                    scale=segment.scale,
                )
            )
    return frames


def rep_frames(
    *,
    knee_deg: float = SRT_STRAIGHT_KNEE_DEG,
    reach_deg: float = SRT_REACH_DEG,
) -> list[PoseFrame]:
    """一次标准坐位体前屈：坐直 → 前伸 → 保持 → 坐回 → 坐直。

    回到 ``SIT_UPRIGHT`` 的那一帧封存一次 rep。

    中间那两段不能省：状态机要在 ``min_dwell_frames`` 与投票窗口里攒够同类证据
    才换相，而 ``SIT_UPRIGHT→HOLDING`` 不是一条边 —— 少了前伸段，保持那一段
    会先在 ``REACHING`` 里被投票，行为与真实动作对不上。
    """
    return frames_from_segments(
        [
            Segment(knee_deg=knee_deg),
            Segment(torso_lean_deg=SRT_MID_DEG, knee_deg=knee_deg),
            Segment(torso_lean_deg=reach_deg, knee_deg=knee_deg),
            Segment(torso_lean_deg=SRT_MID_DEG, knee_deg=knee_deg),
            Segment(knee_deg=knee_deg),
        ]
    )


def knee_bent_in_reaching_frames() -> list[PoseFrame]:
    """一次「前伸途中膝盖松了一下、到底之后又伸直了」的动作。

    **这一份是 ``SRT_KNEE_BENT`` 那条规则窗口取 ``Phase.BOTTOM`` 的理由。**
    膝盖只在前伸段弯，保持段是直的 —— 窗口取整段的话它会被判屈膝，
    而前伸途中膝盖松一下根本不影响成绩。
    """
    return frames_from_segments(
        [
            Segment(),
            Segment(torso_lean_deg=SRT_MID_DEG, knee_deg=SRT_BENT_KNEE_DEG),
            Segment(torso_lean_deg=SRT_REACH_DEG),
            Segment(torso_lean_deg=SRT_MID_DEG),
            Segment(),
        ]
    )


def ballistic_frames(*, swings: int = 3) -> list[PoseFrame]:
    """一次「靠来回弹把上身甩出去」的动作。

    形状与 :func:`rep_frames` **只有一处不同**：前伸途中的那一段来回摆
    （每条边 3 帧、在 ``SRT_BALLISTIC_NEAR_DEG`` 与 ``SRT_BALLISTIC_FAR_DEG``
    之间摆）。于是两种人**前伸到底的角度完全一样**（都到 ``SRT_REACH_DEG``），
    只有序列的形状分得开 —— 这正是 ``SRT_BALLISTIC`` 必须存在、而不能拿一条
    深度类规则顶替的理由。

    摆动只出现在 ``REACHING`` 那一段里，前伸到底之后人是静的 —— 所以
    「只看 ``Phase.BOTTOM``」的窗口在这条序列上数出来一次掉头都没有。
    """
    return frames_from_segments(
        [
            Segment(),
            Segment(torso_lean_deg=SRT_MID_DEG),
            *(
                Segment(
                    count=3,
                    torso_lean_deg=(
                        SRT_BALLISTIC_NEAR_DEG if i % 2 == 0 else SRT_BALLISTIC_FAR_DEG
                    ),
                )
                for i in range(swings * 2)
            ),
            Segment(torso_lean_deg=SRT_REACH_DEG),
            Segment(torso_lean_deg=SRT_MID_DEG),
            Segment(),
        ]
    )


#: 坐直的一段。``SIT_UPRIGHT`` 是坐位体前屈的 resting_state，开场与收尾都用它。
UPRIGHT_SEGMENT = Segment()

#: 前伸途中经过的一段（两条分段线之间）。
MID_SEGMENT = Segment(torso_lean_deg=SRT_MID_DEG)

#: 前伸到底的一段。
REACH_SEGMENT = Segment(torso_lean_deg=SRT_REACH_DEG)

#: 坐姿基线。**两条判定一条都不用它**（膝角与髋角都是绝对量），但它仍然要采 ——
#: 那是 ``Calibrator`` 的门槛，也是「开始之前先坐好」那一步的产物。
SEATED_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
)

#: 内联阈值表。两条判定的取值只为本测试服务；刻意离合成帧的读数远一点，
#: 免得断在阈值同侧的边界上（伸直的膝 175° 对阈 150°、屈膝的 140° 对阈 150°；
#: 平稳前伸掉头 1 次对阈 3 次、弹振 5 次对阈 3 次）。
_THRESHOLD_ROWS = {
    "srt.knee_angle_min": (150.0, "knee_angle_L", "deg"),
    "srt.ballistic_reversals_max": (3.0, "hip_angle_L", "count"),
}


def make_thresholds() -> ThresholdTable:
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="SRT",
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


def srt_config() -> TrackingConfig:
    """与产品一致：坐位体前屈走 45° 主链路。"""
    return TrackingConfig(camera_view="oblique45", max_rep_frames=600)


def srt_runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    """构造一个阈值已核定的坐位体前屈 runner。

    ``config`` 必须**同时**喂给 :func:`build_srt` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or srt_config()
    return ActionRunner(
        build_srt(SEATED_CALIBRATION, config=cfg),
        thresholds=make_thresholds(),
        calibration=SEATED_CALIBRATION,
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


#: 产品机位下的特征读取器。
_PRODUCT_VIEW = FeatureExtractor(camera_view="oblique45")


def feature(frame: PoseFrame, code: str) -> float | None:
    return _PRODUCT_VIEW.extract(frame).get(code)


def guard_of(definition, src: str, dst: str):
    for transition in definition.transitions:
        if transition.src == src and transition.dst == dst:
            return transition.guard
    raise AssertionError(f"没有 {src} → {dst} 这条边")


def hip_angles(frames) -> list[float]:
    """一帧帧读 ``hip_angle_L``（缺失的帧跳过）。

    接的是 ``PoseFrame`` 或 ``FrameFeatures`` 都行 —— 后者只有封存下来的窗口里
    才有，而相位标签也只在那里有。
    """
    if frames and isinstance(frames[0], PoseFrame):
        frames = [_PRODUCT_VIEW.extract(frame) for frame in frames]
    out: list[float] = []
    for frame in frames:
        value = frame.get("hip_angle_L")
        if value is not None:
            out.append(value)
    return out


def knee_min(window, phase: Phase) -> float:
    """某个相位里 ``knee_angle_L`` 的最小值。

    **必须逐帧取、不能整段平均** —— 规则用的是 ``Reduce.MIN``，
    与它对齐才问得到同一件事。
    """
    values = [
        value
        for frame in window.select(phase)
        if (value := frame.get("knee_angle_L")) is not None
    ]
    assert values, f"{phase} 那一段里一帧膝角都没有"
    return min(values)


# --------------------------------------------------------------------------
# 构造期校验
# --------------------------------------------------------------------------


class TestSrtConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """分段线顺序被违反时当场炸，而不是悄悄多一条边。

        这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
        「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，离病因很远。

        **要把保持线抬到坐直线上面**（这里是 90 对 75），这才是髋角这一侧的
        常见错法：照抄仰卧起坐那份写法的人，会下意识觉得「线越高越难」。
        """
        with pytest.raises(ValueError, match="分段线顺序非法"):
            build_srt(
                SEATED_CALIBRATION,
                config=TrackingConfig(
                    camera_view="oblique45",
                    sit_reach_upright_deg=75.0,
                    sit_reach_holding_deg=90.0,
                ),
            )

    def test_default_camera_view_is_oblique45(self) -> None:
        """默认机位是 45°；两个量在正视下**也算得出来** —— 所以正拍是静默失败。

        **与仰卧起坐那一份的同类断言正好相反，这是刻意的。** 仰卧起坐的两个量带
        机位门控，正拍下是 ``None``；而这里的两个量（``hip_angle_L``、
        ``knee_angle_L``）都没有门控，正拍下**照样有数**。

        于是正对镜头时没有一处会报错：前折发生在镜头方向本身上面，肩朝镜头挪过去，
        画面里的髋角几乎不变 —— 状态机永远停在 ``SIT_UPRIGHT``，一次都数不上，
        而 HUD 一直显示「坐直」（那正好是实情的一半）。所以 45° 那件事只能靠
        ``srtSpec.blocking_advice`` 用话讲清楚，特征层是拦不住的。
        """
        assert build_srt(SEATED_CALIBRATION).camera_view == "oblique45"

        frame = srt_pose()
        frontal = FeatureExtractor(camera_view="frontal")
        for code in ("hip_angle_L", "knee_angle_L"):
            assert feature(frame, code) is not None, code
            assert frontal.extract(frame).get(code) is not None, (
                f"{code} 在正视下也应该「算得出来」—— 这正是它危险的地方"
            )

    def test_all_rules_use_absolute_thresholds(self) -> None:
        """两条判定都用绝对阈值 —— 一个基线偏移都不挂。

        挂错的表现是阈值整体挪位、判错率变，而它不报错。膝角与髋角都是关节夹角，
        与体型无关，所以偏移表必须为空。
        """
        definition = build_srt(SEATED_CALIBRATION, config=srt_config())
        assert definition.threshold_offsets == {}, "两条判定的阈值都是绝对的，一个偏移都不该有"


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_hip_angle_is_exact(self) -> None:
        """髋角逐位等于 90° 减去前折角。

        三个姿态各验一次：坐直（90）、途中（65）、前伸到底（40）。这条同时是
        合成帧几何的自检 —— 它错了，下面所有分段与规则的用例都是在测一个别的动作。
        """
        for deg in (SRT_UPRIGHT_DEG, SRT_MID_DEG, SRT_REACH_DEG):
            frame = srt_pose(torso_lean_deg=deg)
            assert feature(frame, "hip_angle_L") == pytest.approx(
                srt_hip_angle_deg(torso_lean_deg=deg), abs=1e-9
            ), f"前折角 {deg}° 的髋角应当逐位等于闭式解"
        assert srt_hip_angle_deg(torso_lean_deg=SRT_UPRIGHT_DEG) > 75.0
        assert srt_hip_angle_deg(torso_lean_deg=SRT_REACH_DEG) < 55.0

    def test_knee_angle_is_exact(self) -> None:
        for deg in (140.0, 160.0, 175.0):
            frame = srt_pose(knee_deg=deg)
            assert feature(frame, "knee_angle_L") == pytest.approx(deg, abs=1e-9)
            # 两侧都造得出来，规则取的那一侧才等于它。
            assert feature(frame, "knee_angle_R") == pytest.approx(deg, abs=1e-9)

    def test_ballistic_series_has_five_reversals_and_steady_one(self) -> None:
        """弹振序列掉头 5 次，平稳序列 1 次。

        **直接对归约函数取值**，而不是反推两条规则的命中与否：这样「弹振是几次」
        与「阈值该定多少」是两件可以分别检查的事。

        平稳那一次是 1 而不是 0：一次「下到底再上来」本身就有一次掉头
        （``count_reversals`` 的第一步只用来定初始方向、不计入）。所以阈值不能
        定成 0 或 1 —— 那会把所有人的每一次标准动作都判成弹振。

        弹振那一次的 5 = 摆的 4 次 + 最后起身那 1 次（两边都有它，所以真正把它与
        平稳那一次分开的是前面那 4 次）。
        """
        assert count_reversals(hip_angles(ballistic_frames())) == 5
        assert count_reversals(hip_angles(rep_frames())) == 1


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestSrtSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        runner = srt_runner()
        feed_all(runner, rep_frames())

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0
        assert runner.current_state == SIT_UPRIGHT

    def test_halfway_reach_is_discarded_not_counted(self) -> None:
        """伸到一半又坐直：计 0、弃 1。

        没伸到底的那一次**不算一次**。它也不是无声无息地消失 ——
        ``discarded_reps`` 记账，界面解释为「有 N 次没计入」。

        反面即第 1 条结论：如果计数点落在 HOLDING 上，这一次会被计成 1 ——
        而它连「前伸到底」那条线都没碰到。
        """
        runner = srt_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    UPRIGHT_SEGMENT,
                    MID_SEGMENT,  # 前伸途中
                    MID_SEGMENT,  # 又坐回去，全程没到保持线
                    UPRIGHT_SEGMENT,
                ]
            ),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == SIT_UPRIGHT, "要坐直等下一次"

    def test_transition_guard_bounds(self) -> None:
        """守卫的上下界：两条线两侧都有滞回带。

        上面那条计数测试一旦变绿，就可能是因为「压根没离开 SIT_UPRIGHT」——
        那样它证明的是别的东西。这里直接对守卫求值。
        """
        config = srt_config()
        definition = build_srt(SEATED_CALIBRATION, config=config)

        def at(src: str, dst: str, hip_deg: float) -> bool:
            return guard_of(definition, src, dst)({"hip_angle_L": hip_deg})

        upright = config.sit_reach_upright_deg  # 75
        holding = config.sit_reach_holding_deg  # 55
        hyst = config.sit_reach_hysteresis_deg  # 8

        # 离开坐直线往下折，要折过整条滞回带才算动起来。
        assert not at(SIT_UPRIGHT, REACHING, upright)
        assert at(SIT_UPRIGHT, REACHING, upright - hyst - 0.01)
        # 而「伸到底」这一侧**不含**滞回带：到达线就是到达线。
        assert not at(REACHING, HOLDING, holding + 0.01)
        assert at(REACHING, HOLDING, holding)

        # 假动作：前伸途中又坐直（用的是与正常收势**同一条**线）。
        assert not at(REACHING, SIT_UPRIGHT, upright - 0.01)
        assert at(REACHING, SIT_UPRIGHT, upright)

        # 离开保持位往回坐，要坐过整条滞回带才算开始坐回。
        assert not at(HOLDING, RETURNING, holding + hyst)
        assert at(HOLDING, RETURNING, holding + hyst + 0.01)

        assert not at(RETURNING, SIT_UPRIGHT, upright - 0.01)
        assert at(RETURNING, SIT_UPRIGHT, upright)

        # 回退：坐到一半又伸回去。
        assert at(RETURNING, HOLDING, holding)
        assert not at(RETURNING, HOLDING, holding + 0.01)

        # 开局与封存落到 SIT_UPRIGHT 用的是**同一条线**：SIT_UPRIGHT 只有一个含义。
        assert guard_of(definition, RETURNING, SIT_UPRIGHT) is guard_of(
            definition, REACHING, SIT_UPRIGHT
        )

        # 而「取不到这个量」时一条守卫都不成立 —— 不能拿 0 顶替（0 正是
        # 「折到极限」，用它会凭空造出一次「已经前伸到底」的结论）。
        for src, dst in (
            (SIT_UPRIGHT, REACHING),
            (REACHING, HOLDING),
            (REACHING, SIT_UPRIGHT),
            (HOLDING, RETURNING),
            (RETURNING, SIT_UPRIGHT),
            (RETURNING, HOLDING),
        ):
            assert not guard_of(definition, src, dst)({}), f"{src}→{dst} 在指标缺失时不该成立"

    def test_falling_back_does_not_get_stuck(self) -> None:
        """回退不卡死：坐到一半又伸回去，仍然坐得直。

        守卫看不见时间，没有 ``RETURNING → HOLDING`` 这条边的话，「坐到一半
        又没劲了」会停在 RETURNING 直到帧上限 —— 既不计数也不丢弃，
        只是每一帧都显示着一个错的状态词。
        """
        runner = srt_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    UPRIGHT_SEGMENT,
                    MID_SEGMENT,
                    REACH_SEGMENT,  # 伸到底
                    MID_SEGMENT,  # 坐到一半（已越过 63°，进了 RETURNING）
                    REACH_SEGMENT,  # 又伸回去
                    MID_SEGMENT,
                    UPRIGHT_SEGMENT,  # 终于坐直 → 封存
                ]
            ),
        )

        assert runner.rep_count == 1, "伸回去之后仍然要坐得直"
        assert runner.current_state == SIT_UPRIGHT

    def test_sitting_still_is_neither_counted_nor_discarded(self) -> None:
        runner = srt_runner()
        feed_all(runner, [srt_pose(i * 33) for i in range(60)])

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "坐着不动不该被记账成一次丢弃"
        assert runner.current_state == SIT_UPRIGHT


# --------------------------------------------------------------------------
# 两条规则
# --------------------------------------------------------------------------


class TestSrtRules:
    def test_knee_bent_fires_only_when_the_bottom_is_bent(self) -> None:
        """屈膝：只命中前伸到底那一段真的弯着的那一次。

        **这一条钉住的是 ``SRT_KNEE_BENT`` 的窗口。**「前伸途中膝盖松了一下、
        到底之后又伸直了」在前伸途中膝角只有 140°，但它**不该被判屈膝** ——
        前伸途中膝盖松一下没人管得着，屈膝只有在前伸到底那一刻才说明问题
        （膝盖一弯，上身就「够」得更远，那正是成绩要排除的作弊姿势）。

        窗口若写成 ``Phase.ALL``，这一次会被判屈膝；写成 ``Phase.BOTTOM`` 才不判。
        """
        passing = srt_runner()
        feed_all(passing, knee_bent_in_reaching_frames())
        assert passing.rep_count == 1, "它前伸到底了，算一次"
        assert stat_of(passing.finish_set(), "SRT_KNEE_BENT") is None, (
            "前伸途中膝松一下不算屈膝 —— 这条规则看的是保持那一段"
        )
        # 而且要把「弯在哪儿」摆出来，别让人以为这条是因为「压根没读到这个量」
        # 才没命中：同一个窗口里，前伸段的最小膝角是那个屈着的值，
        # 保持段的最小膝角是伸直的。
        window = passing.windows[0]
        assert knee_min(window, Phase.DESCENT) == pytest.approx(
            SRT_BENT_KNEE_DEG, abs=1e-9
        )
        assert knee_min(window, Phase.BOTTOM) == pytest.approx(
            SRT_STRAIGHT_KNEE_DEG, abs=1e-9
        )

        # 反过来：全程屈膝 —— 保持那一段也是弯的，必须命中。
        bent = srt_runner()
        feed_all(bent, rep_frames(knee_deg=SRT_BENT_KNEE_DEG))
        assert bent.rep_count == 1, "屈膝不该把这一次挤出计数"
        assert stat_of(bent.finish_set(), "SRT_KNEE_BENT") is not None

        # 腿伸直的正常那一次必须干净 —— 否则这条是「永远命中」。
        straight = srt_runner()
        feed_all(straight, rep_frames())
        assert stat_of(straight.finish_set(), "SRT_KNEE_BENT") is None

    def test_ballistic_fires_only_on_the_bouncing_rep(self) -> None:
        """弹振借力：只命中来回弹的那一次，平稳的那一次不命中。

        **这一条钉住的是 ``SRT_BALLISTIC`` 的窗口与归约。** 弹的两下前伸到底的
        角度**完全一样**（都到 ``SRT_REACH_DEG``），只有序列的形状分得开 ——
        所以窗口必须取 ``Phase.ALL``：只看 ``Phase.BOTTOM`` 会把「抖到位就停住」
        的人漏掉，而那正是这条判定唯一要抓的姿势。

        归约换成 ``MIN`` / ``MAX`` 之类的量比较也不行：那些只看得见一个点，
        两种人的那个点一样。
        """
        ballistic = srt_runner()
        feed_all(ballistic, ballistic_frames())
        assert ballistic.rep_count == 1, "弹振的人前伸到底的角度其实是够的，所以照样算一次"
        assert stat_of(ballistic.finish_set(), "SRT_BALLISTIC") is not None

        # **窗口为什么必须是 ``Phase.ALL``，看这一对数字就明白：** 同一次动作，
        # 前伸到底那一段数出来 **0** 次掉头（那人在这段里是静的），整段数出来
        # **5** 次。窗口写成 ``Phase.BOTTOM`` 的话，这条判定对「抖到够远了就
        # 停住」的那些人一次都不会响 —— 而那正是它唯一要抓的姿势。
        window = ballistic.windows[0]
        assert count_reversals(hip_angles(window.select(Phase.BOTTOM))) == 0
        assert count_reversals(hip_angles(window.select(Phase.ALL))) == 5

        steady = srt_runner()
        feed_all(steady, rep_frames())
        assert stat_of(steady.finish_set(), "SRT_BALLISTIC") is None, (
            "平稳前伸只掉头 1 次，不该被判成弹振 —— 否则这条是「永远命中」"
        )

    def test_the_two_rules_do_not_replace_each_other(self) -> None:
        """两条判定互不顶替：弹振那一次腿是伸直的。

        两条规则打的是同一段动作里的两件不同的事。弹振那一次的屈膝判据必须干净
        —— 否则报告会一次说两句话，而用户只做错了一件。
        """
        ballistic = srt_runner()
        feed_all(ballistic, ballistic_frames())

        summary = ballistic.finish_set()
        assert stat_of(summary, "SRT_BALLISTIC") is not None
        assert stat_of(summary, "SRT_KNEE_BENT") is None


# --------------------------------------------------------------------------
# 阈值表的键
# --------------------------------------------------------------------------


class TestSrtThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        definition = build_srt(SEATED_CALIBRATION, config=srt_config())
        table = make_thresholds()
        for rule in definition.rules:
            value = table.get(rule.threshold_key).value
            assert math.isfinite(value) and value != 0.0, (
                f"{rule.code} 的阈值取到了 0 或非有限值"
            )

    def test_rule_directions_match_the_values(self) -> None:
        """两个键的取值与规则的方向配得上。

        膝角取正值、方向朝下（越小越弯）；掉头次数是无量纲的次数、方向朝上
        （抖得越多越糟）。**两条规则的方向不许写反** —— 写反的表现是
        「标准动作永远命中」或者「永远不命中」，而两者都不会报错。
        """
        definition = build_srt(SEATED_CALIBRATION, config=srt_config())
        by_code = {rule.code: rule for rule in definition.rules}

        knee_bent = by_code["SRT_KNEE_BENT"]
        assert knee_bent.bad_side is Direction.BELOW
        assert knee_bent.reduce is Reduce.MIN
        assert knee_bent.phase is Phase.BOTTOM

        ballistic = by_code["SRT_BALLISTIC"]
        assert ballistic.bad_side is Direction.ABOVE
        assert ballistic.reduce is Reduce.REVERSALS
        assert ballistic.phase is Phase.ALL, (
            "弹振发生在前伸的过程里，窗口只看底部会漏掉绝大多数"
        )


# --------------------------------------------------------------------------
# 标定接缝
# --------------------------------------------------------------------------


class TestRealCalibration:
    """坐姿帧 → 真实 ``Calibrator`` → :func:`build_srt`。

    上面每一个类用的都是手写的 ``SEATED_CALIBRATION``（文件头第 6 条）。
    于是「这一组基线在 45° 机位下根本采不满」这类错一条都发现不了 ——
    而它的表现是标定条卡在 0、屏幕上没有任何错误。

    ``build_srt`` 还要读 ``calibration.knee_angle`` 与 ``calibration.trunk_lean``，
    所以标定走不完的话连定义都建不起来，抛点在会话里 —— 也就是用户做完标定那一刻。

    **与 Dart 侧的刻意分歧**：Dart 那份喂的是 ``srtSpec`` 声明的基线集与机位
    （``action_spec`` 在 app 层，Python 侧没有对应物），所以它额外是「机位写错了」
    的哨兵。这里喂的是 ``Calibrator`` 的默认基线集 —— 能验的是同一件事的下半段：
    真帧采出来的数对不对、拿它建的定义跑不跑得动。
    """

    @staticmethod
    def _calibrate_seated() -> Calibration:
        extractor = FeatureExtractor(camera_view="oblique45")
        calibrator = Calibrator(min_frames=15)
        for i in range(15):
            calibrator.feed(extractor.extract(srt_pose(i * 33)))
        calibration = calibrator.calibration
        assert calibration is not None, (
            "标定没走完 —— 声明的某个基线量在 45° 机位下拿不到"
        )
        return calibration

    def test_calibration_from_seated_frames_reads_back_the_pose(self) -> None:
        """标定「走完了」不等于「采对了」。

        中途换错了特征（比如把躯干倾角读成髋角）时标定照样走完，而两条判定
        读的量整体挪位 —— 膝角与髋角都是绝对量、不挂基线，所以上面那些规则
        用例一条都不会红。
        """
        calibration = self._calibrate_seated()
        assert calibration.frames == 15
        assert calibration.knee_angle == pytest.approx(
            SRT_STRAIGHT_KNEE_DEG, abs=1.0
        ), "坐直时腿是伸直的"
        assert calibration.trunk_lean == pytest.approx(0.0, abs=1.0), (
            "坐直时躯干是竖直的"
        )

    def test_definition_built_from_the_collected_calibration_still_counts(self) -> None:
        calibration = self._calibrate_seated()
        runner = ActionRunner(
            build_srt(calibration, config=srt_config()),
            thresholds=make_thresholds(),
            calibration=calibration,
            config=srt_config(),
        )

        feed_all(runner, rep_frames())

        assert runner.rep_count == 1, "这一组是标准动作"
        assert runner.discarded_reps == 0
