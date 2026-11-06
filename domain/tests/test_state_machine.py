"""state_machine 引擎的行为测试。

组织方式：

- 常量与辅助工厂集中在文件顶部，测试体只写「场景 + 断言」，不散落裸字面量；
- 每个测试的名字与 docstring 直接说明验证哪条契约（三层防抖 / 调用契约 / 边界
  情况），不使用 test_1、test_2 这类命名；
- 深蹲仿真用刻意踩线的抖动膝角序列，验证「抖动不会造成重复计数式的连续状态
  翻转」，并以关闭防抖的裸配置做对照实验。
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import FrozenInstanceError
from itertools import pairwise

import pytest

from vitalteen_domain.state_machine import (
    Guard,
    Signals,
    StateMachine,
    StateMachineError,
    StateUpdate,
    Transition,
)

# ---------------------------------------------------------------------------
# 通用夹具：状态名、时间步长、守卫工厂
# ---------------------------------------------------------------------------

STATE_S = "S"
STATE_T = "T"

FRAME_MS = 33  # 与 30fps 采集对齐的时间步长

#: 工程默认防抖参数（§7.1）：最短停留 3 帧、5 帧中 4 帧
DEFAULT_MIN_DWELL = 3
DEFAULT_VOTE_WINDOW = 5
DEFAULT_VOTE_REQUIRED = 4


def _constant_guard(value: bool) -> Guard:
    """返回固定结果的守卫，把「防抖计时」与「信号内容」解耦。"""

    def guard(_signals: Signals) -> bool:
        return value

    return guard


ALWAYS_TRUE = _constant_guard(True)
ALWAYS_FALSE = _constant_guard(False)


def _is_true(key: str) -> Guard:
    """信号键为 True 才满足的守卫（缺键/None 视为不满足）。"""

    def guard(signals: Signals) -> bool:
        return signals.get(key) is True

    return guard


def _naive_knee_below(limit: float) -> Guard:
    """刻意不判 None 的膝角守卫：模拟调用方按直觉书写、由引擎兜底的情形。"""
    return lambda signals: signals["knee"] < limit


def _knee_below(limit: float) -> Guard:
    """None 安全的「膝角小于」守卫（调用方推荐写法）。"""

    def guard(signals: Signals) -> bool:
        knee = signals.get("knee")
        return knee is not None and knee < limit

    return guard


def _knee_at_most(limit: float) -> Guard:
    """None 安全的「膝角小于等于」守卫。"""

    def guard(signals: Signals) -> bool:
        knee = signals.get("knee")
        return knee is not None and knee <= limit

    return guard


def _knee_above(limit: float) -> Guard:
    """None 安全的「膝角大于」守卫。"""

    def guard(signals: Signals) -> bool:
        knee = signals.get("knee")
        return knee is not None and knee > limit

    return guard


def _run(
    machine: StateMachine, frames: Sequence[Signals], *, start_ms: int = 0
) -> list[StateUpdate]:
    """按固定帧间隔依次喂入信号帧，返回逐帧结果。"""
    return [
        machine.update(signals, start_ms + index * FRAME_MS)
        for index, signals in enumerate(frames)
    ]


def _knee_frames(values: Sequence[float]) -> list[Signals]:
    """把一串膝角数值包装成信号帧。"""
    return [{"knee": value} for value in values]


def _changed_indices(updates: Sequence[StateUpdate]) -> list[int]:
    """发生转移的帧下标列表。"""
    return [index for index, update in enumerate(updates) if update.changed]


def _entered_states(updates: Sequence[StateUpdate]) -> list[str | None]:
    """转移进入的目标状态序列（用于断言相位链）。"""
    return [update.entered for update in updates if update.changed]


def _two_state_machine(
    *,
    min_dwell_frames: int = 0,
    vote_window: int = 1,
    vote_required: int = 1,
) -> StateMachine:
    """S ⇄ T 双状态机，两条边守卫恒真。

    默认参数即「关闭防抖」的裸配置，便于隔离出单一机制做测试；需要考察某层防抖
    时只覆盖对应参数。
    """
    return StateMachine(
        STATE_S,
        [
            Transition(STATE_S, STATE_T, ALWAYS_TRUE, label="s->t"),
            Transition(STATE_T, STATE_S, ALWAYS_TRUE, label="t->s"),
        ],
        min_dwell_frames=min_dwell_frames,
        vote_window=vote_window,
        vote_required=vote_required,
    )


def _flag_machine(
    *,
    min_dwell_frames: int = 0,
    vote_window: int = 1,
    vote_required: int = 1,
) -> StateMachine:
    """由信号键 "flag" 驱动的 S ⇄ T 状态机，便于按帧构造守卫结果序列。"""
    return StateMachine(
        STATE_S,
        [
            Transition(STATE_S, STATE_T, _is_true("flag"), label="s->t"),
            Transition(STATE_T, STATE_S, _is_true("flag"), label="t->s"),
        ],
        min_dwell_frames=min_dwell_frames,
        vote_window=vote_window,
        vote_required=vote_required,
    )


def _valid_transitions() -> list[Transition]:
    """构造期校验测试使用的合法转移图。"""
    return [
        Transition(STATE_S, STATE_T, ALWAYS_TRUE, label="s->t"),
        Transition(STATE_T, STATE_S, ALWAYS_TRUE, label="t->s"),
    ]


# ---------------------------------------------------------------------------
# 深蹲场景夹具（§4.2 状态链 STANDING ⇄ DESCENT ⇄ BOTTOM ⇄ ASCENT → STANDING）
# ---------------------------------------------------------------------------

STANDING = "STANDING"
DESCENT = "DESCENT"
BOTTOM = "BOTTOM"
ASCENT = "ASCENT"

# 训练用示意值（非体育阈值；真实阈值由 server 阈值表核定，见 §7.3）
STAND_KNEE_DEG = 170.0
ENTER_DESCENT_KNEE_DEG = 160.0  # 低于此值判定开始下蹲（滞回下沿）
DEPTH_LINE_KNEE_DEG = 100.0  # 深度线；与 EXIT_BOTTOM_KNEE_DEG 构成滞回带
EXIT_BOTTOM_KNEE_DEG = 110.0  # 高于此值判定离开底部（滞回上沿）
BACK_TO_STANDING_KNEE_DEG = 165.0  # 高于此值判定站直（滞回上沿）
GLITCH_KNEE_DEG = 95.0  # 下蹲段插入的伪帧尖刺值


def _squat_transitions() -> list[Transition]:
    """§4.2 的状态链；滞回全部体现在 guard 的进出阈值差里（调用方职责示范）。"""
    return [
        Transition(
            STANDING, DESCENT, _knee_below(ENTER_DESCENT_KNEE_DEG), label="standing->descent"
        ),
        Transition(DESCENT, BOTTOM, _knee_at_most(DEPTH_LINE_KNEE_DEG), label="descent->bottom"),
        Transition(BOTTOM, ASCENT, _knee_above(EXIT_BOTTOM_KNEE_DEG), label="bottom->ascent"),
        Transition(
            ASCENT, STANDING, _knee_above(BACK_TO_STANDING_KNEE_DEG), label="ascent->standing"
        ),
    ]


def _squat_machine() -> StateMachine:
    """三层防抖全开的深蹲状态机（生产配置）。"""
    return StateMachine(
        STANDING,
        _squat_transitions(),
        min_dwell_frames=DEFAULT_MIN_DWELL,
        vote_window=DEFAULT_VOTE_WINDOW,
        vote_required=DEFAULT_VOTE_REQUIRED,
    )


def _naive_squat_machine() -> StateMachine:
    """关闭三层防抖的深蹲状态机：对照实验用，暴露抖动本会造成的虚假转移。"""
    return StateMachine(
        STANDING,
        _squat_transitions(),
        min_dwell_frames=0,
        vote_window=1,
        vote_required=1,
    )


def _jittery_squat_knee_series() -> list[float]:
    """一段刻意处处「踩线抖动」的深蹲膝角序列（度）。

    每一段都在针对某一层防抖机制：

    - 站立段：混入 2 帧 158° 的下沉抖动（低于进入线 160°）——帧级条件已「满足」，
      只有投票窗口能拒绝；
    - 下蹲段：插入 1 帧 95° 伪帧尖刺（模拟关键点跳变）——裸阈值会立刻误判到最低点；
    - 底部段：膝角在深度线 100° 上下反复穿越（96~103°），且始终低于退出线 110°，
      保证滞回带不被击穿、只剩抖动本身；
    - 站起段与站定段：膝角在 165° 判定线附近抖动（162~170°），站定后又出现
      158° 抖动——不得重新开启一次下蹲。
    """
    standing = [170.0, 171.5, 169.0, 172.0, 158.0, 157.5, 170.5, 169.5]
    descent = [166.0, 159.0, 148.0, 136.0, GLITCH_KNEE_DEG, 130.0, 118.0, 106.0]
    bottom = [97.0, 103.0, 98.0, 99.0, 101.0, 96.0, 100.0, 102.0, 97.0, 99.0]
    ascent = [112.0, 124.0, 136.0, 148.0, 158.0, 166.0, 168.0, 163.0, 167.0, 165.5, 169.0, 162.0]
    settle = [168.0, 170.0, 170.0, 158.0, 157.0, 170.0, 171.0, 169.5]
    return standing + descent + bottom + ascent + settle


# ---------------------------------------------------------------------------
# 基础转移语义
# ---------------------------------------------------------------------------


def test_guard_true_transitions_only_after_full_vote_window() -> None:
    """守卫持续为真也要攒满投票窗口（这里 2 帧中 2 帧）才提交转移。"""
    machine = _two_state_machine(vote_window=2, vote_required=2)
    updates = _run(machine, [{}, {}, {}])

    assert _changed_indices(updates) == [1]
    assert updates[1].previous_state == STATE_S
    assert updates[1].entered == STATE_T
    assert updates[1].left == STATE_S
    assert updates[1].state == STATE_T
    assert updates[2].changed is False
    assert updates[2].state == STATE_T
    assert updates[2].previous_state == STATE_T
    assert machine.state == STATE_T


def test_no_matching_transition_keeps_state_and_reports_unchanged() -> None:
    """没有任何候选满足时：状态保持不变，changed=False，entered/left 均为 None。"""
    machine = StateMachine(
        STATE_S,
        [
            Transition(STATE_S, STATE_T, ALWAYS_FALSE, label="never"),
            Transition(STATE_T, STATE_S, ALWAYS_TRUE, label="unreachable"),
        ],
        min_dwell_frames=0,
        vote_window=1,
        vote_required=1,
    )
    updates = _run(machine, [{} for _ in range(10)])

    assert all(update.changed is False for update in updates)
    assert all(update.entered is None and update.left is None for update in updates)
    assert all(update.state == STATE_S and update.previous_state == STATE_S for update in updates)
    assert machine.state == STATE_S


def test_vote_window_must_fill_before_first_transition() -> None:
    """冷启动不豁免投票窗口：初始状态也要先攒满 vote_window 帧证据。"""
    machine = _flag_machine(
        vote_window=DEFAULT_VOTE_WINDOW, vote_required=DEFAULT_VOTE_REQUIRED
    )
    updates = _run(machine, [{"flag": True} for _ in range(DEFAULT_VOTE_WINDOW + 1)])

    assert _changed_indices(updates) == [DEFAULT_VOTE_WINDOW - 1]


# ---------------------------------------------------------------------------
# N-of-M 投票的作用
# ---------------------------------------------------------------------------


def test_single_dissenting_frame_inside_window_does_not_block_quorum() -> None:
    """5 帧里偶发 1 帧不满足（4/5）不阻止转移：N-of-M 是容忍少数派的。"""
    machine = _flag_machine(
        vote_window=DEFAULT_VOTE_WINDOW, vote_required=DEFAULT_VOTE_REQUIRED
    )
    pattern = [True, True, False, True, True]
    updates = _run(machine, [{"flag": value} for value in pattern])

    assert _changed_indices(updates) == [len(pattern) - 1]
    assert _entered_states(updates) == [STATE_T]


def test_flapping_guard_never_reaches_quorum() -> None:
    """隔帧翻转的抖动信号永远凑不满 4/5：状态纹丝不动，杜绝边界来回跳。"""
    machine = _flag_machine(
        vote_window=DEFAULT_VOTE_WINDOW, vote_required=DEFAULT_VOTE_REQUIRED
    )
    frames = [{"flag": index % 2 == 0} for index in range(20)]
    updates = _run(machine, frames)

    assert _changed_indices(updates) == []
    assert machine.state == STATE_S


# ---------------------------------------------------------------------------
# 最短停留的作用
# ---------------------------------------------------------------------------


def test_min_dwell_blocks_next_transition_until_it_elapses() -> None:
    """转移提交后新状态须完整保持 min_dwell 帧：下一次转移最早在「提交帧 + min_dwell」。"""
    machine = _two_state_machine(min_dwell_frames=DEFAULT_MIN_DWELL)
    updates = _run(machine, [{} for _ in range(6)])

    assert _changed_indices(updates) == [0, DEFAULT_MIN_DWELL]
    assert _entered_states(updates) == [STATE_T, STATE_S]


def test_two_frame_sequence_is_stable_under_dwell_lock() -> None:
    """极短序列（共 2 帧）：首帧转移后第二帧被停留锁定，不崩溃、不连续翻转。"""
    machine = _two_state_machine(min_dwell_frames=DEFAULT_MIN_DWELL)
    updates = _run(machine, [{}, {}])

    assert _changed_indices(updates) == [0]
    assert updates[1].entered is None
    assert updates[1].left is None
    assert machine.state == STATE_T


def test_votes_accumulate_during_dwell_lock() -> None:
    """最短停留只锁「提交」不锁「记票」：锁定期间的真票照常计入窗口。"""
    machine = _two_state_machine(min_dwell_frames=2, vote_window=3, vote_required=3)
    updates = _run(machine, [{} for _ in range(6)])

    assert _changed_indices(updates) == [2, 5]


def test_stale_votes_are_discarded_when_state_changes() -> None:
    """转移时投票作废：回到原状态后必须重新攒票，不能借用上一轮的旧票瞬移。"""
    machine = _two_state_machine(
        min_dwell_frames=DEFAULT_MIN_DWELL,
        vote_window=DEFAULT_VOTE_WINDOW,
        vote_required=DEFAULT_VOTE_REQUIRED,
    )
    updates = _run(machine, [{} for _ in range(15)])

    assert _changed_indices(updates) == [4, 9, 14]


# ---------------------------------------------------------------------------
# 候选独立性：各自计票 + 确定性选择
# ---------------------------------------------------------------------------


def test_candidate_votes_are_maintained_independently() -> None:
    """同一状态的出边各自计票：抖动边的假票不会替稳定边攒票，反之亦然。"""
    machine = StateMachine(
        STATE_S,
        [
            Transition(STATE_S, "A", _is_true("flap"), label="flappy"),
            Transition(STATE_S, "B", _is_true("steady"), label="steady"),
        ],
        min_dwell_frames=0,
        vote_window=DEFAULT_VOTE_WINDOW,
        vote_required=DEFAULT_VOTE_REQUIRED,
    )
    steady_from = 10
    frames = [
        {"flap": index % 2 == 0, "steady": index >= steady_from} for index in range(20)
    ]
    updates = _run(machine, frames)

    assert _changed_indices(updates) == [steady_from + DEFAULT_VOTE_REQUIRED - 1]
    assert _entered_states(updates) == ["B"]


def test_simultaneously_satisfied_candidates_follow_declared_order() -> None:
    """同帧多个候选同时满足：按 transitions 传入顺序取第一个——顺序即优先级。"""
    transitions_ab = [
        Transition(STATE_S, "A", ALWAYS_TRUE, label="a"),
        Transition(STATE_S, "B", ALWAYS_TRUE, label="b"),
    ]
    transitions_ba = list(reversed(transitions_ab))
    params = {"min_dwell_frames": 0, "vote_window": 1, "vote_required": 1}

    updates_ab = _run(StateMachine(STATE_S, transitions_ab, **params), [{}])
    updates_ba = _run(StateMachine(STATE_S, transitions_ba, **params), [{}])

    assert _entered_states(updates_ab) == ["A"]
    assert _entered_states(updates_ba) == ["B"]


# ---------------------------------------------------------------------------
# 坏数据与异常：None / 缺键 / guard 缺陷 —— 一律「不满足」且不崩溃
# ---------------------------------------------------------------------------


def test_none_and_missing_signals_are_unsatisfied_without_raising() -> None:
    """None 与缺键都判为不满足且绝不抛异常（铁律二）；数据恢复后照常计票。"""
    machine = StateMachine(
        STATE_S,
        [Transition(STATE_S, STATE_T, _naive_knee_below(DEPTH_LINE_KNEE_DEG), label="naive")],
        min_dwell_frames=0,
        vote_window=2,
        vote_required=2,
    )
    frames: list[Signals] = [{"knee": None}, {}, {"knee": 90.0}, {"knee": 90.0}]
    updates = _run(machine, frames)

    assert _changed_indices(updates) == [3]
    assert machine.state == STATE_T


def test_guard_exception_is_absorbed_and_does_not_block_other_candidates() -> None:
    """guard 抛异常 = 本帧不满足：不外泄，也不影响同状态的其它候选。"""

    def _exploding_guard(_signals: Signals) -> bool:
        raise RuntimeError("模拟 guard 内部缺陷")

    machine = StateMachine(
        STATE_S,
        [
            Transition(STATE_S, "A", _exploding_guard, label="broken"),
            Transition(STATE_S, "B", ALWAYS_TRUE, label="healthy"),
        ],
        min_dwell_frames=0,
        vote_window=1,
        vote_required=1,
    )
    assert _entered_states(_run(machine, [{}])) == ["B"]

    only_broken = StateMachine(
        STATE_S,
        [Transition(STATE_S, "A", _exploding_guard, label="broken")],
        min_dwell_frames=0,
        vote_window=1,
        vote_required=1,
    )
    broken_updates = _run(only_broken, [{}, {}, {}])
    assert _changed_indices(broken_updates) == []
    assert only_broken.state == STATE_S


def test_non_monotonic_timestamps_do_not_affect_behavior() -> None:
    """时间戳回退/重复/跳跃均安全：引擎只按帧计数，不对时间做任何差分。"""

    def _make() -> StateMachine:
        return StateMachine(
            STATE_S,
            [
                Transition(STATE_S, STATE_T, _is_true("up"), label="up"),
                Transition(STATE_T, STATE_S, _is_true("down"), label="down"),
            ],
            min_dwell_frames=0,
            vote_window=1,
            vote_required=1,
        )

    flags = [False, True, True, False, False, True]
    clean_updates = _run(_make(), [{"up": flag, "down": not flag} for flag in flags])
    assert _changed_indices(clean_updates) == [1, 3, 5]

    wild_timestamps = [10**9, 0, 5, 5, -1, 3]  # 先跳跃、再回退、有重复、有负值
    wild = _make()
    wild_updates = [
        wild.update({"up": flag, "down": not flag}, timestamp)
        for flag, timestamp in zip(flags, wild_timestamps, strict=True)
    ]

    assert wild_updates == clean_updates
    assert wild.state == clean_updates[-1].state


# ---------------------------------------------------------------------------
# 滞回：由调用方在 guard 内实现（引擎分工的执行示例）
# ---------------------------------------------------------------------------

HYSTERESIS_ENTER_KNEE_DEG = 95.0  # 进入下蹲态的滞回下沿
HYSTERESIS_EXIT_KNEE_DEG = 105.0  # 退回站立态的滞回上沿


def test_directional_guards_encode_hysteresis_inside_the_band() -> None:
    """滞回由调用方实现：两向阈值差写进 guard；信号在滞回带内振荡时状态绝不动。"""
    machine = StateMachine(
        "UP",
        [
            Transition("UP", "DOWN", _knee_at_most(HYSTERESIS_ENTER_KNEE_DEG), label="enter"),
            Transition("DOWN", "UP", _knee_above(HYSTERESIS_EXIT_KNEE_DEG), label="exit"),
        ],
        min_dwell_frames=0,
        vote_window=1,
        vote_required=1,
    )
    band_values = [96.0, 104.0, 95.5, 103.0, 97.0, 102.0, 99.0, 101.0]
    frames = _knee_frames([90.0, *band_values, 106.0, *band_values])
    updates = _run(machine, frames)

    assert _changed_indices(updates) == [0, len(band_values) + 1]
    assert _entered_states(updates) == ["DOWN", "UP"]


# ---------------------------------------------------------------------------
# reset：与全新实例等价
# ---------------------------------------------------------------------------


def test_reset_returns_to_initial_state_and_clears_all_evidence() -> None:
    """reset() 回到构造时的初始状态，且清空投票与停留计时——与全新实例逐帧一致。"""
    params = {
        "min_dwell_frames": DEFAULT_MIN_DWELL,
        "vote_window": DEFAULT_VOTE_WINDOW,
        "vote_required": DEFAULT_VOTE_REQUIRED,
    }
    machine = _two_state_machine(**params)
    _run(machine, [{} for _ in range(8)])  # 已转移一次，且残留部分投票
    assert machine.state == STATE_T

    machine.reset()
    assert machine.state == STATE_S

    tail = [{} for _ in range(10)]
    after_reset = _run(machine, tail)
    fresh_updates = _run(_two_state_machine(**params), tail)

    assert after_reset == fresh_updates
    assert _changed_indices(after_reset) == [4, 9]


def test_reset_to_explicit_state_matches_fresh_machine_starting_there() -> None:
    """reset(BOTTOM) 等价于以 BOTTOM 为初始状态新建实例。"""
    machine = _squat_machine()
    _run(machine, _knee_frames(_jittery_squat_knee_series()[:5]))
    machine.reset(BOTTOM)
    assert machine.state == BOTTOM

    fresh = StateMachine(
        BOTTOM,
        _squat_transitions(),
        min_dwell_frames=DEFAULT_MIN_DWELL,
        vote_window=DEFAULT_VOTE_WINDOW,
        vote_required=DEFAULT_VOTE_REQUIRED,
    )
    frames = _knee_frames(_jittery_squat_knee_series()[10:])
    assert _run(machine, frames) == _run(fresh, frames)


def test_reset_rejects_unknown_state() -> None:
    """reset 到状态图之外的状态：立即抛错并保持原状态不动。"""
    machine = _squat_machine()
    with pytest.raises(StateMachineError):
        machine.reset("NOT_A_STATE")
    assert machine.state == STANDING


# ---------------------------------------------------------------------------
# 构造期校验：非法定义尽早失败
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "overrides",
    [
        pytest.param({"vote_required": 4, "vote_window": 3}, id="required_gt_window"),
        pytest.param({"vote_required": 2, "vote_window": 1}, id="quorum_larger_than_window"),
        pytest.param({"vote_window": 0}, id="vote_window_zero"),
        pytest.param({"vote_required": 0}, id="vote_required_zero"),
        pytest.param({"min_dwell_frames": -1}, id="negative_min_dwell"),
        pytest.param({"min_dwell_frames": 2.5}, id="non_integer_min_dwell"),
        pytest.param({"vote_window": True}, id="bool_is_not_a_frame_count"),
    ],
)
def test_invalid_debounce_parameters_fail_fast(overrides: dict[str, object]) -> None:
    """非法参数（越界/负数/非整数）在构造时抛 StateMachineError，而非运行时才暴露。"""
    with pytest.raises(StateMachineError):
        StateMachine(STATE_S, _valid_transitions(), **overrides)


def test_constructor_rejects_empty_transitions() -> None:
    """空转移列表：状态机无法表达任何动作，构造即失败。"""
    with pytest.raises(StateMachineError):
        StateMachine(STATE_S, [])


def test_constructor_rejects_initial_state_outside_graph() -> None:
    """initial_state 不在任何转移的 src/dst 里：多半是拼写错误，构造即失败。"""
    with pytest.raises(StateMachineError):
        StateMachine("STANDING_TYPO", _valid_transitions())


def test_constructor_rejects_self_loop() -> None:
    """自环（src == dst）会制造 changed=True 却状态未变的假象，属于定义错误。"""
    with pytest.raises(StateMachineError):
        StateMachine(
            STATE_S,
            [
                Transition(STATE_S, STATE_S, ALWAYS_TRUE, label="self"),
                Transition(STATE_T, STATE_S, ALWAYS_TRUE, label="back"),
            ],
        )


def test_constructor_rejects_non_transition_objects() -> None:
    """transitions 里混入非 Transition 对象：构造即失败，而不是运行到该条才炸。"""
    with pytest.raises(StateMachineError):
        StateMachine(STATE_S, [Transition(STATE_S, STATE_T, ALWAYS_TRUE), object()])


def test_state_machine_error_is_a_value_error() -> None:
    """StateMachineError 继承 ValueError（接口契约），便于调用方统一捕获参数错误。"""
    assert issubclass(StateMachineError, ValueError)


def test_value_objects_are_frozen() -> None:
    """Transition / StateUpdate 是冻结值对象：不可就地修改（共享与留存的前提）。"""
    transition = Transition(STATE_S, STATE_T, ALWAYS_TRUE, label="s->t")
    update = StateUpdate(
        state=STATE_S, previous_state=STATE_S, changed=False, entered=None, left=None
    )
    with pytest.raises(FrozenInstanceError):
        transition.label = "changed"
    with pytest.raises(FrozenInstanceError):
        update.changed = True


# ---------------------------------------------------------------------------
# 深蹲仿真：抖动不得造成重复计数式的连续状态翻转
# ---------------------------------------------------------------------------


def test_jittery_squat_series_yields_one_clean_rep_without_spurious_flips() -> None:
    """带抖动的完整深蹲：恰好 4 次真实相位转移——无虚假转移、无重复进入、无连续翻转。"""
    machine = _squat_machine()
    series = _jittery_squat_knee_series()
    updates = _run(machine, _knee_frames(series))

    # 相位链恰好走一圈，且没有任何状态被二次进入（二次进入 = 虚假 rep 的根源）
    assert _entered_states(updates) == [DESCENT, BOTTOM, ASCENT, STANDING]
    assert machine.state == STANDING
    assert updates[-1].state == STANDING

    # 任意两次转移之间至少间隔 min_dwell 帧：结构上不可能出现连续帧翻转
    changes = _changed_indices(updates)
    assert len(changes) == 4
    assert all(second - first >= DEFAULT_MIN_DWELL for first, second in pairwise(changes))

    # 下蹲段的 95° 伪帧尖刺不得提前把状态推进到 BOTTOM
    glitch_index = series.index(GLITCH_KNEE_DEG)
    first_bottom_index = next(
        index for index, update in enumerate(updates) if update.entered == BOTTOM
    )
    assert first_bottom_index > glitch_index


def test_jittery_squat_series_would_flap_without_debounce() -> None:
    """对照实验：同一条抖动序列在关闭防抖的裸配置下产生虚假转移（重复进入 DESCENT）。

    它证明前一个测试的「恰好一次干净 rep」并非序列太温和，而是三层防抖在起作用。
    """
    naive_updates = _run(_naive_squat_machine(), _knee_frames(_jittery_squat_knee_series()))
    naive_entered = _entered_states(naive_updates)

    assert len(naive_entered) > 4
    assert naive_entered.count(DESCENT) >= 2  # 站立段的抖动被当成了两次下蹲开始
