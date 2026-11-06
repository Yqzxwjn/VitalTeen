//深蹲动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String squatActionCode = 'SQUAT';
const String squatActionNameZh = '深蹲';

abstract final class SquatStates {
  static const String standing = 'STANDING';
  static const String descent = 'DESCENT';
  static const String bottom = 'BOTTOM';
  static const String ascent = 'ASCENT';
  static const List<String> all = [standing, descent, bottom, ascent];
}

const Map<String, Phase> _stateToPhase = {
  SquatStates.descent: Phase.descent,
  SquatStates.bottom: Phase.bottom,
  SquatStates.ascent: Phase.ascent,
};

const Map<String, double> _severitySpan = {
  'KNEE_VALGUS': 8.0,
  'INSUFFICIENT_DEPTH': 40.0,
  'EXCESSIVE_TRUNK_LEAN': 15.0,
  'HEEL_RISE': 0.15,
  'ASYMMETRY': 0.10,
};

const int _minViolatingFrames = 2;

double? _meanKnee(Signals signals) {
  final left = signals['knee_angle_L'];
  final right = signals['knee_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildSquat(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.sagittal,
}) {
  final cfg = config ?? TrackingConfig(cameraView: cameraView);
  final stand = calibration.kneeAngle;
  final hysteresis = cfg.standingHysteresisDeg;
  final bendLine = stand - cfg.minBendDeg;

  bool leftStanding(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee < stand - hysteresis;
  }

  bool atBendLine(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee <= bendLine;
  }

  bool roseAboveBendLine(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee > bendLine + hysteresis;
  }

  bool returnedToStanding(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee > stand - hysteresis;
  }
  final guards = <(String, String, Guard, String)>[
    (SquatStates.standing, SquatStates.descent, leftStanding, 'standing->descent'),
    (SquatStates.descent, SquatStates.bottom, atBendLine, 'descent->bottom'),
    (
      SquatStates.descent,
      SquatStates.standing,
      returnedToStanding,
      'descent->standing(假动作)',
    ),
    (SquatStates.bottom, SquatStates.ascent, roseAboveBendLine, 'bottom->ascent'),
    (SquatStates.ascent, SquatStates.standing, returnedToStanding, 'ascent->standing'),
    (
      SquatStates.ascent,
      SquatStates.descent,
      atBendLine,
      'ascent->descent(回蹲)',
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'INSUFFICIENT_DEPTH',
      nameZh: '下蹲深度不足',
      metric: 'knee_angle_L',
      thresholdKey: 'squat.min_depth_knee_angle',
      badSide: Direction.above,
      phase: Phase.bottom,
      reduce: Reduce.min,
      severitySpan: _severitySpan['INSUFFICIENT_DEPTH']!,
    ),
    Rule(
      code: 'KNEE_VALGUS',
      nameZh: '膝内扣',
      metric: 'frontal_knee_angle_max',
      thresholdKey: 'squat.knee_valgus_angle_notice',
      badSide: Direction.above,
      phase: Phase.bottom,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['KNEE_VALGUS']!,
    ),
    Rule(
      code: 'EXCESSIVE_TRUNK_LEAN',
      nameZh: '躯干过度前倾',
      metric: 'trunk_lean',
      thresholdKey: 'squat.trunk_lean_max_delta',
      badSide: Direction.above,
      phase: Phase.bottom,
      useAbs: true,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['EXCESSIVE_TRUNK_LEAN']!,
    ),
    Rule(
      code: 'HEEL_RISE',
      nameZh: '脚跟离地',
      metric: 'heel_rise_ratio_L',
      thresholdKey: 'squat.heel_rise_ratio_max_delta',
      badSide: Direction.above,
      phase: Phase.bottom,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['HEEL_RISE']!,
    ),
    Rule(
      code: 'ASYMMETRY',
      nameZh: '左右不对称',
      metric: 'knee_symmetry',
      thresholdKey: 'squat.asymmetry_index_max',
      badSide: Direction.above,
      phase: Phase.bottom,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['ASYMMETRY']!,
    ),
  ];
  return ActionDefinition(
    code: squatActionCode,
    nameZh: squatActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: SquatStates.all,
    restingState: SquatStates.standing,
    bottomState: SquatStates.bottom,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {
      'squat.trunk_lean_max_delta': BaselineOffset(BaselineKey.trunkLean, 1.0),
      'squat.heel_rise_ratio_max_delta':
          BaselineOffset(BaselineKey.heelRiseRatio, 1.0),
    },
  );
}
