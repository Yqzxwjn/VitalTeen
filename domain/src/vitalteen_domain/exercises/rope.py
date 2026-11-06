"""跳绳动作定义。

与 ``app/lib/domain/exercises/rope.dart`` 一一对应，**数值逐位相同**。

**状态环**::

    GROUND ──→ AIR ──→ CUSHION ──→ GROUND
                             │
                             └──→ AIR
                             （又跳起来了：落地的缓冲还没吃完就蹬了上去，
                               否则 CUSHION 会变成走不出去的死角）

``resting_state = GROUND``（双脚落在地上）、``bottom_state = AIR``（腾空）。
回到 ``GROUND`` 就封存一次 —— 「落地了才叫一次」，与设计文档 §4.3 的
「回到双脚触地」一致。

**为什么必须有第三个状态（``CUSHION``）**

两态的环（``GROUND ⇄ AIR``）**看起来**就够了：离地进 AIR、落地回 GROUND。
但 ``RepTracker`` 的缓冲是「离开 resting_state 那一帧开始、重新进入它的那一帧
封存」：两态环下，**封存发生在脚尖刚碰到地面的那一帧** —— 而落地缓冲
（膝屈再伸的那一下）全部发生在那之后。于是 ``ROPE_LOW_BUFFER`` 要判的那一段
证据**整个落在 rep 窗口之外**，它量到的只剩起跳前那一下屈膝。
规则照常产出结论，说的是另一件事。

加了 ``CUSHION`` 之后，脚尖回到地面只是「进入缓冲段」，封存要等到缓冲吃完
（见下面那条边），落地那一段因此落在窗口的中后段。这不是为跳绳特设的机制：
``pu.py`` 的 ``TOP``、``situp.py`` 的 ``SEATED`` 都在解决同一件事。

**分段信号：脚尖高出画面下缘多少（``foot_height_ratio``）**

**这是全仓库唯一一个拿画面当零点的动作。** 别的动作都刻意不这么做
（``shoulder_height_ratio`` 的注释写着为什么：画面上下的位移一半来自人自己的
移动）。这里能这么做，是因为跳绳有一条别的动作没有的前提：**手机架稳不动**，
于是画面下缘在一整组里是一个固定不动的水平面，而「离地」恰恰要相对地面、
不能相对本人。所以产品文案里要写「手机要立住别动」—— 它动了，这个量就跟着
一起动，而屏幕上不会报任何错。

**三条线全部相对本人站立基线**：``takeoff_line = 基线 + rope_takeoff_ratio``，
其余两条同理。因为 ``foot_height_ratio`` 的**绝对值由机位高度决定**
（手机架在腰高还是胸口高，同一个站姿的读数能差一大截），拿它当门槛会变成
「手机架得对不对」的判据。代价是标定姿势对跳绳有额外要求：必须**站稳在地上**
—— 这是唯一一个「基线本身就代表接触地面」的动作。

**``CUSHION → GROUND`` 为什么要看膝角**

光看脚尖是做不出「缓冲吃完了」的：落地之后脚尖一直贴在地面上，「脚尖回到
站立高度」从触地那一刻起就恒真，状态机会在触地后两三帧内封存 —— 又回到上面
那条「证据落在窗口外」。而「缓冲吃完」的物理含义是**膝从屈回到伸**，
所以这条边的守卫是「脚尖回到地面 **且** 膝角回到站立基线附近」，与立定跳远的
``LAND → STANDING`` 是同一条。它同时保证了一件事：**每一个封存下来的 rep，
膝角一定曾经回到过站立线** —— 而 ``ROPE_LOW_BUFFER`` 量的正是这一段里膝角的
**最小值**，那条阈值与这条分段线的相对关系因此是可以推理的
（见阈值表里那条 ``_note``）。

**相位映射刻意留空**

三条规则全部跑在 ``Phase.ALL`` 上，所以 ``_STATE_TO_PHASE`` 是空表。
**不映射 ``CUSHION`` 是有意的**：落地缓冲那一段只有 2–5 帧（一次跳绳的腾空
不到半秒，落地更短），拿它当相位窗口会让「膝盖屈得最深的那一帧」有大概率
落在窗口外，而 ``RepWindow.select`` 对没有区间的相位**退化为整段** ——
那是一条静默的误判路径。整段上取膝角最小值本来就能回答「这一跳屈没屈膝」：
腾空时腿是伸直的，屈膝只发生在触地那一下。

**阈值分工**：三条分段线是工程参数（``rope_takeoff_ratio`` /
``rope_land_ratio`` / ``rope_settle_ratio``），质量判断全交给规则引擎、
用 ``shared/thresholds/`` 里的体育阈值（目前全部 ``pending_review``）。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "ROPE"
ACTION_NAME_ZH = "跳绳"

GROUND = "GROUND"
AIR = "AIR"
CUSHION = "CUSHION"

#: 顺序与 ``preview_poses.dart`` 那三拍、以及 ``action_spec.dart`` 的词表一致。
ROPE_STATES: tuple[str, ...] = (GROUND, AIR, CUSHION)

#: 相位映射。**刻意是空的**，理由见模块文档那一节。
_STATE_TO_PHASE: dict[str, Phase] = {}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 工程参数，不参与「是否判错」的决策，只把 ``delta`` 压成 0–1 供界面排序。
_SEVERITY_SPAN: dict[str, float] = {
    "ROPE_LOW_BUFFER": 30.0,
    "ROPE_TRUNK_LEAN": 15.0,
    "ROPE_SINGLE_LEG": 0.20,
}

#: 「窗口内至少几帧越界才算命中」。
#:
#: **这个值在跳绳上不起作用，写出来是为了不留一个隐含的默认。**
#: ``Rule.min_violating_frames`` 只对 ``Reduce.ANY_FRAME``（逐帧计数的判定）
#: 有意义（见 ``rules.py`` 的那条归约路径）：本动作三条规则全部走 ``MIN`` /
#: ``MAX`` 归约 —— 它们问的是「这一次里最直的那一下有多直」，一次跃迁只产出
#: 一个值，没有「越界帧数」这个东西。
#:
#: 那为什么不是干脆不传？``Rule`` 的默认值是 3。今天它是死的，但只要有人把这
#: 三条里的哪一条改成 ``ANY_FRAME``（比如「躯干前倾改成抖了几帧」），默认值就会
#: 悄悄生效 —— 而 3 帧在跳绳这种十来帧一次的动作里是一道很紧的门槛。
#: 传一个显式的 2，是为了让那一刻的改动者看到这个数，而不是继承一个他没见过的默认。
_MIN_VIOLATING_FRAMES = 2


def _mean_knee(signals: Signals) -> float | None:
    """左右膝角的可用均值。

    一侧被遮挡时退化为另一侧，而不是整体不可用。**分段与判定都不区分左右**：
    单脚落地是**规则**要判的事（``ROPE_SINGLE_LEG``），不是分段条件 ——
    拿它去切段会让「一只脚没看清」变成「这一跳没数上」（同 ``slj.py``）。
    """
    values = [
        v
        for v in (signals.get("knee_angle_L"), signals.get("knee_angle_R"))
        if v is not None
    ]
    return sum(values) / len(values) if values else None


def build_rope(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "oblique45",
) -> ActionDefinition:
    """按工程默认值构建跳绳定义。

    Args:
        calibration: 该用户的站立基线。**只有 ``foot_height`` 用得上** ——
            它是三条分段线的零点（理由见模块文档）。另外两个（膝角、躯干倾角）
            是 ``Calibrator`` 强制要求的量，也是「膝回到站立线」「躯干相对本人
            竖直度」两条判定的参照。
        config: 工程默认值。跳绳会覆盖其中四项（防抖三件套与 ``max_rep_frames``）。
        camera_view: 机位。45° 主链路（同深蹲、立定跳远、俯卧撑、仰卧起坐）。
    """
    # 跳绳的四个工程参数与别的动作都不同，理由逐条：
    #
    # - max_rep_frames = 60（≈2–3 秒）。一次跳绳连起跳带落地约 0.4–0.5 秒
    #   （20–30 fps 下 8–15 帧），60 帧已经是它的四倍。卡住时每一帧 HUD 都顶着
    #   错误的状态词，能短则短（同立定跳远的 120）；但也不能比一次真实跳跃更短，
    #   否则「节奏慢一点」的人会被整组丢弃。
    # - vote_window = 2, vote_required = 2, min_dwell_frames = 1。
    #   **这一组数是被跳绳的节奏逼出来的，不是口味**：状态机每次转移都会清空
    #   全部投票历史，所以每个状态都要**在状态内**重新凑满票 —— 而投票窗口必须
    #   **攒满** vote_window 帧才可能触发，于是每个状态的最短停留就是 vote_window
    #   帧（这里 min_dwell_frames 反而不是约束，1 已经小于 2）。
    #
    #   一个三态环因此最短 3 × 2 = 6 帧。20 fps 下是 0.3 秒一次，合 200 次/分，
    #   在学生 1 分钟跳绳的 100–180 次/分之上留了余量。
    #
    #   **默认那一组（5/4 + 3）会把跳绳数成一半**：每状态要 5 帧才凑满票，
    #   一轮 15 帧 —— 20 fps 下 0.75 秒一次、80 次/分，比大多数人的节奏还慢。
    #   机器于是每隔一次才追上一个转移，而界面上一直显示「双脚着地」，
    #   屏幕上什么错都不报。
    #
    #   取最小值的代价要写清楚：一轮只有 2 帧的防抖，滤不掉连续两帧的关键点
    #   抖动。真机上如果发现**多计**，第一个该调的就是 vote_window
    #   （调到 3 = 每状态 3 帧、一轮 9 帧，20 fps 下 0.45 秒一次、约 133 次/分，
    #   会开始压到跳得快的人）——**不要**去调那三条分段线。
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        max_rep_frames=60,
        min_dwell_frames=1,
        vote_window=2,
        vote_required=2,
    )

    # 三条线共用同一个零点：本人站立时的脚尖高度。
    #
    # **缺席就抛，不取 0**（``Calibration.foot_height`` 是 None 时这里直接炸）：
    # 脚尖高度一旦被当成 0，三条线会全部落在「离画面下缘 0 像素」上，
    # 于是每一帧都被读成「腾空」—— 状态机在 AIR 与 CUSHION 之间空转，
    # 界面上一直显示「腾空」，而屏幕上什么错都不报。
    if calibration.foot_height is None:
        raise ValueError("跳绳需要站立时的脚尖高度基线（foot_height）")
    base = calibration.foot_height

    settle_line = base + cfg.rope_settle_ratio
    land_line = base + cfg.rope_land_ratio
    takeoff_line = base + cfg.rope_takeoff_ratio

    # 膝角回到站立线。「缓冲吃完了」里的后半句，与立定跳远的 LAND→STANDING
    # 同一个形式（stand − standing_hysteresis_deg）。
    stand_line = calibration.knee_angle - cfg.standing_hysteresis_deg

    # 顺序不变式。这三个值全是可调的工程参数，谁把它们调乱，应当**当场炸**，
    # 而不是让状态机悄悄少一条边 —— 那种故障的表现是「计数偶尔不对」，离病因很远。
    if not (settle_line < land_line < takeoff_line):
        raise ValueError(
            f"跳绳的分段线顺序非法，必须 settle(={settle_line}) < "
            f"land(={land_line}) < takeoff(={takeoff_line})。常见成因："
            "把 rope_takeoff_ratio 调到 rope_land_ratio 以下（两条线撞在一起，"
            "AIR 会一闪而过），或把 rope_settle_ratio 调到 rope_land_ratio 以上"
            "（CUSHION 一进去就被封存，落地缓冲那一段又落回窗口之外）。"
        )

    def foot_height(signals: Signals) -> float | None:
        """这一次的脚尖离地量。

        **取不到就返回 ``None``，不能拿 0 顶替** —— 0 在量纲上正是
        「贴着画面下缘」，用它会凭空造出「已经落地」的结论。
        """
        return signals.get("foot_height_ratio")

    def took_off(signals: Signals) -> bool:
        """起跳了：脚尖比站立时高出起跳线。"""
        value = foot_height(signals)
        return value is not None and value > takeoff_line

    def landed(signals: Signals) -> bool:
        """落地了：脚尖回落到落地线以下。

        这是 ``AIR → CUSHION`` 的进入线，**高于** ``settle_line``：
        触地与「站回去」是两件事，中间那一段就是落地缓冲。
        """
        value = foot_height(signals)
        return value is not None and value < land_line

    def recovered(signals: Signals) -> bool:
        """缓冲吃完了：脚尖贴回地面 **且** 膝角回到站立线附近。

        两个条件缺一不可，理由见模块文档：
        只有脚尖 → 触地那一帧就成立，缓冲那一段落在 rep 窗口之外；
        只有膝角 → **腾空时腿本来就是伸直的**，这条在 AIR 里恒真。
        """
        value = foot_height(signals)
        knee = _mean_knee(signals)
        return (
            value is not None and knee is not None and value < settle_line and knee > stand_line
        )

    # 顺序即优先级（状态机契约）。**同一状态的出边两两互斥**：CUSHION 的两条边
    # 相隔 (takeoff_line − settle_line)，一条要求高于前者、一条要求低于后者。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (GROUND, AIR, took_off, "ground->air（起跳）"),
        (AIR, CUSHION, landed, "air->cushion（触地）"),
        (CUSHION, GROUND, recovered, "cushion->ground（封存）"),
        (CUSHION, AIR, took_off, "cushion->air（又跳起来）"),
    )

    rules = (
        # 落地缓冲不足：接不住地，用直腿「砸」下来。这是跳绳最常见的膝踝损伤机制。
        #
        # **整段窗口 + Reduce.MIN + Direction.ABOVE**：取这一次跳里膝角的
        # **最小值**，最小值都还在阈值之上，才叫「全程没屈过膝」。
        # 窗口为什么不切到 CUSHION 上，理由见模块文档（那段只有几帧，
        # 切了反而让最该判的那些人失明）。
        #
        # 指标取左膝，理由同深蹲、俯卧撑、仰卧起坐的同类规则：侧视画面上两条腿
        # 几乎重合，用单侧就够，代价是一侧被挡住时该帧按不可用处理。
        Rule(
            code="ROPE_LOW_BUFFER",
            name_zh="落地缓冲不足",
            metric="knee_angle_L",
            threshold_key="rope.buffer_max_knee_angle",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.MIN,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["ROPE_LOW_BUFFER"],
        ),
        # 躯干前倾：跳的过程中上身越来越往前趴，重心跑到脚前面。
        #
        # **整段最大绝对值**（use_abs + Reduce.MAX）：符号取决于人面朝画面哪一侧，
        # 不是体育含义（同深蹲那一条）。取整段的最大值而不是逐帧计数，问的是
        # 「这一次里有没有一度趴下去过」—— 跳绳的躯干晃动是往复的，
        # 帧计数会把每一次正常的前后摆动都算进去。
        #
        # 相对本人站立基线：有人天生站着就带一点前倾，判决要说的是
        # 「比你自己站着的时候多前倾了多少」。
        Rule(
            code="ROPE_TRUNK_LEAN",
            name_zh="躯干前倾",
            metric="trunk_lean",
            threshold_key="rope.trunk_lean_max_delta",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            use_abs=True,
            reduce=Reduce.MAX,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["ROPE_TRUNK_LEAN"],
        ),
        # 单脚落地（或独脚跳）：两只脚一高一低，落点与缓冲只由一条腿承担。
        #
        # **整段最大值**：``foot_gap_ratio`` 是两只脚尖的高度差，双脚同时起落时
        # 接近 0，一只脚先落或独脚跳时按高度差线性增长。取最大值问的是
        # 「这一次里有没有一度成了单脚」。
        #
        # **绝对阈值，不挂基线**：站稳的人左右脚尖本来就等高（理论上是 0），
        # 挂基线只会得到「0 × 系数 ≈ 0」—— 而这条判的是「差异超过多少算单脚」，
        # 线在 0 附近时每一次落地都会命中。
        Rule(
            code="ROPE_SINGLE_LEG",
            name_zh="单脚落地",
            metric="foot_gap_ratio",
            threshold_key="rope.foot_gap_max_ratio",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.MAX,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["ROPE_SINGLE_LEG"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=ROPE_STATES,
        # 双脚都落在地上。这是唯一一个「resting_state 就是人平时站着的姿势」
        # 的动作 —— 其余四个的 resting_state 都是某个动作位。
        resting_state=GROUND,
        # 腾空：没跳起来的那一次**不算一次**。取 CUSHION 的话，
        # 一次原地提踵就会被计成一次跳绳。
        bottom_state=AIR,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        threshold_offsets={"rope.trunk_lean_max_delta": ("trunk_lean", 1.0)},
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "AIR",
    "CUSHION",
    "GROUND",
    "ROPE_STATES",
    "build_rope",
]
