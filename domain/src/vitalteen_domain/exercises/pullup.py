"""引体向上动作定义。

与 ``app/lib/domain/exercises/pullup.dart`` 一一对应，**数值逐位相同**。

**状态链（形状与俯卧撑一字不差，只是方向反过来）**::

    HANG ──→ PULLING ──→ TOP ──→ LOWERING ──→ HANG
     ↑         │                    │
     └─────────┘                    └──→ PULLING
      （假动作：拉一下又松手落回，      （回拉：放到一半又拉上去，
        从未到过顶部）                  否则 LOWERING 会变成走不出去的死角）

``resting_state = HANG``（直臂悬垂）、``bottom_state = TOP``（拉到顶）。
回到 ``HANG`` 就封存一次。

**``TOP`` 是 ``bottom_state`` 而它在字面上是「顶」**，这不矛盾：
``bottom_state`` 在这个引擎里的含义是「最远的那个极端状态」—— 有没有真正到达过它，
是「这一次算不算数」的判据。俯卧撑的极端是趴得最低，引体向上的极端是拉得最高。

**分段信号：肘角**（``elbow_angle_L/R`` 的可用均值）。直臂悬垂时接近伸直
（165° 以上），拉到顶时弯到 90° 以下。**单调**，可以直接当分段信号。

**计数门槛为什么不用「下颌过杠」**

国标认的是下颌过杠，而本项目量得到它（见 ``PULLUP_CHIN_NOT_OVER``）。但它不做计数
门槛，这是刻意的：下颌过杠要读**嘴点**，而嘴是 33 个关键点里可见性最低的几个之一，
拉上去的时候上臂还可能正好遮住脸。拿它当门槛的话，脸被挡住时状态机永远进不了
``TOP`` —— **整组一次都数不上，而屏幕上什么错都不报**。门槛用肘角（稳健）、
下颌过杠交给规则层去判（脆弱但只影响一次提示）：**少判一次是提示，少计一次是丢数据。**

**三条规则**

===============  ==================  =========================  ================
错误码            判什么               特征                        归约
===============  ==================  =========================  ================
``PULLUP_NOT_DEAD_HANG``    未回到直臂悬垂  ``elbow_angle_L``          整段最大值
``PULLUP_CHIN_NOT_OVER``    下颌未过杠      ``mouth_wrist_dy``         顶点段最小值
``PULLUP_SWING``            身体摆动借力    ``trunk_lean``             整段最大绝对值
===============  ==================  =========================  ================

**下颌过杠那条为什么切在顶点段（``Phase.APEX``）**

不切窗口（跑在 ``Phase.ALL`` 上）时，``Reduce.MIN`` 也会取到同一帧的值 —— 拉的
过程中嘴相对手是单调上升的，最小值本来就出现在最高那一帧。**但两条路径在「读不到」
时的行为相反**：跑在整段上时，只要嘴在**组里任何一帧**看得见（比如悬垂时），
最小值就会取到那个悬垂读数 —— 于是「脸被上臂挡住、其实拉得很到位」的人会被判成
「没拉上去」。切到顶点段之后，那一段读不到就是读不到，规则**不触发**。
这是一条静默误判的边界，所以它写在这里而不是留给下一个人去发现。

**但这份遮挡容错是部分的，不是完全的 —— 这一点必须如实写下来。**
``Phase.APEX`` 那个窗口的**尾巴上有几帧其实是下放**：状态机的换相要经过驻留与
投票（``min_dwell_frames`` / 投票窗口），确认滞后于特征值的变化，所以
``_phase_bounds`` 记下的跨度末尾落在了已经开始的下一段上。后果是：只有当嘴从
顶点段起**一路遮到下放段也读不到**时，这条规则才真的退回「不知道」；只遮顶点段的话，
那几帧尾部的下放读数照样会被 ``Reduce.MIN`` 取到。

所以准确的说法是：切窗口让这条规则**永不比整段宽松，且在一部分遮挡下更严格**
（严格的方向是「少报」），而不是「挡到脸就一定不报」。两个动作测试里为此各有一对
断言：遮挡后不触发、以及**同一批帧把窗口换回整段就必须触发** —— 后半条是决定性的
对照，它证明那份「不报」真的来自窗口。

**它测不出什么**

- ``PULLUP_REST_TIMEOUT``（组内停顿超时）**不做**：国标 1 分钟引体向上里
  「悬垂休息不得超过若干秒」是一个**跨次**的规则，而本项目的规则引擎对每一次动作
  独立求值（窗口只有一次拉起的几十帧），没有「上一次落地到现在过了多久」这个输入。
- 腿的摆动、膝的弯曲不判：单目画面里「腿往前踢」与「腿往后摆」在 45° 机位下的
  投影几乎同形，做出来的规则只会随机触发。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "PULLUP"
ACTION_NAME_ZH = "引体向上"

HANG = "HANG"
PULLING = "PULLING"
TOP = "TOP"
LOWERING = "LOWERING"

PULLUP_STATES: tuple[str, ...] = (HANG, PULLING, TOP, LOWERING)

#: 相位映射。
#:
#: ``HANG`` 不出现在已封存的 rep 里 —— rep 缓冲从「离开悬垂」那一帧开始，
#: 因此悬垂段天然被排除在外（同 ``pu.py`` 对 ``TOP`` 的处理）。
#:
#: ``DESCENT`` / ``ASCENT`` 在这里读作「**离开**极端的那一段」与「**回到**极端
#: 的那一段」，与俯卧撑的用法一一对应，只是肘角在增减上反了过来：引体向上拉起来时
#: 肘角在**变小**，而 ``DESCENT`` 的原意（深蹲往下走）也是「肘/膝角变小」。
#: 需要新名字的是顶点那一段，它确实与「最低点」相反（见 ``Phase.APEX``）。
_STATE_TO_PHASE: dict[str, Phase] = {
    PULLING: Phase.DESCENT,
    TOP: Phase.APEX,
    LOWERING: Phase.ASCENT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供界面排序。
_SEVERITY_SPAN: dict[str, float] = {
    "PULLUP_NOT_DEAD_HANG": 15.0,
    "PULLUP_CHIN_NOT_OVER": 0.25,
    "PULLUP_SWING": 20.0,
}


def _mean_elbow(signals: Signals) -> float | None:
    """两侧肘角的可用均值。

    一侧被遮挡时退化为另一侧，而不是整体不可用。**分段不区分左右**：
    两侧肘角不等是**规则**要判的事，不是分段条件 —— 拿它去切段会让
    「一侧没看清」变成「这一次没数上」（同 ``slj.py``）。
    """
    values = [
        v
        for v in (signals.get("elbow_angle_L"), signals.get("elbow_angle_R"))
        if v is not None
    ]
    if not values:
        return None
    return sum(values) / len(values)


def build_pullup(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "oblique45",
) -> ActionDefinition:
    """按工程默认值构建引体向上定义。

    Args:
        calibration: 该用户的站立基线。**三条判定一条都不用它** ——
            肘角与嘴-腕高差都是绝对量（后者已用躯干长归一），而悬挂时躯干
            本来就竖直，与本人站姿的前倾习惯无关。它仍然要采：那是
            ``Calibrator`` 的门槛，也是「开始之前先站好」这一步的产物。
        config: 工程默认值。
        camera_view: 机位。45° 主链路。
    """
    # 180 帧（≈9 秒）：一次有控制的引体向上下放得慢，比俯卧撑更慢 ——
    # 俯卧撑那 150 帧对「慢慢放下、二头肌离心控制」的人有点紧。
    # 防抖三件套保持默认：一次引体向上约 2–4 秒（40–80 帧），
    # 每状态 5 帧的最小停留相对整次动作绰绰有余。
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=180,
    )

    hang_line = cfg.pullup_hang_deg
    top_line = cfg.pullup_top_deg
    hysteresis = cfg.standing_hysteresis_deg

    # 顺序不变式：顶部线必须在悬垂线**之下**（肘角更小），否则两条线之间的
    # 那一段就成了「既算悬垂又算到顶」，状态机在 PULLING 与 TOP 之间逐帧来回跳。
    if not top_line < hang_line:
        raise ValueError(
            f"引体向上的分段线顺序非法，必须 pullup_top_deg(={top_line}) < "
            f"pullup_hang_deg(={hang_line})。常见成因：把两条线的含义写反了"
            f"（顶部是肘角**小**的那一端）。"
        )

    def left_hang(signals: Signals) -> bool:
        """离开悬垂：肘角弯到进入线以下。"""
        value = _mean_elbow(signals)
        return value is not None and value < hang_line

    def at_top_line(signals: Signals) -> bool:
        """拉到顶线（进入顶部区域）。

        同时用于 ``PULLING→TOP`` 与 ``LOWERING→PULLING``。
        """
        value = _mean_elbow(signals)
        return value is not None and value <= top_line

    def rose_above_top_line(signals: Signals) -> bool:
        """开始下放：从顶线回升超过滞回带。"""
        value = _mean_elbow(signals)
        return value is not None and value > top_line + hysteresis

    def returned_to_hang(signals: Signals) -> bool:
        """回到直臂悬垂：肘角回到进入线以上。

        同时用于 ``LOWERING→HANG``（正常完成一次）与 ``PULLING→HANG``（假动作）。
        谓词相同而语义相反，理由同 ``squat.py``：**有没有到过顶部**这个事实
        该由状态机如实记录，而不是靠外部再加一个变量去猜。
        """
        value = _mean_elbow(signals)
        return value is not None and value > hang_line

    # 顺序即优先级（状态机契约）。同一状态的出边两两互斥，逐条核对过：
    # PULLING 的一条要求肘角 ≤ top_line、一条要求 > hang_line，LOWERING 同理
    # （两条边相隔 top_line 与 hang_line 之间那 75°）。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (HANG, PULLING, left_hang, "hang->pulling（起拉）"),
        (PULLING, TOP, at_top_line, "pulling->top（到顶）"),
        (PULLING, HANG, returned_to_hang, "pulling->hang（假动作）"),
        (TOP, LOWERING, rose_above_top_line, "top->lowering（开始下放）"),
        (LOWERING, HANG, returned_to_hang, "lowering->hang（封存）"),
        (LOWERING, PULLING, at_top_line, "lowering->pulling（回拉）"),
    )

    rules = (
        # 未回到直臂悬垂：落回来时手臂一直弯着，靠耸肩、屈臂挂着。
        #
        # **整段最大值 + ``Direction.BELOW``**：取这一次里肘角的**最大值**，
        # 最大值都还在阈值之下，才叫「整段没伸直过」。用帧计数会把下放途中的
        # 过渡帧全算进去，每一次都误判（同 squat.py 的深度规则）。
        #
        # **这条线与分段线的关系是可推理的，定线时必须满足**：封存条件是
        # 「肘角回到 hang_line(165°) 以上」，所以**每一个被计数的 rep 的整段
        # 最大值都必然 > 165°**。阈值定在 165° 以下的话「最大值越界」恒假，
        # 这条规则**永远不触发**且不报错。所以它必须**高于** hang_line ——
        # 阈值表里取 170°，就是这个道理。
        Rule(
            code="PULLUP_NOT_DEAD_HANG",
            name_zh="未回到直臂悬垂",
            metric="elbow_angle_L",
            threshold_key="pullup.dead_hang_min_elbow",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["PULLUP_NOT_DEAD_HANG"],
        ),
        # 下颌未过杠：拉起来的高度不够，下巴没到杠。
        #
        # **顶点段最小值**：双手握在杠上，腕的高度就是杠的高度，所以
        # ``mouth_wrist_dy < 0`` 就是「嘴高过腕 = 下颌过杠」。取这一段的最小值，
        # 问的是「这一次里嘴相对手**最高**的那一帧，过线了没有」。
        # **带符号，所以阈值是个负数** —— 写成「取绝对值再判」会把
        # 「挂在手下」与「拉过头」压成同一个数。
        #
        # 窗口切在 ``Phase.APEX`` 而不是整段：区别全在「读不到的时候」
        # （见模块文档那一节）。**这是本动作唯一一条会因为遮挡而改变结论的
        # 规则**，所以它必须切窗口。
        #
        # 但遮挡容错只是部分的：这个窗口的尾巴上还有几帧属于下放（换相确认滞后），
        # 所以「不报」要求嘴一路遮到下放段。细节见模块文档那一节。
        Rule(
            code="PULLUP_CHIN_NOT_OVER",
            name_zh="下颌未过杠",
            metric="mouth_wrist_dy",
            threshold_key="pullup.chin_over_dy_max",
            bad_side=Direction.ABOVE,
            phase=Phase.APEX,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["PULLUP_CHIN_NOT_OVER"],
        ),
        # 身体摆动借力：靠前后荡的惯性把身体甩上去（kipping），而不是靠背阔肌。
        #
        # **整段最大绝对值**（``use_abs`` + ``Reduce.MAX``）：符号取决于人面朝
        # 画面哪一侧，不是体育含义（同深蹲、跳绳那两条）。
        #
        # **绝对阈值，不挂基线**：挂在杠上时躯干本来就竖直，与本人站姿的前倾
        # 习惯无关。**它是「最大偏离」，不是严格意义上的「振幅」**：规则引擎
        # 只有 min/max/median 三种归约，算不出「峰谷差」。严格的动作里躯干在
        # 顶点会略向后仰，所以这条线取在 20° 之上 —— 真机标定时**先把标准动作
        # 的读数记下来再定线**，不要凭推算。
        Rule(
            code="PULLUP_SWING",
            name_zh="身体摆动借力",
            metric="trunk_lean",
            threshold_key="pullup.swing_max_lean_deg",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            use_abs=True,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["PULLUP_SWING"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=PULLUP_STATES,
        resting_state=HANG,
        # TOP 而不是 PULLING：没拉到顶的那次**不算一次** ——「引体向上」这个
        # 动作的判定对象就是「下颌过杠再落回直臂」，没到顶的那些由
        # ``discarded_reps`` 解释。取 PULLING 的话，一次几乎没动胳膊的悬挂晃动
        # 也会被计成一次，而规则只会说「下颌未过杠」—— 用户被告知了一个他并没有
        # 做的动作有问题。同开合跳、俯卧撑的 ``bottom_state`` 取舍。
        bottom_state=TOP,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **刻意留空。** 三条判定的阈值都是绝对的：肘角是关节夹角、
        # 嘴-腕高差已用躯干长归一、躯干倾角是本人在悬挂时的绝对偏角 ——
        # 三者都与本人的体型、站姿习惯无关（理由逐条写在规则旁边）。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "HANG",
    "LOWERING",
    "PULLING",
    "PULLUP_STATES",
    "TOP",
    "build_pullup",
]
