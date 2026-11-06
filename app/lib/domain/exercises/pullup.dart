//引体向上动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String pullupActionCode = 'PULLUP';
const String pullupActionNameZh = '引体向上';

abstract final class PullupStates {
  static const String hang = 'HANG';
  static const String pulling = 'PULLING';
  static const String top = 'TOP';
  static const String lowering = 'LOWERING';
  static const List<String> all = [hang, pulling, top, lowering];
}

const Map<String, Phase> _stateToPhase = {
  PullupStates.pulling: Phase.descent,
  PullupStates.top: Phase.apex,
  PullupStates.lowering: Phase.ascent,
};

const Map<String, double> _severitySpan = {
  'PULLUP_NOT_DEAD_HANG': 15.0,
  'PULLUP_CHIN_NOT_OVER': 0.25,
  'PULLUP_SWING': 20.0,
};

const int _minViolatingFrames = 2;

double? _meanElbow(Signals signals) {
  final left = signals['elbow_angle_L'];
  final right = signals['elbow_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildPullup(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.oblique45,
}) {
  final cfg = config ??
      TrackingConfig(cameraView: cameraView, maxRepFrames: 180);
  final hangLine = cfg.pullupHangDeg;
  final topLine = cfg.pullupTopDeg;
  final hysteresis = cfg.standingHysteresisDeg;

  if (!(topLine < hangLine)) {
    throw ExerciseException(
      '引体向上的分段线顺序非法，必须 pullupTopDeg(=$topLine) < '
      'pullupHangDeg(=$hangLine)。常见成因：把两条线的含义写反了'
      '（顶部是肘角**小**的那一端）。',
    );
  }

  bool leftHang(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow < hangLine;
  }

  bool atTopLine(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow <= topLine;
  }

  bool roseAboveTopLine(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow > topLine + hysteresis;
  }

  bool returnedToHang(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow > hangLine;
  }
  final guards = <(String, String, Guard, String)>[
    (PullupStates.hang, PullupStates.pulling, leftHang, 'hang->pulling（起拉）'),
    (PullupStates.pulling, PullupStates.top, atTopLine, 'pulling->top（到顶）'),
    (
      PullupStates.pulling,
      PullupStates.hang,
      returnedToHang,
      'pulling->hang（假动作）',
    ),
    (
      PullupStates.top,
      PullupStates.lowering,
      roseAboveTopLine,
      'top->lowering（开始下放）',
    ),
    (PullupStates.lowering, PullupStates.hang, returnedToHang, 'lowering->hang（封存）'),
    (
      PullupStates.lowering,
      PullupStates.pulling,
      atTopLine,
      'lowering->pulling（回拉）',
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'PULLUP_NOT_DEAD_HANG',
      nameZh: '未回到直臂悬垂',
      metric: 'elbow_angle_L',
      thresholdKey: 'pullup.dead_hang_min_elbow',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.max,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PULLUP_NOT_DEAD_HANG']!,
    ),
    Rule(
      code: 'PULLUP_CHIN_NOT_OVER',
      nameZh: '下颌未过杠',
      metric: 'mouth_wrist_dy',
      thresholdKey: 'pullup.chin_over_dy_max',
      badSide: Direction.above,
      phase: Phase.apex,
      reduce: Reduce.min,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PULLUP_CHIN_NOT_OVER']!,
    ),
    Rule(
      code: 'PULLUP_SWING',
      nameZh: '身体摆动借力',
      metric: 'trunk_lean',
      thresholdKey: 'pullup.swing_max_lean_deg',
      badSide: Direction.above,
      phase: Phase.all,
      useAbs: true,
      reduce: Reduce.max,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PULLUP_SWING']!,
    ),
  ];
  return ActionDefinition(
    code: pullupActionCode,
    nameZh: pullupActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: PullupStates.all,
    restingState: PullupStates.hang,
    bottomState: PullupStates.top,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
  );
}
