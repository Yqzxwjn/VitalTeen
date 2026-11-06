"""通用动作状态机引擎（L3 状态级防抖）。

把「一帧帧的特征信号」变成「稳定的动作相位」。深蹲、俯卧撑、开合跳等所有动作共享
同一套骨架：动作差异（状态图 + 各转移条件）全部由调用方以 ``Transition`` 列表声明，
新增动作 = 新增一组转移，不改引擎（docs/domain-layer-design.md §4.1）。

**三层防抖的分工**（§4.1 规定全部必加；本模块实现后两层）

1. **滞回**：由调用方在 guard 闭包里实现——进入与退出使用不同阈值。引擎只看到布尔
   结果，不感知阈值：``lambda s: s["knee"] is not None and s["knee"] < base - 5``。
   这是刻意的分工：阈值可能来自 server 阈值表、随标准分群与个人基线变化（§7），
   不能固化进通用引擎。
2. **最短停留** ``min_dwell_frames``：本模块实现。转移提交后，新状态还必须完整保持
   至少这么多帧，才允许下一次转移——防「刚进新状态，立刻被下一条边的条件带走」。
3. **N-of-M 投票**：本模块实现。候选转移的 guard 须在最近 ``vote_window`` 帧中至少
   ``vote_required`` 帧为真；投票窗口**按候选转移分别维护**，互不串票。

三者是 AND 关系：滞回管「边界不来回跳」（输入侧），投票管「证据要够」，停留管
「时间要够」；任一不满足，本帧就不转移。

**调用契约（依赖本模块的代码请逐条遵守）**

- **一次 ``update()`` 调用即一帧。** 全部防抖只依赖帧计数，不依赖 ``timestamp_ms``：
  时间戳仅被记录（供相位时长统计与 rep 封存使用），引擎对它不做单调性检查、不做
  差分，因此回退、重复、乱序的时间戳既不抛错也不影响状态迁移。
- **缺键、值为 ``None``、guard 抛异常 → 本帧判「不满足」，绝不向上抛**（§0 铁律二、
  §3.2：不可用特征输出 null，该帧不参与判定）。guard 因此可以放心写
  ``s["knee"] < 100`` 而无需先判 None。代价要说清楚：guard 里真正的 bug 同样会被
  静默记为「不满足」，表现为状态机纹丝不动；排查时用 ``Transition.label`` 找出
  「从未通过的候选」。
- **多个候选同时满足 → 按 ``transitions`` 传入顺序取第一个匹配。** 顺序即优先级，
  结果确定可复现；不要用字典或集合的迭代顺序表达优先级。
- **guard 必须是纯函数。** 当前状态的每条出边 guard 每帧都会被调用（不短路），
  保证每个候选的投票窗口逐帧连续；带副作用的 guard 会产生不可复现的行为。
- **``reset`` 与「全新实例」等价。** reset 清空全部投票与停留计时，上一段动作的
  证据不会被带进下一段——这正是 §3.2「长时丢失后重新同步」需要的语义。

本模块**只依赖标准库**，也不含任何体育阈值（铁律三）：状态机是纯信号组件，不关心
信号来自姿态估计还是别的什么；移植到端侧（Dart）时只需逐条对齐本文件的语义。
"""

from __future__ import annotations

from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TypeAlias

#: 一帧的特征信号：特征码 → 数值或 None（None = 本帧该特征不可用，§0 铁律二）
Signals: TypeAlias = Mapping[str, float | None]

#: 候选转移的守卫：读一帧信号，回答「本帧是否满足转移条件」。
#: 滞回阈值与个体基线的比较都写在闭包里——这是调用方的职责（见模块文档第 1 条）。
Guard: TypeAlias = Callable[[Signals], bool]


class StateMachineError(ValueError):
    """状态机定义或构造参数非法。

    这类错误属于「定义错误」（状态图自相矛盾、参数越界），应在构造或 reset 时尽早
    暴露，而不是等运行到一半才以难以定位的方式发作。继承 ``ValueError`` 是刻意的：
    非法参数就是取值错误，调用方可按 ``ValueError`` 统一捕获。
    """


def _require_frame_count(name: str, value: object, *, minimum: int) -> int:
    """校验帧数类参数是「非 bool 的 int 且不小于 minimum」。

    ``bool`` 是 ``int`` 的子类，``min_dwell_frames=True`` 几乎必然是把开关量喂错了
    位置，宁可报错也不默默当成 1。
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise StateMachineError(
            f"{name} 必须是整数帧数，实际为 {value!r}（{type(value).__name__}）"
        )
    if value < minimum:
        raise StateMachineError(f"{name} 不能小于 {minimum}，实际为 {value}")
    return value


@dataclass(frozen=True, slots=True)
class Transition:
    """一条候选转移（动作定义的最小单元）。

    ``guard`` 是调用方提供的纯函数，承接了「体育判断」与「滞回」：进入与退出用不同
    阈值、与本人基线比较，都在这个闭包里表达（§4.1 的分工）。引擎本身不碰阈值——
    阈值随人群、个体、机位变化，且有独立的核定与治理流程（§7），不能固化进引擎。

    guard 收到的信号映射可能缺键、可能含 None：引擎已把「抛异常」兜底记为「不满足」，
    guard 因此可以按直觉书写比较式；若需要显式降级逻辑，应在闭包内自行表达。

    ``label`` 只用于调试与测试定位（哪条候选触发了转移），不参与任何逻辑。
    """

    src: str
    dst: str
    guard: Guard
    label: str | None = None


@dataclass(frozen=True, slots=True)
class StateUpdate:
    """一次 ``update()`` 的结果——该帧结束后的状态快照。

    返回不可变值对象而非就地修改，是为了让调用方（rep 封存、错误累计）能安全地
    留存历史帧，不担心被后续 update 改动。

    ``entered`` / ``left`` 仅在 ``changed`` 为真时非 None：「无转移」与「转移到
    自身」是两回事，后者（自环）在构造时已被禁止。
    """

    state: str
    previous_state: str
    changed: bool
    entered: str | None
    left: str | None


class StateMachine:
    """通用动作状态机引擎：把逐帧信号推进为稳定相位。

    实例是有状态的推进器：``update()`` 每调用一次吃一帧并返回快照，``state``
    随时可读，``reset()`` 回到干净状态。完整语义见模块文档的调用契约。

    典型用法（深蹲，状态链见 §4.2）::

        machine = StateMachine(
            initial_state="STANDING",
            transitions=[
                Transition("STANDING", "DESCENT", stand_to_descent, label="standing->descent"),
                Transition("DESCENT", "BOTTOM", descent_to_bottom, label="descent->bottom"),
                Transition("BOTTOM", "ASCENT", bottom_to_ascent, label="bottom->ascent"),
                Transition("ASCENT", "STANDING", ascent_to_standing, label="ascent->standing"),
            ],
        )
        for frame in stream:              # frame 提供 signals / timestamp_ms 两个字段
            update = machine.update(frame.signals, frame.timestamp_ms)
            if update.changed and update.entered == "STANDING":
                seal_rep()                # 回到站立 = 一次 rep 完成（§4.2 rep 封存）

    **冷启动**：投票窗口从零攒起，任何状态（包括初始状态）最早也要在
    ``vote_window`` 帧之后才可能发生第一次转移；``vote_window=1, vote_required=1``
    即关闭投票机制。初始状态不受最短停留限制——它没有被「进入」过，停留门槛只从
    引擎自己提交的转移开始累计。

    **选择规则**：同帧多个候选满足时，取 ``transitions`` 中靠前者；guard 必须为
    纯函数，并应容忍信号缺键或为 None（引擎保证不会因 guard 抛错而中断）。
    """

    def __init__(
        self,
        initial_state: str,
        transitions: Sequence[Transition],
        *,
        min_dwell_frames: int = 3,
        vote_window: int = 5,
        vote_required: int = 4,
    ) -> None:
        """构造状态机并完成全部定义校验（非法定义在构造期抛错，不留到运行时）。

        默认防抖参数取自工程默认值清单（§7.1），与体育阈值无关（铁律三）。

        Args:
            initial_state: 初始状态；必须出现在某条转移的 ``src`` 或 ``dst`` 里，
                否则该状态触发不了任何转移，多半是状态名拼写错误。
            transitions: 有向转移列表。**顺序即优先级**：同帧多个候选满足时取靠前
                者（见类文档）。内部会拷贝为元组，事后修改入参不影响本实例。
            min_dwell_frames: 转移提交后，新状态至少还要完整保持的帧数；下一次
                转移最早出现在「提交帧 + min_dwell_frames」。0 表示关闭该机制。
            vote_window: 投票窗口长度 M（帧）。
            vote_required: 窗口内至少为真的帧数 N；须满足 ``1 <= N <= M``。
                窗口攒满 M 帧之前不会转移（冷启动需要 M 帧证据）。

        Raises:
            StateMachineError: 状态图或参数非法：转移列表为空、初始状态不在图内、
                自环、参数越界/负数/非整数、``vote_required > vote_window`` 等。
        """
        min_dwell = _require_frame_count("min_dwell_frames", min_dwell_frames, minimum=0)
        window = _require_frame_count("vote_window", vote_window, minimum=1)
        quorum = _require_frame_count("vote_required", vote_required, minimum=1)
        if quorum > window:
            raise StateMachineError(
                f"vote_required（{quorum}）不能大于 vote_window（{window}）："
                "窗口里凑不满这么多真票，状态机将永远无法转移"
            )

        graph = tuple(transitions)
        if not graph:
            raise StateMachineError("transitions 不能为空：没有转移的状态机表达不了任何动作")
        for transition in graph:
            if not isinstance(transition, Transition):
                raise StateMachineError(f"transitions 里混入了非 Transition 对象：{transition!r}")
            if not isinstance(transition.src, str) or not transition.src:
                raise StateMachineError(f"转移的 src 必须是非空字符串：{transition!r}")
            if not isinstance(transition.dst, str) or not transition.dst:
                raise StateMachineError(f"转移的 dst 必须是非空字符串：{transition!r}")
            if transition.src == transition.dst:
                raise StateMachineError(
                    f"转移 {transition.src!r}->{transition.dst!r} 是自环：停留在原状态是"
                    "引擎的默认行为，自环只会制造 changed=True 却状态未变的假象"
                )
            if not callable(transition.guard):
                raise StateMachineError(
                    f"转移 {transition.src!r}->{transition.dst!r} 的 guard 不可调用："
                    f"{transition.guard!r}"
                )

        known_states = frozenset({t.src for t in graph} | {t.dst for t in graph})
        if not isinstance(initial_state, str) or initial_state not in known_states:
            raise StateMachineError(
                f"initial_state={initial_state!r} 未出现在任何转移的 src/dst 中："
                "该状态触发不了任何转移，多半是状态名拼写错误"
            )

        self._initial_state = initial_state
        self._transitions = graph
        self._known_states = known_states
        self._min_dwell_frames = min_dwell
        self._vote_window = window
        self._vote_required = quorum
        self._state = initial_state
        self._frames_since_transition: int | None = None
        self._last_timestamp_ms: int | None = None
        # 投票历史按「候选转移在列表中的位置」维护：同一状态的多条出边各自独立，
        # 即使两条转移的 src/dst 完全相同也是两个候选（位置即身份，不依赖哈希）。
        self._votes: list[deque[bool]] = [deque(maxlen=window) for _ in graph]

    @property
    def state(self) -> str:
        """当前状态（最近一次 ``update()`` 或 ``reset()`` 之后的状态）。"""
        return self._state

    def update(self, signals: Signals, timestamp_ms: int) -> StateUpdate:
        """推进一帧，返回本帧结束后的状态快照。

        每调用一次算一帧，与 ``timestamp_ms`` 的取值无关（见模块文档契约）。
        本方法不会因 guard 抛错而中断：异常一律记为「本帧不满足」。

        Args:
            signals: 本帧的特征信号。允许缺键、允许值为 None——按「不满足」处理
                （§0 铁律二：不可用特征输出 null，该帧不参与判定）。
            timestamp_ms: 本帧时间戳。仅被记录，不参与任何计算；回退、重复、
                跳跃均安全。

        Returns:
            本帧结束后的状态快照；``changed`` 为真时 ``entered`` / ``left``
            携带本次转移的两端，未转移时二者为 None。
        """
        previous = self._state
        self._last_timestamp_ms = timestamp_ms

        # 停留计时：转移提交帧记 0，此后每帧自增；从未发生过转移（None）不设门槛。
        if self._frames_since_transition is not None:
            self._frames_since_transition += 1
        dwell_satisfied = self._frames_since_transition is None or (
            self._frames_since_transition >= self._min_dwell_frames
        )

        chosen: Transition | None = None
        for index, transition in enumerate(self._transitions):
            if transition.src != previous:
                continue
            # 投票按候选转移独立累计。锁定期间照常记票（停留只锁提交、不锁计票）。
            history = self._votes[index]
            history.append(self._guard_passed(transition.guard, signals))
            if (
                chosen is None
                and dwell_satisfied
                and len(history) >= self._vote_window
                and sum(history) >= self._vote_required
            ):
                chosen = transition
                # 不 break：其余候选本帧也照常记票，保证各候选的投票窗口逐帧连续、
                # 与它排在列表的第几位无关。

        if chosen is None:
            return StateUpdate(
                state=previous,
                previous_state=previous,
                changed=False,
                entered=None,
                left=None,
            )

        self._state = chosen.dst
        self._frames_since_transition = 0
        # 证据只对「本次停留」有效：换状态后全部旧票作废，避免下次回到原状态时
        # 用过期证据瞬移（例如回到 STANDING 后立刻被上一轮的旧票推进 DESCENT）。
        for history in self._votes:
            history.clear()
        return StateUpdate(
            state=chosen.dst,
            previous_state=previous,
            changed=True,
            entered=chosen.dst,
            left=previous,
        )

    def reset(self, state: str | None = None) -> None:
        """把状态机恢复到干净状态，等价于重新构造一个实例。

        ``state=None`` 回到构造时的 ``initial_state``；否则跳到指定状态。两条路径
        都会清空全部投票窗口与停留计时——reset 后不存在任何上一段动作的残留证据，
        行为与「以目标状态为 initial_state 新建」的实例完全一致。这正是 §3.2
        「长时丢失后从校准态重新同步」需要的语义：旧一组的证据绝不能带进新一组。

        Args:
            state: 目标状态；None 表示回到 ``initial_state``。

        Raises:
            StateMachineError: 目标状态不在任何转移的 src/dst 中（多半是拼写错误）。
                ``initial_state`` 不会触发此错误——它在构造时已校验。
        """
        if state is None:
            target = self._initial_state
        else:
            if not isinstance(state, str) or state not in self._known_states:
                raise StateMachineError(
                    f"reset 目标 {state!r} 未出现在任何转移的 src/dst 中，多半是拼写错误"
                )
            target = state
        self._state = target
        self._frames_since_transition = None
        self._last_timestamp_ms = None
        for history in self._votes:
            history.clear()

    @staticmethod
    def _guard_passed(guard: Guard, signals: Signals) -> bool:
        """评估 guard；「数据不可用」与「guard 缺陷」一律归约为「本帧不满足」。

        这是本模块最重要的鲁棒性边界。理由：信号缺特征、特征为 None 是常态
        （§0 铁律二要求不可用特征输出 null），而 guard 的自然写法
        ``s["knee"] < 100`` 比较 None 时会抛 TypeError。异常一旦逃逸，实时循环
        会被一帧坏数据打断；因此这里统一捕获、记为「不满足」，等价于该帧
        「不参与判定」（§3.2）。代价：guard 里真正的 bug 也会静默表现为「条件
        永不满足」，请借助 ``Transition.label`` 定位。

        ``BaseException``（KeyboardInterrupt、SystemExit 等控制流异常）不在捕获
        范围内，必须继续向上传播。
        """
        try:
            return bool(guard(signals))
        except Exception:
            return False
