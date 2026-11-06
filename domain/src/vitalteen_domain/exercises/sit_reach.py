"""坐位体前屈动作定义。

与 ``app/lib/domain/exercises/sit_reach.dart`` 一一对应，**数值逐位相同**。

**状态链**::

    SIT_UPRIGHT ──→ REACHING ──→ HOLDING ──→ RETURNING ──→ SIT_UPRIGHT
         ↑              │           │            │
         └──────────────┘           └────────────┘
          （假动作：伸到一半又坐直，    （回退：坐回一半又伸回去，
            从头到尾没伸到底）            否则 HOLDING 会变成走不出去的死角）

形状与仰卧起坐、深蹲**一模一样**（一个中立位、一个极值、两侧各一段行程），
相位映射也逐字复用：``REACHING→DESCENT``、``HOLDING→BOTTOM``、``RETURNING→ASCENT``。

**信号为什么是髋角，而不是「手够到哪儿」**

国标量的是**厘米**（指尖超过脚尖多少）。端侧量不了 —— 单目没有世界坐标、
量不出绝对长度（设计文档附录 A 那条老账）。所以这个动作在端侧**不测成绩**，
只判动作规范性（``exercise_catalog.dart`` 的 ``note`` 里如实写着这一点）。

剩下的量里只有 ``hip_angle_L``（肩—髋—膝那个夹角）同时满足三件事：
坐直时约 90°、前伸到底时降到 40° 上下（行程够大、噪声盖不住）、
而且**没有机位门控**（该特征的 ``views`` 为空，任何机位都有定义）。
前伸的幅度与这个角一一对应，所以拿它切段是稳的。

**机位：为什么非要 45°**

两个特征都没有机位门控，看起来正对镜头也能算 —— **不能**，而且失败是静默的：
正对镜头时「前折」发生在**镜头方向本身**上，肩朝镜头挪过去，画面上髋角
几乎不变。状态机于是永远停在 ``SIT_UPRIGHT``，一次都数不上，
而屏幕上什么错都不报（HUD 一直显示「坐直」，那正好是实情的一半）。
45° 斜前方下这个折角被投影到画面里，读数才跟着动。

**「保持」不是等时间，是等角度**

国标要求前伸到底后**停两秒**。端侧不去数那两秒（数了也只是数时间），
而是**把「伸到底」这一个姿势当成一个状态**：``HOLDING`` 的进入条件是髋角
小到 ``sit_reach_holding_deg``。停多久不影响计数 —— 它只影响这个状态停留
多少帧，而规则看的是**这段里发生了什么**（膝有没有弯、前伸段抖没抖），
不是它持续了几秒。

**阈值分工**

分段线是工程参数（``sit_reach_upright_deg`` / ``sit_reach_holding_deg`` /
``sit_reach_hysteresis_deg``），质量判断全交给规则引擎、用
``shared/thresholds/`` 里的体育阈值（目前全部待核定）。

与深蹲、立定跳远不同，这里的分段线是**绝对角度**而不是相对基线的增量 ——
理由写在 ``TrackingConfig.sit_reach_upright_deg`` 的文档里。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "SRT"
ACTION_NAME_ZH = "坐位体前屈"

SIT_UPRIGHT = "SIT_UPRIGHT"
REACHING = "REACHING"
HOLDING = "HOLDING"
RETURNING = "RETURNING"

#: **四个词与 ``preview_poses.py`` 里那四拍逐字一致、顺序一致** ——
#: ``exercise_preview_test.dart`` 里有一条断言把这件事变成可执行的。
SRT_STATES: tuple[str, ...] = (SIT_UPRIGHT, REACHING, HOLDING, RETURNING)

#: 相位映射。
#:
#: ``SIT_UPRIGHT`` 不出现在已封存的 rep 里（缓冲从离开它开始），
#: 同深蹲的 ``STANDING``、仰卧起坐的 ``SEATED``。
_STATE_TO_PHASE: dict[str, Phase] = {
    REACHING: Phase.DESCENT,
    HOLDING: Phase.BOTTOM,
    RETURNING: Phase.ASCENT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供界面排序。
_SEVERITY_SPAN: dict[str, float] = {
    "SRT_KNEE_BENT": 30.0,
    "SRT_BALLISTIC": 4.0,
}


def build_srt(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "oblique45",
) -> ActionDefinition:
    """按工程默认值构建坐位体前屈定义。

    Args:
        calibration: 该用户的基线。**两条判定一条都不用它** ——
            膝角与髋角都是关节夹角，与本人身材无关。它仍然要采：
            那是 ``Calibrator`` 的门槛，也是「开始之前先坐好」这一步的产物，
            与其余动作共用同一套流程。
        config: 工程默认值。
        camera_view: 机位。45° 主链路，理由见模块文档。
    """
    # 20 秒（≈600 帧）：前伸、保持、坐回三段加起来比一次深蹲长得多，
    # 而国标那个「保持两秒」本来就慢。上限留够，但**不能不设** ——
    # 卡住时每一帧 HUD 都顶着错误的状态词（同立定跳远那条理由）。
    cfg = config or TrackingConfig(camera_view=camera_view, max_rep_frames=600)

    upright_line = cfg.sit_reach_upright_deg
    holding_line = cfg.sit_reach_holding_deg
    hysteresis = cfg.sit_reach_hysteresis_deg

    # 顺序不变式：保持线必须**明显低于**坐直线，中间要留得下两条滞回带，
    # 否则一次动作里 SIT_UPRIGHT 与 HOLDING 之间的行程是负的 ——
    # 状态机在两者之间逐帧来回跳，每一次都封存一次 rep。
    # （髋角是**越小越前折**，所以这里的比较方向与仰卧起坐那条正好相反。）
    if not holding_line + hysteresis < upright_line - hysteresis:
        raise ValueError(
            f"坐位体前屈的分段线顺序非法，必须 sit_reach_holding_deg + "
            f"sit_reach_hysteresis(={holding_line + hysteresis}) < "
            f"sit_reach_upright_deg − sit_reach_hysteresis"
            f"(={upright_line - hysteresis})。常见成因：把保持线抬得太高，"
            f"或把坐直线压得太低。"
        )

    def hip_angle(signals: Signals) -> float | None:
        """这一帧的髋角。

        **取不到就返回 ``None``，不能拿 0 顶替** —— 0 在量纲上正是
        「折到极限」，用它会凭空造出一次「已经前伸到底」的结论。
        """
        return signals.get("hip_angle_L")

    def started_reaching(signals: Signals) -> bool:
        """开始前伸（离开坐直）。"""
        value = hip_angle(signals)
        return value is not None and value < upright_line - hysteresis

    def reached_bottom(signals: Signals) -> bool:
        """伸到底了。"""
        value = hip_angle(signals)
        return value is not None and value <= holding_line

    def started_returning(signals: Signals) -> bool:
        """开始坐回（离开前伸到底）。"""
        value = hip_angle(signals)
        return value is not None and value > holding_line + hysteresis

    def sat_upright(signals: Signals) -> bool:
        """坐直了。

        同时用于 ``RETURNING→SIT_UPRIGHT``（正常完成一次）与
        ``REACHING→SIT_UPRIGHT``（假动作）—— **有没有伸到底**这个事实由
        状态机如实记录（bottom_state），不靠外部再加一个变量去猜。
        """
        value = hip_angle(signals)
        return value is not None and value >= upright_line

    def reached_again(signals: Signals) -> bool:
        """坐回到一半又伸回去。"""
        value = hip_angle(signals)
        return value is not None and value <= holding_line

    # 顺序即优先级（状态机契约）。同一状态的出边两两互斥。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (SIT_UPRIGHT, REACHING, started_reaching, "upright->reaching"),
        (REACHING, HOLDING, reached_bottom, "reaching->holding"),
        (REACHING, SIT_UPRIGHT, sat_upright, "reaching->upright(假动作)"),
        (HOLDING, RETURNING, started_returning, "holding->returning"),
        (RETURNING, SIT_UPRIGHT, sat_upright, "returning->upright"),
        (RETURNING, HOLDING, reached_again, "returning->holding(回退)"),
    )

    rules = (
        # 屈膝：腿伸直是这个动作的前提（膝盖一弯，上身就"够"得更远，
        # 而那正是成绩要排除的作弊姿势）。
        #
        # **窗口取 Phase.BOTTOM（= HOLDING 那一段）**：屈膝是在前伸到底那一
        # 瞬间才说明问题的 —— 前伸途中膝盖松一下没人管得着。
        #
        # Reduce.MIN + Direction.BELOW：取这一段里膝角的**最小值**，
        # 最小值都还在阈值之下，才叫「这一次膝没直过」。取错了方向
        #（比如用 MAX）的话，这一条会对每一个标准动作命中 —— 而膝角在 45°
        # 下的正常读数是 170° 上下，与屈膝的 140° 差了 30°，方向反了就是天壤
        # 之别。
        Rule(
            code="SRT_KNEE_BENT",
            name_zh="屈膝",
            metric="knee_angle_L",
            threshold_key="srt.knee_angle_min",
            bad_side=Direction.BELOW,
            phase=Phase.BOTTOM,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["SRT_KNEE_BENT"],
        ),
        # 弹振借力：靠来回弹把上身甩出去，用冲量够距离。
        #
        # **窗口必须是 Phase.ALL（整次动作），不能只看 Phase.BOTTOM。**
        # 弹振发生在**前伸的过程**里：抖到够远了就停住，保持段可以一点也
        # 不抖。只看 Phase.BOTTOM 会漏掉绝大多数弹振的人 —— 而那正是这条判定
        # 唯一要抓的姿势。
        #
        # 归约用 Reduce.REVERSALS（窗口内序列掉头的次数），语义与那条
        # 「靠弹振够距离的人前伸到底的角度可能是够的」的推理绑在一起，
        # 见 ``rules.py`` 里 ``Reduce.REVERSALS`` 的文档。
        Rule(
            code="SRT_BALLISTIC",
            name_zh="弹振借力",
            metric="hip_angle_L",
            threshold_key="srt.ballistic_reversals_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.REVERSALS,
            severity_span=_SEVERITY_SPAN["SRT_BALLISTIC"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=SRT_STATES,
        # 坐直：起始姿势，也是计数点。同仰卧起坐的 SEATED —— resting_state
        # 不出现在已封存的 rep 里，所以它必须是**动作开始与结束都停在那儿**
        # 的那个状态。
        resting_state=SIT_UPRIGHT,
        # HOLDING：没伸到底的那一次**不算一次**。取 REACHING 的话，一次刚弯下
        # 腰就坐直的动作也会被计成一次，而报告只会说「屈膝」—— 用户被告知了
        # 一个他没做过的动作有问题。同俯卧撑的 BOTTOM。
        bottom_state=HOLDING,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **刻意留空。** 两条判定的阈值都是绝对的：膝角与髋角都是关节夹角，
        # 与本人的体型无关（同 jj.py / pu.py / situp.py 的理由）。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "HOLDING",
    "REACHING",
    "RETURNING",
    "SIT_UPRIGHT",
    "SRT_STATES",
    "build_srt",
]
