"""俯卧撑动作定义测试（``app/test/domain/pu_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住四类结论，每一类都是「不做就会**静默**出错」的：

1. **塌腰与撅臀是两件事，不能合成一条规则。** 现成的 ``body_line_angle``
   是个 0–180° 的夹角，两种错在它上面**逐位相同**（下面有一条断言量了这件事）。
   判断方向的依据是 ``body_line_offset_ratio`` 的符号，而符号如果取错了参照系
   （「连线的哪一侧」而不是重力方向），同一个塌腰在换一个站位后就会翻号 ——
   那时两条规则会互相顶替，而屏幕上只是「这两条判定怎么老是乱报」。
2. **「算不算一次」与「做得好不好」是两条线。** 下不到 ``pushup_depth_deg``
   的那些根本不进计数（走 ``discarded_reps``），而深度规则管的是进来的那些 ——
   两者合成一条，用户就分不清「这一次没算」与「这一次算了但可以更好」。
3. **四条判定都不挂本人基线。** 肘角是关节夹角、体线偏移已用躯干长归一，
   再乘一个基线只会引入噪声；而挂错的表现是阈值整体挪位，判错率变，不报错。
4. **「顶部未伸直」与「深度不足」共用同一个特征、方向相反。** 谁把它们
   写成同向，两条规则里必有一条变成「永远命中」或「永远不命中」。

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
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_pu
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.pu import BOTTOM, DOWN, TOP, UP
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_slj.py``：角度在像素空间计算，
#: 非方形画幅会把 x 与 y 缩放成不同倍率。俯卧撑这边还多一层 ——
#: ``body_line_offset_ratio`` 的分母是躯干长（**欧氏**距离），而非方形画幅下
#: 横向与纵向的两个分量被缩放成不同倍率，这个比值就不再是合成的那个姿态，
#: 而它不会报错，只会让两条体线规则一起判歪。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_pu.dart`` 逐位相同** ----

_SHOULDER_X = 0.30
_HIP_X = 0.50
_ANKLE_X = 0.72

#: 体线所在的高度。平直时肩、髋、踝都在它上面。
_BODY_Y = 0.50

#: 左右同侧点的横向缝隙。侧视下本来就几乎重合，留一条缝是为了
#: ``shoulder_width_px`` 之类的分母不退化。
SIDE_GAP = 0.01

_UPPER_ARM_LEN = 0.10
_FORE_ARM_LEN = 0.10

#: 撑起（伸直）时的肘角。取 175 而不是 180：180 要求肩、肘、腕严格共线，
#: 一个正好落在边界上的合成值会把「阈值取 170」这类测试变成浮点比较。
PU_TOP_ELBOW_DEG = 175.0

#: 下到最低时的肘角。
PU_BOTTOM_ELBOW_DEG = 80.0

#: 下放/撑起途中经过的肘角（两条分段线的中间）。
PU_MID_ELBOW_DEG = 130.0


def pu_pose(
    timestamp_ms: int = 0,
    *,
    elbow_deg: float = PU_TOP_ELBOW_DEG,
    hip_offset: float = 0.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧俯卧撑姿态。

    - ``elbow_deg``：``elbow_angle_L`` 与 ``elbow_angle_R`` 的目标值，**精确**。
      肘点固定在肩点正下方，腕点由「肩→肘」方向绕肘点精确旋转得到，
      于是 ``angle3(肩, 肘, 腕)`` 逐位等于它。
    - ``hip_offset``：髋点整体下移多少（归一化画幅单位）。正 = 塌腰、负 = 撅臀。
      **只有近似**：``body_line_offset_ratio`` 的分母是躯干长（肩中点到髋中点），
      髋一动分母也跟着动，所以比值不等于它本身（δ=0.04 时约 0.196）。
      所以测试不拿它卡阈值边界 —— 要么用「明显塌腰」与「平直」两端，
      要么直接读特征值再断言。
    """
    hip_y = _BODY_Y + hip_offset

    def wrist_of(elbow: tuple[float, float], deg: float) -> tuple[float, float]:
        """由「肩→肘」方向绕肘点精确旋转 ``deg`` 得到腕点。

        肘点在肩点正下方，所以「肩→肘」是 (0, +1)（图像 y 向下），
        旋转后是 ``(sin θ, −cos θ)``。θ=180° 时腕落在肘的正下方（手臂伸直朝下），
        θ=90° 时落在肘的正右方（上臂与前臂成直角）。
        """
        rad = math.radians(deg)
        return (
            elbow[0] + _FORE_ARM_LEN * math.sin(rad),
            elbow[1] - _FORE_ARM_LEN * math.cos(rad),
        )

    left_shoulder = (_SHOULDER_X, _BODY_Y)
    right_shoulder = (_SHOULDER_X + SIDE_GAP, _BODY_Y)
    left_elbow = (left_shoulder[0], left_shoulder[1] + _UPPER_ARM_LEN)
    right_elbow = (right_shoulder[0], right_shoulder[1] + _UPPER_ARM_LEN)
    left_hip = (_HIP_X, hip_y)
    right_hip = (_HIP_X + SIDE_GAP, hip_y)
    left_ankle = (_ANKLE_X, _BODY_Y)
    right_ankle = (_ANKLE_X + SIDE_GAP, _BODY_Y)

    # 其余的点（眼、耳、嘴）堆在头前方一点：可见、不参与俯卧撑的任何特征。
    # 俯卧撑是趴着的，头在肩的前面（画面左侧），所以放在肩左边而不是头顶。
    pts: dict[int, tuple[float, float]] = dict.fromkeys(
        range(N_LANDMARKS), (_SHOULDER_X - 0.08, _BODY_Y)
    )
    pts[L.LEFT_SHOULDER] = left_shoulder
    pts[L.RIGHT_SHOULDER] = right_shoulder
    pts[L.LEFT_ELBOW] = left_elbow
    pts[L.RIGHT_ELBOW] = right_elbow
    pts[L.LEFT_WRIST] = wrist_of(left_elbow, elbow_deg)
    pts[L.RIGHT_WRIST] = wrist_of(right_elbow, elbow_deg)
    pts[L.LEFT_HIP] = left_hip
    pts[L.RIGHT_HIP] = right_hip
    pts[L.LEFT_KNEE] = (_HIP_X + 0.10, hip_y)
    pts[L.RIGHT_KNEE] = (_HIP_X + 0.10 + SIDE_GAP, hip_y)
    pts[L.LEFT_ANKLE] = left_ankle
    pts[L.RIGHT_ANKLE] = right_ankle
    # 脚跟与脚尖不参与俯卧撑的任何特征，但给出来更接近真实帧 ——
    # 也正因为它们给了，「左脚出画会被拦住」那类门禁测试才有反例可用。
    pts[L.LEFT_HEEL] = (left_ankle[0] + 0.02, left_ankle[1] + 0.01)
    pts[L.RIGHT_HEEL] = (right_ankle[0] + 0.02 + SIDE_GAP, right_ankle[1] + 0.01)
    pts[L.LEFT_FOOT_INDEX] = (left_ankle[0] + 0.04, left_ankle[1] + 0.01)
    pts[L.RIGHT_FOOT_INDEX] = (right_ankle[0] + 0.04 + SIDE_GAP, right_ankle[1] + 0.01)

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
    """一个姿态段：连续 ``count`` 帧，两个自变量固定。

    用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（最低点段下得不够深、
    撑起段顶部没伸直），段读起来与动作一一对应。
    """

    elbow_deg: float = PU_TOP_ELBOW_DEG
    count: int = 14
    hip_offset: float = 0.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                pu_pose(
                    start + i * interval_ms,
                    elbow_deg=segment.elbow_deg,
                    hip_offset=segment.hip_offset,
                )
            )
    return frames


#: 撑在顶部的段。开场与收尾都用它。
TOP_SEGMENT = Segment()

#: 下放/撑起途中经过的一段。
MID_SEGMENT = Segment(elbow_deg=PU_MID_ELBOW_DEG)

#: 最低点。
BOTTOM_SEGMENT = Segment(elbow_deg=PU_BOTTOM_ELBOW_DEG)

#: 站立基线。**俯卧撑一条都不用它**（四条判定全是绝对量），但它仍然要采 ——
#: 那是 ``Calibrator`` 的门槛，也是「开始之前先站好」那一步的产物。
STANDING_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
)

#: 内联阈值表。四条判定的取值只为本测试服务；刻意离合成帧的取值远一点，
#: 免得断在阈值同侧的边界上（最低点 80° 对阈 90°、顶部 175° 对阈 170°、
#: 偏离 0 对阈 0.10）。
#:
#: **注意 ``pu.hip_pike_ratio_min`` 是一个负数** —— 撅臀的判据是「髋比体线高」，
#: 在这个带符号的特征上就是负值。所以本文件里不能断言「阈值一律为正」，
#: 只能断言「非零、有限」。
_THRESHOLD_ROWS = {
    "pu.min_depth_elbow_angle": (90.0, "elbow_angle_L", "deg"),
    "pu.top_extension_elbow_angle": (170.0, "elbow_angle_L", "deg"),
    "pu.hip_sag_ratio_max": (0.10, "body_line_offset_ratio", "ratio"),
    "pu.hip_pike_ratio_min": (-0.10, "body_line_offset_ratio", "ratio"),
}


def make_thresholds() -> ThresholdTable:
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="PU",
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


def pu_config() -> TrackingConfig:
    """与产品一致：俯卧撑走 45° 主链路（``productCameraView``）。"""
    return TrackingConfig(camera_view="oblique45", max_rep_frames=150)


def pu_runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    """构造一个阈值已核定的俯卧撑 runner。

    ``config`` 必须**同时**喂给 :func:`build_pu` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or pu_config()
    return ActionRunner(
        build_pu(STANDING_CALIBRATION, config=cfg),
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
#: **必须显式给这个机位**：``body_line_offset_ratio`` 声明
#: ``views=("sagittal", "oblique45")``，用别的机位读出来的是 ``view_mismatch``
#: 而不是数值 —— 而那是静默的（``get`` 返回 ``None``）。
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


class TestPuConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """分段线顺序被违反时当场炸，而不是悄悄少一条边。

        这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
        「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
        离病因非常远。把含义写反（深度线跑到顶部线上面）是最容易犯的一种。
        """
        with pytest.raises(ValueError, match="分段线顺序非法"):
            build_pu(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    camera_view="oblique45",
                    pushup_depth_deg=150.0,
                    pushup_top_deg=120.0,
                ),
            )

    def test_default_camera_view_is_sagittal(self) -> None:
        """默认机位是侧视；两条判定用的量在 45° 下照样读得出来。"""
        assert build_pu(STANDING_CALIBRATION).camera_view == "sagittal"

        # 反面：正视下体线偏移读不出来（「身体前后方向」就是镜头方向本身），
        # 而特征不可用时规则不命中、也不报错。
        frame = pu_pose()
        frontal = FeatureExtractor(camera_view="frontal")
        assert frontal.extract(frame).get("body_line_offset_ratio") is None
        assert feature(frame, "elbow_angle_L") is not None

    def test_all_rules_use_absolute_thresholds(self) -> None:
        """四条判定都用绝对阈值 —— 一个基线偏移都不挂。

        挂错的表现是阈值整体挪位、判错率变，而它不报错。肘角与体线偏移都
        与体型无关（一个是关节夹角、一个已用躯干长归一），所以偏移表必须为空。
        """
        definition = build_pu(STANDING_CALIBRATION, config=pu_config())
        assert definition.threshold_offsets == {}, "四条判定的阈值都是绝对的，一个偏移都不该有"


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_elbow_angle_is_exact(self) -> None:
        """判定测试要断的是「越没越过阈值」，所以自变量必须算得准。"""
        for deg in (PU_BOTTOM_ELBOW_DEG, PU_MID_ELBOW_DEG, PU_TOP_ELBOW_DEG):
            frame = pu_pose(elbow_deg=deg)
            assert feature(frame, "elbow_angle_L") == pytest.approx(deg, abs=1e-9)
            # 两侧都造得出来，分段用的均值才等于它。
            assert feature(frame, "elbow_angle_R") == pytest.approx(deg, abs=1e-9)

    def test_flat_body_has_zero_offset(self) -> None:
        flat = pu_pose()
        assert feature(flat, "body_line_offset_ratio") == pytest.approx(0.0, abs=1e-9)
        assert feature(flat, "body_line_angle") == pytest.approx(180.0, abs=1e-3)

    def test_sag_and_pike_are_indistinguishable_by_the_unsigned_angle(self) -> None:
        """塌腰与撅臀在夹角上逐位相同，只有带符号的偏离分得开。

        **这条是整组测试里最值钱的一条。** ``body_line_angle`` 是 ``angle3``
        的夹角，值域 [0°, 180°] —— 髋往上顶和髋往下掉都只是让它变小，
        两者在数值上**完全同形**（下面那条近似断言量到的就是这件事）。
        所以「塌腰」与「撅臀」不能共用它，必须用带符号的
        ``body_line_offset_ratio``：正 = 髋更低 = 塌腰，负 = 髋更高 = 撅臀。

        而 ``body_line_offset_ratio`` 取的是**图像 y 方向**（即重力方向）、
        不是「连线的哪一侧」—— 后者会随人面朝画面哪一边翻号，
        同一个塌腰会得到一正一负。
        """
        sag = pu_pose(hip_offset=0.04)
        pike = pu_pose(hip_offset=-0.04)

        assert feature(sag, "body_line_angle") == pytest.approx(
            feature(pike, "body_line_angle"), abs=1e-9
        ), "夹角本来就分不开这两种错 —— 这正是要另造一个量的原因"
        assert feature(sag, "body_line_offset_ratio") > 0.10
        assert feature(pike, "body_line_offset_ratio") < -0.10

        # 两条规则的方向就是靠这个符号分开的：无论哪一侧，正的都是塌腰。
        assert feature(sag, "body_line_offset_ratio") == pytest.approx(
            -feature(pike, "body_line_offset_ratio"), abs=1e-9
        )


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestPuSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        runner = pu_runner()
        feed_all(
            runner,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0
        assert runner.current_state == TOP

    def test_shallow_rep_is_discarded_not_counted(self) -> None:
        """没下到底就撑起来：计 0、弃 1。

        「俯卧撑」这个动作的判定对象就是「下到底再撑起来」。只弯到 130°
        （高于 ``pushup_depth_deg`` 100°）的那一次**不算一次**，而它也不是无声无息
        地消失 —— ``discarded_reps`` 记账，界面解释为「有 N 次没计入」。
        """
        runner = pu_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    TOP_SEGMENT,
                    Segment(elbow_deg=PU_MID_ELBOW_DEG),
                    TOP_SEGMENT,
                ]
            ),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == TOP, "要回到顶部等下一次"

    def test_transition_guard_bounds(self) -> None:
        """守卫的上下界：弯一点就离开顶部，回到进入线以上才算撑起来。

        上面那条计数测试一旦变绿，就可能是因为「压根没离开 TOP」——
        那样它证明的是别的东西。这里直接对守卫求值。
        """
        definition = build_pu(STANDING_CALIBRATION, config=pu_config())

        def at(src: str, dst: str, elbow: float) -> bool:
            return guard_of(definition, src, dst)({"elbow_angle_L": elbow})

        assert not at(TOP, DOWN, PU_TOP_ELBOW_DEG)
        assert at(TOP, DOWN, PU_MID_ELBOW_DEG)
        assert at(TOP, DOWN, PU_BOTTOM_ELBOW_DEG)

        assert not at(DOWN, BOTTOM, PU_MID_ELBOW_DEG)
        assert at(DOWN, BOTTOM, PU_BOTTOM_ELBOW_DEG)

        # 开局与封存落到 TOP 用的是**同一条线**：TOP 只有一个含义。
        assert guard_of(definition, UP, TOP) is guard_of(definition, DOWN, TOP)

        # 而滞回带保证「刚进 BOTTOM」的那一帧不会被同一条线立刻推出去。
        assert not at(BOTTOM, UP, 101.0)
        assert at(BOTTOM, UP, 109.0)

    def test_rebound_does_not_get_stuck(self) -> None:
        """回压不卡死：撑到一半又沉下去，仍然撑得起来。

        守卫看不见时间，没有 ``UP → DOWN`` 这条边的话，「撑起来一点又没劲了」
        会停在 UP 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
        一个错的状态词。
        """
        runner = pu_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    TOP_SEGMENT,
                    MID_SEGMENT,
                    BOTTOM_SEGMENT,
                    MID_SEGMENT,  # 撑到一半
                    BOTTOM_SEGMENT,  # 又沉回去
                    MID_SEGMENT,
                    TOP_SEGMENT,  # 终于撑到顶 → 封存
                ]
            ),
        )

        assert runner.rep_count == 1, "回压之后仍然要撑得起来"
        assert runner.current_state == TOP

    def test_holding_the_top_is_neither_counted_nor_discarded(self) -> None:
        runner = pu_runner()
        feed_all(runner, [pu_pose(i * 33) for i in range(60)])

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "撑着不动不该被记账成一次丢弃"
        assert runner.current_state == TOP

    def test_top_state_contributes_no_phase(self) -> None:
        """TOP 不映射相位 —— 那么四条规则就都得跑在整段上。

        ``RepWindow.select`` 在相位缺失时**静默**返回整段，而俯卧撑的四条判定
        本来就该看整次动作（峰值/极值在整段上取），所以它们必须显式写
        ``Phase.ALL``。谁把它们改成一个没被映射的相位，行为一模一样、测试不会红 ——
        所以这里钉的是**意图**，不是行为。
        """
        definition = build_pu(STANDING_CALIBRATION, config=pu_config())
        assert all(rule.phase == Phase.ALL for rule in definition.rules), (
            "四条判定问的都是「整次动作的极值」，窗口必须显式开成整段"
        )

        runner = pu_runner()
        feed_all(
            runner,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )
        window = runner.windows[0]
        assert set(window.phase_bounds) == {Phase.DESCENT, Phase.BOTTOM, Phase.ASCENT}
        for phase in (Phase.DESCENT, Phase.BOTTOM, Phase.ASCENT):
            start, end = window.phase_bounds[phase]
            assert end - start < len(window.frames), "相位退化成了整段"


# --------------------------------------------------------------------------
# 四条规则
# --------------------------------------------------------------------------


class TestPuRules:
    def test_insufficient_depth_fires_only_on_the_shallow_rep(self) -> None:
        """最低点给到 95°：**高于绝对阈值 90°、低于分段线 100°** —— 于是这一次
        被正常计数，然后被这条规则指出「下得不够深」。这是「算数的那些里
        做得不好的」，也正是这条规则唯一有活干的那一段。

        给到 130°（连分段线都够不着）的话，这一次会被 ``bottom_state`` 挡在外面、
        整段丢弃，这条规则根本没机会求值 —— 那就变成在测上面那条丢弃测试了。
        """
        shallow = pu_runner()
        feed_all(
            shallow,
            frames_from_segments(
                [
                    TOP_SEGMENT,
                    MID_SEGMENT,
                    Segment(elbow_deg=95.0),
                    MID_SEGMENT,
                    TOP_SEGMENT,
                ]
            ),
        )
        assert shallow.rep_count == 1, "过了 pushup_depth_deg（100°），算一次"
        assert stat_of(shallow.finish_set(), "PU_INSUFFICIENT_DEPTH") is not None

        deep = pu_runner()
        feed_all(
            deep,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )
        assert stat_of(deep.finish_set(), "PU_INSUFFICIENT_DEPTH") is None, (
            "下到底的俯卧撑不该被判深度不足 —— 否则这条规则是「永远命中」"
        )

    def test_incomplete_extension_fires_only_on_the_soft_top(self) -> None:
        """顶部给到 168°：**低于绝对阈值 170°、高于分段线 165°** —— 于是这一次
        被计数了，然后被这条规则指出「还没完全伸直」。撑不到 165° 的那些
        根本不被计数（走 ``discarded_reps``），那是另一条测试在管的事。

        方向写成 ``ABOVE`` 的话，规则会变成「撑得越直越是错」，下面那条
        「下到底、撑到顶」的标准动作会红。
        """
        soft = pu_runner()
        feed_all(
            soft,
            frames_from_segments(
                [
                    Segment(elbow_deg=168.0),
                    MID_SEGMENT,
                    BOTTOM_SEGMENT,
                    MID_SEGMENT,
                    Segment(elbow_deg=168.0),
                ]
            ),
        )
        assert soft.rep_count == 1, "过了 pushup_top_deg（165°），算一次"
        assert stat_of(soft.finish_set(), "PU_INCOMPLETE_EXTENSION") is not None

        straight = pu_runner()
        feed_all(
            straight,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )
        assert stat_of(straight.finish_set(), "PU_INCOMPLETE_EXTENSION") is None, (
            "撑到伸直不该被判未伸直"
        )

    def test_hip_sag_fires_only_when_the_hip_drops(self) -> None:
        sag = pu_runner()
        feed_all(
            sag,
            frames_from_segments(
                [
                    Segment(hip_offset=0.04),
                    Segment(elbow_deg=PU_MID_ELBOW_DEG, hip_offset=0.04),
                    Segment(elbow_deg=PU_BOTTOM_ELBOW_DEG, hip_offset=0.04),
                    Segment(elbow_deg=PU_MID_ELBOW_DEG, hip_offset=0.04),
                    Segment(hip_offset=0.04),
                ]
            ),
        )
        assert sag.rep_count == 1
        assert stat_of(sag.finish_set(), "PU_HIP_SAG") is not None

        flat = pu_runner()
        feed_all(
            flat,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )
        assert stat_of(flat.finish_set(), "PU_HIP_SAG") is None

    def test_hip_pike_fires_only_when_the_hip_rises(self) -> None:
        """撅臀：只命中髋往上顶的那一次，而且不会顶替塌腰。

        **两条规则共用同一个特征、方向相反**，所以必须成对断言：
        只断言「撅臀时命中」的话，一条方向写反（变成 ``ABOVE``）的撅臀规则
        会在塌腰那组上同样命中 —— 而这两条要说的纠正建议正好相反。
        """
        pike = pu_runner()
        feed_all(
            pike,
            frames_from_segments(
                [
                    Segment(hip_offset=-0.04),
                    Segment(elbow_deg=PU_MID_ELBOW_DEG, hip_offset=-0.04),
                    Segment(elbow_deg=PU_BOTTOM_ELBOW_DEG, hip_offset=-0.04),
                    Segment(elbow_deg=PU_MID_ELBOW_DEG, hip_offset=-0.04),
                    Segment(hip_offset=-0.04),
                ]
            ),
        )
        assert pike.rep_count == 1
        assert stat_of(pike.finish_set(), "PU_HIP_PIKE") is not None
        assert stat_of(pike.finish_set(), "PU_HIP_SAG") is None, "髋往上顶不该同时被判成塌腰"

        flat = pu_runner()
        feed_all(
            flat,
            frames_from_segments(
                [TOP_SEGMENT, MID_SEGMENT, BOTTOM_SEGMENT, MID_SEGMENT, TOP_SEGMENT]
            ),
        )
        assert stat_of(flat.finish_set(), "PU_HIP_PIKE") is None
        assert stat_of(flat.finish_set(), "PU_HIP_SAG") is None, "平直的身体两条都不该命中"


# --------------------------------------------------------------------------
# 阈值表的键
# --------------------------------------------------------------------------


class TestPuThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        definition = build_pu(STANDING_CALIBRATION, config=pu_config())
        table = make_thresholds()
        for rule in definition.rules:
            value = table.get(rule.threshold_key).value
            # **不能断言 > 0**：撅臀那条的阈值就是负数（见 ``_THRESHOLD_ROWS``）。
            assert math.isfinite(value) and value != 0.0, f"{rule.code} 的阈值取到了 0 或非有限值"

    def test_sag_and_pike_thresholds_straddle_zero(self) -> None:
        """这两条共用一个带符号的特征，所以阈值必须一个正一个负。

        都取正数的话，撅臀那条会被写成一个「永远命中」或「永远不命中」的规则。
        """
        definition = build_pu(STANDING_CALIBRATION, config=pu_config())
        table = make_thresholds()
        by_code = {rule.code: rule.threshold_key for rule in definition.rules}

        assert table.get(by_code["PU_HIP_SAG"]).value > 0
        assert table.get(by_code["PU_HIP_PIKE"]).value < 0
