"""平板支撑动作定义。

与 ``app/lib/domain/exercises/plank.dart`` 一一对应，**数值逐位相同**。

**状态链：两态，撑住 ⇄ 没撑住**::

    HOLD_BREAK ⇄ HOLD_OK

``resting_state = HOLD_BREAK``（不在支撑位上）、``bottom_state = HOLD_OK``（撑住了）。
**一次 rep = 一段连续的支撑**：状态机在「离开 ``HOLD_BREAK``」那一帧开窗、在
「回到 ``HOLD_BREAK``」那一帧封存，所以 rep 窗口就是那一段支撑本身。于是这个动作的
两个产出恰好是首页卡片承诺的那两件事：**每段撑了多久**（``RepWindow`` 首末帧时间戳
之差，早已进决策契约的 ``duration_ms``）与**每段里犯了什么错**（规则层）。
「累计撑了多久」是前者之和。

**这是全仓库第一个「计时制」的动作。** 前面七个的 rep 是「一次动作」，只有它的 rep
是「一段时间」。引擎为此一行都不用改（rep 窗口本来就带时间戳，``decision_request``
早就在算 ``duration_ms``），要改的是**界面怎么显示** —— 一个 40 秒的支撑被显示成
「1 个」，用户会以为计数器没在看他（见 ``counting_hud.dart`` 的计时分支与
``ActionSpec.is_timed``）。

**只有两个状态，够不够？** 够，而且不能再少。对照跳绳（``rope.py`` 模块文档）那道题：
跳绳必须有第三个状态，因为它的规则要判的证据（落地缓冲）发生在「回到 resting_state」
**之后**，两态环下那一段整个落在窗口外。平板支撑没有这个问题 —— 它要判的东西全程
都在支撑段里，窗口正好把它整个圈住。

**分段信号：三件事的合取**（``base.py`` 的 ``TrackingConfig`` 里逐条写了取值）

1. **身体放平了**（``|trunk_lean| >= plank_lie_deg``）
2. **体线大致成一条线**（``|body_line_offset_ratio| <= plank_line_enter_ratio``）
3. **撑地的手臂在支撑带上**（肘角落在 ``plank_elbow_min_deg``..``plank_elbow_max_deg``）

**为什么必须是三条的合取，一条都不能省**：每一条拎出来都会把别的东西读成支撑。
站着的人体线也直（肩在髋上、髋在踝上，偏移 ≈ 0）—— 只看第 2 条，标定那 15 帧站立
就会被读成一次长支撑；趴在地上的人体线也直、也水平 —— 只看第 1、2 条，中途趴下休息
也算「撑着」。加第 3 条是因为前臂支撑的姿势里肘角被几何锁在 90° 上下，而站着或趴着
放松时手臂是伸直的（≈180°）。

**它挡不住什么（已知边界，写在这里因为屏幕上不报错）**：一个**趴在地上**的人摆出
同样的关节构型（前臂撑在身侧、肘角 90°、身体成一条直线），在单目投影下与真正的
平板支撑**完全同形** —— 两者的差别只有「离地多高」，而单目无深度参照（设计文档
附录 A 那一条）。侧躺同理：腹侧朝上还是朝下，侧视画面上只差四肢的弯折方向。缓解手段
只有两条，都不是判定：站位门禁要求全身入画（趴着/撑着至少都看得见人），以及计数屏上
那个「撑住 / 没撑住」的状态词 —— 用户看得见系统把它读成了什么。**别把这条边界写成
「已经解决」**：它换来的是「躺在地上不动不会被静默计成一组好成绩」以外的所有情况
都得靠用户自己对一眼屏幕。

**人出画不会把一段支撑切开 —— 这是有意的，代价要说清楚。** ``loss_recovery`` 是空的
（同深蹲、俯卧撑那几个）：撑到一半人走出画面再回来，状态机停在 ``HOLD_OK`` 上等，回来
接着算，**一次支撑仍然是一次**。代价在这个动作上比在别的动作上直接：那几帧人是真的不在
画面里，而**那段时间照样算进这一段的时长** —— 「撑了 40 秒」里可能含着 5 秒人不在。
防线不在这一层，在会话层的 ``interrupted`` 标记与屏幕上那句「中途离开过画面，计数可能
不准」。**别为它在规则里编一条判据** —— 那会把「人走开了」写成「动作变形」。

**机位：侧视（矢状面）**。``body_line_offset_ratio`` 声明 ``[sagittal, oblique45]``，
主链路 45° 机位同样成立 —— **正对镜头则两条体线判定一起消失**（正面画面上「身体的前后
方向」就是镜头方向本身），所以站位与深蹲、立定跳远同向：要侧身。

**阈值分工**：分段用工程参数（``plank_lie_deg`` / ``plank_line_*_ratio`` /
``plank_elbow_*_deg``），质量判断全部交给规则引擎、用 ``shared/thresholds/`` 里的体育
阈值（目前全部待核定）。**门槛比判据宽**：塌腰 0.20 就被判错，但要塌到 0.45 才算
「离开支撑位」—— 中间那一段正是 ``PLANK_HIP_SAG`` 有活干的地方（同开合跳的分腿幅度、
俯卧撑的深度）。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "PLANK"
ACTION_NAME_ZH = "平板支撑"

#: 不在支撑位上：还没趴下去、撑不住了、或者已经起身。
HOLD_BREAK = "HOLD_BREAK"

#: 撑住了：身体放平、体线成一条线、前臂在支撑带上。
HOLD_OK = "HOLD_OK"

#: **顺序即 HUD 上的词序**（``exercise_preview_test.dart`` 拿它跟预览的拍子逐字
#: 比对）。撑住那一拍在前：预览要先把动作长什么样给人看，再说清「没撑住」长什么样。
PLANK_STATES = (HOLD_OK, HOLD_BREAK)

#: 相位映射：**空**。
#:
#: 两态环下，rep 窗口就是支撑段本身（缓冲从离开 ``HOLD_BREAK`` 那一帧开始、到回到
#: 它的那一帧结束），映射一个相位只是给同一批帧再起一个名字 —— 而
#: ``RepTracker._phase_bounds`` 会跳过没有映射的状态，所以这里的空表意味着三条规则
#: 都跑在整段上，正是想要的（同 ``jj.py`` 那条「没有任何东西要求每个状态都得映射
#: 一个相位」）。**别为了对称补一个 ``Phase.BOTTOM``**：那个成员的名字与它上面三条
#: 规则说的都是「最低点」，而平板支撑没有最低点，支撑段是**一段时间**。
_STATE_TO_PHASE: dict[str, Phase] = {}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供 UI 排序。
#: 前两条与俯卧撑同量同值（都是 ``body_line_offset_ratio``，同样的塌/拱幅度该得到
#: 同样的严重度）；肘角那条按「偏离 90° 二十度算满」取。
_SEVERITY_SPAN = {
    "PLANK_HIP_SAG": 0.15,
    "PLANK_HIP_PIKE": 0.15,
    "PLANK_ELBOW": 20.0,
}

#: 「一段支撑里至少几帧越界才算命中」。
#:
#: **比别的动作大得多（它们取 2）**，是这个动作特有的两件事决定的：
#:
#: 1. **它是计时制。** 一段支撑动辄几百帧，逐帧判错的代价被放大了 —— 抖一下不该在
#:    四十秒的支撑里变成一次犯规。
#: 2. **窗口的尾巴上有几帧不属于支撑段。** 状态机换相要经过驻留与投票，确认「离开
#:    支撑位」的那一帧**已经晚了几帧**（那几帧里人其实已经塌了），而它们落在窗口里。
#:    2 帧的门槛会让**每一次正常收势都被判成塌腰** —— 因为收势（收回膝盖、或者撑起来）
#:    正好从这几帧开始。8 帧（约半秒）把这段确认滞后挡在门槛之外，而真正撑不住的塌
#:    是持续几十帧的。
#:
#: 这条与 ``pullup.py`` 里那条「相位窗口的边界不是精确的」是同一件事的两个后果：
#: 那边让遮挡容错变成部分的，这边让门槛必须留出滞后的余量。
_MIN_VIOLATING_FRAMES = 8


def _mean_elbow(signals: Signals) -> float | None:
    """两侧肘角的可用均值。

    与 ``pu.py`` 的同名函数一样：45° 机位下远侧手臂常被躯干或近侧手臂挡住，
    取均值比只看单侧稳健，一侧被遮挡时退化为另一侧而不是整体不可用。

    **这只用在分段守卫上。** 规则用的是 ``elbow_angle_L`` 这个特征本身 ——
    分段看的是「这个人现在在不在支撑位上」，能看清一侧就够；规则判的是「他撑得够不够
    好」，而那是两回事（同 ``pu.py`` 那条）。平板支撑还要多一层：两侧都不清楚时守
    **维持**当前状态（见 ``left_hold``），不会因为看不见而断开。

    代价是两侧差得很大时均值会把差异平掉 —— 而「两只手臂不对称」本来就是这个动作
    不判的事（``PLANK_ELBOW`` 判的是偏离，两条规则共用那一个码）。
    """
    values = [
        v
        for v in (signals.get("elbow_angle_L"), signals.get("elbow_angle_R"))
        if v is not None
    ]
    if not values:
        return None
    return sum(values) / len(values)


def build_plank(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "sagittal",
) -> ActionDefinition:
    """按工程默认值构造平板支撑定义。

    Args:
        calibration: 该用户的站立基线。**三条判定一条都不用它**（体线偏移已用躯干长
            归一、肘角是关节夹角，两者都与体型无关），但它仍然要采 —— 那是
            ``Calibrator`` 的门槛，也是「开始之前先站好」这一步的产物（同 ``pu.py``）。
        config: 工程默认值。
        camera_view: 机位。侧视是主链路。
    """
    # 3600 帧：按推理机位常见的 15 帧/秒约 4 分钟、30 帧/秒约 2 分钟。
    #
    # 这个上限**是帧数不是时长**（``RepTracker`` 按帧数封顶），所以它的真实含义随
    # 帧率变 —— 这一点在前七个动作上无关紧要（一次动作几十帧），在这里却是一条要
    # 写下来的边界：撑过上限的那一段会被丢弃（走 ``discarded_reps``），而它同时是
    # **内存**上限（每帧一份 31 个特征的映射，3600 帧约十几 MB）。取 4 分钟是因为
    # 再长已经不是学生体测的场景，而缓冲区不能无限涨。
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=3600,
    )

    lie_deg = cfg.plank_lie_deg
    hysteresis = cfg.standing_hysteresis_deg
    enter_ratio = cfg.plank_line_enter_ratio
    exit_ratio = cfg.plank_line_exit_ratio
    elbow_min = cfg.plank_elbow_min_deg
    elbow_max = cfg.plank_elbow_max_deg

    # 顺序不变式，四条。全是工程参数，谁调乱了应当当场炸 —— 而不是让状态机卡在
    # 某个状态上，屏幕上只表现为「计数一直是 0」（同 ``slj.py`` / ``jj.py`` 的
    # 构造期断言）。
    if not exit_ratio > enter_ratio:
        raise ValueError(
            f"平板支撑的体线容差顺序非法，必须 plank_line_enter_ratio(={enter_ratio}) "
            f"< plank_line_exit_ratio(={exit_ratio})。两者之间是滞回带，写反或写等会"
            f"让髋在边界上抖一帧就把一次支撑切成两段。"
        )
    if not lie_deg > hysteresis:
        raise ValueError(
            f"平板支撑的身体放平线太小：plank_lie_deg(={lie_deg}) 必须大于 "
            f"standing_hysteresis_deg(={hysteresis})，否则退出线（放平线减滞回）"
            f"落到 0 附近，站着的人也会被读成「身体放平了」。"
        )
    if not elbow_min < elbow_max:
        raise ValueError(
            f"平板支撑的支撑带上下沿写反了：必须 plank_elbow_min_deg(={elbow_min}) < "
            f"plank_elbow_max_deg(={elbow_max})。"
        )
    if not elbow_max + hysteresis < 180.0:
        raise ValueError(
            f"平板支撑的支撑带上沿太高：plank_elbow_max_deg(={elbow_max}) 加上滞回 "
            f"{hysteresis} 之后必须仍低于 180°（手臂伸直）。够到 180° 的话，站着或"
            f"趴着放松（肘角≈180°）也会落进支撑带，光靠肘角就分不出「撑着」与「站着」。"
        )

    def _in_support(signals: Signals, *, ratio: float) -> bool:
        """这一帧在不在支撑位上（宽的一侧：进入用它）。"""
        lean = signals.get("trunk_lean")
        offset = signals.get("body_line_offset_ratio")
        elbow = _mean_elbow(signals)
        # 读不到任何一个量 → 不认为进了支撑位。**这不等于「离开了」**：出边用的是
        # 另一个函数（见 ``left_hold``），那里的取舍正好相反。
        if lean is None or offset is None or elbow is None:
            return False
        return (
            abs(lean) >= lie_deg
            and abs(offset) <= ratio
            and elbow_min <= elbow <= elbow_max
        )

    def entered_hold(signals: Signals) -> bool:
        """进入支撑位：三个量同时满足（较紧的一侧）。"""
        return _in_support(signals, ratio=enter_ratio)

    def left_hold(signals: Signals) -> bool:
        """离开支撑位：放宽之后的三个量**有一个不满足**。

        **读不到特征时返回 ``False``（＝维持「撑住」）。** 这与进入那一侧正好相反，
        是刻意的：人还撑在那儿、只是某一帧某个点被挡住，不该被读成「这一段到此为止」。
        这一段会因为 ``max_rep_frames`` 或者人真的动起来而结束，不需要靠「读不到」来
        结束 —— 而「读不到就结束」会把一次遮挡变成一次计数。
        """
        lean = signals.get("trunk_lean")
        offset = signals.get("body_line_offset_ratio")
        elbow = _mean_elbow(signals)
        if lean is None or offset is None or elbow is None:
            return False
        still_holding = (
            abs(lean) >= lie_deg - hysteresis
            and abs(offset) <= exit_ratio
            and elbow_min - hysteresis <= elbow <= elbow_max + hysteresis
        )
        return not still_holding

    # 顺序即优先级（状态机契约）。两态环上每个状态各一条出边。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (HOLD_BREAK, HOLD_OK, entered_hold, "break->ok"),
        (HOLD_OK, HOLD_BREAK, left_hold, "ok->break"),
    )

    rules = (
        # 塌腰：髋比「肩—踝」连线低。问的是「这一段里有没有**持续**塌下去」，
        # 所以走 ``ANY_FRAME`` 而不是 ``MIN``/``MAX`` 归约 ——
        #
        # 判「有没有达到某个位置」的那两条归约（俯卧撑的深度、立定跳远的缓冲）适合
        # 一次性的动作极值；这里要判的是**一段时间里的姿态**，逐帧计数才是它的语义
        # （与深蹲的 ``EXCESSIVE_TRUNK_LEAN`` 同一类）。
        #
        # 与撅臀那条**共用同一个指标、方向相反**：现成的 ``body_line_angle`` 是
        # ``angle3`` 的夹角，值域 [0°, 180°]，塌腰与撅臀都只是让它变小 —— 同形，
        # 而两者该说的话正好相反。所以用带符号的 ``body_line_offset_ratio``
        # （与 ``pu.py`` 那两条同源，连阈值口径都一样）。
        Rule(
            code="PLANK_HIP_SAG",
            name_zh="塌腰",
            metric="body_line_offset_ratio",
            threshold_key="plank.hip_sag_ratio_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.ANY_FRAME,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["PLANK_HIP_SAG"],
        ),
        # 撅臀：髋比连线高。阈值是**负数**（``plank.hip_pike_ratio_min``），方向是
        # ``BELOW`` —— 越负越坏。写成这样而不是「取绝对值再判」，是为了让「倾向哪一边」
        # 这件事在阈值表里看得见（同 ``pu.py``）。
        Rule(
            code="PLANK_HIP_PIKE",
            name_zh="撅臀",
            metric="body_line_offset_ratio",
            threshold_key="plank.hip_pike_ratio_min",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.ANY_FRAME,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["PLANK_HIP_PIKE"],
        ),
        # 肘角偏离支撑位：**两条规则共用一个错误码**，一条管「太直」、一条管「太塌」
        # —— 因为前臂支撑的肘角被几何锁在 90° 上下，偏离两个方向都算错，而
        # ``Rule.bad_side`` 只有一侧。
        #
        # **这不是绕过引擎的限制，是引擎明确支持的做法**：``RuleEngine.evaluate_set``
        # 里写着「同一 rep 内重复命中同一错误只计一次，否则出现率会虚高（两条不同的
        # 规则可以共享一个错误码）」。所以两条同时命中时，那一次支撑在统计里只算犯了
        # 一次 —— 正是想要的。
        #
        # **两条的阈值必须严格落在支撑带里面**（``plank.elbow_angle_min`` >
        # ``plank_elbow_min_deg``、``plank.elbow_angle_max`` < ``plank_elbow_max_deg``），
        # 否则「肘角越界」蕴含「离开支撑位」—— 而那一段已经被封存成 rep 了，规则的
        # 越界帧数永远攒不够，**规则永远不触发也不报错**。与引体向上、跳绳那两条
        # 「阈值必须在封存线之内」是同一类自查，由 ``plank_test.dart`` 用真实资产表钉住。
        Rule(
            code="PLANK_ELBOW",
            name_zh="肘角偏离",
            metric="elbow_angle_L",
            threshold_key="plank.elbow_angle_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.ANY_FRAME,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["PLANK_ELBOW"],
        ),
        Rule(
            code="PLANK_ELBOW",
            name_zh="肘角偏离",
            metric="elbow_angle_L",
            threshold_key="plank.elbow_angle_min",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.ANY_FRAME,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["PLANK_ELBOW"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=PLANK_STATES,
        resting_state=HOLD_BREAK,
        # HOLD_OK 而不是 HOLD_BREAK：rep 的语义就是「撑住的那一段」，而状态机在
        # **离开** resting_state 时开窗，所以这一条实际上等于「凡是开窗的段落必然到过
        # 支撑位」—— 两态环下它恒真，写出来是为了把语义写死：哪天有人给这个动作加一个
        # 中间态（比如「正在撑起」），门槛仍在支撑位上。
        bottom_state=HOLD_OK,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **刻意留空。** 三条判定的阈值都是绝对的：肘角是关节夹角、体线偏移已用躯干长
        # 归一，两者都与本人的体型无关（同 ``pu.py`` / ``jj.py`` 的理由）。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "HOLD_BREAK",
    "HOLD_OK",
    "PLANK_STATES",
    "build_plank",
]
