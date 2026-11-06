//坐位体前屈动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String sitReachActionCode = 'SRT';
const String sitReachActionNameZh = '坐位体前屈';

abstract final class SitReachStates {
  static const String upright = 'SIT_UPRIGHT';
  static const String reaching = 'REACHING';
  static const String holding = 'HOLDING';
  static const String returning = 'RETURNING';
  static const List<String> all = [upright, reaching, holding, returning];
}

const Map<String, Phase> _stateToPhase = {
  SitReachStates.reaching: Phase.descent,
  SitReachStates.holding: Phase.bottom,
  SitReachStates.returning: Phase.ascent,
};

const Map<String, double> _severitySpan = {
  'SRT_KNEE_BENT': 30.0,
  'SRT_BALLISTIC': 4.0,
};

ActionDefinition buildSitReach(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.oblique45,
}) {
  final cfg = config ??
      TrackingConfig(cameraView: cameraView, maxRepFrames: 600);
  final uprightLine = cfg.sitReachUprightDeg;
  final holdingLine = cfg.sitReachHoldingDeg;
  final hysteresis = cfg.sitReachHysteresisDeg;

  if (!(holdingLine + hysteresis < uprightLine - hysteresis)) {
    throw ExerciseException(
      '坐位体前屈的分段线顺序非法，必须 sitReachHoldingDeg + sitReachHysteresis'
      '(=${holdingLine + hysteresis}) < sitReachUprightDeg − sitReachHysteresis'
      '(=${uprightLine - hysteresis})。常见成因：把保持线抬得太高，或把坐直线压得太低。',
    );
  }
  double? hipAngle(Signals signals) => signals['hip_angle_L'];

  bool startedReaching(Signals signals) {
    final value = hipAngle(signals);
    return value != null && value < uprightLine - hysteresis;
  }

  bool reachedBottom(Signals signals) {
    final value = hipAngle(signals);
    return value != null && value <= holdingLine;
  }

  bool startedReturning(Signals signals) {
    final value = hipAngle(signals);
    return value != null && value > holdingLine + hysteresis;
  }

  bool satUpright(Signals signals) {
    final value = hipAngle(signals);
    return value != null && value >= uprightLine;
  }

  bool reachedAgain(Signals signals) {
    final value = hipAngle(signals);
    return value != null && value <= holdingLine;
  }
  final guards = <(String, String, Guard, String)>[
    (
      SitReachStates.upright,
      SitReachStates.reaching,
      startedReaching,
      'upright->reaching'
    ),
    (
      SitReachStates.reaching,
      SitReachStates.holding,
      reachedBottom,
      'reaching->holding'
    ),
    (
      SitReachStates.reaching,
      SitReachStates.upright,
      satUpright,
      'reaching->upright(假动作)'
    ),
    (
      SitReachStates.holding,
      SitReachStates.returning,
      startedReturning,
      'holding->returning'
    ),
    (
      SitReachStates.returning,
      SitReachStates.upright,
      satUpright,
      'returning->upright'
    ),
    (
      SitReachStates.returning,
      SitReachStates.holding,
      reachedAgain,
      'returning->holding(回退)'
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'SRT_KNEE_BENT',
      nameZh: '屈膝',
      metric: 'knee_angle_L',
      thresholdKey: 'srt.knee_angle_min',
      badSide: Direction.below,
      phase: Phase.bottom,
      reduce: Reduce.min,
      severitySpan: _severitySpan['SRT_KNEE_BENT']!,
    ),
    Rule(
      code: 'SRT_BALLISTIC',
      nameZh: '弹振借力',
      metric: 'hip_angle_L',
      thresholdKey: 'srt.ballistic_reversals_max',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.reversals,
      severitySpan: _severitySpan['SRT_BALLISTIC']!,
    ),
  ];
  return ActionDefinition(
    code: sitReachActionCode,
    nameZh: sitReachActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: SitReachStates.all,
    restingState: SitReachStates.upright,
    bottomState: SitReachStates.holding,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
  );
}
