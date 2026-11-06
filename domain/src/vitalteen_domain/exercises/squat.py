"""深蹲动作定义。

**状态链**（设计文档 §4.2，另补两条回退边）::

    STANDING ──→ DESCENT ──→ BOTTOM ──→ ASCENT ──→ STANDING
                    │                       │
                    └──→ STANDING           └──→ DESCENT
                        （假动作：弯一下      （回蹲：起身到一半
                          又直起来，           又弯回去，否则 ASCENT
                          从未到过底部）        会变成走不出去的死角）

**为什么必须有回退边**：只写「一路向前」的链条时，如果用户没有沿预期路径走
（弯 20 度就直起来、起身到一半又蹲下去），状态机会**卡在中间状态出不来** ——
既不计数也不丢弃，表现为 App 从此再也数不出任何动作。这是线性状态机的经典缺陷，
回退边不是可选的健壮性增强，而是正确性的一部分。

**机位**：侧视（矢状面）——下蹲深度、躯干前倾、脚跟离地都是矢状面量。
膝内扣是额状面量，侧拍下不可判，因此正视机位需要单独跑一遍
（``camera_view="frontal"``），两条流各自出结果。本定义只负责侧视主链路。

**分段阈值全部是个体化 + 工程参数，不含体育阈值**

- 站立基线 ``stand`` 来自该用户自己的校准（体型差异大，绝对角度没有意义）
- ``min_bend_deg`` 是「弯曲多少度才算一次下蹲尝试」的**分段**决策
- 滞回带 ``standing_hysteresis_deg`` 是防抖的**工程**决策

至于「蹲得够不够深」「膝内扣得算不算问题」这类**质量**判断，全部交给规则引擎，
用 ``shared/thresholds/`` 里的体育阈值（目前全部待核定，只会产出提示）。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "SQUAT"
ACTION_NAME_ZH = "深蹲"

STANDING = "STANDING"
DESCENT = "DESCENT"
BOTTOM = "BOTTOM"
ASCENT = "ASCENT"

SQUAT_STATES: tuple[str, ...] = (STANDING, DESCENT, BOTTOM, ASCENT)

#: 相位映射。STANDING 不出现在已封存的 rep 里 —— rep 缓冲从「离开站立态」那一帧
#: 开始，因此站立段天然被排除在外。
_STATE_TO_PHASE: dict[str, Phase] = {
    DESCENT: Phase.DESCENT,
    BOTTOM: Phase.BOTTOM,
    ASCENT: Phase.ASCENT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 这是**工程参数**，不是体育阈值 —— 它不参与「是否判错」的决策（那由阈值表决定），
#: 只把 ``delta`` 压成 0–1 供 UI 排序与展示。取值依据是「超出这个量通常已属明显偏离」，
#: 可按实际观感调整，不需要体育专业成员核定。
_SEVERITY_SPAN: dict[str, float] = {
    "KNEE_VALGUS": 8.0,
    "INSUFFICIENT_DEPTH": 40.0,
    "EXCESSIVE_TRUNK_LEAN": 15.0,
    "HEEL_RISE": 0.15,
    "ASYMMETRY": 0.10,
}

#: 一条规则在底部窗口内至少需要多少帧越界才判命中。
#:
#: 底部窗口通常有 5–15 帧，取 2 是为了滤掉单帧关键点抖动 —— 单帧误判会让
#: 用户看到「被告知了一个他并没有犯的错误」，比漏判更伤害信任。
_MIN_VIOLATING_FRAMES = 2


def _mean_knee(signals: Signals) -> float | None:
    """左右膝角的可用均值。

    侧视机位下双腿在画面上几乎重合，取均值比只看单侧稳健；一侧被遮挡时
    退化为另一侧，而不是整体不可用。
    """
    values = [
        v for v in (signals.get("knee_angle_L"), signals.get("knee_angle_R")) if v is not None
    ]
    return sum(values) / len(values) if values else None


def build_squat(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "sagittal",
) -> ActionDefinition:
    """按本人的站立基线构造深蹲定义。

    分段阈值全部由 ``calibration`` 与 ``config`` 推出，**不查体育阈值表** ——
    分段与判定必须解耦（见 ``base.py`` 模块文档）。

    Args:
        calibration: 该用户的站立基线。
        config: 工程默认值。默认按侧视机位构造。
        camera_view: 机位。侧视跑主链路；正视只用于额状面（膝内扣）评估。
    """
    cfg = config or TrackingConfig(camera_view=camera_view)

    stand = calibration.knee_angle
    hysteresis = cfg.standing_hysteresis_deg
    bend_line = stand - cfg.min_bend_deg

    def left_standing(signals: Signals) -> bool:
        """离开站立：膝角比基线弯曲超过滞回带。"""
        knee = _mean_knee(signals)
        return knee is not None and knee < stand - hysteresis

    def at_bend_line(signals: Signals) -> bool:
        """膝角到达或低于分段线（进入底部区域）。

        同时用于 ``DESCENT→BOTTOM`` 与 ``ASCENT→DESCENT`` —— 两条边的几何条件
        相同，区别只在从哪个状态出发。
        """
        knee = _mean_knee(signals)
        return knee is not None and knee <= bend_line

    def rose_above_bend_line(signals: Signals) -> bool:
        """开始起身：从分段线回升超过滞回带。"""
        knee = _mean_knee(signals)
        return knee is not None and knee > bend_line + hysteresis

    def returned_to_standing(signals: Signals) -> bool:
        """回到站立：膝角回到基线附近。

        同时用于 ``ASCENT→STANDING``（正常完成一次深蹲）与 ``DESCENT→STANDING``
        （假动作）。谓词相同但语义相反：前者封存一次 rep，后者被丢弃。
        之所以不合并，是因为「有没有到过底部」这个事实应当由状态机如实记录，
        而不是靠外部再加一个变量去猜。
        """
        knee = _mean_knee(signals)
        return knee is not None and knee > stand - hysteresis

    # 顺序即优先级（状态机契约）。同一状态的出边两两互斥：
    # DESCENT 的「到分段线」与「回到站立」不可能同时成立，
    # ASCENT 的「回到站立」与「重新下蹲」同理。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (STANDING, DESCENT, left_standing, "standing->descent"),
        (DESCENT, BOTTOM, at_bend_line, "descent->bottom"),
        (DESCENT, STANDING, returned_to_standing, "descent->standing(假动作)"),
        (BOTTOM, ASCENT, rose_above_bend_line, "bottom->ascent"),
        (ASCENT, STANDING, returned_to_standing, "ascent->standing"),
        (ASCENT, DESCENT, at_bend_line, "ascent->descent(回蹲)"),
    )

    rules = (
        # 深度问的是「整次动作的**最低点**够不够深」，不是「有多少帧够深」，
        # 因此用 MIN 归约，而不是越界帧计数。若用计数，底部窗口里下降与回升的
        # 过渡帧（膝角从 135° 扫到 90° 再回到 143°）会全部算作越界，
        # 结果是**每一个动作都被误判为深度不足**。阈值待体育专业核定。
        Rule(
            code="INSUFFICIENT_DEPTH",
            name_zh="下蹲深度不足",
            metric="knee_angle_L",
            threshold_key="squat.min_depth_knee_angle",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["INSUFFICIENT_DEPTH"],
        ),
        # 膝内扣：正视机位才有效；侧拍时该特征判为机位不匹配、规则静默不触发。
        Rule(
            code="KNEE_VALGUS",
            name_zh="膝内扣",
            metric="frontal_knee_angle_max",
            threshold_key="squat.knee_valgus_angle_notice",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["KNEE_VALGUS"],
        ),
        # 躯干前倾：相对本人站立基线的增量。符号取决于人面朝画面哪一侧，
        # 不是体育含义，因此 use_abs。
        Rule(
            code="EXCESSIVE_TRUNK_LEAN",
            name_zh="躯干过度前倾",
            metric="trunk_lean",
            threshold_key="squat.trunk_lean_max_delta",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            use_abs=True,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["EXCESSIVE_TRUNK_LEAN"],
        ),
        # 脚跟离地：同样相对本人站立基线（鞋跟高度、站姿都有个体差异）。
        Rule(
            code="HEEL_RISE",
            name_zh="脚跟离地",
            metric="heel_rise_ratio_L",
            threshold_key="squat.heel_rise_ratio_max_delta",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["HEEL_RISE"],
        ),
        # 左右不对称：只做提示级判断。惯用腿差异、机位不居中都可能造成假阳性，
        # 因此生产环境还应结合组内跨 rep 一致性（见设计文档 §5.2）。
        Rule(
            code="ASYMMETRY",
            name_zh="左右不对称",
            metric="knee_symmetry",
            threshold_key="squat.asymmetry_index_max",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["ASYMMETRY"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=SQUAT_STATES,
        resting_state=STANDING,
        bottom_state=BOTTOM,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # 这两条规则的判据是「相对本人站立基线的增量」，而规则引擎只做
        # 「指标 vs 阈值」的直接比较，因此在查表时把基线加回去。
        threshold_offsets={
            "squat.trunk_lean_max_delta": ("trunk_lean", 1.0),
            "squat.heel_rise_ratio_max_delta": ("heel_rise_ratio", 1.0),
        },
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "ASCENT",
    "BOTTOM",
    "DESCENT",
    "SQUAT_STATES",
    "STANDING",
    "build_squat",
]
