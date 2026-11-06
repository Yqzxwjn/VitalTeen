"""立定跳远动作定义测试（``app/test/domain/slj_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住四类结论，每一类都是「不做就会**静默**出错」的：

1. **四个相位区间必然齐全，且各自短于整段。** :meth:`RepWindow.select` 在区间缺失时
   静默返回整段，于是「只在落地段求值」的规则会悄悄变成「在整次动作上求值」。
2. **假跳必然超时不计数。** 状态机分不出「蹬直到站起来」与「蹬直到跳起来」——
   守卫看不见时间，唯一的分界是有没有落地缓冲。
3. **收腿不被当成落地。** 少了 ``landing_hip_floor`` 那道门槛，落地缓冲规则会变成
   一条永远不再触发的规则：收腿越标准越被判成缓冲充足。
4. **五条规则各自的相位与方向**，每条都有正例与反例。
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
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_slj
from vitalteen_domain.exercises.base import ActionRunner
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅。** 角度在像素空间计算（``angle3`` 吃的是像素坐标），
#: 而 720×1280 这种画幅会把 x 与 y 缩放成不同倍率，于是量出来的膝角与合成的
#: 角度对不上 —— 请求 155° 会量出 165.3°，正好越过落地线 163°，表现为
#: 「落地段进不去」这种离病因很远的症状。深蹲那份合成姿态不需要精确角度
#: （它的断言是「接近 180°」，abs=1.0），所以一直用的是非方形画幅。
WIDTH, HEIGHT = 1000, 1000

#: 合成姿态的几何常量。**与 ``app/test/support/synthetic_slj.dart`` 逐位相同** ——
#: 两边如果各用一套几何，测出来的就不是同一个动作了。
STAND_DEG = 175.0
_HIP_Y = 0.30
_LEG_LEN = 0.15
_TORSO_LEN = 0.10
_HIP_X = 0.50
_SIDE_GAP = 0.02
_FOOT_SPAN = 0.08


def slj_pose(
    left_knee_deg: float,
    timestamp_ms: int = 0,
    *,
    right_knee_deg: float | None = None,
    knee_lift: float = 0.0,
    trunk_lean_deg: float = 0.0,
    heel_rise: float = 0.0,
) -> PoseFrame:
    """合成一帧立定跳远姿态。

    踝的位置是**算出来的**：把「髋→膝」方向的单位向量绕膝旋转给定角度，得到
    「膝→踝」方向。膝被抬到别处时（收腹举腿）这个式子仍然成立，而照抄深蹲那份
    「踝在膝正下方」的摆法会让实际膝角与参数对不上 —— 那种错不会报错。
    """
    right_deg = left_knee_deg if right_knee_deg is None else right_knee_deg
    knee_y = _HIP_Y + _LEG_LEN - knee_lift

    def ankle_of(knee: tuple[float, float], hip: tuple[float, float], deg: float) -> tuple[float, float]:
        dx, dy = hip[0] - knee[0], hip[1] - knee[1]
        length = math.hypot(dx, dy)
        vx, vy = dx / length, dy / length
        rad = math.radians(deg)
        rx = vx * math.cos(rad) - vy * math.sin(rad)
        ry = vx * math.sin(rad) + vy * math.cos(rad)
        return (knee[0] + _LEG_LEN * rx, knee[1] + _LEG_LEN * ry)

    left_hip = (_HIP_X, _HIP_Y)
    right_hip = (_HIP_X + _SIDE_GAP, _HIP_Y)
    left_knee = (_HIP_X, knee_y)
    right_knee = (_HIP_X + _SIDE_GAP, knee_y)
    left_ankle = ankle_of(left_knee, left_hip, left_knee_deg)
    right_ankle = ankle_of(right_knee, right_hip, right_deg)

    # 脚跟抬升比 = d / √(L² + d²)，其中 d 是脚跟往上挪的距离、L 是脚的水平长度。
    # 反解 d = rL/√(1−r²) —— d 自己也进了分母，直接按 r×L 挪会得到偏小的比值。
    heel_dy = 0.0 if heel_rise == 0 else heel_rise * _FOOT_SPAN / math.sqrt(1 - heel_rise**2)
    lean_dx = 0.0 if trunk_lean_deg == 0 else _TORSO_LEN * math.tan(math.radians(trunk_lean_deg))
    shoulder_y = _HIP_Y - _TORSO_LEN
    shoulder_x = _HIP_X + lean_dx

    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), (0.5, 0.06))
    pts[L.LEFT_SHOULDER] = (shoulder_x, shoulder_y)
    pts[L.RIGHT_SHOULDER] = (shoulder_x + _SIDE_GAP, shoulder_y)
    pts[L.LEFT_ELBOW] = (shoulder_x - 0.02, shoulder_y + 0.05)
    pts[L.RIGHT_ELBOW] = (shoulder_x + _SIDE_GAP + 0.02, shoulder_y + 0.05)
    pts[L.LEFT_WRIST] = (shoulder_x - 0.04, shoulder_y + 0.10)
    pts[L.RIGHT_WRIST] = (shoulder_x + _SIDE_GAP + 0.04, shoulder_y + 0.10)
    pts[L.LEFT_HIP] = left_hip
    pts[L.RIGHT_HIP] = right_hip
    pts[L.LEFT_KNEE] = left_knee
    pts[L.RIGHT_KNEE] = right_knee
    pts[L.LEFT_ANKLE] = left_ankle
    pts[L.RIGHT_ANKLE] = right_ankle
    pts[L.LEFT_HEEL] = (left_ankle[0] - 0.03, left_ankle[1] + 0.008 - heel_dy)
    pts[L.RIGHT_HEEL] = (right_ankle[0] - 0.03, right_ankle[1] + 0.008 - heel_dy)
    pts[L.LEFT_FOOT_INDEX] = (left_ankle[0] + 0.05, left_ankle[1] + 0.008)
    pts[L.RIGHT_FOOT_INDEX] = (right_ankle[0] + 0.05, right_ankle[1] + 0.008)

    return PoseFrame(
        landmarks=tuple(
            Landmark(x=pts[i][0], y=pts[i][1], z=0.0, visibility=1.0) for i in range(N_LANDMARKS)
        ),
        frame_width=WIDTH,
        frame_height=HEIGHT,
        timestamp_ms=timestamp_ms,
    )


@dataclass(frozen=True)
class Segment:
    """一个姿态段：连续 ``count`` 帧，左右膝角固定，其余参数逐段可选。

    缺陷通常只出现在某一个相位里 —— 蓄力段抬了脚跟、蹬伸段躯干前倾。
    用「段」描述，测试读起来就与动作本身一一对应。
    """

    left_knee_deg: float
    count: int = 12
    right_knee_deg: float | None = None
    knee_lift: float = 0.0
    trunk_lean_deg: float = 0.0
    heel_rise: float = 0.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                slj_pose(
                    segment.left_knee_deg,
                    start + i * interval_ms,
                    right_knee_deg=segment.right_knee_deg,
                    knee_lift=segment.knee_lift,
                    trunk_lean_deg=segment.trunk_lean_deg,
                    heel_rise=segment.heel_rise,
                )
            )
    return frames


STAND = Segment(STAND_DEG, count=16)  #: 站立段：状态机要 5 帧同证据才换相
PREP = Segment(95.0, count=12)  #: 蓄力段：95° 远低于前蹲线 150°
SOFT_LANDING = Segment(115.0, count=12)  #: 落地缓冲段：低于缓冲线 140°
RECOVER = Segment(STAND_DEG, count=16)

CALIBRATION = Calibration(knee_angle=STAND_DEG, trunk_lean=0.0, heel_rise_ratio=0.0, frames=15)

#: 分段线在 stand=175 时的位置（见 ``slj.py`` 模块文档的推导）。
BEND_LINE, RISE_LINE, LAND_LINE, STAND_LINE, FLY_LINE = 150.0, 158.0, 163.0, 167.0, 171.0


def make_thresholds() -> ThresholdTable:
    """内联阈值表。数值只为本测试服务，**不是**体育判定依据。"""
    rows = {
        "slj.prejump_foot_off_max_delta": (0.15, "heel_rise_ratio_L", "ratio"),
        "slj.takeoff_symmetry_max": (0.10, "knee_symmetry", "ratio"),
        "slj.landing_symmetry_max": (0.10, "knee_symmetry", "ratio"),
        # 缓冲线取 140°：合成序列里「有缓冲」落在 115°、「没缓冲」落在 155°。
        "slj.landing_buffer_min_knee_angle": (140.0, "knee_angle_L", "deg"),
        "slj.trunk_lean_max_delta": (15.0, "trunk_lean", "deg"),
    }
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="SLJ",
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


def slj_runner(*, config: TrackingConfig | None = None) -> ActionRunner:
    """构造一个阈值已核定的立定跳远 runner。

    ``config`` 必须**同时**喂给 :func:`build_slj` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。
    """
    cfg = config or TrackingConfig(camera_view="oblique45", min_bend_deg=25.0, max_rep_frames=120)
    return ActionRunner(
        build_slj(CALIBRATION, config=cfg),
        thresholds=make_thresholds(),
        calibration=CALIBRATION,
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


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestSljSegmentation:
    def test_counts_one_full_rep_with_all_four_phases(self) -> None:
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments([STAND, PREP, Segment(178.0, count=16), SOFT_LANDING, RECOVER]),
        )

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0

        window = runner.windows[0]
        assert window.index == 1, "rep 序号从 1 起算，供报告直接显示「第 N 次」"

        phases = (Phase.PREP, Phase.TAKEOFF, Phase.FLIGHT, Phase.LANDING)
        for phase in phases:
            assert phase in window.phase_bounds, f"缺少相位 {phase}"
        starts = [window.phase_bounds[p][0] for p in phases]
        assert starts == sorted(starts), f"相位顺序不对：{starts}"

    def test_each_phase_is_strictly_shorter_than_the_whole_rep(self) -> None:
        """整段退化在本动作上走不到 —— 这是状态图的结构性质，不是运气。"""
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments([STAND, PREP, Segment(178.0, count=16), SOFT_LANDING, RECOVER]),
        )
        window = runner.windows[0]

        for phase in (Phase.PREP, Phase.TAKEOFF, Phase.FLIGHT, Phase.LANDING):
            selected = window.select(phase)
            assert selected, f"{phase} 一帧都取不到"
            assert len(selected) < len(window.frames), f"{phase} 退化成了整段"

    def test_fake_jump_is_discarded_by_timeout_and_resets(self) -> None:
        """「蹲一下又站起来」走得到 FLIGHT，然后站着不动，只能等超时。

        这不是缺陷而是本设计的已知代价：没有落地缓冲就分不出假跳与真跳。
        收尾那 140 帧是刻意的，要让它**真的**越过 120 帧上限，
        才能验证 RepTracker 会复位而不是永远挂着半个 rep。
        """
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    Segment(95.0, count=14),
                    Segment(178.0, count=14),
                    Segment(STAND_DEG, count=140),
                ]
            ),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == "STANDING", "必须复位回站立态等下一段"

    def test_resync_after_loss_lands_and_keeps_all_four_phases(self) -> None:
        """停在 LAUNCH 时的重同步：回来那一下蹲仍然被认成落地。

        立定跳远与深蹲最不一样的一点：**人会离开原地**。出画时状态机停在哪个
        状态是随机的，而多半停在 LAUNCH —— 出画的瞬间恰好是蹬伸最快的那几帧，
        膝角刚过蹬伸线（158°）、还够不着离地线（171°）。停在 LAUNCH 的后果不是
        「少计一次」，而是**连环丢掉一次本来看得见的落地**：回来蹲下被读成回蹲，
        站直又把它推回 FLIGHT，最后等超时。

        重同步要是不给旧的那一段收尾，后面的帧会被记进 LAUNCH 的区间里，
        而错相位不报错 —— 只会让落地缓冲、落地同步两条规则去评一段不属于它的帧。
        所以这里逐个相位核一遍，不只核计数。
        """
        runner = slj_runner()
        before = frames_from_segments([STAND, PREP, Segment(165.0, count=12)])
        feed_all(runner, before)
        assert runner.current_state == "LAUNCH", "前提：出画那一刻确实停在 LAUNCH"

        assert runner.recover_from_loss() is True
        assert runner.current_state == "FLIGHT", "按登记的那条边落到 FLIGHT"
        assert runner.recover_from_loss() is False, "FLIGHT 没有再登记的边：重复调用是空操作"

        feed_all(
            runner,
            frames_from_segments(
                [SOFT_LANDING, RECOVER], start_ms=before[-1].timestamp_ms + 33
            ),
        )

        assert runner.rep_count == 1, "蹬伸那几帧没看见，但落地看见了，这是一次真跳"
        assert runner.discarded_reps == 0

        window = runner.windows[0]
        for phase in (Phase.PREP, Phase.TAKEOFF, Phase.FLIGHT, Phase.LANDING):
            assert phase in window.phase_bounds, f"缺少相位 {phase}"
            assert len(window.select(phase)) < len(window.frames), f"{phase} 退化成了整段"
        assert len(window.select(Phase.LANDING)) <= SOFT_LANDING.count + RECOVER.count, (
            "落地相位只该覆盖「回来之后」那一段"
        )

    def test_resync_only_puts_you_airborne(self) -> None:
        """重同步只把人放进空中：回来时已经站直，仍然不算数。

        这是上一条的边界，也是它与「直接封存一次落地」的分界线。改成
        LAUNCH→LAND 的话这条会红 —— 而那正是**编分数**：落地两条规则读的都是
        landing 相位，人走回来那几帧会被拿去评「缓冲够不够」。
        """
        runner = slj_runner()
        before = frames_from_segments([STAND, PREP, Segment(165.0, count=12)])
        feed_all(runner, before)
        runner.recover_from_loss()

        feed_all(
            runner,
            frames_from_segments(
                [Segment(STAND_DEG, count=140)], start_ms=before[-1].timestamp_ms + 33
            ),
        )

        assert runner.rep_count == 0, "没有任何一帧看到落地，就没有计数的依据"
        assert runner.discarded_reps == 1, "但要如实记账，不能装作什么都没发生"
        assert runner.current_state == "STANDING", "超时之后要复位等下一跳"

    def test_resync_is_a_no_op_outside_a_rep(self) -> None:
        """不在一次 rep 里时是空操作 —— 站着不动不会被推着走。

        若它不管这件事，一段长丢失结束时会把一个站着不动的人推进 FLIGHT，
        下一帧的站立姿态什么守卫都不满足，只能等超时 —— 用户站着没跳，
        却被告知丢了一次。
        """
        runner = slj_runner()
        feed_all(runner, frames_from_segments([Segment(STAND_DEG, count=20)]))

        assert runner.recover_from_loss() is False
        assert runner.current_state == "STANDING"
        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "站着不动不该被记账成一次丢弃"

    def test_crouch_back_edge_does_not_deadlock(self) -> None:
        """蹬伸到一半又蹲回去 —— 回退边是正确性的一部分。"""
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    PREP,
                    Segment(170.0, count=8),  # 蹬起一点 → LAUNCH
                    Segment(95.0, count=12),  # 又蹲回去 → PREP
                    Segment(178.0, count=16),  # 这次蹬直 → FLIGHT
                    SOFT_LANDING,
                    RECOVER,
                ]
            ),
        )

        assert runner.rep_count == 1
        assert runner.current_state == "STANDING"


# --------------------------------------------------------------------------
# 落地门槛
# --------------------------------------------------------------------------


class TestLandingGate:
    def test_hip_not_above_knee_is_not_a_landing(self) -> None:
        """守卫单独测 —— 门槛失效时状态机走得更「顺」，只是 LAND 变成了那段收腿。"""
        definition = build_slj(CALIBRATION)
        guard = next(
            t.guard for t in definition.transitions if t.src == "FLIGHT" and t.dst == "LAND"
        )

        assert guard({"knee_angle_L": 100.0, "knee_angle_R": 100.0, "hip_height_ratio": 1.5})
        assert not guard(
            {"knee_angle_L": 100.0, "knee_angle_R": 100.0, "hip_height_ratio": -0.5}
        ), "收腹举腿：膝折到胸口，髋中点已经低于膝中点"
        assert not guard(
            {"knee_angle_L": 100.0, "knee_angle_R": 100.0}
        ), "特征不可用时不能默认放行 —— 那会把遮挡变成一次落地"
        assert not guard(
            {"knee_angle_L": 170.0, "knee_angle_R": 170.0, "hip_height_ratio": 1.5}
        ), "膝还没屈到落地线以下，根本不是落地"

    def test_tuck_is_not_taken_as_landing_with_control_group(self) -> None:
        """门槛的端到端回归，含「拆掉门槛」的对照组。

        刻意让收腿（100°）比真正的落地（155°）还深。这是本设计里最难自查的失败
        模式：门槛失效时一切正常，只是 ``LANDING`` 变成了那一段收腿，于是
        「落地缓冲不足」**静默失效**。所以这里不只断言门槛在的时候对，
        还断言门槛不在的时候确实错 —— 否则这条测试可能只是在空转。
        """
        frames = frames_from_segments(
            [
                STAND,
                PREP,
                Segment(178.0, count=16),
                Segment(100.0, count=12, knee_lift=0.20),  # 收腹举腿
                Segment(155.0, count=14),  # 真正的落地缓冲
                RECOVER,
            ]
        )

        def lowest_knee(runner: ActionRunner) -> float:
            window = runner.windows[0]
            knees = [f.get("knee_angle_L") for f in window.select(Phase.LANDING)]
            values = [v for v in knees if v is not None]
            assert values, "落地段一帧都取不到"
            return min(values)

        gated = slj_runner()
        feed_all(gated, frames)
        assert gated.rep_count == 1
        assert lowest_knee(gated) == pytest.approx(155.0, abs=1.0), "落地段里混进了收腿的帧"
        assert stat_of(gated.finish_set(), "SLJ_LAND_STIFF") is not None, (
            "落地屈膝只有 155°，缓冲不足应当命中；没命中说明落地段被抓错了"
        )

        # 对照组：门槛放到 -1.0（收腿时 hip 约 -0.5，仍然放行）。
        ungated = slj_runner(
            config=TrackingConfig(
                camera_view="oblique45",
                min_bend_deg=25.0,
                max_rep_frames=120,
                landing_hip_floor=-1.0,
            )
        )
        feed_all(ungated, frames)
        assert ungated.rep_count == 1, "门槛不该影响计数，只影响分段"
        assert lowest_knee(ungated) == pytest.approx(100.0, abs=1.0), "落地段退化成了收腿"
        assert stat_of(ungated.finish_set(), "SLJ_LAND_STIFF") is None, (
            "这就是门槛失效的样子：真的没缓冲，却什么都不报"
        )


# --------------------------------------------------------------------------
# 规则
# --------------------------------------------------------------------------


class TestSljRules:
    def test_clean_jump_has_no_faults(self) -> None:
        """反例组的总闸：任何一条规则方向写反、相位写错都会让这条先红。"""
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments([STAND, PREP, Segment(178.0, count=16), SOFT_LANDING, RECOVER]),
        )

        summary = runner.finish_set()
        assert summary.rep_count == 1
        assert not summary.fault_stats, f"命中了 {[s.code for s in summary.fault_stats]}"

    def test_stiff_landing_hits_land_stiff(self) -> None:
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [STAND, PREP, Segment(178.0, count=16), Segment(155.0, count=14), RECOVER]
            ),
        )

        stat = stat_of(runner.finish_set(), "SLJ_LAND_STIFF")
        assert stat is not None
        assert stat.rate == 1.0
        assert stat.scorable, "内联表标的是 LITERATURE"

    def test_deeper_landing_is_cleared(self) -> None:
        """判据是最低点，不是越界帧计数 —— 否则每一次落地都会被误判。"""
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments([STAND, PREP, Segment(178.0, count=16), SOFT_LANDING, RECOVER]),
        )
        assert stat_of(runner.finish_set(), "SLJ_LAND_STIFF") is None

    def test_asymmetric_takeoff_hits_takeoff_async(self) -> None:
        """一条腿先蹬直、另一条还差 28°：均值 164° 进得了 LAUNCH、够不到腾空线。

        这个「两腿差值不可能太大」是设计使然：差得再多，均值就够不到腾空线，
        这一跳根本不会被计数。所以两条同步规则抓的是**中等幅度**的不同步。
        """
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    PREP,
                    Segment(178.0, count=14, right_knee_deg=150.0),
                    Segment(180.0, count=12, right_knee_deg=178.0),
                    SOFT_LANDING,
                    RECOVER,
                ]
            ),
        )

        stat = stat_of(runner.finish_set(), "SLJ_TAKEOFF_ASYNC")
        assert stat is not None, "膝角对称指数 2×28/328 ≈ 0.17，越过 0.10"
        assert stat.rate == 1.0

    def test_asymmetric_landing_hits_land_async(self) -> None:
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    PREP,
                    Segment(178.0, count=16),
                    Segment(115.0, count=14, right_knee_deg=145.0),
                    RECOVER,
                ]
            ),
        )
        assert stat_of(runner.finish_set(), "SLJ_LAND_ASYNC") is not None

    def test_heel_rise_in_prep_hits_prejump_heel_off(self) -> None:
        """码名 HEEL_OFF（脚跟）与中文名「前掌离地」指向相反方向，取绝对值一次覆盖。"""
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    Segment(95.0, count=12, heel_rise=0.25),
                    Segment(178.0, count=16),
                    SOFT_LANDING,
                    RECOVER,
                ]
            ),
        )
        assert stat_of(runner.finish_set(), "SLJ_PREJUMP_HEEL_OFF") is not None

    def test_excess_trunk_lean_hits_trunk_control(self) -> None:
        runner = slj_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    STAND,
                    PREP,
                    Segment(178.0, count=16, trunk_lean_deg=40.0),
                    SOFT_LANDING,
                    RECOVER,
                ]
            ),
        )
        assert stat_of(runner.finish_set(), "SLJ_TRUNK_CONTROL") is not None
