"""平板支撑动作定义测试（``app/test/domain/plank_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住六类结论，每一类都是「不做就会**静默**出错」的：

1. **支撑位是三条判据的合取，而且每一条都在起作用。** 站着的人体线也直、
   趴着的人体线也直也水平 —— 三条里少掉哪一条，都会有一整类不属于支撑的姿势
   被安静地计成一整组好成绩。
2. **一次 rep 的时长就是那一段支撑。** 这个动作的产品承诺是「累计撑了多久」，
   而时长不是任何一条规则算出来的 —— 它来自 rep 窗口的首末帧时间戳。
   谁把窗口的开合位置改了，累计时长就跟着错，而屏幕上只会显示一个看起来还挺合理的数。
3. **撑住的过程中被挡住一会儿，不该把一次支撑切成两段。** ``left_hold`` 在
   「读不到特征」时维持撑住，与 ``entered_hold`` 的取舍正好相反。
4. **四条规则的灵敏度与方向。** 每一条都给「合规」与「违规」两组：
   只断言「违规时命中」的话，一条永远命中的规则也是绿的。
5. **``PLANK_ELBOW`` 的两条规则共用一个错误码，组级只算一次。**
6. **三条判定都不挂本人基线。**

阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
与真实资产的对照在 Dart 侧「真实阈值表」那组里。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

import pytest

from vitalteen_domain import (
    N_LANDMARKS,
    L,
    Landmark,
    PoseFrame,
    Threshold,
    ThresholdTable,
)
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_plank
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.exercises.plank import HOLD_BREAK, HOLD_OK
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_slj.py``：角度在像素空间计算，
#: 非方形画幅会把 x 与 y 缩放成不同倍率。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_plank.dart`` 逐位相同** ----

#: 肩中点的位置。身体从它出发、沿着身体方向伸展。
SHOULDER_X = 0.30
SHOULDER_Y = 0.50

#: 肩中点到髋中点、以及到踝中点的距离。躯干长 0.20，身体全长 0.42。
TORSO_LEN = 0.20
BODY_LEN = 0.42

#: 左右同侧点的横向缝隙。侧视下两条手臂、两条腿几乎重合，真实帧里也是这样；
#: 留一条 0.01 的缝是为了 ``shoulder_width_px`` 之类的分母不退化。
SIDE_GAP = 0.01

#: 上臂与前臂长（归一化画幅单位）。等长即可，值本身不参与任何判定。
UPPER_ARM_LEN = 0.10
FORE_ARM_LEN = 0.10

#: 支撑时躯干与竖直方向的夹角：**身体放平**。
PLANK_HELD_ANGLE_DEG = 90.0

#: 站立时躯干与竖直方向的夹角。
PLANK_STANDING_ANGLE_DEG = 0.0

#: 支撑时撑地那条手臂的肘角（直角）。
PLANK_HOLD_ELBOW_DEG = 90.0

#: 手臂伸直（趴着放松、或者站着）。**落在支撑带之外**，
#: 正是用来验第三条判据真的在起作用的那个值。
PLANK_STRAIGHT_ARM_DEG = 175.0

#: 明显塌腰 / 明显撅臀的髋点下移量（归一化画幅单位，正 = 更低）。
#:
#: 0.06 对上去的比值约 0.287，**比资产表里的塌腰阈值（0.20）大、比分段的进入线
#: （0.45）小** —— 于是它正好落在「还在支撑位上、但已经被判错」那一段里。
#: **0.04 不够**：那个位移对上去只有约 0.196，比 0.20 还小一点 —— 于是
#: 「塌腰组」会安安静静地通过，而测试仍然全绿。
PLANK_SAG_OFFSET = 0.06


def plank_pose(
    timestamp_ms: int = 0,
    *,
    body_angle_deg: float = PLANK_HELD_ANGLE_DEG,
    elbow_deg: float = PLANK_HOLD_ELBOW_DEG,
    hip_offset: float = 0.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧平板支撑姿态。

    - ``body_angle_deg``：躯干与竖直方向的夹角。90° = 身体放平（支撑），0° = 站立。
    - ``elbow_deg``：``elbow_angle_L`` 与 ``elbow_angle_R`` 的目标值，**精确**。
    - ``hip_offset``：髋点整体沿画面 y 方向下移多少（正 = 更低 = 塌腰）。
      **在站立姿势下它对比值没有影响**（肩-踝连线是竖直的，髋在这条线上滑动
      不改变 y 方向的偏离）—— 这不是 bug，是那个特征的定义使然，
      也正是「站立的体线也直」这句话的算式版本。

    **手臂的上臂始终朝画面下方（+y）**，取的是画面方向而不是身体方向：手机架在
    身体侧前方、水平不俯仰，于是「朝着地面」在两种姿势下都是画面的 +y ——
    站着的人手臂垂在身侧、撑着的人上臂指向垫子，两者的上臂方向在画面上是同一个。
    """
    rad = math.radians(body_angle_deg)
    along_x, along_y = math.sin(rad), math.cos(rad)

    def at(length: float, *, dy: float = 0.0) -> tuple[float, float]:
        """从肩点出发、沿身体方向走 ``length`` 得到的点，再沿画面 y 压 ``dy``。"""
        return (SHOULDER_X + length * along_x, SHOULDER_Y + length * along_y + dy)

    def wrist_of(elbow: tuple[float, float], deg: float) -> tuple[float, float]:
        """由「上臂方向」绕肘点旋转 ``deg`` 得到腕点。

        与 ``test_pu.py`` 的旋转式相同，只有**取哪一支**不同：那边的手臂朝画面右
        （俯卧撑的人趴着、头在左，前臂因此朝脚的方向），这里取的是朝画面左 ——
        前臂支撑的人前臂朝头的方向。两支的 ``angle3`` 完全相同（对称解），
        所以**这个选择不影响任何特征**，只影响这张图读起来对不对。
        """
        r = math.radians(deg)
        return (
            elbow[0] - FORE_ARM_LEN * math.sin(r),
            elbow[1] - FORE_ARM_LEN * math.cos(r),
        )

    left_shoulder = at(0.0)
    right_shoulder = (left_shoulder[0] + SIDE_GAP, left_shoulder[1])
    left_hip = at(TORSO_LEN, dy=hip_offset)
    right_hip = (left_hip[0] + SIDE_GAP, left_hip[1])
    left_ankle = at(BODY_LEN)
    right_ankle = (left_ankle[0] + SIDE_GAP, left_ankle[1])

    # 膝点放在髋 → 踝的连线下方四成处。**它与任何判定都无关** ——
    # 这个动作一条规则都不用膝角，放对了只是为了让这一帧读起来像个人。
    left_knee = (
        left_hip[0] + (left_ankle[0] - left_hip[0]) * 0.4,
        left_hip[1] + (left_ankle[1] - left_hip[1]) * 0.4,
    )
    right_knee = (left_knee[0] + SIDE_GAP, left_knee[1])

    left_elbow = (left_shoulder[0], left_shoulder[1] + UPPER_ARM_LEN)
    right_elbow = (left_elbow[0] + SIDE_GAP, left_elbow[1])

    # 头画在身体方向的**反**方向（身体从肩往踝伸，头在另一头）。
    # 眼、耳、嘴三个点堆在那里：可见、且不参与平板支撑的任何特征。
    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), at(-0.08))
    pts[L.LEFT_SHOULDER] = left_shoulder
    pts[L.RIGHT_SHOULDER] = right_shoulder
    pts[L.LEFT_ELBOW] = left_elbow
    pts[L.RIGHT_ELBOW] = right_elbow
    pts[L.LEFT_WRIST] = wrist_of(left_elbow, elbow_deg)
    pts[L.RIGHT_WRIST] = wrist_of(right_elbow, elbow_deg)
    pts[L.LEFT_HIP] = left_hip
    pts[L.RIGHT_HIP] = right_hip
    pts[L.LEFT_KNEE] = left_knee
    pts[L.RIGHT_KNEE] = right_knee
    pts[L.LEFT_ANKLE] = left_ankle
    pts[L.RIGHT_ANKLE] = right_ankle
    # 脚跟与脚尖不参与平板支撑的任何特征，但给出来更接近真实帧。
    pts[L.LEFT_HEEL] = (left_ankle[0] + 0.02, left_ankle[1] + 0.01)
    pts[L.RIGHT_HEEL] = (left_ankle[0] + 0.02 + SIDE_GAP, left_ankle[1] + 0.01)
    pts[L.LEFT_FOOT_INDEX] = (left_ankle[0] + 0.04, left_ankle[1] + 0.01)
    pts[L.RIGHT_FOOT_INDEX] = (
        left_ankle[0] + 0.04 + SIDE_GAP,
        left_ankle[1] + 0.01,
    )

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

    用「段」描述而不是逐帧列表，理由同 ``test_pu.py``：一段支撑里的问题总是
    「有一段时间塌下去了」，段读起来与动作一一对应。
    """

    count: int = 30
    body_angle_deg: float = PLANK_HELD_ANGLE_DEG
    elbow_deg: float = PLANK_HOLD_ELBOW_DEG
    hip_offset: float = 0.0
    #: 这一段里**看不见**的关键点。用途只有一个：验「撑住的过程中被挡住一会儿，
    #: 不该把一次支撑切成两段」—— 对应 ``left_hold`` 在特征缺失时维持撑住。
    hidden: frozenset[int] = frozenset()


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                plank_pose(
                    start + i * interval_ms,
                    body_angle_deg=segment.body_angle_deg,
                    elbow_deg=segment.elbow_deg,
                    hip_offset=segment.hip_offset,
                    visibility_overrides={idx: 0.0 for idx in segment.hidden}
                    or None,
                )
            )
    return frames


#: 标准支撑的一段。
HOLD_SEGMENT = Segment()

#: 塌腰的支撑段：体线偏移明显超阈值，但仍在支撑位上（见 ``PLANK_SAG_OFFSET``）。
SAG_SEGMENT = Segment(hip_offset=PLANK_SAG_OFFSET)

#: 撅臀的支撑段。
PIKE_SEGMENT = Segment(hip_offset=-PLANK_SAG_OFFSET)

#: 站立的一段 —— 标定用它，也是「站着不该被读成支撑」那条断言的反例。
STANDING_SEGMENT = Segment(count=15, body_angle_deg=PLANK_STANDING_ANGLE_DEG)

#: 站立基线。**平板支撑三条判定一条都不用它**（体线偏移已用躯干长归一、
#: 肘角是关节夹角），但它仍然要采 —— 那是 ``Calibrator`` 的门槛，
#: 也是「开始之前先站好」那一步的产物，与其余动作共用同一套流程。
STANDING_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
)

#: 内联阈值表。四条判定的取值只为本测试服务（与 Dart 侧逐值相同）：
#:
#: ====== ======== ============ ============
#: 量      合规     违规          阈值
#: ====== ======== ============ ============
#: 体线偏移  0      ±0.287       ±0.20
#: 肘角     90°    60° / 120°   70° / 110°
#: ====== ======== ============ ============
#:
#: **肘角那一对必须严格落在支撑带里面**（50..130），否则「越界」蕴含「离开支撑位」，
#: 那一段会被封存成 rep、越界帧数永远攒不够，**规则永远不触发也不报错**。
#:
#: **注意 ``plank.hip_pike_ratio_min`` 是一个负数** —— 撅臀的判据是「髋比连线高」，
#: 在这个带符号的特征上是负值。所以本文件里不能断言「阈值一律为正」，
#: 只能断言「非零、有限」。
_THRESHOLD_ROWS = {
    "plank.hip_sag_ratio_max": (0.20, "body_line_offset_ratio", "ratio"),
    "plank.hip_pike_ratio_min": (-0.20, "body_line_offset_ratio", "ratio"),
    "plank.elbow_angle_max": (110.0, "elbow_angle_L", "deg"),
    "plank.elbow_angle_min": (70.0, "elbow_angle_L", "deg"),
}


def make_thresholds(overrides: dict[str, float] | None = None) -> ThresholdTable:
    """内联阈值表。``overrides`` 用来把某一条线换成一个**故意调坏的**值。"""
    rows = dict(_THRESHOLD_ROWS)
    for key, value in (overrides or {}).items():
        feature, unit = rows[key][1], rows[key][2]
        rows[key] = (value, feature, unit)
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="PLANK",
                feature_code=feature,
                value=value,
                unit=unit,
                source_type=SourceType.LITERATURE,
                version="test_v1",
            )
            for key, (value, feature, unit) in rows.items()
        ],
        version="test_v1",
    )


def plank_config() -> TrackingConfig:
    """与产品一致：平板支撑走 45° 主链路（``productCameraView``）。"""
    return TrackingConfig(camera_view="oblique45", max_rep_frames=3600)


def plank_runner(
    *,
    config: TrackingConfig | None = None,
    thresholds: ThresholdTable | None = None,
) -> ActionRunner:
    """构造一个阈值已核定的平板支撑 runner。

    ``config`` 必须**同时**喂给 :func:`build_plank` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or plank_config()
    return ActionRunner(
        build_plank(STANDING_CALIBRATION, config=cfg),
        thresholds=thresholds or make_thresholds(),
        calibration=STANDING_CALIBRATION,
        config=cfg,
    )


def feed_all(runner: ActionRunner, frames: list[PoseFrame]) -> None:
    for frame in frames:
        runner.feed(frame)


def duration_ms(window) -> int:
    """一次支撑的时长：rep 窗口首末帧的时间戳之差。

    **这就是产品上那个「累计撑了多久」** —— 决策契约里的 ``duration_ms``
    与它同源（读的是同一对时间戳）。
    """
    return window.frames[-1].timestamp_ms - window.frames[0].timestamp_ms


def one_hold_frames(
    *,
    hold_count: int = 90,
    standing_count: int = 10,
    interval_ms: int = 33,
    hip_offset: float = 0.0,
    elbow_deg: float = PLANK_HOLD_ELBOW_DEG,
) -> list[PoseFrame]:
    """一次完整的支撑：站好 →（离开站立）→ 撑住 →（回到站立）。

    ``rep_count`` 只会是 1，而它代表「撑了 ``hold_count`` 帧」—— 这是这个动作与
    前面七个最不一样的地方。前后各留一段站立：状态机在**离开** ``HOLD_BREAK``
    那一帧开窗、在**回到**它的那一帧封存。
    """
    return frames_from_segments(
        [
            Segment(count=standing_count, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
            Segment(count=hold_count, hip_offset=hip_offset, elbow_deg=elbow_deg),
            Segment(count=standing_count, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
        ],
        interval_ms=interval_ms,
    )


def stat_of(summary, code: str):
    """取出某个错误的组级统计，没有则返回 None。"""
    for stat in summary.fault_stats:
        if stat.code == code:
            return stat
    return None


#: 产品机位下读一帧的特征值。分段用的三个量在 45° 下都可用。
_PRODUCT_VIEW = FeatureExtractor(camera_view="oblique45")


def guard_of(definition, src: str, dst: str):
    """取出某个状态的出边守卫，用来单独验证分段条件。"""
    for transition in definition.transitions:
        if transition.src == src and transition.dst == dst:
            return transition.guard
    raise AssertionError(f"没有 {src} → {dst} 这条边")


def signals_of(frame: PoseFrame) -> dict[str, float | None]:
    return _PRODUCT_VIEW.extract(frame).as_signals()


class TestConstructionChecks:
    """构造期校验：四条顺序不变式。

    调乱之后状态机不会报错，只会在某个状态上卡住、或者多一条「一进新状态就成立」
    的边 —— 表现都是「计数一直是 0」或者「计数偶尔不对」。
    """

    def test_enter_ratio_must_be_below_exit_ratio(self):
        with pytest.raises(ValueError, match="体线容差顺序非法"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    plank_line_enter_ratio=0.60, plank_line_exit_ratio=0.45
                ),
            )
        with pytest.raises(ValueError, match="体线容差顺序非法"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    plank_line_enter_ratio=0.45, plank_line_exit_ratio=0.45
                ),
            )

    def test_lie_line_must_clear_the_hysteresis(self):
        with pytest.raises(ValueError, match="身体放平线太小"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(plank_lie_deg=5.0),
            )

    def test_elbow_band_edges_must_be_in_order(self):
        with pytest.raises(ValueError, match="支撑带上下沿写反了"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    plank_elbow_min_deg=130.0, plank_elbow_max_deg=50.0
                ),
            )

    def test_elbow_band_top_must_stay_clear_of_straight_arm(self):
        with pytest.raises(ValueError, match="支撑带上沿太高"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(plank_elbow_max_deg=175.0),
            )
        # 边界值：加上滞回正好够到 180°，仍然会炸（要求严格小于）。
        with pytest.raises(ValueError, match="支撑带上沿太高"):
            build_plank(
                STANDING_CALIBRATION,
                config=TrackingConfig(plank_elbow_max_deg=172.0),
            )
        # 差一点点就过关的：171 通过。
        assert build_plank(
            STANDING_CALIBRATION,
            config=TrackingConfig(plank_elbow_max_deg=171.0),
        )


class TestSegmentation:
    """分段：三条判据各挡一类姿势。"""

    def test_one_hold_counts_once_and_lasts_about_the_hold(self):
        interval, hold_count = 33, 90
        runner = plank_runner()
        feed_all(
            runner, one_hold_frames(hold_count=hold_count, interval_ms=interval)
        )

        assert runner.rep_count == 1
        assert runner.discarded_reps == 0

        # 容差 ±8 帧：状态机换相要经过驻留与投票（min_dwell_frames = 3、
        # 投票窗口 5 取 4），所以「离开 HOLD_BREAK」与「回到 HOLD_BREAK」都比人
        # 真正动的那一帧晚几帧。**这个滞后是计时的固有代价**，
        # 它让时长有一两百毫秒的偏差 —— 反过来，任何要求「逐帧精确」的计时
        # 都不可能由状态机做出来。
        elapsed = duration_ms(runner.windows[0])
        assert (hold_count - 8) * interval <= elapsed <= (hold_count + 8) * interval

    def test_two_separate_holds_are_two_reps(self):
        interval = 33
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    Segment(count=60),
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    Segment(count=60),
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                ],
                interval_ms=interval,
            ),
        )
        assert runner.rep_count == 2
        assert runner.discarded_reps == 0
        total = sum(duration_ms(w) for w in runner.windows)
        assert 96 * interval <= total <= 136 * interval

    def test_standing_throughout_counts_nothing(self):
        runner = plank_runner()
        feed_all(runner, frames_from_segments([Segment(count=120, body_angle_deg=0.0)]))
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0

    def test_body_flat_but_arms_straight_counts_nothing(self):
        """**趴着放松**的姿势：满足前两条（身体放平、体线成一条线），只差肘角。

        少了第三条判据，趴在地上休息会被安静地计成一整段支撑 ——
        而这正是计时的动作最容易被钻的漏洞。
        """
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [Segment(count=120, elbow_deg=PLANK_STRAIGHT_ARM_DEG)]
            ),
        )
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0

    def test_standing_with_elbow_in_the_band_counts_nothing(self):
        """反过来的那一半：肘角 90°、体线也直，只有「身体放平」这一条不满足。"""
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    Segment(
                        count=120,
                        body_angle_deg=PLANK_STANDING_ANGLE_DEG,
                        elbow_deg=PLANK_HOLD_ELBOW_DEG,
                    )
                ]
            ),
        )
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0

    def test_body_flat_but_line_bent_counts_nothing(self):
        """身体放平、肘角也对，但体线弯过了退出线（撑不住了、塌在地上）。"""
        runner = plank_runner()
        feed_all(
            runner, one_hold_frames(hold_count=120, hip_offset=0.20)
        )
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0

    def test_guards_require_all_three_conditions(self):
        definition = build_plank(STANDING_CALIBRATION, config=plank_config())
        entered = guard_of(definition, HOLD_BREAK, HOLD_OK)
        held = guard_of(definition, HOLD_OK, HOLD_BREAK)

        assert entered(signals_of(plank_pose()))
        assert not entered(
            signals_of(plank_pose(body_angle_deg=PLANK_STANDING_ANGLE_DEG))
        ), "第一条判据：身体没放平"
        assert not entered(
            signals_of(plank_pose(elbow_deg=PLANK_STRAIGHT_ARM_DEG))
        ), "第三条判据：手臂伸直"
        assert not entered(
            signals_of(plank_pose(hip_offset=0.20))
        ), "第二条判据：体线弯过了进入线"

        # 读不到特征：进入侧说「没进」，维持侧说「还撑着」—— 两者相反是刻意的。
        blind = signals_of(
            plank_pose(
                visibility_overrides={
                    L.LEFT_SHOULDER: 0.0,
                    L.RIGHT_SHOULDER: 0.0,
                }
            )
        )
        assert not entered(blind)
        assert not held(blind), "读不到就维持撑住，不该断开这一段的计数"

    def test_a_short_occlusion_does_not_split_the_hold(self):
        """撑住的过程中被挡住一会儿，不该把一次支撑切成两段。

        一次遮挡变成两次计数的话，累计时长会凭空缩短，而屏幕上只有数字。
        """
        interval = 33
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    Segment(count=40),
                    Segment(
                        count=20,
                        hidden=frozenset([L.LEFT_SHOULDER, L.RIGHT_SHOULDER]),
                    ),
                    Segment(count=40),
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                ],
                interval_ms=interval,
            ),
        )
        assert runner.rep_count == 1
        assert runner.discarded_reps == 0
        assert duration_ms(runner.windows[0]) >= 88 * interval


class TestRuleSensitivity:
    """四条规则的灵敏度与方向。每条都给「合规」与「违规」两组。"""

    @staticmethod
    def _hold_with(
        *,
        hip_offset: float = 0.0,
        elbow_deg: float = PLANK_HOLD_ELBOW_DEG,
        hold_count: int = 60,
    ):
        runner = plank_runner()
        feed_all(
            runner,
            one_hold_frames(
                hold_count=hold_count,
                hip_offset=hip_offset,
                elbow_deg=elbow_deg,
            ),
        )
        assert runner.rep_count == 1, "这一组的前提是它得被算成一次"
        return runner.finish_set()

    def test_a_clean_hold_reports_nothing(self):
        summary = self._hold_with()
        assert summary.rep_count == 1
        assert not summary.fault_stats, (
            "合规组必须什么都不报，否则「违规组会报」什么也证明不了"
        )

    def test_hip_sag_hits_only_the_sag_rule(self):
        summary = self._hold_with(hip_offset=PLANK_SAG_OFFSET)
        assert stat_of(summary, "PLANK_HIP_SAG") is not None
        assert stat_of(summary, "PLANK_HIP_PIKE") is None, (
            "两者共用同一个指标、方向相反；方向判错时它们会互相顶替"
        )
        assert stat_of(summary, "PLANK_ELBOW") is None

    def test_hip_pike_hits_only_the_pike_rule(self):
        summary = self._hold_with(hip_offset=-PLANK_SAG_OFFSET)
        assert stat_of(summary, "PLANK_HIP_PIKE") is not None
        assert stat_of(summary, "PLANK_HIP_SAG") is None
        assert stat_of(summary, "PLANK_ELBOW") is None

    @pytest.mark.parametrize("elbow", [60.0, 120.0])
    def test_elbow_deviations_hit_the_shared_code(self, elbow):
        summary = self._hold_with(elbow_deg=elbow)
        assert stat_of(summary, "PLANK_ELBOW") is not None, (
            f"肘角 {elbow}° 落在支撑带内、但越过了质量阈值，必须被判错"
        )
        assert stat_of(summary, "PLANK_HIP_SAG") is None, "体线是直的，不该被连坐"

    def test_two_rules_sharing_a_code_count_once_at_set_level(self):
        """肘角在同一次支撑里先撑得太直、再撑得太塌，组级只能有一条统计。

        改成两个错误码的话，那两段会各报一次，出现率直接翻倍 ——
        而两个码名字一样、用户看不出差别。
        """
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    Segment(count=30, elbow_deg=120.0),
                    Segment(count=30, elbow_deg=90.0),
                    Segment(count=30, elbow_deg=60.0),
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                ]
            ),
        )
        assert runner.rep_count == 1
        summary = runner.finish_set()
        assert len([s for s in summary.fault_stats if s.code == "PLANK_ELBOW"]) == 1

    def test_a_brief_dip_is_tolerated_but_a_sustained_one_is_not(self):
        """``min_violating_frames`` = 8 那条工程参数唯一的用处。

        合成帧是逐帧精确的，所以这里的差别**只**来自门槛帧数。
        """

        def hold_with_sag_frames(sag_frames: int):
            runner = plank_runner()
            feed_all(
                runner,
                frames_from_segments(
                    [
                        Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                        Segment(count=40),
                        Segment(count=sag_frames, hip_offset=PLANK_SAG_OFFSET),
                        Segment(count=40),
                        Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    ]
                ),
            )
            assert runner.rep_count == 1
            return runner.finish_set()

        assert stat_of(hold_with_sag_frames(4), "PLANK_HIP_SAG") is None, (
            "抖一下不该在几十秒的支撑里变成一次犯规"
        )
        assert stat_of(hold_with_sag_frames(40), "PLANK_HIP_SAG") is not None, (
            "门槛把真塌也放过了的话，8 这个数就是大的方向调过头了"
        )

    def test_a_normal_dismount_reports_nothing(self):
        """状态机换相滞后几帧，所以 rep 窗口的**尾巴上有几帧已经是起身了**。

        门槛取 2 帧的时候，正是这几帧会把每一次正常收势判成塌腰
        —— 这也是 8 这个数的由来。
        """
        runner = plank_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    Segment(count=10, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                    Segment(count=60),
                    Segment(count=20, body_angle_deg=PLANK_STANDING_ANGLE_DEG),
                ]
            ),
        )
        assert runner.rep_count == 1
        assert not runner.finish_set().fault_stats


class TestNoBaselineDependence:
    """三条判定都不挂本人基线。"""

    def test_threshold_offsets_are_empty(self):
        definition = build_plank(STANDING_CALIBRATION)
        assert definition.threshold_offsets == {}
        for rule in definition.rules:
            assert "baseline" not in rule.metric

    def test_another_calibration_gives_the_same_verdict(self):
        def judge(calibration: Calibration):
            runner = ActionRunner(
                build_plank(calibration, config=plank_config()),
                thresholds=make_thresholds(),
                calibration=calibration,
                config=plank_config(),
            )
            feed_all(
                runner, one_hold_frames(hold_count=60, hip_offset=PLANK_SAG_OFFSET)
            )
            return runner.finish_set()

        another = Calibration(
            knee_angle=150.0,
            trunk_lean=12.0,
            heel_rise_ratio=0.30,
            frames=15,
        )
        a, b = judge(STANDING_CALIBRATION), judge(another)
        assert a.rep_count == b.rep_count
        assert [s.code for s in a.fault_stats] == [s.code for s in b.fault_stats]
