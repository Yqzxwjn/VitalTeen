"""立定跳远动作定义。

与 ``app/lib/domain/exercises/slj.dart`` 一一对应，**数值逐位相同**。

**状态链**::

    STANDING ──→ PREP ──→ LAUNCH ──→ FLIGHT ──→ LAND ──→ STANDING
                    ↑          │
                    └──────────┘
                    （回蹲：蹬伸到一半又蹲回去，
                      否则 LAUNCH 会变成走不出去的死角）

与深蹲那条链同一个理由：只写「一路向前」的边，用户没沿预期路径走时状态机会
**卡在中间状态出不来**，既不计数也不丢弃。回退边是正确性的一部分。

**为什么没有 DIP 状态**：一个 8° 就进的「起势」状态能把「站着晃一下」也记成一次
尝试，但 ``RepTracker`` 从**离开静止态**那一帧就开始建缓冲，于是小晃动会变成
``discarded_reps`` 往上跳，而界面只能解释说「有 N 次没计入」—— 用户站着没跳，
却被告知丢了 N 次。用一个 25° 的进入线让晃动根本不离开 STANDING。

**机位**：45° 斜向，而且不是可选项。正视机位下 ``heel_rise_ratio_*`` 声明的是
``views: [sagittal, oblique45]``，标定会**静默卡死** —— ``Calibrator.feed``
永远拿不到它要的特征，返回 ``None`` 到天荒地老，界面上表现为「一直在标定」。
因此本模块的 ``camera_view`` 默认值就是 ``oblique45``。

**一条被刻意去掉的边：没有 ``LAUNCH → LAND``**

「起跳了但没蹬直就屈膝」看起来很自然，但它**在进入 LAUNCH 的那一帧就恒真**：
LAUNCH 的进入线（``stand − 25 + 8``）本来就低于落地线（``stand − 12``），
所以「当前膝角 < 落地线」一进 LAUNCH 便成立。而守卫是只看一帧信号的纯函数
（``state_machine.Guard``）—— **看不见时间**，表达不了「先蹬上去、再落下来」这个
次序。

代价说清楚：**没蹬到近乎伸直的一跳不会被计数**（停在 LAUNCH/FLIGHT 直到
``max_rep_frames``，然后被 ``RepTracker`` 丢弃并复位）。这是朝着安全方向的损失 ——
少计一次，而不是凭空多出一次。旋钮是 ``TrackingConfig.flight_extension_deg``：
真机上发现漏计偏多就调大它，**不要加边**。

去掉它换来一个更值钱的东西：``_reached_bottom`` 只在进入 LAND 时置位，而 LAND
只能从 FLIGHT 来、FLIGHT 只能从 LAUNCH 来、LAUNCH 只能从 PREP 来 —— 于是
**每一个被封存的 rep 都必定同时有 prep/takeoff/flight/landing 四个相位区间**，
``RepWindow.select`` 那条「相位缺失就退化成整段」的静默误判路径在本动作上走不到。

**分段阈值全部是个体化 + 工程参数，不含体育阈值**

- 站立基线 ``stand`` 来自该用户自己的校准
- ``min_bend_deg``（取 25）是「弯多少度才算有意下蹲」的**分段**决策
- ``flight_extension_deg`` / ``landing_flex_deg`` / ``landing_hip_floor``
  都是分段的**工程**决策

至于「落地缓冲够不够」「双脚同不同步」这类**质量**判断，全部交给规则引擎，
用 ``shared/thresholds/`` 里的体育阈值（目前全部待核定，只会产出提示）。
"""

from __future__ import annotations

from ..features import CameraView
from ..rules import Direction, Phase, Reduce, Rule
from ..state_machine import Guard, Signals, Transition
from .base import ActionDefinition, Calibration, TrackingConfig

ACTION_CODE = "SLJ"
ACTION_NAME_ZH = "立定跳远"

STANDING = "STANDING"
PREP = "PREP"
LAUNCH = "LAUNCH"
FLIGHT = "FLIGHT"
LAND = "LAND"

SLJ_STATES: tuple[str, ...] = (STANDING, PREP, LAUNCH, FLIGHT, LAND)

#: 相位映射。
#:
#: 四个非静止状态**全部**有映射，没有孤儿 —— 不存在一个「状态机走过了、
#: 但规则引擎看不到」的区间。
_STATE_TO_PHASE: dict[str, Phase] = {
    PREP: Phase.PREP,
    LAUNCH: Phase.TAKEOFF,
    FLIGHT: Phase.FLIGHT,
    LAND: Phase.LANDING,
}

#: 严重度归一化的跨度：超出阈值多少算「满严重度」。
#:
#: 这是**工程参数**，不是体育阈值 —— 它不参与「是否判错」的决策（那由阈值表决定），
#: 只把 ``delta`` 压成 0–1 供 UI 排序与展示，可按实际观感调整。
_SEVERITY_SPAN: dict[str, float] = {
    "SLJ_PREJUMP_HEEL_OFF": 0.15,
    "SLJ_TAKEOFF_ASYNC": 0.10,
    "SLJ_LAND_ASYNC": 0.10,
    "SLJ_LAND_STIFF": 30.0,
    "SLJ_TRUNK_CONTROL": 15.0,
}

#: 姿态类规则在窗口内至少需要多少帧越界才判命中。
#:
#: 取 2 是为了滤掉单帧关键点抖动 —— 单帧误判会让用户看到「被告知了一个他并没有
#: 犯的错误」，比漏判更伤害信任。与深蹲的姿态类规则同一个取值。
_MIN_VIOLATING_FRAMES = 2


def _mean_knee(signals: Signals) -> float | None:
    """左右膝角的可用均值。

    一侧被遮挡时退化为另一侧，而不是整体不可用。注意**分段不区分左右**：
    单腿发力是**规则**要判的事（``SLJ_TAKEOFF_ASYNC``），不是分段条件 ——
    拿它去切段会让「一只脚没看清」变成「这一跳没数上」。
    """
    values = [
        v for v in (signals.get("knee_angle_L"), signals.get("knee_angle_R")) if v is not None
    ]
    return sum(values) / len(values) if values else None


def build_slj(
    calibration: Calibration,
    *,
    config: TrackingConfig | None = None,
    camera_view: CameraView = "oblique45",
) -> ActionDefinition:
    """按本人的站立基线构建立定跳远定义。

    Args:
        calibration: 该用户的站立基线。
        config: 工程默认值。默认按 45° 斜机位构造。
        camera_view: 机位。默认 45° 斜向，理由见模块文档。
    """
    cfg = config or TrackingConfig(
        camera_view=camera_view,
        min_bend_deg=25.0,
        max_rep_frames=120,
    )

    stand = calibration.knee_angle
    hysteresis = cfg.standing_hysteresis_deg

    # 五条线，全部落在膝角一根轴上。**相对站立基线**，所以体型差异不进来。
    bend_line = stand - cfg.min_bend_deg
    rise_line = bend_line + hysteresis
    land_line = stand - cfg.landing_flex_deg
    stand_line = stand - hysteresis
    fly_line = stand - cfg.flight_extension_deg

    # 顺序不变式。这几个值全是可调的工程参数，谁把它们调乱，应当**当场炸**，
    # 而不是让状态机悄悄少一条边（或者多一条一进新状态就立刻触发的边）——
    # 那种故障的表现是「计数偶尔不对」，离病因非常远。
    if not (bend_line < rise_line < land_line < stand_line < fly_line):
        raise ValueError(
            f"立定跳远的分段线顺序非法，必须 bend(={bend_line}) < rise(={rise_line}) "
            f"< land(={land_line}) < stand(={stand_line}) < fly(={fly_line})。"
            "常见成因：landing_flex_deg 小于等于 standing_hysteresis_deg（落地线与"
            "站立线撞在一起，LAND 会一闪而过），或 flight_extension_deg 太大"
            "（腾空线落到落地线以下）。"
        )

    def crouched(signals: Signals) -> bool:
        """有意下蹲：膝角弯到前蹲线以下。也是 ``LAUNCH → PREP`` 的回蹲条件。"""
        knee = _mean_knee(signals)
        return knee is not None and knee <= bend_line

    def pushing_off(signals: Signals) -> bool:
        """蹬伸开始：从前蹲线回升超过滞回带。与 :func:`crouched` 相隔 8°。"""
        knee = _mean_knee(signals)
        return knee is not None and knee > rise_line

    def extended(signals: Signals) -> bool:
        """蹬直 ≈ 离地。

        **这是代理量** —— 没有任何特征能证明人真的离了地（单目无世界坐标，
        设计文档附录 A）。它同时也是漏计的旋钮。
        """
        knee = _mean_knee(signals)
        return knee is not None and knee > fly_line

    def absorbing(signals: Signals) -> bool:
        """落地缓冲：屈膝到落地线以下，**且髋中点还在膝中点上方**。

        后半句是收腿剔除。收腹举腿是正规技术，腾空中膝盖会折到胸口，膝中点跑到
        髋中点上方，``hip_height_ratio`` 变负 —— 不挡的话这一条会在半空中触发，
        ``Phase.LANDING`` 就变成那一段收腿，而落地缓冲判的正是 landing 上膝角的
        **最小值**：收腿越标准越被判成缓冲充足，一条永远不再触发的规则。

        门槛取绝对值（0.2）而不是「本人站立值的某个比例」：该特征已经用躯干长
        归一过，个体差异在算式里就消掉了。落地屈膝那一刻实测约 0.85，收腿时为负。
        """
        knee = _mean_knee(signals)
        hip = signals.get("hip_height_ratio")
        return (
            knee is not None
            and hip is not None
            and knee < land_line
            and hip > cfg.landing_hip_floor
        )

    def returned_to_standing(signals: Signals) -> bool:
        """回到站立：膝角回到基线附近。回到这里就封存一次 rep。"""
        knee = _mean_knee(signals)
        return knee is not None and knee > stand_line

    # 顺序即优先级（状态机契约）。**同一状态的出边两两互斥**，逐条核对过：
    #   LAUNCH 的两条边相隔 21°（≤150 与 >171），谁也不会在进入的那一帧成立；
    #   PREP 只有一条出边，LAND 只有一条，FLIGHT 只有一条。
    # 进入新状态到它的出边成立之间至少隔着 4°（LAND→STANDING）——
    # 这就是为什么 landing_flex_deg 必须严格大于 standing_hysteresis_deg。
    guards: tuple[tuple[str, str, Guard, str], ...] = (
        (STANDING, PREP, crouched, "standing->prep（起势）"),
        (PREP, LAUNCH, pushing_off, "prep->launch（蹬伸）"),
        (LAUNCH, PREP, crouched, "launch->prep（回蹲）"),
        (LAUNCH, FLIGHT, extended, "launch->flight（蹬直≈离地）"),
        (FLIGHT, LAND, absorbing, "flight->land（落地缓冲）"),
        (LAND, STANDING, returned_to_standing, "land->standing（封存）"),
    )

    rules = (
        # 起跳前前掌离地。问的是「蓄力段有没有**持续**出现足部离地姿态」——
        # 姿态类问题，因此按越界帧数计，而不是取极值。
        #
        # use_abs + 基线偏移是一处**幅度代理**：错误码叫 HEEL_OFF（脚跟）、
        # 中文名叫「前掌离地」，两者指向相反方向，而特征只对「脚跟抬升」有符号。
        # 取绝对值再与本人站立基线比，一次覆盖两个方向。**码名与中文名的方向
        # 不一致是有意的**，别去「修」其中一个。
        Rule(
            code="SLJ_PREJUMP_HEEL_OFF",
            name_zh="起跳前前掌离地",
            metric="heel_rise_ratio_L",
            threshold_key="slj.prejump_foot_off_max_delta",
            bad_side=Direction.ABOVE,
            phase=Phase.PREP,
            use_abs=True,
            min_violating_frames=_MIN_VIOLATING_FRAMES,
            severity_span=_SEVERITY_SPAN["SLJ_PREJUMP_HEEL_OFF"],
        ),
        # 起跳双脚不同步。问的是「两只脚有没有在**某个瞬间**明显不同步」——
        # 瞬态事件，取窗口内最坏的一帧，所以是 MAX 而不是帧计数。
        # 单帧尖峰由引擎自带的 confidence（越界帧占比 × 有效帧占比）兜住。
        #
        # 判据是**膝角对称指数**，这是「双脚是否同时发力离地」的**代理量**：
        # 单目无足底接触测量，也无从确认离地时刻。
        Rule(
            code="SLJ_TAKEOFF_ASYNC",
            name_zh="起跳双脚不同步",
            metric="knee_symmetry",
            threshold_key="slj.takeoff_symmetry_max",
            bad_side=Direction.ABOVE,
            phase=Phase.TAKEOFF,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["SLJ_TAKEOFF_ASYNC"],
        ),
        # 落地双脚不同步。同上，只是窗口换成落地段 —— 单脚先触地表现为两膝不对称。
        Rule(
            code="SLJ_LAND_ASYNC",
            name_zh="落地双脚不同步",
            metric="knee_symmetry",
            threshold_key="slj.landing_symmetry_max",
            bad_side=Direction.ABOVE,
            phase=Phase.LANDING,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["SLJ_LAND_ASYNC"],
        ),
        # 落地缓冲不足。问的是「缓冲**最深的那个点**够不够屈膝」——极值问题，
        # 取窗口内膝角的最小值。方向是 ABOVE：**最小值仍然偏大**才算没缓冲。
        #
        # 这里若改用帧计数（ANY_FRAME），落地前后那些过渡帧会全部算作越界，
        # 结果是**每一次落地都被误判**，正是深蹲 INSUFFICIENT_DEPTH 注释里
        # 警告过的那个错误。
        Rule(
            code="SLJ_LAND_STIFF",
            name_zh="落地缓冲不足",
            metric="knee_angle_L",
            threshold_key="slj.landing_buffer_min_knee_angle",
            bad_side=Direction.ABOVE,
            phase=Phase.LANDING,
            reduce=Reduce.MIN,
            severity_span=_SEVERITY_SPAN["SLJ_LAND_STIFF"],
        ),
        # 躯干控制不足。问的是「蹬伸段躯干偏离本人的最坏值超没超」，取极值。
        # use_abs：符号取决于人面朝画面哪一侧，不是体育含义。
        Rule(
            code="SLJ_TRUNK_CONTROL",
            name_zh="躯干控制不足",
            metric="trunk_lean",
            threshold_key="slj.trunk_lean_max_delta",
            bad_side=Direction.ABOVE,
            phase=Phase.TAKEOFF,
            use_abs=True,
            reduce=Reduce.MAX,
            severity_span=_SEVERITY_SPAN["SLJ_TRUNK_CONTROL"],
        ),
    )

    return ActionDefinition(
        code=ACTION_CODE,
        name_zh=ACTION_NAME_ZH,
        camera_view=camera_view,
        states=SLJ_STATES,
        resting_state=STANDING,
        # LAND 而不是 LAUNCH：一次「蹲下去又站起来」必须**不**被计成跳跃，
        # 而它与真跳的唯一区别就是有没有落地缓冲。
        bottom_state=LAND,
        transitions=tuple(
            Transition(src, dst, guard, label=label) for src, dst, guard, label in guards
        ),
        rules=rules,
        state_to_phase=dict(_STATE_TO_PHASE),
        # 出画多半就发生在蹬伸到腾空那几帧，而「蹬直」这条线只比站立低 4° ——
        # 这几帧没被看见，状态机就停在 LAUNCH，回来那一下蹲会被读成**回蹲**，
        # 一次真跳连同一次本来看得见的落地一起被丢掉。
        #
        # 只登记 LAUNCH→FLIGHT，**不登记 LAUNCH→LAND**：前者只是承认「蹬伸那几帧
        # 没看见，人已经在空中了」，落地仍然要靠看得见的蹲下来认定；后者会封存
        # 一次落地没被看见的 rep，拿人走回来的那几帧去评落地缓冲 —— 那是编分数。
        loss_recovery={LAUNCH: FLIGHT},
        # 这两条规则的判据是「相对本人站立基线的增量」，而规则引擎只做
        # 「指标 vs 阈值」的直接比较，因此在查表时把基线加回去。
        threshold_offsets={
            "slj.prejump_foot_off_max_delta": ("heel_rise_ratio", 1.0),
            "slj.trunk_lean_max_delta": ("trunk_lean", 1.0),
        },
    )


__all__ = [
    "ACTION_CODE",
    "ACTION_NAME_ZH",
    "FLIGHT",
    "LAND",
    "LAUNCH",
    "PREP",
    "SLJ_STATES",
    "STANDING",
    "build_slj",
]
