"""仰卧起坐动作定义测试（``app/test/domain/su_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住五类结论，每一类都是「不做就会**静默**出错」的：

1. **计数点只能落在 ``SEATED`` 上。** 落回 ``LYING`` 的话，「这一次的肩到底贴到
   垫上没有」这个证据正好落在 rep 缓冲的边界上（缓冲从离开 resting_state 开始
   封存），而且**偏向起得快的人**。下面那条「肩只降到 0.21 就起来」的用例量到的
   就是这件事 —— 它与「老老实实贴到垫上」在缓冲里给出的读数必须分得开。
2. **坐起线不能取到 1.0。** 那是「躯干严格竖直」的奇点，取它一次标准的仰卧起坐
   永远不会被计数、且不报任何错；更坏的是臀一离垫比值反倒能越过 1，于是线
   **奖励正要被罚的那个错**（见 ``situp.py`` 模块文档）。
3. **「算不算一次」与「做得好不好」是两条线。** 肩没贴到垫上的那些次**照样算**
   一次（``SU_SHOULDER_NOT_GROUND`` 指出来），而躺到一半又坐起来的那些次根本
   不算（走 ``discarded_reps``）。
4. **三条判定一个基线都不挂。** 肩高比与体线偏移已用躯干长归一、膝角是关节夹角，
   再乘一个基线只会引入噪声；挂错的表现是阈值整体挪位、判错率变，不报错。
5. **``SU_HIP_LIFT`` 取的是整段的 min、方向朝下；``SU_SHOULDER_NOT_GROUND``
   取的是 ``BOTTOM`` 段的 min、方向朝上。** 两者共用一个「取最小值」的归约，
   方向或相位写错的表现是同一件事：这条判定时不时冒出来，看不出病因。

阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
与真实资产的对照在 Dart 侧「真实阈值表」那组里。
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
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_su
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.situp import LOWERING, LYING, SEATED
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Direction, Phase, Reduce
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_pu.py``：角度在像素空间计算，
#: 非方形画幅会把 x 与 y 缩放成不同倍率。仰卧起坐这边还多一层 ——
#: ``shoulder_height_ratio`` 与 ``body_line_offset_ratio`` 的分母都是躯干长
#: （**欧氏**距离），非方形画幅下横向与纵向的两个分量被缩放成不同倍率，
#: 这两个比值就不再是合成的那个姿态，而它不会报错，只会让分段线与判定一起偏。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_su.dart`` 逐位相同** ----

#: 垫面的高度。**踝自始至终在它上面**，所以它同时是这个量纲的零点。
_MAT_Y = 0.70

#: 髋中点的横坐标。臀在整组里钉在这里（起身时只有肩在动）。
_HIP_X = 0.50

#: 躯干长。特征拿它当分母，所以肩点严格解在以髋为圆心、半径为它的圆上。
_TORSO_LEN = 0.20

#: 大腿长与小腿长。两侧等长，于是膝点落在髋-踝的中垂线上，屈膝角有闭式解。
_THIGH_LEN = 0.10
_SHIN_LEN = 0.10

#: 左右同侧点的横向缝隙。侧视下本来就几乎重合，留一条缝是为了
#: ``shoulder_width_px`` 之类的分母不退化。
SIDE_GAP = 0.01

#: 仰卧平躺的躯干角。取 −87° 而不是 −90°：真实平躺时背弓让肩略高于垫
#: （比值约 0.05），而正好 −90° 会让肩、髋、踝三点共线、贴着 ``body_line_angle``
#: 的 180° 边界，也会让「躺平」恰好压在比值的下界上。留 3° 的余量。
SU_LYING_DEG = -87.0

#: 坐起的躯干角。取 +26°（向脚那一侧前倾）而不是 0°：国标的收势是前倾
#: （肘触膝），而 0°（躯干严格竖直）是比值 1 那个奇点。
SU_SEATED_DEG = 26.0

#: 躺下/起身途中经过的躯干角（两条分段线的中间）。
SU_MID_DEG = -60.0

#: 屈膝角。国标要求屈膝约 90°。
SU_KNEE_DEG = 90.0


def su_shoulder_ratio(*, torso_deg: float = SU_LYING_DEG, hip_lift: float = 0.0) -> float:
    """由躯干角与髋离垫算出 ``shoulder_height_ratio`` 的闭式值。

    肩绕**贴在垫上的那个髋位**转（不是抬起来的那份，理由见 :func:`su_pose`），
    于是::

        肩高 = L·cos(torso_deg)
        比值 = L·cos(torso_deg) / sqrt(L²sin² + (hip_lift − L·cos)²)

    测试拿它当期望值 —— 合成帧上真算出来的特征值应当**逐位**等于它。
    """
    rad = math.radians(torso_deg)
    sin, cos = math.sin(rad), math.cos(rad)
    dy = hip_lift - _TORSO_LEN * cos
    torso = math.sqrt(_TORSO_LEN * _TORSO_LEN * sin * sin + dy * dy)
    return _TORSO_LEN * cos / torso


def su_pose(
    timestamp_ms: int = 0,
    *,
    torso_deg: float = SU_LYING_DEG,
    hip_lift: float = 0.0,
    knee_deg: float = SU_KNEE_DEG,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧仰卧起坐姿态。

    - ``torso_deg``：躯干与竖直方向的夹角（度）。负 = 躺下、正 = 前倾坐起，
      **精确**。
    - ``hip_lift``：髋抬离垫面多少（归一化画幅单位）。正 = 顶髋借力。
      与 ``body_line_offset_ratio`` 的关系是近似的（它的分母与连线的两端都跟着动）。

    **圆心取的是「贴在垫上的那份髋位」，不是抬起来的那份**：顶髋借力时肩还留在
    垫上，所以抬起来的是髋、不是整个躯干。两个都抬的话造出来的是「人整体飘起来」，
    而 ``body_line_offset_ratio`` 对它**不敏感**（整段平移不改变髋相对连线的位置），
    那条规则就会变成一个测不出任何东西的形状。
    """
    assert knee_deg >= 1.0, f"屈膝角太小，合成几何解不出来（收到 {knee_deg}）"
    # 两侧等长是「膝点落在中垂线上」这个闭式解的前提，下面只用大腿长当半径。
    assert _SHIN_LEN == _THIGH_LEN, "大小腿不等长时膝点不落在中垂线上，要另解"

    rad = math.radians(torso_deg)
    hip_y = _MAT_Y - hip_lift
    shoulder_x = _HIP_X + _TORSO_LEN * math.sin(rad)
    shoulder_y = _MAT_Y - _TORSO_LEN * math.cos(rad)

    # 踝踩在垫面上。膝角给定了髋-踝距离（两侧等长时 d = 2·t·sin(θ/2)），
    # 于是踝的横坐标由它反解 —— 髋抬起来时这个距离里含一个竖直分量，
    # 横坐标要减掉它（顶髋到超过整条腿的极端姿势会无解，夹到 0）。
    knee_rad = math.radians(knee_deg)
    hip_to_ankle = 2 * _THIGH_LEN * math.sin(knee_rad / 2)
    dx2 = hip_to_ankle * hip_to_ankle - hip_lift * hip_lift
    ankle_x = _HIP_X + (math.sqrt(dx2) if dx2 > 0 else 0.0)
    ankle_y = _MAT_Y

    # 膝点：以髋、踝为圆心、半径各为大腿长/小腿长的两圆交点（两侧等长，
    # 于是它落在中垂线上）。两个交点里取**离垫子更远**的那一个 —— 屈膝的膝盖
    # 朝上，不朝垫子。按 y 比大小来选，而不是按某个固定旋向：髋抬起来之后
    # u 的方向会翻，固定旋向会掉到垫子下面去。
    mid_x = (_HIP_X + ankle_x) / 2
    mid_y = (hip_y + ankle_y) / 2
    ux, uy = ankle_x - _HIP_X, ankle_y - hip_y
    u_len = math.hypot(ux, uy)
    half = u_len / 2
    hh = _THIGH_LEN * _THIGH_LEN - half * half
    h = math.sqrt(hh) if hh > 0 else 0.0
    k1 = (mid_x + h * uy / u_len, mid_y - h * ux / u_len)
    k2 = (mid_x - h * uy / u_len, mid_y + h * ux / u_len)
    knee_x, knee_y = k1 if k1[1] <= k2[1] else k2

    # 其余的点（眼、耳、嘴）堆在头前方一点：可见、不参与仰卧起坐的任何特征。
    # 头接着躯干往远离髋的那一头长，于是躺下时在画面左边、坐起时在肩上方。
    head = (
        shoulder_x + 0.08 * (shoulder_x - _HIP_X) / _TORSO_LEN,
        shoulder_y + 0.08 * (shoulder_y - hip_y) / _TORSO_LEN,
    )

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), head)
    pts[L.LEFT_SHOULDER] = (shoulder_x, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (shoulder_x + SIDE_GAP, shoulder_y)
    pts[L.LEFT_ELBOW] = (shoulder_x + SIDE_GAP / 2, shoulder_y + 0.06)
    pts[L.RIGHT_ELBOW] = (shoulder_x + SIDE_GAP / 2 + SIDE_GAP, shoulder_y + 0.06)
    pts[L.LEFT_WRIST] = (shoulder_x + SIDE_GAP / 2, shoulder_y + 0.02)
    pts[L.RIGHT_WRIST] = (shoulder_x + SIDE_GAP / 2 + SIDE_GAP, shoulder_y + 0.02)
    pts[L.LEFT_HIP] = (_HIP_X, hip_y)
    pts[L.RIGHT_HIP] = (_HIP_X + SIDE_GAP, hip_y)
    pts[L.LEFT_KNEE] = (knee_x, knee_y)
    pts[L.RIGHT_KNEE] = (knee_x + SIDE_GAP, knee_y)
    pts[L.LEFT_ANKLE] = (ankle_x, ankle_y)
    pts[L.RIGHT_ANKLE] = (ankle_x + SIDE_GAP, ankle_y)
    # 脚跟与脚尖不参与仰卧起坐的任何特征，但给出来更接近真实帧 ——
    # 也正因为它们给了，「某只脚出画会被拦住」那类门禁测试才有反例可用。
    pts[L.LEFT_HEEL] = (ankle_x - 0.02, ankle_y + 0.01)
    pts[L.RIGHT_HEEL] = (ankle_x - 0.02 + SIDE_GAP, ankle_y + 0.01)
    pts[L.LEFT_FOOT_INDEX] = (ankle_x + 0.02, ankle_y + 0.01)
    pts[L.RIGHT_FOOT_INDEX] = (ankle_x + 0.02 + SIDE_GAP, ankle_y + 0.01)

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

    用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（躺平那一段肩没贴到
    垫、整段顶着髋借力），段读起来与动作一一对应。
    """

    torso_deg: float = SU_LYING_DEG
    count: int = 14
    hip_lift: float = 0.0
    knee_deg: float = SU_KNEE_DEG


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                su_pose(
                    start + i * interval_ms,
                    torso_deg=segment.torso_deg,
                    hip_lift=segment.hip_lift,
                    knee_deg=segment.knee_deg,
                )
            )
    return frames


def rep_frames(
    *,
    torso_deg: float = SU_SEATED_DEG,
    lie_torso_deg: float = SU_LYING_DEG,
    hip_lift: float = 0.0,
    knee_deg: float = SU_KNEE_DEG,
) -> list[PoseFrame]:
    """一次标准仰卧起坐：坐起 → 躺下 → 躺平 → 起身 → 回到坐起。

    回到 ``SEATED`` 的那一帧封存一次 rep。

    中间那两段不能省：状态机要在 ``min_dwell_frames`` 与投票窗口里攒够同类证据
    才换相，而 ``SEATED→LYING`` 不是一条边 —— 少了下放段，躺平那一段会先在
    ``LOWERING`` 里被投票，行为与真实动作对不上。
    """
    return frames_from_segments(
        [
            Segment(torso_deg=torso_deg, hip_lift=hip_lift, knee_deg=knee_deg),
            Segment(torso_deg=SU_MID_DEG, hip_lift=hip_lift, knee_deg=knee_deg),
            Segment(torso_deg=lie_torso_deg, hip_lift=hip_lift, knee_deg=knee_deg),
            Segment(torso_deg=SU_MID_DEG, hip_lift=hip_lift, knee_deg=knee_deg),
            Segment(torso_deg=torso_deg, hip_lift=hip_lift, knee_deg=knee_deg),
        ]
    )


#: 坐在垫上的段。``SEATED`` 是仰卧起坐的 resting_state，开场与收尾都用它。
SEATED_SEGMENT = Segment(torso_deg=SU_SEATED_DEG)

#: 躺下/起身途中经过的一段。
MID_SEGMENT = Segment(torso_deg=SU_MID_DEG)

#: 仰卧贴垫的一段。
LYING_SEGMENT = Segment(torso_deg=SU_LYING_DEG)

#: 站立基线。**仰卧起坐一条都不用它**（三条判定全是绝对量），但它仍然要采 ——
#: 那是 ``Calibrator`` 的门槛，也是「开始之前先站好」那一步的产物。
STANDING_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
)

#: 内联阈值表。三条判定的取值只为本测试服务；刻意离合成帧的读数远一点，
#: 免得断在阈值同侧的边界上（躺平 0.05 对阈 0.10、顶髋 −0.22 对阈 −0.10、
#: 屈膝 90° 对阈 120°）。
#:
#: **注意 ``su.hip_lift_ratio_min`` 是一个负数** —— 顶髋的判据是「髋比体线高」，
#: 在这个带符号的特征上就是负值。所以本文件里不能断言「阈值一律为正」，
#: 只能断言「非零、有限」。
_THRESHOLD_ROWS = {
    "su.shoulder_to_mat_ratio_max": (0.10, "shoulder_height_ratio", "ratio"),
    "su.hip_lift_ratio_min": (-0.10, "body_line_offset_ratio", "ratio"),
    "su.knee_angle_max": (120.0, "knee_angle_L", "deg"),
}


def make_thresholds() -> ThresholdTable:
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="SU",
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


def su_config() -> TrackingConfig:
    """与产品一致：仰卧起坐走 45° 主链路。"""
    return TrackingConfig(camera_view="oblique45", max_rep_frames=600)


def su_runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    """构造一个阈值已核定的仰卧起坐 runner。

    ``config`` 必须**同时**喂给 :func:`build_su` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or su_config()
    return ActionRunner(
        build_su(STANDING_CALIBRATION, config=cfg),
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


#: 产品机位下的特征读取器。
#:
#: **必须显式给这个机位**：两个特征都声明 ``views=("sagittal", "oblique45")``，
#: 用别的机位读出来的是 ``view_mismatch`` 而不是数值 —— 而那是静默的。
_PRODUCT_VIEW = FeatureExtractor(camera_view="oblique45")


def feature(frame: PoseFrame, code: str) -> float | None:
    return _PRODUCT_VIEW.extract(frame).get(code)


def guard_of(definition, src: str, dst: str):
    for transition in definition.transitions:
        if transition.src == src and transition.dst == dst:
            return transition.guard
    raise AssertionError(f"没有 {src} → {dst} 这条边")


# --------------------------------------------------------------------------
# 构造期校验
# --------------------------------------------------------------------------


class TestSuConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """分段线顺序被违反时当场炸，而不是悄悄多一条边。

        这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
        「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，离病因很远。
        """
        with pytest.raises(ValueError, match="分段线顺序非法"):
            build_su(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    camera_view="oblique45",
                    situp_lie_ratio=0.60,
                    situp_seat_ratio=0.55,
                ),
            )

    def test_seat_line_stays_below_the_vertical_singularity(self) -> None:
        """坐起线取不到 1.0 —— 那是「躯干严格竖直」的奇点。

        **这条是全文件里最值钱的一条断言。** 臀贴在垫上时肩绕髋转，
        ``shoulder_height_ratio`` = 躯干与竖直方向夹角的余弦，于是 1.0 只在
        角度恰好为 0 时取到。国标的收势是前倾（肘触膝，约 26°），读数 0.9 ——
        取 1.0 的话标准动作**一次都不会被计数**，而且屏幕上没有任何提示。
        更坏的是臀一离垫比值反倒能越过 1，线就**奖励了正要被罚的那个错**。
        """
        config = su_config()
        assert config.situp_seat_ratio < 1.0, "取到 1.0（或更大）会让标准动作永远坐不起来"
        assert config.situp_seat_ratio < su_shoulder_ratio(torso_deg=SU_SEATED_DEG), (
            "坐起线必须低于国标收势的读数，否则那一次不算数"
        )

    def test_default_camera_view_is_oblique45(self) -> None:
        """默认机位是 45°；两个量都声明了侧视与 45°，正视下读不出来。"""
        assert build_su(STANDING_CALIBRATION).camera_view == "oblique45"

        frame = su_pose()
        # 正面：两个判据用的特征在 45° 下都必须可用 —— 判掉一个就等于少一条规则，
        # 而特征不可用时规则不命中、也不报错。
        for code in ("shoulder_height_ratio", "body_line_offset_ratio"):
            assert feature(frame, code) is not None, code
        # 而正视下两个 y 方向的差都读不出来（「身体的长边」就是镜头方向本身）。
        frontal = FeatureExtractor(camera_view="frontal")
        for code in ("shoulder_height_ratio", "body_line_offset_ratio"):
            assert frontal.extract(frame).get(code) is None, code

    def test_all_rules_use_absolute_thresholds(self) -> None:
        """三条判定都用绝对阈值 —— 一个基线偏移都不挂。

        挂错的表现是阈值整体挪位、判错率变，而它不报错。肩高比与体线偏移都已用
        躯干长归一、膝角是关节夹角，三者都与体型无关，所以偏移表必须为空。
        """
        definition = build_su(STANDING_CALIBRATION, config=su_config())
        assert definition.threshold_offsets == {}, "三条判定的阈值都是绝对的，一个偏移都不该有"


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_shoulder_height_ratio_is_exact(self) -> None:
        """肩高比逐位等于闭式解。

        三个姿态各验一次：躺平（≈0）、途中（≈0.5）、坐起（≈0.9）。这条同时是
        合成帧几何的自检 —— 它错了，下面所有分段与规则的用例都是在测一个别的动作。
        """
        for deg in (SU_LYING_DEG, SU_MID_DEG, SU_SEATED_DEG):
            frame = su_pose(torso_deg=deg)
            assert feature(frame, "shoulder_height_ratio") == pytest.approx(
                su_shoulder_ratio(torso_deg=deg), abs=1e-9
            ), f"躯干角 {deg}° 的肩高比应当逐位等于闭式解"
        assert su_shoulder_ratio(torso_deg=SU_LYING_DEG) < 0.10
        assert su_shoulder_ratio(torso_deg=SU_SEATED_DEG) > 0.85

    def test_flat_body_has_near_zero_offset_and_hip_lift_goes_negative(self) -> None:
        """平躺时体线偏移≈0，顶髋把它压成负值。

        **顶髋的判据就是一个负号。** 平躺时肩、髋、踝三点几乎共线，偏移≈0；
        把髋单独顶起来（肩不动），髋就跑到肩-踝连线的上方，读数为负。
        与俯卧撑的 ``PU_HIP_PIKE`` 是同一个量、同一个方向。
        """
        # 平躺时不是严格 0：合成帧的躯干留了 3° 余量（``SU_LYING_DEG``），
        # 肩于是比踝略高，肩-踝连线是斜的。0.02 上下就是这个斜度带来的。
        flat = su_pose(torso_deg=SU_LYING_DEG)
        assert feature(flat, "body_line_offset_ratio") == pytest.approx(0.0, abs=0.05)

        lifted = su_pose(torso_deg=SU_LYING_DEG, hip_lift=0.05)
        assert feature(lifted, "body_line_offset_ratio") < -0.10

    def test_seated_pose_has_a_positive_offset(self) -> None:
        """坐起的过程中体线偏移是正的 —— 所以这条规则只能取 min。

        这条不是「顺便一测」，它钉住的是 ``SU_HIP_LIFT`` 的归约方式：起身时髋
        本来就会落到连线下方（正值），只有取整段的**最小值**才问得到「有没有把臀
        顶起来」。改成 ``ANY_FRAME`` 的话前半段全是越界帧，每一次仰卧起坐都会被
        判顶髋。
        """
        seated = su_pose(torso_deg=SU_SEATED_DEG)
        assert feature(seated, "body_line_offset_ratio") > 0.10

    def test_knee_angle_is_exact(self) -> None:
        for deg in (90.0, 120.0, 170.0):
            frame = su_pose(knee_deg=deg)
            assert feature(frame, "knee_angle_L") == pytest.approx(deg, abs=1e-9)
            # 两侧都造得出来，规则取的那一侧才等于它。
            assert feature(frame, "knee_angle_R") == pytest.approx(deg, abs=1e-9)


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestSuSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        runner = su_runner()
        feed_all(runner, rep_frames())

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0
        assert runner.current_state == SEATED

    def test_halfway_down_is_discarded_not_counted(self) -> None:
        """躺到一半又坐起来：计 0、弃 1。

        没躺回垫上的那一次**不算一次**。它也不是无声无息地消失 ——
        ``discarded_reps`` 记账，界面解释为「有 N 次没计入」。

        反面即第 1 条结论：如果计数点落在 LYING 上，这一次会被计成 1 ——
        而它连垫子都没碰到。
        """
        runner = su_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    SEATED_SEGMENT,
                    MID_SEGMENT,
                    Segment(torso_deg=SU_MID_DEG),  # 又坐回去，全程没到躺平线
                    SEATED_SEGMENT,
                ]
            ),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == SEATED, "要回到坐姿等下一次"

    def test_transition_guard_bounds(self) -> None:
        """守卫的上下界：躺平线两侧都有滞回带。

        上面那条计数测试一旦变绿，就可能是因为「压根没离开 SEATED」——
        那样它证明的是别的东西。这里直接对守卫求值。
        """
        config = su_config()
        definition = build_su(STANDING_CALIBRATION, config=config)

        def at(src: str, dst: str, ratio: float) -> bool:
            return guard_of(definition, src, dst)({"shoulder_height_ratio": ratio})

        lie = config.situp_lie_ratio  # 0.25
        seat = config.situp_seat_ratio  # 0.75
        hyst = config.situp_hysteresis  # 0.06

        assert not at(SEATED, LOWERING, seat)
        assert at(SEATED, LOWERING, seat - hyst - 0.01)
        assert at(SEATED, LOWERING, lie)

        assert not at(LOWERING, LYING, lie + 0.01)
        assert at(LOWERING, LYING, lie)

        assert not at(LOWERING, SEATED, seat - 0.01)
        assert at(LOWERING, SEATED, seat)

        assert not at(LYING, "RISING", lie + hyst)
        assert at(LYING, "RISING", lie + hyst + 0.01)

        assert not at("RISING", LYING, lie)
        assert at("RISING", LYING, lie - 0.01)

        # 开局与封存落到 SEATED 用的是**同一条线**：SEATED 只有一个含义。
        assert guard_of(definition, "RISING", SEATED) is guard_of(
            definition, LOWERING, SEATED
        )

        # 而「取不到这个量」时一条守卫都不成立 —— 不能拿 0 顶替（0 正是「躺着」，
        # 用它会凭空造出一次「已经躺平了」的结论）。
        for src, dst in (
            (SEATED, LOWERING),
            (LOWERING, LYING),
            (LOWERING, SEATED),
            (LYING, "RISING"),
            ("RISING", SEATED),
            ("RISING", LYING),
        ):
            assert not guard_of(definition, src, dst)({}), f"{src}→{dst} 在指标缺失时不该成立"

    def test_falling_back_does_not_get_stuck(self) -> None:
        """回退不卡死：起到一半又躺回去，仍然坐得起来。

        守卫看不见时间，没有 ``RISING → LYING`` 这条边的话，「起到一半又没劲了」
        会停在 RISING 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
        一个错的状态词。
        """
        runner = su_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    SEATED_SEGMENT,
                    MID_SEGMENT,
                    LYING_SEGMENT,
                    MID_SEGMENT,  # 起到一半
                    LYING_SEGMENT,  # 又躺回去
                    MID_SEGMENT,
                    SEATED_SEGMENT,  # 终于坐起来 → 封存
                ]
            ),
        )

        assert runner.rep_count == 1, "躺回去之后仍然要坐得起来"
        assert runner.current_state == SEATED

    def test_holding_the_seat_is_neither_counted_nor_discarded(self) -> None:
        runner = su_runner()
        feed_all(runner, [su_pose(i * 33, torso_deg=SU_SEATED_DEG) for i in range(60)])

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "坐着不动不该被记账成一次丢弃"
        assert runner.current_state == SEATED

    def test_seated_state_contributes_no_phase(self) -> None:
        """SEATED 不映射相位；三条判定各自把窗口开在自己该在的地方。

        ``RepWindow.select`` 在相位缺失时**静默**返回整段，所以「肩胛有没有贴垫」
        那条（跑在 ``BOTTOM`` 上）必须显式写 ``Phase.BOTTOM``：谁把它改成
        ``Phase.ALL``，整段上「肩最低」的那一刻在起身之后就被冲掉了 ——
        而那正是这条判定的全部内容。这里钉的是**意图**，行为断言在下面那组。
        """
        definition = build_su(STANDING_CALIBRATION, config=su_config())
        by_code = {rule.code: rule for rule in definition.rules}

        assert by_code["SU_SHOULDER_NOT_GROUND"].phase == Phase.BOTTOM
        assert by_code["SU_SHOULDER_NOT_GROUND"].reduce == Reduce.MIN
        assert by_code["SU_SHOULDER_NOT_GROUND"].bad_side == Direction.ABOVE
        assert by_code["SU_HIP_LIFT"].phase == Phase.ALL
        assert by_code["SU_HIP_LIFT"].reduce == Reduce.MIN
        assert by_code["SU_HIP_LIFT"].bad_side == Direction.BELOW
        assert by_code["SU_KNEE_ANGLE"].reduce == Reduce.MAX
        assert by_code["SU_KNEE_ANGLE"].bad_side == Direction.ABOVE

        runner = su_runner()
        feed_all(runner, rep_frames())
        window = runner.windows[0]
        assert SEATED not in window.phase_bounds
        assert set(window.phase_bounds) == {Phase.DESCENT, Phase.BOTTOM, Phase.ASCENT}
        for phase in (Phase.DESCENT, Phase.BOTTOM, Phase.ASCENT):
            start, end = window.phase_bounds[phase]
            assert end - start < len(window.frames), "相位退化成了整段"


# --------------------------------------------------------------------------
# 三条规则
# --------------------------------------------------------------------------


class TestSuRules:
    def test_shoulder_not_ground_fires_only_on_the_shallow_rep(self) -> None:
        """躺下时躯干角给到 −78°（比值 ≈ 0.208）：**低于躺平线 0.25、高于绝对
        阈值 0.10** —— 于是这一次被正常计数，然后被这条规则指出「肩没贴到垫上」。
        这是「算数的那些里做得不好的」，也正是这条规则唯一有活干的那一段。

        给到 −60°（比值 0.5，够不着躺平线）的话这一次会被 ``bottom_state`` 挡在
        外面、整段丢弃，这条规则根本没机会求值 —— 那就变成在测上面那条丢弃测试。
        """
        shallow = su_runner()
        feed_all(shallow, rep_frames(lie_torso_deg=-78.0))
        assert shallow.rep_count == 1, "过了躺平线 0.25，算一次"
        assert stat_of(shallow.finish_set(), "SU_SHOULDER_NOT_GROUND") is not None

        grounded = su_runner()
        feed_all(grounded, rep_frames())
        assert stat_of(grounded.finish_set(), "SU_SHOULDER_NOT_GROUND") is None, (
            "贴到垫上的仰卧起坐不该被判未触垫 —— 否则这条规则是「永远命中」"
        )

    def test_hip_lift_fires_only_when_the_hip_is_pushed_up(self) -> None:
        """臀离垫借力：只命中顶着髋做的那一次，而且不会顶替肩胛那条。

        两条规则共用「取窗口最小值」这个归约、方向相反（一条 ABOVE、一条 BELOW），
        而且窗口不同（BOTTOM / ALL）。所以必须成对断言：只断言「顶髋时命中」的话，
        一条窗口写错（比如也写成 BOTTOM）的顶髋规则在平躺那组上同样会命中。
        """
        lifted = su_runner()
        feed_all(lifted, rep_frames(hip_lift=0.05))
        assert lifted.rep_count == 1, "顶髋不该把这一次挤出计数"
        assert stat_of(lifted.finish_set(), "SU_HIP_LIFT") is not None
        assert stat_of(lifted.finish_set(), "SU_SHOULDER_NOT_GROUND") is None, (
            "顶髋借力不该同时被判成肩没贴垫"
        )

        flat = su_runner()
        feed_all(flat, rep_frames())
        assert stat_of(flat.finish_set(), "SU_HIP_LIFT") is None
        assert stat_of(flat.finish_set(), "SU_SHOULDER_NOT_GROUND") is None, (
            "平躺做的那一次两条都不该命中"
        )

    def test_knee_angle_fires_only_when_the_leg_is_too_straight(self) -> None:
        """国标要求屈膝约 90°，伸到 150° 是走形的常见做法。阈值取 120°。

        方向写成 ``BELOW`` 的话，规则会变成「腿越弯越是错」—— 而 ``MAX`` 配上
        ``BELOW`` 更糟：整段的最大值也小于阈值时才命中，一条永远命中的规则。
        """
        straight = su_runner()
        feed_all(straight, rep_frames(knee_deg=150.0))
        assert straight.rep_count == 1
        assert stat_of(straight.finish_set(), "SU_KNEE_ANGLE") is not None

        bent = su_runner()
        feed_all(bent, rep_frames())
        assert stat_of(bent.finish_set(), "SU_KNEE_ANGLE") is None, (
            "屈膝 90° 是国标要求的姿势，不该被判错"
        )


# --------------------------------------------------------------------------
# 阈值表的键
# --------------------------------------------------------------------------


class TestSuThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        definition = build_su(STANDING_CALIBRATION, config=su_config())
        table = make_thresholds()
        for rule in definition.rules:
            value = table.get(rule.threshold_key).value
            # **不能断言 > 0**：顶髋那条的阈值就是负数（见 ``_THRESHOLD_ROWS``）。
            assert math.isfinite(value) and value != 0.0, f"{rule.code} 的阈值取到了 0 或非有限值"

    def test_threshold_signs_straddle_zero(self) -> None:
        """三条共用一个「取最小值」的归约，但只有顶髋那条问的是「够不够负」。

        都取正数的话，顶髋会被写成一个「永远命中」或「永远不命中」的规则。
        """
        definition = build_su(STANDING_CALIBRATION, config=su_config())
        table = make_thresholds()
        by_code = {rule.code: rule.threshold_key for rule in definition.rules}

        assert table.get(by_code["SU_HIP_LIFT"]).value < 0
        assert table.get(by_code["SU_SHOULDER_NOT_GROUND"]).value > 0
        assert table.get(by_code["SU_KNEE_ANGLE"]).value > 0
