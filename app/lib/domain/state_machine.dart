//通用动作状态机，三层防抖
library;

import 'dart:collection';

typedef Signals = Map<String, double?>;

typedef Guard = bool Function(Signals signals);

class StateMachineException implements Exception {
  const StateMachineException(this.message);
  final String message;
  @override
  String toString() => 'StateMachineException: $message';
}

int _requireFrameCount(String name, int value, {int minimum = 0}) {
  if (value < minimum) {
    throw StateMachineException('$name 不能小于 $minimum，实际为 $value');
  }
  return value;
}

class Transition {
  const Transition({
    required this.src,
    required this.dst,
    required this.guard,
    this.label,
  });
  final String src;
  final String dst;
  final Guard guard;
  final String? label;
  @override
  String toString() => 'Transition(${label ?? "$src->$dst"})';
}

class StateUpdate {
  const StateUpdate({
    required this.state,
    required this.previousState,
    required this.changed,
    this.entered,
    this.left,
  });
  final String state;
  final String previousState;
  final bool changed;
  final String? entered;
  final String? left;
  @override
  String toString() =>
      'StateUpdate($previousState -> $state${changed ? "" : " (unchanged)"})';
}

class StateMachine {
  StateMachine({
    required this.initialState,
    required List<Transition> transitions,
    int minDwellFrames = 3,
    int voteWindow = 5,
    int voteRequired = 4,
  })  : minDwellFrames = _requireFrameCount('minDwellFrames', minDwellFrames),
        voteWindow = _requireFrameCount('voteWindow', voteWindow, minimum: 1),
        voteRequired = _requireFrameCount('voteRequired', voteRequired, minimum: 1) {
    if (this.voteRequired > this.voteWindow) {
      throw StateMachineException(
        'voteRequired（${this.voteRequired}）不能大于 voteWindow（${this.voteWindow}）：'
        '窗口里凑不满这么多真票，状态机将永远无法转移',
      );
    }
    if (transitions.isEmpty) {
      throw const StateMachineException('transitions 不能为空：没有转移的状态机表达不了任何动作');
    }
    for (final transition in transitions) {
      if (transition.src.isEmpty) {
        throw const StateMachineException('转移的 src 必须是非空字符串');
      }
      if (transition.dst.isEmpty) {
        throw const StateMachineException('转移的 dst 必须是非空字符串');
      }
      if (transition.src == transition.dst) {
        throw StateMachineException(
          '转移 ${transition.src}->${transition.dst} 是自环：停留在原状态是引擎的默认行为，'
          '自环只会制造 changed=true 却状态未变的假象',
        );
      }
    }
    final known = <String>{
      for (final t in transitions) ...[t.src, t.dst],
    };
    if (!known.contains(initialState)) {
      throw StateMachineException(
        'initialState=$initialState 未出现在任何转移的 src/dst 中：'
        '该状态触发不了任何转移，多半是状态名拼写错误',
      );
    }
    _transitions = List.unmodifiable(transitions);
    _knownStates = known;
    _currentState = initialState;
    _votes = List.generate(
      _transitions.length,
      (_) => Queue<bool>(),
    );
    _everPassed = List<bool>.filled(_transitions.length, false);
  }
  final String initialState;
  final int minDwellFrames;
  final int voteWindow;
  final int voteRequired;
  late final List<Transition> _transitions;
  late final Set<String> _knownStates;
  late final List<Queue<bool>> _votes;
  String _currentState = '';
  int? _framesSinceTransition;
  int? _lastTimestampMs;
  String get state => _currentState;
  int? get lastTimestampMs => _lastTimestampMs;

  StateUpdate update(Signals signals, int timestampMs) {
    final previous = _currentState;
    _lastTimestampMs = timestampMs;
    final sinceTransition = _framesSinceTransition;
    if (sinceTransition != null) {
      _framesSinceTransition = sinceTransition + 1;
    }
    final dwellSatisfied =
        _framesSinceTransition == null || _framesSinceTransition! >= minDwellFrames;
    Transition? chosen;
    for (var index = 0; index < _transitions.length; index++) {
      final transition = _transitions[index];
      if (transition.src != previous) continue;
      final history = _votes[index];
      final passed = _guardPassed(transition.guard, signals);
      if (passed) _everPassed[index] = true;
      history.addLast(passed);
      while (history.length > voteWindow) {
        history.removeFirst();
      }
      if (chosen == null &&
          dwellSatisfied &&
          history.length >= voteWindow &&
          history.where((v) => v).length >= voteRequired) {
        chosen = transition;
      }
    }
    if (chosen == null) {
      return StateUpdate(
        state: previous,
        previousState: previous,
        changed: false,
      );
    }
    _currentState = chosen.dst;
    _framesSinceTransition = 0;
    for (final history in _votes) {
      history.clear();
    }
    return StateUpdate(
      state: chosen.dst,
      previousState: previous,
      changed: true,
      entered: chosen.dst,
      left: previous,
    );
  }

  void reset({String? target}) {
    if (target == null) {
      _currentState = initialState;
    } else {
      if (!_knownStates.contains(target)) {
        throw StateMachineException(
          'reset 目标 $target 未出现在任何转移的 src/dst 中，多半是拼写错误',
        );
      }
      _currentState = target;
    }
    _framesSinceTransition = null;
    _lastTimestampMs = null;
    for (final history in _votes) {
      history.clear();
    }
  }
  late final List<bool> _everPassed;

  Map<String, bool> guardHealth() => {
        for (var i = 0; i < _transitions.length; i++)
          _transitions[i].label ?? '${_transitions[i].src}->${_transitions[i].dst}':
              _everPassed[i],
      };

  bool _guardPassed(Guard guard, Signals signals) {
    try {
      return guard(signals);
    } catch (_) {
      return false;
    }
  }
}
