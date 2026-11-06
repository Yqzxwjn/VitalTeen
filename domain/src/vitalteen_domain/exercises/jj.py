"""开合跳动作定义。

与 ``app/lib/domain/exercises/jj.dart`` 一一对应，**数值逐位相同**。

**状态链：四态一循环**::

    CLOSED ──→ OPENING ──→ OPEN ──→ CLOSING ──→ CLOSED
       ↑           │          ↑         │
       └───────────┘          └─────────┘

两条回退边与立定跳远的「回蹲」同源：守卫是纯函数、**看不见时间**，没有它们的话
「腿开到一半又合上」会停在 OPENING 直到 ``max_rep_frames``，「落地后弹一下又开」
会停在 CLOSING —— 两种都是走不出去的死角，既不计数也不丢弃，只是每一帧都在 HUD 上
显示一个错的状态词。

计数确认点是**回到 CLOSED**（设计文档 §4.3）：一次开合跳以「双脚回到并腿站立」
为结束，而不是以「开到最大」为止。

**机位只能是正面，而这不是可选项**

卡片、设计文档 §4.3 与两个判据用的特征都指向正面：``leg_spread_ratio`` 与
``frontal_knee_angle_max`` 都声明 ``views: [frontal]``，45° 下它们判为机位不匹配、
**直接不可用** —— 两条判定会静默消失。所以本模块的 ``camera_view`` 默认值就是
``frontal``。

代价是标定：正面机位下 ``heel_rise_ratio_L`` 声明的是
``views: [sagittal, oblique45]``，恒不可用，于是基线集必须是
``{膝角, 躯干倾角, 分腿比}``（见 ``ActionSpec.calibrationBaselines``）。

**三条判定，全部用绝对阈值**

与深蹲那一套（深度、躯干前倾、脚跟离地全部相对本人站立基线）相反，理由是量纲本身
就不同：那三个是**度**与**比值**，个体差异大（腿长、踝背屈活动度、站姿），必须
个体化；而 ``leg_spread_ratio`` 已经用肩宽归一过（体型在算式里约掉了）、
``shoulder_angle_min`` 与 ``frontal_knee_angle_max`` 都是夹角（肢长同样约掉了）。
再乘一个本人基线只会引入噪声。

**尤其不能给 ``leg_spread_ratio`` 挂基线偏移** —— 并腿站立时两踝的横向间距本来就
接近 0，所以「基线 × k」也接近 0，而 ``Direction.BELOW`` 判的是「峰值 < 阈值」：
阈值恒接近 0 而峰值恒大于 0，这条规则于是**永远不触发**。谁哪天为了让判定
「更个体化」把它改回去，``test_jj.py`` 里那两条断言会红。

**分段用相对线、质量用绝对线**

四条分段线**全部相对本人站立基线**（``calibration.leg_spread``），这一点让
「标定时该站成什么样」这个问题消失：自然站立（多数人双脚约与髋同宽，比值大致
0.5–0.8，不是 0）与并腿站立都可以，线跟着本人的站姿走，「比你自己站的时候多开
``spread_full_delta``」是同一个意思。而判定那三条用的是绝对阈值，因此也不受站姿
口径影响 —— 两处都不需要在标定文案上做约定，也就不会出现「两个用户因为站姿习惯
不同拿到不同判定线」这种没人看得出的事。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "JJ"
ACTION_NAME_ZH = "开合跳"

CLOSED = "CLOSED"
OPENING = "OPENING"
OPEN = "OPEN"
CLOSING = "CLOSING"

JJ_STATES: tuple[str, ...] = (CLOSED, OPENING, OPEN, CLOSING)

#: 相位映射。**只映射一个状态，这是刻意的。**
#:
#: ``CLOSING``（落地合拢）是唯一需要独立相位的区间：``JJ_KNEE_VALGUS`` 判的是
#: **触地那一刻**之后的膝内扣，把窗口切到这一段才拿得到「落地时膝朝哪边」。
#:
#: ``OPENING`` 与 ``OPEN`` 不映射，理由不是省事：``_phase_bounds`` 会**跳过没有
#: 映射的状态**，而两条「幅度不足」类规则跑在 ``Phase.ALL`` 上 —— 它们问的是
#: 「整次动作的峰值」，峰值本来就发生在开得最大的那一刻，切窗口只带来失明
#: （详见下面那两条规则的注释），不带来精度。少映射两个状态，就少两处
#: 「以为它在起作用」的地方。
_STATE_TO_PHASE: dict[str, Phase] = {
    CLOSING: Phase.CONTACT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策（那由阈值表决定），只把 ``delta`` 压成
#: 0–1 供界面排序与展示，可按实际观感调整，不需要体育专业成员核定。
_SEVERITY_SPAN: dict[str, float] = {
    "JJ_INSUFFICIENT_SPREAD": 0.5,
    "JJ_INSUFFICIENT_ARM": 30.0,
    "JJ_KNEE_VALGUS": 10.0,
}


def build_jj(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "frontal",
) -> ActionDefinition:
    """按本人的站立基线构建开合跳定义。

    Args:
        calibration: 该用户的站立基线，**必须含 ``leg_spread``**
            （正面机位的基线集里它就是分腿幅度的零点）。
        config: 工程默认值。默认按正面机位构造。
        camera_view: 机位。默认正面，理由见模块文档。

    Raises:
        ValueError: 校准结果里没有 ``leg_spread``。**缺席即抛，不取 0** ——
            一个编造的基线会让下面四条分段线全部落在错误的位置上，而它不报错，
            只会让每一次计数都判歪。
    """
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=90,
    )

    stand = calibration.leg_spread
    if stand is None:
        # 与 Dart 侧 ``BaselineKey.legSpread.of`` 同一句话术：抛出来的理由
        # 只有一处，标定那一侧说的是同一句。
        raise ValueError("这个动作没有采集分腿幅度基线")
    hysteresis = cfg.spread_hysteresis

    # 三条线，全部落在 ``leg_spread_ratio`` 一根轴上，**相对本人站立基线**。
    #
    #   stand_line  合回来了   —— 两条落到 CLOSED 的边都用它（回退与封存）
    #   open_line   开起来了   —— CLOSED→OPENING 的进入线
    #   full_line   开到位了   —— OPENING→OPEN 与 CLOSING→OPEN（回弹）
    #
    # 「落到 CLOSED 只有一条线」是刻意的：CLOSED 的含义是「双脚回到了本人站立时
    # 的样子」，那么无论从哪条路回来，判据都该是同一个。
    stand_line = stand + hysteresis
    open_line = stand + cfg.spread_enter_delta
    full_line = stand + cfg.spread_full_delta

    # 顺序不变式。这几个值全是可调的工程参数，谁把它们调乱，应当**当场炸**，
    # 而不是让状态机悄悄少一条边（或者多一条一进新状态就立刻触发的边）——
    # 那种故障的表现是「计数偶尔不对」，离病因非常远。
    #
    # ``stand < stand_line < open_line < full_line`` 同时保证了另外两件事：
    # 进入 CLOSING（< open_line）到它自己成立（< stand_line）之间隔着
    # ``spread_enter_delta − spread_hysteresis``，CLOSING 不会一闪而过；
    # 而从 OPEN 回落到 CLOSING 之后，要再回到 OPEN 必须重新超过 full_line。
    if not (stand_line < open_line < full_line):
        raise ValueError(
            f"开合跳的分段线顺序非法，必须 stand_line(={stand_line}) < "
            f"open_line(={open_line}) < full_line(={full_line})。常见成因："
            "spread_hysteresis 大于等于 spread_enter_delta（没有起步空间，"
            "CLOSED 与 OPENING 会逐帧来回跳），或 spread_full_delta 太小"
            "（开到位线与起步线贴住，OPEN 一闪而过）。"
        )

    def opened_enough(signals: Signals) -> bool:
        """开起来了。也是离开 CLOSED 的唯一一条边。"""
        value = signals.get("leg_spread_ratio")
        return value is not None and value > open_line

    def fully_open(signals: Signals) -> bool:
        """开到位了。**同时是两个「回弹」边的守卫。**

        开合跳的正规技术会在最高点短暂停留，滞回带之外的小回落不该把它踢出 OPEN。
        """
        value = signals.get("leg_spread_ratio")
        return value is not None and value > full_line

    def closing(signals: Signals) -> bool:
        """开始合了。

        取 ``open_line`` 而不是另设一条线：从 OPEN 往回落到「开起来了」那条线
        以下，就是开始收。
        """
        value = signals.get("leg_spread_ratio")
        return value is not None and value < open_line

    def back_together(signals: Signals) -> bool:
        """合回来了。两条落到 CLOSED 的边共用它。"""
        value = signals.get("leg_spread_ratio")
        return value is not None and value < stand_line

    # 顺序即优先级（状态机契约）。**每个状态的出边两两互斥**，逐条核对过
    # （线间距就是它们的间隔）：CLOSED 只有一条出边；OPENING 的 back_together 与
    # fully_open 之间隔着 ``spread_full_delta − spread_hysteresis``；OPEN 的
    # closing 与「进入 OPEN 的 fully_open」隔着
    # ``spread_full_delta − spread_enter_delta``；CLOSING 的 back_together 与
    # fully_open 之间隔着整条 ``spread_full_delta − spread_enter_delta`` 再加回程。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (CLOSED, OPENING, opened_enough, "closed->opening（起跳）"),
        (OPENING, CLOSED, back_together, "opening->closed（开一半又合上）"),
        (OPENING, OPEN, fully_open, "opening->open（展开）"),
        (OPEN, CLOSING, closing, "open->closing（合拢）"),
        (CLOSING, OPEN, fully_open, "closing->open（回弹）"),
        (CLOSING, CLOSED, back_together, "closing->closed（封存）"),
    )

    rules = (
        # 分腿幅度不足。问的是「整次动作分得**最开的那一刻**够不够开」，不是
        # 「有多少帧开得够开」，因此取 MAX 再与下界比 —— 用帧计数会把一次标准的
        # 开合跳判成犯规（同 squat.py 为深度规则写下的那条理由）。
        #
        # ``Phase.ALL`` 而不是切到顶点那一段，理由是反的：把窗口切到一个只在
        # 「已经开到位」时才存在的状态上，恰好会让这条规则**在最需要它的人身上
        # 失明** —— 而峰值在整段窗口上取 MAX 与在顶点段取 MAX 是同一个数。
        Rule(
            code="JJ_INSUFFICIENT_SPREAD",
            name_zh="分腿幅度不足",
            metric="leg_spread_ratio",
            threshold_key="jj.spread_min_ratio",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["JJ_INSUFFICIENT_SPREAD"],
        ),
        # 手臂上举幅度不足。同上：问的是「举得**最高**那次够不够高」。
        #
        # 指标取左右两个肩角里**小**的那一个（``shoulder_angle_min``），
        # 因为这条规则问的是「两只手臂**都**举到位了吗」，落后那一只才是判据。
        # 一侧看不清时**不**退化成另一侧 —— 那是分段信号的做法
        # （见 slj.py 的 ``_mean_knee``），而手臂举不够是**规则要判的事**，
        # 不能因为一侧遮挡就放过。
        Rule(
            code="JJ_INSUFFICIENT_ARM",
            name_zh="手臂上举幅度不足",
            metric="shoulder_angle_min",
            threshold_key="jj.arm_min_angle",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["JJ_INSUFFICIENT_ARM"],
        ),
        # 落地膝内扣。窗口是 CLOSING（触地之后的合拢段），取窗口内**最大**的
        # 额状面膝角 —— 方向是 ABOVE，因为 ``frontal_knee_angle_*`` 的约定是
        # 「直腿 = 0°，内扣越大角越大」，**与 ``knee_angle_*`` 正好相反**。
        #
        # 这条容易被误改成 BELOW（看上去「腿越直越坏」的直觉是反的），而改错的
        # 表现在真机上只表现为「这条判定老是误报」，看不出病因 —— 所以
        # test_jj.py 里用合成帧把方向钉死了（合规组不命中、内扣组命中）。
        #
        # **它是本轮唯一一条真正跑得起来的正面判定。** 深蹲那条同名的规则
        # （squat.py 的 ``KNEE_VALGUS``）在产品里一帧都没执行过：它用的
        # ``frontal_knee_angle_max`` 声明 ``[frontal]``，而深蹲跑的是 45°。
        # 下一个人多半会以为它在工作。
        #
        # 措辞与切点按设计文档 §5.2 的保留办：2D 视频对下肢额状面运动的效度
        # 有争议、最小可检测差异约 8°，所以这条只出**提示级**结论。
        Rule(
            code="JJ_KNEE_VALGUS",
            name_zh="落地膝内扣",
            metric="frontal_knee_angle_max",
            threshold_key="jj.knee_valgus_angle_notice",
            bad_side=Direction.ABOVE,
            phase=Phase.CONTACT,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["JJ_KNEE_VALGUS"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=JJ_STATES,
        resting_state=CLOSED,
        # OPEN 而不是 OPENING：只开到一半的跳**不算一次** ——「开合」这个动作的
        # 判定对象是「开」到没到位，而没开到位的那些由 ``discarded_reps`` 解释
        # （见 ``ActionSpec.discardedReason``）。取 OPENING 的话，一次几乎没动腿的
        # 抖动也会被计成一次，而规则只会说「分腿幅度不足」——
        # 用户被告知了一个他并没有做的动作有问题。
        bottom_state=OPEN,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **只登记一条，而且它换来的不是「救回这次」，是「判它不算」。**
        #
        # 人在合拢时出画（手臂与双腿同时向内收，边界上最先丢的常是腿），回来时
        # 已经站定：状态机跳回 CLOSED 之后不会有任何转移成立，这一段就一直挂着，
        # 直到 ``max_rep_frames`` 把它按丢弃结账。
        #
        # 这与立定跳远那条 ``LAUNCH → FLIGHT`` 的取舍同源、方向相反：那边是
        # 「承认人已经在空中」，这边是「**拒绝**给一次落地没被完整看见的动作打分」。
        # 不登记的话（让 CLOSING 自己走到 CLOSED）那一次会被计数，而
        # ``Phase.CONTACT`` 的区间会横跨丢失前后 —— 回来那几帧站立姿态也被算进
        # 「落地膝内角」里。更坏的是一种更隐蔽的走法：``RepWindow.select`` 在相位
        # **缺失**时退化成整段，于是规则会去评整次动作的膝角，而它自己不知道
        # 自己在评什么。
        #
        # 代价如实记账：少计一次，界面上说「有 1 次没计入（幅度不够或太快）」。
        loss_recovery={CLOSING: CLOSED},
        # **刻意留空。** 三条判定的阈值都是绝对的，没有一条相对本人基线 ——
        # 理由见模块文档，尤其不要给 ``jj.spread_min_ratio`` 挂
        # ``("leg_spread", k)``：那会让这条规则永远不触发，而且不报错。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "CLOSED",
    "CLOSING",
    "JJ_STATES",
    "OPEN",
    "OPENING",
    "build_jj",
]
