"""仰卧起坐动作定义。

与 ``app/lib/domain/exercises/situp.dart`` 一一对应，**数值逐位相同**。

**状态链（设计文档 §4.3）**::

    SEATED ──→ LOWERING ──→ LYING ──→ RISING ──→ SEATED
      ↑           │                      │
      └───────────┘                      └──→ LOWERING
       （假动作：躺到一半又坐起来，          （回退：起到一半又躺回去，
         从头到尾没躺平过）                   否则 LYING 会变成走不出去的死角）

形状与深蹲**一模一样**，连相位映射都一样（``LOWERING→DESCENT``、
``LYING→BOTTOM``、``RISING→ASCENT``）—— 这两个动作的骨架本来就同形：
一个中立位、一个最低点、两侧各一段行程。

**计数点为什么是「回到 SEATED」而不是「回到 LYING」（与 §4.3 的一处出入）**

§4.3 那张表写的是「回到 ``LYING`` 且肩胛触垫确认」。**做不出来**，原因是引擎的
一条硬性质：``RepTracker`` 的缓冲**从离开 resting_state 那一帧开始、到重新进入
它的那一帧封存**，而 resting_state 本身不出现在已封存的 rep 里（``pu.py`` 的
``TOP`` 是同一件事）。

于是如果把 ``LYING`` 当 resting_state，「这一次的肩到底贴到垫上没有」这个证据
**正好落在 rep 缓冲的边界上**：缓冲里能看到的、肩最低的那一刻，就是判定「躺平了」
的那一帧 —— 一个刚降到线上一瞬间就起来的人，与一个老老实实贴到垫上的人，
在缓冲里给出的最小值几乎一样。更糟的是它**偏向快速起身的人**：防抖让封存晚几帧
发生，起得越快，封存时肩已经多降了一截，读数越小、越不容易被判「没贴垫」——
而慢速控制恰恰是这个动作最该鼓励的。

把 resting_state 换成 ``SEATED``、bottom_state 换成 ``LYING`` 之后，躺平那一段
**落进缓冲的中段**，``Phase.BOTTOM`` 上的最小值才是它本来的意思。

**机位**：45° 主链路（同深蹲、立定跳远、俯卧撑）。它的两个量
（``shoulder_height_ratio``、``body_line_offset_ratio``）都声明
``("sagittal", "oblique45")``：**正视下身体的长边就是镜头方向本身**，
两个 y 方向的差都读不出来。所以正对镜头是拦人级错误，侧对与 45° 都放行。

**「坐起线」为什么不能取 1.0（一个物理上界，不是调参口味）**

``shoulder_height_ratio`` 是**肩比踝高多少**。臀贴在垫上时肩绕髋转，记躯干与
竖直方向的夹角为 α、躯干长为 L::

    肩高（离垫） = L·cos α      →      比值 = L·cos α / L = cos α

于是这个比值在「臀不离垫」的前提下**上界是 1**，而 1 只在 α = 0（躯干严格竖直）
那一刻取到 —— 一个奇点。国标的收势是前倾（肘触膝），前倾 30° 就只有 0.87。
**取 1.0 会让标准动作永远不被计数，且不报任何错。**

更坏的是它会奖励正要被罚的那个错：臀一离垫，肩被顶高，比值能越过 1.0 ——
老老实实做的人够不着线，顶着髋借力的人够得着。所以取 0.75（α ≲ 41°）。

（站着时这个比值能到 3 上下，因为那时踝到肩跨了整条腿；上界 1 只在
**臀不离垫**这一个前提下成立，也就是仰卧起坐的全过程。）

**阈值分工**：分段线是工程参数（``situp_lie_ratio`` / ``situp_seat_ratio`` /
``situp_hysteresis``），质量判断全交给规则引擎、用 ``shared/thresholds/`` 里的
体育阈值（目前全部待核定）。「坐起」与「肩胛贴垫」是两条不同的线：
前者只管「这一次算不算一次」，肩没贴到垫上的那些次**照样算**，由
``SU_SHOULDER_NOT_GROUND`` 指出来。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "SU"
ACTION_NAME_ZH = "仰卧起坐"

LYING = "LYING"
RISING = "RISING"
SEATED = "SEATED"
LOWERING = "LOWERING"

#: 顺序与 ``preview_poses.py`` 那四拍、以及 ``action_spec.dart`` 的词表一致。
SU_STATES: tuple[str, ...] = (LYING, RISING, SEATED, LOWERING)

#: 相位映射。
#:
#: ``SEATED`` 不出现在已封存的 rep 里（缓冲从离开它开始），同深蹲的 ``STANDING``。
#: 三个成员与深蹲逐字复用，理由见模块文档。
_STATE_TO_PHASE: dict[str, Phase] = {
    LOWERING: Phase.DESCENT,
    LYING: Phase.BOTTOM,
    RISING: Phase.ASCENT,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供界面排序。
_SEVERITY_SPAN: dict[str, float] = {
    "SU_SHOULDER_NOT_GROUND": 0.15,
    "SU_HIP_LIFT": 0.15,
    "SU_KNEE_ANGLE": 30.0,
}


def build_su(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "oblique45",
) -> ActionDefinition:
    """按工程默认值构建仰卧起坐定义。

    Args:
        calibration: 该用户的站立基线。**三条判定一条都不用它** ——
            肩高比与体线偏移都已用躯干长归一，膝角是个夹角。它仍然要采：
            那是 ``Calibrator`` 的门槛，也是「开始之前先站好」这一步的产物，
            与其余四个动作共用同一套流程。
        config: 工程默认值。
        camera_view: 机位。45° 主链路。
    """
    # 20 秒（≈600 帧）而不是深蹲的 10 秒：一分钟仰卧起坐是真的有人赶速度做，
    # 一次 1.5–3 秒是常态，上限要留够「慢下来做标准」的余量。
    # 但也不能不设 —— 卡住时每一帧 HUD 都顶着错误的状态词（同立定跳远那条理由）。
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=600,
    )

    lie_line = cfg.situp_lie_ratio
    seat_line = cfg.situp_seat_ratio
    hysteresis = cfg.situp_hysteresis

    # 顺序不变式：躺平线必须**明显低于**坐起线，中间要留得下两条滞回带，
    # 否则一次动作里 LYING 与 SEATED 之间的行程是负的 —— 状态机在两者之间
    # 逐帧来回跳，每一次都封存一次 rep。
    if not lie_line + hysteresis < seat_line - hysteresis:
        raise ValueError(
            f"仰卧起坐的分段线顺序非法，必须 situp_lie_ratio + situp_hysteresis"
            f"(={lie_line + hysteresis}) < situp_seat_ratio − situp_hysteresis"
            f"(={seat_line - hysteresis})。常见成因：把躺平线抬得太高，"
            f"或把坐起线压得太低。"
        )

    def shoulder_height(signals: Signals) -> float | None:
        """这一次的肩上高度。

        **取不到就返回 ``None``，不能拿 0 顶替** —— 0 在量纲上正是「躺着」，
        用它会凭空造出一次「已经躺平了」的结论。
        """
        return signals.get("shoulder_height_ratio")

    def started_lowering(signals: Signals) -> bool:
        """开始躺下（离开坐姿）。"""
        value = shoulder_height(signals)
        return value is not None and value < seat_line - hysteresis

    def reached_mat(signals: Signals) -> bool:
        """躺到垫上了。"""
        value = shoulder_height(signals)
        return value is not None and value <= lie_line

    def started_rising(signals: Signals) -> bool:
        """开始起身（离开垫子）。"""
        value = shoulder_height(signals)
        return value is not None and value > lie_line + hysteresis

    def seated_up(signals: Signals) -> bool:
        """坐起来了。

        同时用于 ``RISING→SEATED``（正常完成一次）与 ``LOWERING→SEATED``
        （假动作）—— 同深蹲与俯卧撑：**有没有躺平过**这个事实由状态机如实记录
        （bottom_state），不靠外部再加一个变量去猜。
        """
        value = shoulder_height(signals)
        return value is not None and value >= seat_line

    def fell_back(signals: Signals) -> bool:
        """起到一半又躺回去。"""
        value = shoulder_height(signals)
        return value is not None and value < lie_line

    # 顺序即优先级（状态机契约）。同一状态的出边两两互斥。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (SEATED, LOWERING, started_lowering, "seated->lowering"),
        (LOWERING, LYING, reached_mat, "lowering->lying"),
        (LOWERING, SEATED, seated_up, "lowering->seated(假动作)"),
        (LYING, RISING, started_rising, "lying->rising"),
        (RISING, SEATED, seated_up, "rising->seated"),
        (RISING, LYING, fell_back, "rising->lying(回退)"),
    )

    rules = (
        # 肩胛未触垫：问的是「这一次里肩**离垫最近的那一刻**有没有贴到垫上」。
        #
        # **窗口必须是 Phase.BOTTOM（= LYING 那一段）**，不能是整段：整段上
        # 「肩最低」的那一刻在起身之后就被冲掉了 —— 那正是这个动作判定的全部
        # 内容。也不能退到 Phase.ALL 上碰运气，理由见模块文档那一节。
        #
        # Reduce.MIN + Direction.ABOVE：取这一段里肩高的**最小值**，
        # 最小值都还在阈值之上，才叫「一次都没贴到垫上」。
        Rule(
            code="SU_SHOULDER_NOT_GROUND",
            name_zh="肩胛未触垫",
            metric="shoulder_height_ratio",
            threshold_key="su.shoulder_to_mat_ratio_max",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["SU_SHOULDER_NOT_GROUND"],
        ),
        # 臀离垫借力：垫上做仰卧起坐时用臀/腰把身体顶起来借惯性。
        #
        # 取整段窗口（Phase.ALL）里的**最小值**：``body_line_offset_ratio`` 在那
        # 一段里是「髋比肩-踝连线低多少」，而坐起来的过程中髋本来就会跑到连线
        # 下方（读数为正）—— 那些正值不干扰取 min。**只有真的把臀顶起来**
        # （髋比连线更高）才会压出负值，所以这条规则看的是 min 够不够负。
        #
        # 与俯卧撑的 ``PU_HIP_PIKE`` 是同一个量、同一个方向，只是换了个动作背景。
        Rule(
            code="SU_HIP_LIFT",
            name_zh="臀离垫借力",
            metric="body_line_offset_ratio",
            threshold_key="su.hip_lift_ratio_min",
            bad_side=Direction.BELOW,
            phase=Phase.ALL,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["SU_HIP_LIFT"],
        ),
        # 屈膝角度不符：国标要求屈膝约 90°，腿伸直是走形的常见做法。
        #
        # **只判一侧（伸得太直），不判弯得太过。** 一条只带一个方向的规则表达
        # 不了区间，而两端里只有「伸太直」是真正的动作走形。写了区间的话两端
        # 要各写一条，而其中一条的纠正建议（「把腿伸直点」）与国标相反。
        #
        # 指标取左膝，理由同深蹲与俯卧撑的深度规则：侧视画面上两条腿几乎重合，
        # 用单侧就够，代价是一侧被挡住时该帧按不可用处理。
        Rule(
            code="SU_KNEE_ANGLE",
            name_zh="屈膝角度不符",
            metric="knee_angle_L",
            threshold_key="su.knee_angle_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["SU_KNEE_ANGLE"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=SU_STATES,
        # **坐在上面**（而不是躺在垫上），理由见模块文档那一整节 ——
        # 换回 LYING 会让「肩胛有没有贴垫」这条判定失去它唯一的证据。
        resting_state=SEATED,
        # LYING：没躺回垫上的那一次**不算一次**。取 RISING 的话，一次几乎没动的
        # 抬肩也会被计成一次，而规则只会说「肩胛未触垫」—— 用户被告知了一个他
        # 并没有做的动作有问题。同开合跳的 OPEN 与俯卧撑的 BOTTOM。
        bottom_state=LYING,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # **刻意留空。** 三条判定的阈值都是绝对的：肩高比与体线偏移已用躯干长
        # 归一，膝角是关节夹角，三者都与本人的体型无关（同 jj.py / pu.py 的理由）。
        threshold_offsets={},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "LOWERING",
    "LYING",
    "RISING",
    "SEATED",
    "SU_STATES",
    "build_su",
]
