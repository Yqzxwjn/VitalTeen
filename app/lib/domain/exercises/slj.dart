//立定跳远动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String sljActionCode = 'SLJ';
const String sljActionNameZh = '立定跳远';

abstract final class SljStates {
  static const String standing = 'STANDING';
  static const String prep = 'PREP';
  static const String launch = 'LAUNCH';
  static const String flight = 'FLIGHT';
  static const String land = 'LAND';
  static const List<String> all = [standing, prep, launch, flight, land];
}

const Map<String, Phase> _stateToPhase = {
  SljStates.prep: Phase.prep,
  SljStates.launch: Phase.takeoff,
  SljStates.flight: Phase.flight,
  SljStates.land: Phase.landing,
};

const Map<String, double> _severitySpan = {
  'SLJ_PREJUMP_HEEL_OFF': 0.15,
  'SLJ_TAKEOFF_ASYNC': 0.10,
  'SLJ_LAND_ASYNC': 0.10,
  'SLJ_LAND_STIFF': 30.0,
  'SLJ_TRUNK_CONTROL': 15.0,
};

const int _minViolatingFrames = 2;

double? _meanKnee(Signals signals) {
  final left = signals['knee_angle_L'];
  final right = signals['knee_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildSlj(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.oblique45,
}) {
  final cfg = config ??
      TrackingConfig(
        cameraView: cameraView,
        minBendDeg: 25.0,
        maxRepFrames: 120,
      );
  final stand = calibration.kneeAngle;
  final hysteresis = cfg.standingHysteresisDeg;
  final bendLine = stand - cfg.minBendDeg;
  final riseLine = bendLine + hysteresis;
  final landLine = stand - cfg.landingFlexDeg;
  final standLine = stand - hysteresis;
  final flyLine = stand - cfg.flightExtensionDeg;

  if (!(bendLine < riseLine &&
      riseLine < landLine &&
      landLine < standLine &&
      standLine < flyLine)) {
    throw ExerciseException(
      '立定跳远的分段线顺序非法，必须 bend(=$bendLine) < rise(=$riseLine) '
      '< land(=$landLine) < stand(=$standLine) < fly(=$flyLine)。'
      '常见成因：landingFlexDeg 小于等于 standingHysteresisDeg（落地线与'
      '站立线撞在一起，LAND 会一闪而过），或 flightExtensionDeg 太大'
      '（腾空线落到落地线以下）。',
    );
  }

  bool crouched(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee <= bendLine;
  }

  bool pushingOff(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee > riseLine;
  }

  bool extended(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee > flyLine;
  }

  bool absorbing(Signals signals) {
    final knee = _meanKnee(signals);
    final hip = signals['hip_height_ratio'];
    return knee != null &&
        hip != null &&
        knee < landLine &&
        hip > cfg.landingHipFloor;
  }

  bool returnedToStanding(Signals signals) {
    final knee = _meanKnee(signals);
    return knee != null && knee > standLine;
  }
  final guards = <(String, String, Guard, String)>[
    (SljStates.standing, SljStates.prep, crouched, 'standing->prep（起势）'),
    (SljStates.prep, SljStates.launch, pushingOff, 'prep->launch（蹬伸）'),
    (
      SljStates.launch,
      SljStates.prep,
      crouched,
      'launch->prep（回蹲）',
    ),
    (
      SljStates.launch,
      SljStates.flight,
      extended,
      'launch->flight（蹬直≈离地）',
    ),
    (
      SljStates.flight,
      SljStates.land,
      absorbing,
      'flight->land（落地缓冲）',
    ),
    (
      SljStates.land,
      SljStates.standing,
      returnedToStanding,
      'land->standing（封存）',
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'SLJ_PREJUMP_HEEL_OFF',
      nameZh: '起跳前前掌离地',
      metric: 'heel_rise_ratio_L',
      thresholdKey: 'slj.prejump_foot_off_max_delta',
      badSide: Direction.above,
      phase: Phase.prep,
      useAbs: true,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['SLJ_PREJUMP_HEEL_OFF']!,
    ),
    Rule(
      code: 'SLJ_TAKEOFF_ASYNC',
      nameZh: '起跳双脚不同步',
      metric: 'knee_symmetry',
      thresholdKey: 'slj.takeoff_symmetry_max',
      badSide: Direction.above,
      phase: Phase.takeoff,
      reduce: Reduce.max,
      severitySpan: _severitySpan['SLJ_TAKEOFF_ASYNC']!,
    ),
    Rule(
      code: 'SLJ_LAND_ASYNC',
      nameZh: '落地双脚不同步',
      metric: 'knee_symmetry',
      thresholdKey: 'slj.landing_symmetry_max',
      badSide: Direction.above,
      phase: Phase.landing,
      reduce: Reduce.max,
      severitySpan: _severitySpan['SLJ_LAND_ASYNC']!,
    ),
    Rule(
      code: 'SLJ_LAND_STIFF',
      nameZh: '落地缓冲不足',
      metric: 'knee_angle_L',
      thresholdKey: 'slj.landing_buffer_min_knee_angle',
      badSide: Direction.above,
      phase: Phase.landing,
      reduce: Reduce.min,
      severitySpan: _severitySpan['SLJ_LAND_STIFF']!,
    ),
    Rule(
      code: 'SLJ_TRUNK_CONTROL',
      nameZh: '躯干控制不足',
      metric: 'trunk_lean',
      thresholdKey: 'slj.trunk_lean_max_delta',
      badSide: Direction.above,
      phase: Phase.takeoff,
      useAbs: true,
      reduce: Reduce.max,
      severitySpan: _severitySpan['SLJ_TRUNK_CONTROL']!,
    ),
  ];
  return ActionDefinition(
    code: sljActionCode,
    nameZh: sljActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: SljStates.all,
    restingState: SljStates.standing,
    bottomState: SljStates.land,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    lossRecovery: const {SljStates.launch: SljStates.flight},
    thresholdOffsets: const {
      'slj.prejump_foot_off_max_delta':
          BaselineOffset(BaselineKey.heelRiseRatio, 1.0),
      'slj.trunk_lean_max_delta': BaselineOffset(BaselineKey.trunkLean, 1.0),
    },
  );
}
