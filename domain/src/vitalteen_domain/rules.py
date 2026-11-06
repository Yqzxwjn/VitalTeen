"""错误规则引擎。

把「一次 rep 的逐帧特征」判定为若干条 :class:`Fault`，供组级聚合与决策层消费。

**本模块不含任何体育数值。** 所有阈值通过 :class:`~vitalteen_domain.thresholds.ThresholdTable`
查找，规则定义里只写阈值键名。这不是洁癖 —— 混进来的第一个硬编码数字会被
下一个维护者当成「国标规定」，然后写进答辩材料。

**未核定的阈值只能产出「提示」。** 若规则引用的阈值 ``source_type`` 是
``pending_review``，产出的 :class:`Fault` 会带 ``scorable=False``，不参与组级
扣分。这是把「我们不知道学生群体的准确切点」这一事实诚实地传导到产品行为，
而不是编一个数字装作知道。

判定模型
--------

统一为「**在指定相位窗口内，越界帧数达到下限即判命中**」。

之所以不用「整个窗口的极值越界就命中」：那会让一个 60 帧的 rep 被单帧抖动
判成错误，而姿态关键点的单帧抖动是常态（见设计文档 §3）。要求连续或累计
若干帧越界，是把「持续性的动作缺陷」和「一次噪声」区分开的最小代价手段。

而「下蹲深度不足」这类看似特殊的规则，并不需要单独的判定逻辑 —— 它靠
**相位窗口**归位：只在 ``BOTTOM`` 相位求值。BOTTOM 由状态机按局部极小值切分
（不使用任何绝对阈值，因此不存在循环依赖），一个站直的人其 BOTTOM 相位的
膝角同样高于深度线，自然命中。这样两类规则统一成了一个模型。
"""

from __future__ import annotations

import statistics
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from types import MappingProxyType

from .features import FrameFeatures
from .thresholds import ThresholdTable


class Phase(StrEnum):
    """rep 内的相位。规则只在指定相位上求值。

    两套相位名并存而不是合成一份通用词表：相位的语义由动作决定，
    「下蹲」与「蹬伸」不是同一个东西换了个词，硬凑一份反而要让每个动作
    解释自己为什么借用了别人的词。加成员是安全的 —— 没有任何一处对
    ``Phase`` 做穷尽分支，只有 ``== Phase.ALL`` 的比较。

    与 ``app/lib/domain/rules.dart`` 的 ``Phase`` 逐值对应。
    """

    ALL = "all"
    """全部帧（不做相位切分）。"""

    STAND = "stand"
    """深蹲：站立段（rep 缓冲从离开它开始，因此不出现在已封存的 rep 里）。"""

    DESCENT = "descent"
    """深蹲与仰卧起坐：向最低点去的那一段（下蹲 / 躺下）。

    两者共用不是巧合：仰卧起坐的状态环与深蹲**同形** —— 都有一个中立位、
    一个最低点、两侧各一段行程。差别只在最低点是蹲姿还是躺在垫上，而那点差别
    由各自的判定去说，不需要两个只是名字不同的相位。**刻意不为仰卧起坐新加
    成员**：当年开合跳单独立了 ``CONTACT`` 是因为语义确实不同（一段是缓冲深度、
    一段是额状面朝向），这里不是。
    """

    BOTTOM = "bottom"
    """深蹲与仰卧起坐：最低点（蹲底 / 仰卧贴垫）。

    仰卧起坐的一条判定跑在这一段上：「肩胛有没有贴垫」看肩上高度在这段里的
    **最小值** —— 它离开躺姿就无从谈起，落在 ``ASCENT`` / ``ALL`` 上评的都是
    别的东西。
    """

    ASCENT = "ascent"
    """深蹲与仰卧起坐：从最低点起来的那一段（起身 / 坐起）。"""

    PREP = "prep"
    """立定跳远：预蹲蓄力。"""

    TAKEOFF = "takeoff"
    """立定跳远：蹬伸发力（起跳）。"""

    FLIGHT = "flight"
    """立定跳远：腾空。"""

    LANDING = "landing"
    """立定跳远：落地缓冲。"""

    CONTACT = "contact"
    """开合跳：**触地那一刻**及其后的合拢段。

    与 ``LANDING`` 刻意分开，虽然两者都发生在落地前后：``LANDING`` 的语义是
    「触地之后的**屈曲缓冲**」（它判的是这一段上膝角的最小值），而开合跳要判的是
    「脚落下来时膝盖朝哪边」—— 一段是缓冲深度，一段是额状面的朝向，
    不是同一件事换了个词。合成一个成员会让下一个人以为两条规则在问同一个问题。
    """

    APEX = "apex"
    """引体向上：**拉到顶的那一段**（身体最高的那一刻）。

    与 ``BOTTOM`` 是同一个角色的两个方向：那个成员是「动作的极端」，只是
    深蹲/俯卧撑/仰卧起坐的极端都在最低处，而引体向上的极端在最高处。
    **不能借用 BOTTOM**：它的文档、它的名字、以及三条已经跑在它上面的规则
    说的都是「最低点」，把引体向上的顶点塞进去，下一个人读规则时会以为
    那一段是身体最低的时候 —— 而 ``PULLUP_CHIN_NOT_OVER`` 恰恰是唯一一条
    必须在「读不到就不判」这一点上切窗口的规则，窗口切错不会报错，
    只会让判定换个意思。

    **相位窗口的边界不是精确的，这一点对每一个成员都成立**：跨度记的是状态机
    **确认**换相的那一帧，而确认要经过驻留与投票（``min_dwell_frames`` 与投票
    窗口），所以窗口的尾巴上通常还带着几帧**已经属于下一段**的数据。
    对大多数规则这无关紧要（相邻两段的量本来就连续），但凡是把「这一段读不到」
    当成结论的规则 —— 目前只有 ``PULLUP_CHIN_NOT_OVER`` —— 就必须知道：
    遮挡要盖过窗口的尾巴才算真的读不到。见 ``pullup.py`` 模块文档。
    """


class Direction(StrEnum):
    """指标偏向哪一侧算越界。"""

    ABOVE = "above"
    BELOW = "below"


class Reduce(StrEnum):
    """在相位窗口内如何把逐帧指标归约成一个判定依据。

    **为什么需要区分**：两类错误在语义上完全不同，用一个模型套是错的。

    - ``ANY_FRAME`` 回答「**有没有持续出现**某个错误姿态」——膝内扣、躯干前倾
      属于这一类。单帧抖动不足以判错，因此按越界帧数计数。
    - ``MIN`` / ``MAX`` 回答「**有没有达到某个位置**」——下蹲深度属于这一类。
      它问的是整次动作的**最低点**，而不是逐帧都合格。若用 ``ANY_FRAME`` 判深度，
      下降与回升的过渡帧（膝角从 135° 扫到 90° 再回到 143°）会全部被算作越界，
      结果是**每一个动作都被误判为深度不足**。
    """

    ANY_FRAME = "any_frame"
    """越界帧数达到 ``min_violating_frames`` 即判命中。"""

    MIN = "min"
    """取窗口内最小值与阈值比较（用于「必须达到」类判据）。"""

    MAX = "max"
    """取窗口内最大值与阈值比较。"""

    MEDIAN = "median"
    """取窗口中位数与阈值比较（对单帧抖动不敏感）。"""

    REVERSALS = "reversals"
    """窗口内相邻帧差分的**符号翻转次数**（带 ``REVERSAL_DEADBAND`` 的死区）。

    前四个归约都是「从这个窗口里挑一个代表值，再拿它跟阈值比」。弹振借力
    不是这么坏的：坐位体前屈里靠弹振够距离的人，**前伸到底那一刻的角度
    可能是够的**（弹的那一下比慢慢够得更远），坏的是过程 —— 一伸一缩一伸一缩。
    它的证据是**序列的形状**，不是任何一个极值，所以 MIN/MAX/MEDIAN 都看不见它。
    """


REVERSAL_DEADBAND = 2.0
"""``Reduce.REVERSALS`` 的死区，单位与该指标一致（度）。

**工程默认值，真机标定后再定。** 见 ``count_reversals``。
"""


def count_reversals(
    values: Sequence[float], *, deadband: float = REVERSAL_DEADBAND
) -> int:
    """数窗口里序列**掉头**了几次：相邻两步方向相反即算一次。

    步长不超过 ``deadband`` 的那一步忽略 —— 没有死区的话，匀速前伸时的读数
    抖动也会被数成几十次翻转。第一步只用来定初始方向，不计入，否则一段
    「先升后降」的平稳序列会得到 1 次翻转，而它显然不是弹振。
    """
    reversals = 0
    last_sign = 0
    for previous, current in zip(values, values[1:]):
        delta = current - previous
        if abs(delta) <= deadband:
            continue
        sign = 1 if delta > 0 else -1
        if last_sign != 0 and sign != last_sign:
            reversals += 1
        last_sign = sign
    return reversals


@dataclass(frozen=True, slots=True)
class Deviation:
    """一次偏离的量化描述，直接对应决策层请求体里的 ``deviations`` 字段。"""

    feature: str
    measured: float
    """窗口内**最严重**的越界值（越界方向上的极值），而非均值 —— 报告应反映最坏情况。"""

    threshold: float
    delta_signed: float
    severity_0_1: float | None
    """0–1 的严重度。``None`` 表示规则未定义 ``severity_span``，无法归一。"""


@dataclass(frozen=True, slots=True)
class Fault:
    """一条错误判定。"""

    code: str
    name_zh: str
    scorable: bool
    """``False`` 表示所依据的阈值尚未经体育专业成员核定 —— 只出提示、不计扣分。"""

    confidence: float
    evidence_timestamps: tuple[int, ...]
    deviation: Deviation


@dataclass(frozen=True, slots=True)
class Rule:
    """一条错误规则定义。

    Args:
        metric: 依据的特征码，例如 ``"knee_angle_L"``。
        threshold_key: 阈值表中的键。**规则里不写数值。**
        bad_side: 指标越过阈值的哪一侧算越界。
        phase: 只在 rep 的这个相位上求值。
        use_abs: 是否先取绝对值再比较（用于躯干前倾这类带符号量，
            其符号取决于人在画面里面朝哪一侧，不是体育含义）。
        reduce: 窗口内的归约方式，决定这类错误「问的是什么问题」。见 :class:`Reduce`。
        min_violating_frames: 仅对 ``Reduce.ANY_FRAME`` 有意义 ——
            越界帧数下限，低于此数判为噪声、不产出错误。
        severity_span: 越界超过多少算「满严重度」。``None`` 表示不归一。
    """

    code: str
    name_zh: str
    metric: str
    threshold_key: str
    bad_side: Direction
    phase: Phase = Phase.ALL
    use_abs: bool = False
    reduce: Reduce = Reduce.ANY_FRAME
    min_violating_frames: int = 3
    severity_span: float | None = None

    def __post_init__(self) -> None:
        """构造期校验。

        参数错误应在定义动作时立刻暴露，而不是等运行到某个特定数据组合上才炸 ——
        那时错误现场离病因已经很远了（``state_machine`` 对同类参数也是构造期校验）。
        """
        if self.min_violating_frames < 1:
            raise ValueError(
                f"规则 {self.code} 的 min_violating_frames 必须 >= 1，"
                f"实际为 {self.min_violating_frames}。取 0 会让「零越界帧」也越过帧数"
                "门槛，随后在对空序列取极值时抛 ValueError。"
            )
        if self.severity_span is not None and self.severity_span <= 0:
            raise ValueError(
                f"规则 {self.code} 的 severity_span 必须为正数或 None，"
                f"实际为 {self.severity_span}。非正值会让 severity_0_1 落到 0–1 之外："
                "负 span 产出负严重度，0 则被真值判断静默当成「不归一」。"
            )


def _no_bounds() -> Mapping[Phase, tuple[int, int]]:
    """空相位表。

    必须是工厂函数而非直接写 ``MappingProxyType({})`` 作默认值 —— dataclasses
    会把 mappingproxy 判定为可变默认值并拒绝，无论它实际上是只读的。
    """
    return MappingProxyType({})


@dataclass(frozen=True, slots=True)
class RepWindow:
    """一次 rep 的帧与相位边界。

    这是规则引擎与状态机之间的**唯一接缝**：状态机负责切分相位，规则引擎只消费
    切好的窗口。如此两边可以各自测试，互不依赖对方的内部实现。
    """

    index: int
    frames: tuple[FrameFeatures, ...]
    phase_bounds: Mapping[Phase, tuple[int, int]] = field(default_factory=_no_bounds)
    """相位 → 帧索引的闭区间 ``(start, end)``。缺失的相位退化为整段。"""

    def select(self, phase: Phase) -> tuple[FrameFeatures, ...]:
        if phase is Phase.ALL or phase not in self.phase_bounds:
            return self.frames
        start, end = self.phase_bounds[phase]
        return self.frames[max(start, 0) : end + 1]

    @property
    def duration_ms(self) -> int:
        """一次 rep 的时长（毫秒），由首末帧时间戳推出。

        **放在 rep 窗口自己身上，而不是各调用点各算一遍**（Dart 侧逐字对应）。
        它有两个消费者：决策请求里的 ``duration_ms``，与界面上的计时
        （平板支撑的「这一段撑了多久」）。两处各写一遍的话，哪天有人给其中一处
        加个边界条件（比如扣掉第一帧），屏幕上就会出现「计时器说 40.0 秒、
        请求里写 39.9 秒」这种**没有任何地方报错**的分歧。

        帧数少于 2 时无法得出时长，返回 0 —— 「不知道」在这里没有第三种表达方式，
        而契约要求非负整数。调用方应结合 rep 数判断该值是否可用
        （``_mean_tempo_ms`` 就是这么做的）。时间戳回退同样收敛到 0。
        """
        if len(self.frames) < 2:
            return 0
        return max(0, self.frames[-1].timestamp_ms - self.frames[0].timestamp_ms)


class RuleEngine:
    """按规则集判定单个 rep，并可汇总到组级。

    Args:
        rules: 规则集。
        thresholds: 阈值表。引擎按 ``threshold_key`` 查值，并对未核定的阈值
            自动降级为不可扣分。
    """

    def __init__(self, rules: Sequence[Rule], thresholds: ThresholdTable) -> None:
        self.rules = tuple(rules)
        self.thresholds = thresholds

    def evaluate_rep(self, window: RepWindow) -> tuple[Fault, ...]:
        """判定单个 rep，返回命中的错误。未命中返回空元组。"""
        return tuple(
            fault for rule in self.rules if (fault := self._evaluate(rule, window)) is not None
        )

    def _evaluate(self, rule: Rule, window: RepWindow) -> Fault | None:
        frames = window.select(rule.phase)

        # 逐帧取值。不可用的帧直接跳过，绝不填 0 —— 见设计文档铁律二。
        # 一个编造出来的 0 度膝角会被当成「膝盖完全对折」，比缺失危险得多。
        samples: list[tuple[int, float]] = []
        for f in frames:
            value = f.get(rule.metric) if f.is_valid(rule.metric) else None
            if value is None:
                continue
            samples.append((f.timestamp_ms, abs(value) if rule.use_abs else value))

        if not samples:
            return None

        threshold = self.thresholds.get(rule.threshold_key)
        limit = threshold.value

        violating = [(ts, v) for ts, v in samples if _is_violation(v, limit, rule.bad_side)]

        if rule.reduce is Reduce.ANY_FRAME:
            # 「有没有持续出现」：越界帧太少判为噪声
            if len(violating) < rule.min_violating_frames:
                return None
            # 报告最坏情况：越界帧中的极值
            worst = (
                max(v for _, v in violating)
                if rule.bad_side is Direction.ABOVE
                else min(v for _, v in violating)
            )
        else:
            # 「有没有达到某个位置」：先归约再判定。此时 min_violating_frames 不适用 ——
            # 一次动作只有一个最低点，不存在「多少帧达到」的问题。
            values = [v for _, v in samples]
            worst = _reduce(values, rule.reduce)
            if not _is_violation(worst, limit, rule.bad_side):
                return None

        delta = worst - limit
        severity = (
            min(abs(delta) / rule.severity_span, 1.0) if rule.severity_span else None
        )

        # 置信度 = 越界帧占比 × 有效帧占比。
        # 两个因子都不可省：前者低说明是偶发抖动，后者低说明数据本身不可信
        # （关键点被遮挡或漏检），此时即使全帧越界也不该高置信。
        coverage = len(violating) / len(samples)
        validity = len(samples) / len(frames) if frames else 0.0

        return Fault(
            code=rule.code,
            name_zh=rule.name_zh,
            scorable=threshold.may_drive_scoring,
            confidence=round(coverage * validity, 4),
            evidence_timestamps=tuple(ts for ts, _ in violating),
            deviation=Deviation(
                feature=rule.metric,
                measured=round(worst, 4),
                threshold=limit,
                delta_signed=round(delta, 4),
                severity_0_1=None if severity is None else round(severity, 4),
            ),
        )

    def evaluate_set(self, windows: Sequence[RepWindow]) -> SetSummary:
        """组级聚合：统计各错误在整组 reps 中的出现情况。

        决策层的输入正是这份汇总 —— 它不关心某一次 rep 的第 137 帧发生了什么。
        """
        per_rep = [self.evaluate_rep(w) for w in windows]

        counts: dict[str, int] = {}
        reps: dict[str, list[int]] = {}
        worst_delta: dict[str, float] = {}
        scorable: dict[str, bool] = {}
        names: dict[str, str] = {}

        for window, faults in zip(windows, per_rep, strict=True):
            seen: set[str] = set()
            for fault in faults:
                code = fault.code
                names[code] = fault.name_zh
                scorable[code] = fault.scorable
                delta = abs(fault.deviation.delta_signed)
                worst_delta[code] = max(worst_delta.get(code, 0.0), delta)
                # 同一 rep 内重复命中同一错误只计一次，否则「出现率」会虚高
                if code in seen:
                    continue
                seen.add(code)
                counts[code] = counts.get(code, 0) + 1
                reps.setdefault(code, []).append(window.index)

        total = len(windows)
        stats = tuple(
            FaultStat(
                code=code,
                name_zh=names[code],
                scorable=scorable[code],
                count=counts[code],
                rate=round(counts[code] / total, 4) if total else 0.0,
                rep_indices=tuple(reps.get(code, ())),
                worst_delta=round(worst_delta.get(code, 0.0), 4),
            )
            for code in sorted(counts)
        )
        return SetSummary(rep_count=total, fault_stats=stats)


@dataclass(frozen=True, slots=True)
class FaultStat:
    """组级统计中的一个错误码。"""

    code: str
    name_zh: str
    scorable: bool
    count: int
    rate: float
    rep_indices: tuple[int, ...]
    worst_delta: float


@dataclass(frozen=True, slots=True)
class SetSummary:
    """组级判定汇总。"""

    rep_count: int
    fault_stats: tuple[FaultStat, ...]

    @property
    def scorable_faults(self) -> tuple[FaultStat, ...]:
        """可用于扣分的错误。未核定阈值产生的不在其中。"""
        return tuple(s for s in self.fault_stats if s.scorable)

    @property
    def notices(self) -> tuple[FaultStat, ...]:
        """仅供提示、不可扣分的项（阈值未核定）。"""
        return tuple(s for s in self.fault_stats if not s.scorable)

    def primary_fault(self) -> FaultStat | None:
        """出现率最高的错误。仅作为**规则层的建议**，最终主问题由决策层选择
        （见设计文档 §6.1：主问题选择是决策层的 Choice 职责）。"""
        if not self.fault_stats:
            return None
        return max(self.fault_stats, key=lambda s: (s.rate, s.worst_delta))


def _reduce(values: Sequence[float], how: Reduce) -> float:
    match how:
        case Reduce.MIN:
            return min(values)
        case Reduce.MAX:
            return max(values)
        case Reduce.MEDIAN:
            return statistics.median(values)
        case Reduce.REVERSALS:
            return float(count_reversals(values))
        case _:
            raise ValueError(f"_reduce 不支持 {how}；ANY_FRAME 不走归约路径")


def _is_violation(value: float, threshold: float, bad_side: Direction) -> bool:
    return value > threshold if bad_side is Direction.ABOVE else value < threshold


__all__ = [
    "REVERSAL_DEADBAND",
    "Deviation",
    "Direction",
    "Fault",
    "FaultStat",
    "Phase",
    "Reduce",
    "RepWindow",
    "Rule",
    "RuleEngine",
    "SetSummary",
    "count_reversals",
]
