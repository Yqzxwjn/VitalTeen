"""俯卧撑动作定义。

与 ``app/lib/domain/exercises/pu.dart`` 一一对应，**数值逐位相同**。

**状态链（设计文档 §4.3，另补两条回退边）**::

    TOP ──→ DOWN ──→ BOTTOM ──→ UP ──→ TOP
     ↑       │                     │
     └───────┘                     └──→ DOWN
      （假动作：撑一下又直起来，       （回压：撑到一半又沉下去，
        从未到过底部）                 否则 UP 会变成走不出去的死角）

形状与深蹲一字不差，两条回退边的理由也相同（见 ``squat.py`` 的模块文档）。
不同的只是判据从膝角换成了肘角。

**机位：侧视（矢状面）** —— 肘角与体线都是矢状面量，主链路 45° 机位下同样成立。

**有一条卡片上写着、但这个机位下量不出来的**：``PU_ELBOW_FLARE``（肘部过度外展）。
「外展」是上臂相对躯干在**额状面**内张开的角度，而矢状/45° 画面上「手臂往前往后」
与「手臂往两侧张」都会让投影出来的肩角变小，两者**在数值上同形**。要判它得用正面
机位。所以本轮不实现这个码，卡片上的措辞也一并收掉（``exercise_catalog.dart``）——
卡片说得比规则能做到的满，是上线之后最容易被用户抓住的那种不一致。

**两条「门槛」与两条「质量」是刻意分开的**

``pushup_depth_deg`` 只决定「这一下算不算一次」（下不到 100° 的那次走
``discarded_reps``），而 ``pu.min_depth_elbow_angle``（90°）管的是「算数的那些里，
下得够不够低」。顶部那两条同理（165° 对 170°）。把两者合成一条会让「没做到位」与
「姿势不合格」分不开 —— 前者该说「这一次没算」，后者该说「这一次算了，但可以更好」。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "PU"
ACTION_NAME_ZH = "俯卧撑"

TOP = "TOP"
DOWN = "DOWN"
BOTTOM = "BOTTOM"
UP = "UP"

PU_STATES: tuple[str, ...] = (TOP, DOWN, BOTTOM, UP)

#: 相位映射。
#:
#: ``TOP`` 不出现在已封存的 rep 里 —— rep 缓冲从「离开顶部」那一帧开始，
#: 因此顶部段天然被排除在外（同 ``squat.py`` 对 ``STANDING`` 的处理）。
#:
#: 四个状态的相位是给 rep 记录与 HUD 用的；四条规则全部跑在 ``Phase.ALL`` 上
#: （见每条规则的注释），所以切窗口不参与任何判定。
_STATE_TO_PHASE: dict[str, Phase] = {
    DOWN: Phase.DESCENT,
    BOTTOM: Phase.BOTTOM,
    UP: Phase.ASCENT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供界面排序。
_SEVERITY_SPAN: dict[str, float] = {
    "PU_INSUFFICIENT_DEPTH": 40.0,
    "PU_INCOMPLETE_EXTENSION": 15.0,
    "PU_HIP_SAG": 0.15,
    "PU_HIP_PIKE": 0.15,
}


def _mean_elbow(signals: Signals) -> float | None:
    """两侧肘角的可用均值。

    45° 机位下远侧手臂常被躯干或近侧手臂挡住，取均值比只看单侧稳健；
    一侧被遮挡时退化为另一侧，而不是整体不可用。

    **这只用在分段守卫上。** 规则用的是 ``elbow_angle_L`` 这个特征本身 ——
    分段看的是「这个人现在在做什么」，能看清一侧就够；规则判的是
    「他做得够不够好」，而那是两回事。
    """
    values = [
        v
        for v in (signals.get("elbow_angle_L"), signals.get("elbow_angle_R"))
        if v is not None
    ]
    if not values:
        return None
    return sum(values) / len(values)


def build_pu(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "sagittal",
) -> ActionDefinition:
    """按工程默认值构建俯卧撑定义。

    Args:
        calibration: 该用户的站立基线。**俯卧撑的四条判定一条都不用它**
            （肘角与体线偏移都是绝对量），但它仍然要采 —— 那是 ``Calibrator``
            的门槛，也是「开始之前先站好」这一步的产物，与深蹲/立定跳远共用
            同一套流程。
        config: 工程默认值。
        camera_view: 机位。侧视是主链路。
    """
    # 150 帧（≈5 秒）：一次有控制的俯卧撑大约 2–4 秒，留出余量。
    # 取深蹲的 300 太长（卡住时 HUD 会顶着错误的状态词显示 10 秒），
    # 取立定跳远的 120 又对慢速离心有点紧。
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=150,
    )

    top_line = cfg.pushup_top_deg
    depth_line = cfg.pushup_depth_deg
    hysteresis = cfg.standing_hysteresis_deg

    # 顺序不变式：下到底的那条线必须在撑起来那条线**之下**，否则两条线之间的
    # 那一段就成了「既算到底又算撑起」，状态机在 DOWN 与 TOP 之间逐帧来回跳。
    if not depth_line < top_line:
        raise ValueError(
            f"俯卧撑的分段线顺序非法，必须 pushup_depth_deg(={depth_line}) < "
            f"pushup_top_deg(={top_line})。常见成因：把两条线的含义写反了。"
        )

    def left_top(signals: Signals) -> bool:
        """离开顶部：肘角弯到进入线以下。"""
        value = _mean_elbow(signals)
        return value is not None and value < top_line

    def at_depth_line(signals: Signals) -> bool:
        """肘角到达分段线（进入最低点区域）。

        同时用于 ``DOWN→BOTTOM`` 与 ``UP→DOWN`` —— 两条边的几何条件相同，
        区别只在从哪个状态出发。
        """
        value = _mean_elbow(signals)
        return value is not None and value <= depth_line

    def rose_above_depth_line(signals: Signals) -> bool:
        """开始撑起：从分段线回升超过滞回带。"""
        value = _mean_elbow(signals)
        return value is not None and value > depth_line + hysteresis

    def returned_to_top(signals: Signals) -> bool:
        """回到顶部：肘角回到进入线以上。

        同时用于 ``UP→TOP``（正常完成一次）与 ``DOWN→TOP``（假动作）。
        谓词相同而语义相反，理由同 ``squat.py``：**有没有到过底部**这个事实
        该由状态机如实记录，而不是靠外部再加一个变量去猜。
        """
        value = _mean_elbow(signals)
        return value is not None and value > top_line

    # 顺序即优先级（状态机契约）。同一状态的出边两两互斥。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (TOP, DOWN, left_top, "top->down"),
        (DOWN, BOTTOM, at_depth_line, "down->bottom"),
        (DOWN, TOP, returned_to_top, "down->top(假动作)"),
        (BOTTOM, UP, rose_above_depth_line, "bottom->up"),
        (UP, TOP, returned_to_top, "up->top"),
        (UP, DOWN, at_depth_line, "up->down(回压)"),
    )

    rules = (
        # 深度：问的是「整次动作里肘弯得**最深的那一刻**够不够深」，不是
        # 「有多少帧够深」—— 用帧计数会把每一次俯卧撑都判成深度不足
        # （下降与撑起的过渡帧全在线上），同 squat.py 为深度规则写下的理由。
        #
        # 指标取左肘，与深蹲的深度规则取左膝是同一个取舍：两臂在侧视画面上
        # 几乎重合，用单侧就够。代价是一侧被挡住时该帧不可用、规则引擎按
        # 「不可用」处理 —— 这是显式接受的。
        Rule(
            code="PU_INSUFFICIENT_DEPTH",
            name_zh="俯卧撑深度不足",
            metric="elbow_angle_L",
            threshold_key="pu.min_depth_elbow_angle",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["PU_INSUFFICIENT_DEPTH"],
        ),
        # 顶部未伸直：问的是「撑得**最直的那一刻**够不够直」。
        #
        # 与深度那条**共用同一个指标、方向相反**，两条一起看才是完整的一次：
        # 深度管肘角的最小值、伸直管最大值。这也说明为什么它们不能用同一条
        # 规则「偏离 180 多少」来表达 —— 那样「下得不够深」与「撑得不够直」
        # 会在数值上同形，而这正是 ``body_line_offset_ratio`` 要解决的那类问题。
        #
        # 与计数门槛的关系（对照开合跳的分腿幅度）：``pushup_top_deg``=165° 是
        # 「这一下算不算一次」的线，而这里这条是**质量**线（170°）。撑到
        # 165–170 之间的人**被计数了**，然后被这条规则指出「还没完全伸直」；
        # 撑不到 165 的那些根本不被计数，走 ``discarded_reps``。两条都有活干。
        Rule(
            code="PU_INCOMPLETE_EXTENSION",
            name_zh="顶部手臂未伸直",
            metric="elbow_angle_L",
            threshold_key="pu.top_extension_elbow_angle",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["PU_INCOMPLETE_EXTENSION"],
        ),
        # 塌腰：髋比「肩—踝」连线低。取整次动作里**最低**的那一刻
        # （``Reduce.MAX`` 作用在有向偏离上，正方向就是「更低」），
        # 因为塌腰通常发生在最吃力的时候。
        #
        # 与撅臀那条**共用同一个指标、方向相反**：现成的 ``body_line_angle``
        # 是 ``angle3`` 的夹角，值域 [0°, 180°]，塌腰与撅臀都只是让它变小 ——
        # 同形，分不出是哪一种，而两者该说的话正好相反。所以这里用的是
        # 带符号的 ``body_line_offset_ratio``。
        Rule(
            code="PU_HIP_SAG",
            name_zh="塌腰",
            metric="body_line_offset_ratio",
            threshold_key="pu.hip_sag_ratio_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["PU_HIP_SAG"],
        ),
        # 撅臀：髋比连线高。阈值是**负数**（``pu.hip_pike_ratio_min``），
        # 方向是 ``BELOW`` —— 越负越坏。写成这样而不是「取绝对值再判」，
        # 是为了让「倾向哪一边」这件事在阈值表里看得见。
        Rule(
            code="PU_HIP_PIKE",
            name_zh="撅臀",
            metric="body_line_offset_ratio",
            threshold_key="pu.hip_pike_ratio_min",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["PU_HIP_PIKE"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=PU_STATES,
        resting_state=TOP,
        # BOTTOM 而不是 DOWN：下不到底的那一次**不算一次** ——「俯卧撑」这个动作
        # 的判定对象就是「下到底再撑起来」，没下到底的那些由 ``discarded_reps``
        # 解释。取 DOWN 的话，一次几乎没动胳膊的抖动也会被计成一次，
        # 而规则只会说「深度不足」—— 用户被告知了一个他并没有做的动作有问题。
        bottom_state=BOTTOM,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **刻意留空。** 四条判定的阈值都是绝对的：肘角是关节夹角、体线偏移
        # 已用躯干长归一，两者都与本人的体型无关（同 jj.py 的理由）。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "BOTTOM",
    "DOWN",
    "PU_STATES",
    "TOP",
    "UP",
    "build_pu",
]
