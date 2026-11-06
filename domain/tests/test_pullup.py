"""引体向上动作定义测试（``app/test/domain/pullup_test.dart`` 的 Python 镜像）。

两侧的断言刻意**逐条对应**：合成几何相同、阈值相同、结论相同。语言之间出现分歧时，
``check_all.py`` 不会报警 —— 唯一的发现方式就是两侧各有一份说同一件事的测试。

这里钉住五类结论，每一类都是「不做就会**静默**出错」的：

1. **分段信号是肘角，判定信号是肘角 + 嘴高差 + 躯干倾角 —— 三者互不干扰。**
   合成帧的三个自变量各有一个几何支点，所以能造出「拉到位但身体在荡」
   「不荡但没回到直臂」这类交叉用例。
2. **「算不算一次」与「做得好不好」是两条线。** 没到过 ``TOP`` 的那些根本不进
   计数（走 ``discarded_reps``），而下颌过杠那条管的是进来的那些 ——
   两者合成一条，用户就分不清「这一次没算」与「这一次算了但可以更好」。
3. **下颌过杠那条切在顶点段（``Phase.APEX``），而这件事只有在「读不到」时才
   看得出差别。** 下面有一条专门造「拉到顶之后脸就被上臂挡住」的断言，
   并且用**同一批帧 + 把窗口换回整段的对照定义**证明那份「不报」真的来自窗口。
4. **``PULLUP_NOT_DEAD_HANG`` 的阈值必须高于分段线。** 低于的话
   「整段最大值越界」恒假，规则永远不触发、也不报错。
5. **三条判定都不挂本人基线。**

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
from vitalteen_domain.exercises import Calibration, TrackingConfig, build_pullup
from vitalteen_domain.exercises.base import ActionDefinition, ActionRunner
from vitalteen_domain.exercises.pullup import HANG, LOWERING, PULLING, TOP
from vitalteen_domain.features import FeatureExtractor
from vitalteen_domain.rules import Phase
from vitalteen_domain.thresholds import SourceType

#: **必须是正方形画幅**，理由同 ``test_slj.py``：角度在像素空间计算，
#: 非方形画幅会把 x 与 y 缩放成不同倍率。引体向上这边还多一层 ——
#: ``mouth_wrist_dy`` 的分子是像素空间中嘴与腕的 y 之差，而它的分母是躯干长；
#: 非方形画幅下两者被缩放成不同倍率，这个比值就不再是合成的那个姿态，
#: 而它不会报错，只会让「下颌过杠」这条规则判歪。
WIDTH, HEIGHT = 1000, 1000

# ---- 合成姿态的几何常量。**与 ``app/test/support/synthetic_pullup.dart`` 逐位相同** ----

#: 单杠的高度 —— 也就是两手手腕的高度。整个骨架从这里往下长。
BAR_Y = 0.25

#: 手腕的横坐标（左右手的中点）。
_WRIST_X = 0.50

#: 上臂与前臂长（归一化画幅单位）。
UPPER_ARM_LEN = 0.10
FORE_ARM_LEN = 0.10

#: 躯干长：肩中点到髋中点的距离。**它同时是 ``mouth_wrist_dy`` 的分母**，
#: 所以这个数一旦改了，所有以比值为单位的用例都要跟着看一遍。
TORSO_LEN = 0.20

#: 大腿与小腿长。只为了让骨架落在画面里，不参与任何判定。
_UPPER_LEG_LEN = 0.14
_LOWER_LEG_LEN = 0.14

#: 左右同侧点的横向缝隙。侧视下本来就几乎重合，留一条缝是为了
#: ``shoulder_width_px`` 之类的分母不退化。
SIDE_GAP = 0.01

#: 直臂悬垂时的肘角。取 175 而不是 180：180 要求肩、肘、腕严格共线，
#: 一个正好落在边界上的合成值会把「阈值取 170」这类测试变成浮点比较。
PULLUP_HANG_ELBOW_DEG = 175.0

#: 拉到顶时的肘角。
PULLUP_TOP_ELBOW_DEG = 80.0

#: 上拉/下放途中经过的肘角（两条分段线 90 与 165 之间）。
PULLUP_MID_ELBOW_DEG = 130.0

#: 直臂悬垂时嘴相对腕的高度（正值 = 嘴在杠**下方**）。
PULLUP_HANG_MOUTH_DY = 0.30

#: 拉到顶时嘴相对腕的高度。**负值 = 嘴在杠上方 = 下颌过杠。**
PULLUP_TOP_MOUTH_DY = -0.15

#: 上拉/下放途中经过的嘴高差（嘴正在接近杠）。
PULLUP_MID_MOUTH_DY = 0.10


def pullup_pose(
    timestamp_ms: int = 0,
    *,
    elbow_deg: float = PULLUP_HANG_ELBOW_DEG,
    mouth_wrist_dy: float = PULLUP_HANG_MOUTH_DY,
    trunk_lean_deg: float = 0.0,
    visibility: float = 1.0,
    visibility_overrides: dict[int, float] | None = None,
) -> PoseFrame:
    """合成一帧引体向上姿态。

    **支点选在手腕上**（与 ``test_pu.py`` 相反）：双手握在杠上，腕是不动的那一个。
    腕点固定在 ``(WRIST_X, BAR_Y)``、肘点固定在腕点正下方，肩点由「肘→腕」方向
    绕肘点**精确旋转** ``elbow_deg`` 得到；髋点由「肩点 − 躯干长 × (sin θ, −cos θ)」
    放置；嘴中点的 y 直接由 ``mouth_wrist_dy`` 反推。三个量因此都是**精确**的
    （俯卧撑那边髋偏离只有近似）。

    - ``elbow_deg``：``elbow_angle_L`` 与 ``elbow_angle_R`` 的目标值，**精确**。
    - ``mouth_wrist_dy``：``mouth_wrist_dy`` 的目标值，**精确**。负 = 嘴高过腕。
    - ``trunk_lean_deg``：``trunk_lean`` 的目标值，**精确**。正 = 肩在髋的右侧。
    """
    rad = math.radians(elbow_deg)
    lean_rad = math.radians(trunk_lean_deg)

    # 手腕固定在杠上。
    left_wrist = (_WRIST_X - SIDE_GAP / 2, BAR_Y)
    right_wrist = (_WRIST_X + SIDE_GAP / 2, BAR_Y)

    # 肘在腕的正下方。
    elbow_y = BAR_Y + FORE_ARM_LEN
    left_elbow = (left_wrist[0], elbow_y)
    right_elbow = (right_wrist[0], elbow_y)

    # 肩由「肘→腕」方向（图像里是 (0, -1)，朝上）绕肘点精确旋转 elbow_deg 得到：
    # 旋转后是 (sin θ, -cos θ)。于是 angle3(肩, 肘, 腕) 逐位等于 θ。
    upper_dir = (math.sin(rad), -math.cos(rad))
    left_shoulder = (
        left_elbow[0] + UPPER_ARM_LEN * upper_dir[0],
        left_elbow[1] + UPPER_ARM_LEN * upper_dir[1],
    )
    right_shoulder = (
        right_elbow[0] + UPPER_ARM_LEN * upper_dir[0],
        right_elbow[1] + UPPER_ARM_LEN * upper_dir[1],
    )

    shoulder_mid = (
        (left_shoulder[0] + right_shoulder[0]) / 2,
        (left_shoulder[1] + right_shoulder[1]) / 2,
    )

    # 髋：tilt_from_vertical(髋, 肩) 逐位等于 trunk_lean_deg，且躯干长逐位等于 TORSO_LEN。
    hip_mid = (
        shoulder_mid[0] - TORSO_LEN * math.sin(lean_rad),
        shoulder_mid[1] + TORSO_LEN * math.cos(lean_rad),
    )

    knee_mid = (hip_mid[0], hip_mid[1] + _UPPER_LEG_LEN)
    ankle_mid = (knee_mid[0], knee_mid[1] + _LOWER_LEG_LEN)

    # 嘴中点：直接由比值反推 y。分母（躯干长）构造上就等于 TORSO_LEN。
    mouth_mid = (shoulder_mid[0], BAR_Y + mouth_wrist_dy * TORSO_LEN)

    # 其余的点（眼、耳、鼻）跟着嘴走：头就长在那儿。
    pts: dict[int, tuple[float, float]] = dict.fromkeys(range(N_LANDMARKS), mouth_mid)
    # 肩与肘**不再另外平移**那半条缝：它们是从已经带缝的腕点推出来的，
    # 相对几何因此逐位保持（肘角才等于 ``elbow_deg``）。再平移一次会让
    # 「肘-肩」与「肘-腕」两条边错开半个缝宽，一个 175° 的直臂悬垂会被读成
    # 172.1° —— 而 3° 足够跨过分段线。
    pts[L.LEFT_SHOULDER] = left_shoulder
    pts[L.RIGHT_SHOULDER] = right_shoulder
    pts[L.LEFT_ELBOW] = left_elbow
    pts[L.RIGHT_ELBOW] = right_elbow
    pts[L.LEFT_WRIST] = left_wrist
    pts[L.RIGHT_WRIST] = right_wrist
    # 髋、膝、踝是左右对称地绕中点摆的 —— `torso_length()` 取的就是两个中点的距离。
    pts[L.LEFT_HIP] = (hip_mid[0] - SIDE_GAP / 2, hip_mid[1])
    pts[L.RIGHT_HIP] = (hip_mid[0] + SIDE_GAP / 2, hip_mid[1])
    pts[L.LEFT_KNEE] = (knee_mid[0] - SIDE_GAP / 2, knee_mid[1])
    pts[L.RIGHT_KNEE] = (knee_mid[0] + SIDE_GAP / 2, knee_mid[1])
    pts[L.LEFT_ANKLE] = (ankle_mid[0] - SIDE_GAP / 2, ankle_mid[1])
    pts[L.RIGHT_ANKLE] = (ankle_mid[0] + SIDE_GAP / 2, ankle_mid[1])
    # 脚跟与脚尖不参与引体向上的任何特征，但给出来更接近真实帧 ——
    # 也正因为它们给了，「左脚出画会被拦住」那类门禁测试才有反例可用。
    pts[L.LEFT_HEEL] = (ankle_mid[0] - SIDE_GAP / 2 + 0.02, ankle_mid[1] + 0.01)
    pts[L.RIGHT_HEEL] = (ankle_mid[0] + SIDE_GAP / 2 + 0.02, ankle_mid[1] + 0.01)
    pts[L.LEFT_FOOT_INDEX] = (ankle_mid[0] - SIDE_GAP / 2 + 0.04, ankle_mid[1] + 0.01)
    pts[L.RIGHT_FOOT_INDEX] = (ankle_mid[0] + SIDE_GAP / 2 + 0.04, ankle_mid[1] + 0.01)
    pts[L.MOUTH_LEFT] = (mouth_mid[0] - SIDE_GAP / 2, mouth_mid[1])
    pts[L.MOUTH_RIGHT] = (mouth_mid[0] + SIDE_GAP / 2, mouth_mid[1])

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
    """一个姿态段：连续 ``count`` 帧，三个自变量固定。"""

    elbow_deg: float = PULLUP_HANG_ELBOW_DEG
    count: int = 14
    mouth_wrist_dy: float = PULLUP_HANG_MOUTH_DY
    trunk_lean_deg: float = 0.0


def frames_from_segments(
    segments: list[Segment], *, start_ms: int = 0, interval_ms: int = 33
) -> list[PoseFrame]:
    frames: list[PoseFrame] = []
    for segment in segments:
        start = start_ms + len(frames) * interval_ms
        for i in range(segment.count):
            frames.append(
                pullup_pose(
                    start + i * interval_ms,
                    elbow_deg=segment.elbow_deg,
                    mouth_wrist_dy=segment.mouth_wrist_dy,
                    trunk_lean_deg=segment.trunk_lean_deg,
                )
            )
    return frames


#: 直臂悬垂段。开场与收尾都用它。
HANG_SEGMENT = Segment()

#: 上拉/下放途中经过的一段。
MID_SEGMENT = Segment(
    elbow_deg=PULLUP_MID_ELBOW_DEG,
    mouth_wrist_dy=PULLUP_MID_MOUTH_DY,
)

#: 拉到顶（嘴过杠）。
TOP_SEGMENT = Segment(
    elbow_deg=PULLUP_TOP_ELBOW_DEG,
    mouth_wrist_dy=PULLUP_TOP_MOUTH_DY,
)

#: 站立基线。**引体向上三条判定一条都不用它**，但它仍然要采 ——
#: 那是 ``Calibrator`` 的门槛，也是「开始之前先站好」那一步的产物。
STANDING_CALIBRATION = Calibration(
    knee_angle=175.0,
    trunk_lean=0.0,
    heel_rise_ratio=0.0,
    frames=15,
)

#: 内联阈值表。三条判定的取值只为本测试服务；刻意离合成帧的取值远一点，
#: 免得断在阈值同侧的边界上（悬垂 175° 对阈 170°、到顶嘴高差 −0.15 对阈 −0.10、
#: 倾角 0 对阈 20°）。
#:
#: **注意 ``pullup.chin_over_dy_max`` 是一个负数** —— 下颌过杠的判据是
#: 「嘴高于手腕」，在这个带符号的特征上就是负值。所以本文件里不能断言
#: 「阈值一律为正」，只能断言「非零、有限」。
_THRESHOLD_ROWS = {
    "pullup.dead_hang_min_elbow": (170.0, "elbow_angle_L", "deg"),
    "pullup.chin_over_dy_max": (-0.10, "mouth_wrist_dy", "ratio"),
    "pullup.swing_max_lean_deg": (20.0, "trunk_lean", "deg"),
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
                action_code="PULLUP",
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


def pullup_config() -> TrackingConfig:
    """与产品一致：引体向上走 45° 主链路（``productCameraView``）。"""
    return TrackingConfig(camera_view="oblique45", max_rep_frames=180)


def pullup_runner(
    *,
    config: TrackingConfig | None = None,
    thresholds: ThresholdTable | None = None,
    definition: ActionDefinition | None = None,
) -> ActionRunner:
    """构造一个阈值已核定的引体向上 runner。

    ``config`` 必须**同时**喂给 :func:`build_pullup` 与 :class:`ActionRunner` ——
    Python 侧的定义不携带 config（与 Dart 的刻意分歧，见 ``base.py`` 的说明），
    只传一边不会报错，只会让另一半静默用回默认值。

    ``definition`` 用来塞一个**改过一处**的定义（见 :func:`chin_rule_on_whole_rep`）。
    """
    cfg = config or pullup_config()
    return ActionRunner(
        definition or build_pullup(STANDING_CALIBRATION, config=cfg),
        thresholds=thresholds or make_thresholds(),
        calibration=STANDING_CALIBRATION,
        config=cfg,
    )


def chin_rule_on_whole_rep() -> ActionDefinition:
    """把「下颌未过杠」那条规则的窗口从顶点段换成整段，**其余一字不动**。

    用来做**对照**：同一批帧、同一条规则，只有窗口不同。结论不同就证明那处窗口
    真的在起作用 —— 而不是「不报」这件事碰巧由别的原因（比如压根没计数）造成。
    """
    base = build_pullup(STANDING_CALIBRATION, config=pullup_config())
    return replace(
        base,
        rules=tuple(
            replace(rule, phase=Phase.ALL)  # ← 唯一改动。
            if rule.code == "PULLUP_CHIN_NOT_OVER"
            else rule
            for rule in base.rules
        ),
    )


def feed_all(runner: ActionRunner, frames: list[PoseFrame]) -> None:
    for frame in frames:
        runner.feed(frame)


def stat_of(summary, code: str):
    for stat in summary.fault_stats:
        if stat.code == code:
            return stat
    return None


def rep_frames(
    *,
    start_ms: int = 0,
    hang_elbow_deg: float = PULLUP_HANG_ELBOW_DEG,
    top_mouth_wrist_dy: float = PULLUP_TOP_MOUTH_DY,
    trunk_lean_deg: float = 0.0,
) -> list[PoseFrame]:
    """一次标准引体向上：悬垂 → 上拉 → 顶部 → 下放 → 回到直臂悬垂。"""
    return frames_from_segments(
        [
            Segment(elbow_deg=hang_elbow_deg, trunk_lean_deg=trunk_lean_deg),
            Segment(
                elbow_deg=PULLUP_MID_ELBOW_DEG,
                mouth_wrist_dy=PULLUP_MID_MOUTH_DY,
                trunk_lean_deg=trunk_lean_deg,
            ),
            Segment(
                elbow_deg=PULLUP_TOP_ELBOW_DEG,
                mouth_wrist_dy=top_mouth_wrist_dy,
                trunk_lean_deg=trunk_lean_deg,
            ),
            Segment(
                elbow_deg=PULLUP_MID_ELBOW_DEG,
                mouth_wrist_dy=PULLUP_MID_MOUTH_DY,
                trunk_lean_deg=trunk_lean_deg,
            ),
            Segment(elbow_deg=hang_elbow_deg, trunk_lean_deg=trunk_lean_deg),
        ],
        start_ms=start_ms,
    )


def rep_with_mouth_hidden_from_the_top(*, top_mouth_wrist_dy: float) -> list[PoseFrame]:
    """一次「拉到顶那一刻起，脸就被上臂挡住」的引体向上。

    嘴点在**顶点段与它之后的整段下放**上可见性设成 0，上拉段与悬垂段正常可见。
    顶点段的嘴高差由 ``top_mouth_wrist_dy`` 给 —— 传一个**该被判违规**的值，
    用来看规则到底判不判。

    **为什么连下放段一起挡住**：状态机换相要经过投票窗口，确认会滞后几帧，
    所以顶点相位窗口的**尾巴上有几帧其实是下放**（见对应测试的注释）。
    只挡顶点段的话，那几帧照样会被读到 —— 这条用例要验的是「整段读不到就不判」。
    """
    frames: list[PoseFrame] = []
    timestamp = 0

    def add(segment: Segment, *, hide_mouth: bool = False) -> None:
        nonlocal timestamp
        for _ in range(segment.count):
            frames.append(
                pullup_pose(
                    timestamp,
                    elbow_deg=segment.elbow_deg,
                    mouth_wrist_dy=segment.mouth_wrist_dy,
                    trunk_lean_deg=segment.trunk_lean_deg,
                    visibility_overrides=(
                        {L.MOUTH_LEFT: 0.0, L.MOUTH_RIGHT: 0.0} if hide_mouth else None
                    ),
                )
            )
            timestamp += 33

    add(HANG_SEGMENT)
    add(MID_SEGMENT)
    add(
        Segment(
            elbow_deg=PULLUP_TOP_ELBOW_DEG,
            mouth_wrist_dy=top_mouth_wrist_dy,
        ),
        hide_mouth=True,
    )
    add(MID_SEGMENT, hide_mouth=True)
    add(HANG_SEGMENT)
    return frames


#: 产品机位下的特征读取器。
#:
#: 三个自变量用的特征（``elbow_angle_*`` / ``mouth_wrist_dy`` / ``trunk_lean``）
#: 在 45° 下都**没有机位门控**，所以与 runner 内部用的那个一致。
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


class TestPullupConstruction:
    def test_rejects_illegal_line_order(self) -> None:
        """分段线顺序被违反时当场炸，而不是悄悄多一条边。

        把两条线的含义写反（顶部线跑到悬垂线上面）是最容易犯的一种：
        看起来只是两个数字换了位置，而后果是状态机在 PULLING 与 TOP 之间
        逐帧来回跳 —— 表现为「计数偶尔不对」，离病因非常远。
        """
        with pytest.raises(ValueError, match="分段线顺序非法"):
            build_pullup(
                STANDING_CALIBRATION,
                config=TrackingConfig(
                    camera_view="oblique45",
                    pullup_hang_deg=120.0,
                    pullup_top_deg=150.0,
                ),
            )

    def test_default_camera_view_is_oblique45(self) -> None:
        assert build_pullup(STANDING_CALIBRATION).camera_view == "oblique45"

        # 三个自变量用的特征在主链路机位下都必须可用 —— 判掉一个就等于少一条
        # 规则，而规则不可用时不命中、也不报错。
        frame = pullup_pose()
        for code in ("elbow_angle_L", "mouth_wrist_dy", "trunk_lean"):
            assert feature(frame, code) is not None, code

    def test_all_rules_use_absolute_thresholds(self) -> None:
        """三条判定都用绝对阈值 —— 一个基线偏移都不挂。"""
        definition = build_pullup(STANDING_CALIBRATION, config=pullup_config())
        assert definition.threshold_offsets == {}, "三条判定的阈值都是绝对的，一个偏移都不该有"


# --------------------------------------------------------------------------
# 合成姿态的数值
# --------------------------------------------------------------------------


class TestSyntheticGeometry:
    def test_three_variables_are_exact(self) -> None:
        """判定测试要断的是「越没越过阈值」，所以自变量必须算得准。"""
        for deg in (
            PULLUP_HANG_ELBOW_DEG,
            PULLUP_MID_ELBOW_DEG,
            PULLUP_TOP_ELBOW_DEG,
        ):
            frame = pullup_pose(elbow_deg=deg)
            assert feature(frame, "elbow_angle_L") == pytest.approx(deg, abs=1e-9)
            # 两侧都造得出来，分段用的均值才等于它。
            assert feature(frame, "elbow_angle_R") == pytest.approx(deg, abs=1e-9)

        for dy in (PULLUP_HANG_MOUTH_DY, PULLUP_MID_MOUTH_DY, PULLUP_TOP_MOUTH_DY):
            frame = pullup_pose(mouth_wrist_dy=dy)
            assert feature(frame, "mouth_wrist_dy") == pytest.approx(dy, abs=1e-9)

        for lean in (0.0, 12.0, -20.0):
            frame = pullup_pose(trunk_lean_deg=lean)
            assert feature(frame, "trunk_lean") == pytest.approx(lean, abs=1e-6)

    def test_mouth_wrist_dy_is_signed(self) -> None:
        """悬垂为正、到顶为负。

        **不能取绝对值。** 取绝对值会把「挂在杠下」与「拉过头」压成同一个数，
        于是「下颌未过杠」这条规则会同时指向两种方向相反的姿势 ——
        而它给的纠正建议只有一句。
        """
        assert PULLUP_HANG_MOUTH_DY > 0
        assert PULLUP_TOP_MOUTH_DY < 0

        hanging = pullup_pose()
        at_top = pullup_pose(
            elbow_deg=PULLUP_TOP_ELBOW_DEG, mouth_wrist_dy=PULLUP_TOP_MOUTH_DY
        )
        assert feature(hanging, "mouth_wrist_dy") > 0
        assert feature(at_top, "mouth_wrist_dy") < 0

    def test_the_three_variables_do_not_interfere(self) -> None:
        """改一个自变量不该动到另一个的读数。

        耦合起来的话，一条规则的命中会跟着另一条的自变量变，
        而屏幕上只表现为「这两条老是乱报」。
        """
        lean_only = pullup_pose(trunk_lean_deg=25.0)
        assert feature(lean_only, "elbow_angle_L") == pytest.approx(
            PULLUP_HANG_ELBOW_DEG, abs=1e-9
        )
        assert feature(lean_only, "mouth_wrist_dy") == pytest.approx(
            PULLUP_HANG_MOUTH_DY, abs=1e-9
        )

        top_only = pullup_pose(
            elbow_deg=PULLUP_TOP_ELBOW_DEG, mouth_wrist_dy=PULLUP_TOP_MOUTH_DY
        )
        assert feature(top_only, "trunk_lean") == pytest.approx(0.0, abs=1e-6)


# --------------------------------------------------------------------------
# 分段
# --------------------------------------------------------------------------


class TestPullupSegmentation:
    def test_counts_one_standard_rep(self) -> None:
        runner = pullup_runner()
        feed_all(runner, rep_frames())

        assert runner.rep_count == 1, f"丢弃了 {runner.discarded_reps}"
        assert runner.discarded_reps == 0
        assert runner.current_state == HANG

    def test_rep_that_never_reached_top_is_discarded_not_counted(self) -> None:
        """没拉到顶就落回来：计 0、弃 1。

        「引体向上」这个动作的判定对象就是「拉到顶再落回直臂悬垂」。只弯到
        130°（够不着 ``pullup_top_deg`` 90°）的那一次**不算一次**，
        而它也不是无声无息地消失 —— ``discarded_reps`` 记账。
        """
        runner = pullup_runner()
        feed_all(
            runner,
            frames_from_segments([HANG_SEGMENT, MID_SEGMENT, HANG_SEGMENT]),
        )

        assert runner.rep_count == 0
        assert runner.discarded_reps == 1
        assert runner.current_state == HANG, "要回到悬垂等下一次"

    def test_transition_guard_bounds(self) -> None:
        """守卫的上下界：弯一点就离开悬垂，肘角回到进入线以上才算落回来。"""
        definition = build_pullup(STANDING_CALIBRATION, config=pullup_config())

        def at(src: str, dst: str, elbow: float) -> bool:
            return guard_of(definition, src, dst)({"elbow_angle_L": elbow})

        assert not at(HANG, PULLING, PULLUP_HANG_ELBOW_DEG)
        assert at(HANG, PULLING, PULLUP_MID_ELBOW_DEG)
        assert at(HANG, PULLING, PULLUP_TOP_ELBOW_DEG)

        assert not at(PULLING, TOP, PULLUP_MID_ELBOW_DEG)
        assert at(PULLING, TOP, PULLUP_TOP_ELBOW_DEG)

        # 开局与封存落到 HANG 用的是**同一条线**：HANG 只有一个含义。
        assert guard_of(definition, LOWERING, HANG) is guard_of(
            definition, PULLING, HANG
        )

        # 而滞回带保证「刚进 TOP」的那一帧不会被同一条线立刻推出去。
        assert not at(TOP, LOWERING, 91.0)
        assert at(TOP, LOWERING, 99.0)

    def test_rebound_does_not_get_stuck(self) -> None:
        """回拉不卡死：下放到一半又拉上去，仍然落得回来。"""
        runner = pullup_runner()
        feed_all(
            runner,
            frames_from_segments(
                [
                    HANG_SEGMENT,
                    MID_SEGMENT,
                    TOP_SEGMENT,
                    MID_SEGMENT,  # 下放到一半
                    TOP_SEGMENT,  # 又拉回去
                    MID_SEGMENT,
                    HANG_SEGMENT,  # 终于落回 → 封存
                ]
            ),
        )

        assert runner.rep_count == 1, "回拉之后仍然要落得回来"
        assert runner.current_state == HANG

    def test_hanging_still_is_neither_counted_nor_discarded(self) -> None:
        runner = pullup_runner()
        feed_all(runner, [pullup_pose(i * 33) for i in range(60)])

        assert runner.rep_count == 0
        assert runner.discarded_reps == 0, "挂着不动不该被记账成一次丢弃"
        assert runner.current_state == HANG

    def test_hang_contributes_no_phase_and_top_maps_to_apex(self) -> None:
        """HANG 不产出相位，TOP 产出的是 ``Phase.APEX``。

        ``RepWindow.select`` 在相位缺失时**静默**返回整段。HANG 不映射相位是
        刻意的，但 TOP 必须映射到 ``Phase.APEX`` —— 下颌过杠那条规则切的就是它，
        **漏映射的后果是它悄悄跑在整个 rep 上**。
        """
        definition = build_pullup(STANDING_CALIBRATION, config=pullup_config())

        runner = pullup_runner()
        feed_all(runner, rep_frames())
        window = runner.windows[0]

        assert set(window.phase_bounds) == {Phase.DESCENT, Phase.APEX, Phase.ASCENT}
        for phase in (Phase.DESCENT, Phase.APEX, Phase.ASCENT):
            start, end = window.phase_bounds[phase]
            assert end - start + 1 < len(window.frames), "相位退化成了整段"

        # 而 apex 确实是「最高那一段」：它落在 descent 之后。
        assert window.phase_bounds[Phase.APEX][0] >= window.phase_bounds[Phase.DESCENT][1]

        # 反面：三条规则里恰好只有下颌过杠那条切窗口 —— 另外两条问的是
        # 整次动作的极值，顺手也切进某个相位会让它们换个意思。
        assert [r.code for r in definition.rules if r.phase is not Phase.ALL] == [
            "PULLUP_CHIN_NOT_OVER"
        ]


# --------------------------------------------------------------------------
# 三条规则
# --------------------------------------------------------------------------


class TestPullupRules:
    def test_not_dead_hang_fires_only_on_the_bent_arm_rep(self) -> None:
        """落回来时肘角停在 168°：**低于绝对阈值 170°、高于分段线 165°** ——
        于是这一次被正常计数，然后被这条规则指出「没伸直」。停在 160°
        （够不着分段线）的话这一次会被 ``bottom_state`` 挡在外面、整段丢弃，
        这条规则根本没机会求值。
        """
        soft = pullup_runner()
        feed_all(soft, rep_frames(hang_elbow_deg=168.0))
        assert soft.rep_count == 1, "过了 pullup_hang_deg（165°），算一次"
        assert stat_of(soft.finish_set(), "PULLUP_NOT_DEAD_HANG") is not None

        straight = pullup_runner()
        feed_all(straight, rep_frames())
        assert stat_of(straight.finish_set(), "PULLUP_NOT_DEAD_HANG") is None, (
            "回到直臂悬垂不该被判未伸直 —— 否则这条规则是「永远命中」"
        )

    def test_threshold_below_the_segmentation_line_never_fires(self) -> None:
        """**把注释里的推理量出来**，不是在验产品行为。

        封存条件是「肘角回到分段线 165° 以上」，所以每一个被计数的 rep 的
        整段最大值都必然 > 165°。阈值定在 160° 时「最大值越界」恒假 ——
        规则永远不触发，**而且不报错**。所以资产表里那条线只能取在 165° 之上。
        """
        trapped = pullup_runner(
            thresholds=make_thresholds({"pullup.dead_hang_min_elbow": 160.0})
        )
        feed_all(trapped, rep_frames(hang_elbow_deg=168.0))
        assert trapped.rep_count == 1
        assert stat_of(trapped.finish_set(), "PULLUP_NOT_DEAD_HANG") is None, (
            "168° 的整段最大值已经越过了 160° 这条线 —— 它本来就是坏的"
        )

    def test_chin_not_over_fires_only_on_the_short_pull(self) -> None:
        """到顶时嘴还停在杠下（高差 +0.05 > 阈值 −0.10）：这一次**算数**
        （肘角到了 ``pullup_top_deg``），只是高度不够。"""
        short = pullup_runner()
        feed_all(short, rep_frames(top_mouth_wrist_dy=0.05))
        assert short.rep_count == 1, "到了顶就算一次 —— 判定的是「算数的那次好不好」"
        assert stat_of(short.finish_set(), "PULLUP_CHIN_NOT_OVER") is not None

        over = pullup_runner()
        feed_all(over, rep_frames())
        assert stat_of(over.finish_set(), "PULLUP_CHIN_NOT_OVER") is None, (
            "下颌过杠不该被判未过杠"
        )

    def test_hidden_mouth_from_the_top_does_not_fire(self) -> None:
        """**本文件里最值钱的一条。**

        同一个「嘴还停在杠下」的姿态，唯一的差别是顶点段的嘴点看不见。
        切在 ``Phase.APEX`` 上时那一段一个可用值都没有 → 规则不触发；
        跑在整段上时，上拉段那个看得见的读数会被 ``reduce: min`` 取成
        「这一次里最高的一帧」，于是脸被上臂挡住、其实拉得很到位的人
        会被判成没拉上去。

        代价是这条判定会因为遮挡而**静默地不生效** —— 那是有意选的：
        少判一次是提示，误报一次是告诉用户他做错了。
        """
        frames = rep_with_mouth_hidden_from_the_top(top_mouth_wrist_dy=0.05)

        hidden = pullup_runner()
        feed_all(hidden, frames)
        assert hidden.rep_count == 1, "肘角照样到了顶 —— 计数不受遮挡影响"
        assert stat_of(hidden.finish_set(), "PULLUP_CHIN_NOT_OVER") is None, (
            "顶点段的嘴读不到，应当「不知道」而不是「没过杠」"
        )

        # **对照：同一批帧、同一条规则，只把窗口换回整段 —— 必须命中。**
        # 这一半是决定性的：它证明上一条的「不报」真的来自窗口，
        # 而不是来自别的原因（计数没发生、阈值根本没被查到之类）。
        whole = pullup_runner(definition=chin_rule_on_whole_rep())
        feed_all(whole, frames)
        assert whole.rep_count == 1
        assert stat_of(whole.finish_set(), "PULLUP_CHIN_NOT_OVER") is not None, (
            "窗口换成整段之后，上拉段那个读数就会被取到 —— 这正是要防的误报"
        )

        # 第三个对照组：同一个姿态、嘴看得见 → 也必须命中。
        # 否则「嘴挡住时规则安静」可能是因为这条规则压根不工作。
        visible = pullup_runner()
        feed_all(visible, rep_frames(top_mouth_wrist_dy=0.05))
        assert stat_of(visible.finish_set(), "PULLUP_CHIN_NOT_OVER") is not None

    def test_swing_fires_only_when_the_body_sweeps(self) -> None:
        """符号取决于人面朝画面哪一侧，不是体育含义，所以 ``use_abs`` ——
        前后两个方向的摆动都要判命中。"""
        for lean in (25.0, -25.0):
            swinging = pullup_runner()
            feed_all(swinging, rep_frames(trunk_lean_deg=lean))
            assert swinging.rep_count == 1
            assert stat_of(swinging.finish_set(), "PULLUP_SWING") is not None, (
                f"倾角 {lean}° 应当被判成摆动"
            )

        steady = pullup_runner()
        feed_all(steady, rep_frames())
        assert stat_of(steady.finish_set(), "PULLUP_SWING") is None

    def test_a_clean_rep_hits_nothing(self) -> None:
        """一次标准动作三条规则一条都不命中。"""
        runner = pullup_runner()
        feed_all(runner, rep_frames())
        assert runner.rep_count == 1

        summary = runner.finish_set()
        assert summary.fault_stats == ()


# --------------------------------------------------------------------------
# 阈值表的键
# --------------------------------------------------------------------------


class TestPullupThresholdKeys:
    def test_rules_resolve_against_the_inline_table(self) -> None:
        definition = build_pullup(STANDING_CALIBRATION, config=pullup_config())
        table = make_thresholds()
        for rule in definition.rules:
            value = table.get(rule.threshold_key).value
            # **不能断言 > 0**：下颌过杠那条的阈值就是负数（见 ``_THRESHOLD_ROWS``）。
            assert math.isfinite(value) and value != 0.0, (
                f"{rule.code} 的阈值取到了 0 或非有限值"
            )

    def test_chin_over_threshold_is_negative(self) -> None:
        """那个量的符号约定（嘴高于腕 = 负）一旦被谁改成「取绝对值再判」，
        正负号就会失去意义、两条方向相反的姿势被压成同一个数。"""
        definition = build_pullup(STANDING_CALIBRATION, config=pullup_config())
        table = make_thresholds()
        key = next(
            r.threshold_key for r in definition.rules if r.code == "PULLUP_CHIN_NOT_OVER"
        )
        assert table.get(key).value < 0
