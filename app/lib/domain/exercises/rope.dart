//跳绳动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String ropeActionCode = 'ROPE';
const String ropeActionNameZh = '跳绳';

abstract final class RopeStates {
  static const String ground = 'GROUND';
  static const String air = 'AIR';
  static const String cushion = 'CUSHION';
  static const List<String> all = [ground, air, cushion];
}

const Map<String, Phase> _stateToPhase = {};

const Map<String, double> _severitySpan = {
  'ROPE_LOW_BUFFER': 30.0,
  'ROPE_TRUNK_LEAN': 15.0,
  'ROPE_SINGLE_LEG': 0.20,
};

const int _minViolatingFrames = 2;

double? _meanKnee(Signals signals) {
  final left = signals['knee_angle_L'];
  final right = signals['knee_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildRope(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.oblique45,
}) {
  final cfg = config ??
      TrackingConfig(
        cameraView: cameraView,
        maxRepFrames: 60,
        minDwellFrames: 1,
        voteWindow: 2,
        voteRequired: 2,
      );
  final base = calibration.footHeight ??
      (throw const ExerciseException('跳绳需要站立时的脚尖高度基线'));
  final settleLine = base + cfg.ropeSettleRatio;
  final landLine = base + cfg.ropeLandRatio;
  final takeoffLine = base + cfg.ropeTakeoffRatio;
  final standLine = calibration.kneeAngle - cfg.standingHysteresisDeg;

  if (!(settleLine < landLine && landLine < takeoffLine)) {
    throw ExerciseException(
      '跳绳的分段线顺序非法，必须 settle(=$settleLine) < land(=$landLine) '
      '< takeoff(=$takeoffLine)。常见成因：把 ropeTakeoffRatio 调到 '
      'ropeLandRatio 以下（两条线撞在一起，AIR 会一闪而过），'
      '或把 ropeSettleRatio 调到 ropeLandRatio 以上（CUSHION 一进去就被封存，'
      '落地缓冲那一段又落回窗口之外）。',
    );
  }
  double? footHeight(Signals signals) => signals['foot_height_ratio'];

  bool tookOff(Signals signals) {
    final value = footHeight(signals);
    return value != null && value > takeoffLine;
  }

  bool landed(Signals signals) {
    final value = footHeight(signals);
    return value != null && value < landLine;
  }

  bool recovered(Signals signals) {
    final value = footHeight(signals);
    final knee = _meanKnee(signals);
    return value != null &&
        knee != null &&
        value < settleLine &&
        knee > standLine;
  }
  final guards = <(String, String, Guard, String)>[
    (
      RopeStates.ground,
      RopeStates.air,
      tookOff,
      'ground->air（起跳）',
    ),
    (
      RopeStates.air,
      RopeStates.cushion,
      landed,
      'air->cushion（触地）',
    ),
    (
      RopeStates.cushion,
      RopeStates.ground,
      recovered,
      'cushion->ground（封存）',
    ),
    (
      RopeStates.cushion,
      RopeStates.air,
      tookOff,
      'cushion->air（又跳起来）',
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'ROPE_LOW_BUFFER',
      nameZh: '落地缓冲不足',
      metric: 'knee_angle_L',
      thresholdKey: 'rope.buffer_max_knee_angle',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.min,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['ROPE_LOW_BUFFER']!,
    ),
    Rule(
      code: 'ROPE_TRUNK_LEAN',
      nameZh: '躯干前倾',
      metric: 'trunk_lean',
      thresholdKey: 'rope.trunk_lean_max_delta',
      badSide: Direction.above,
      phase: Phase.all,
      useAbs: true,
      reduce: Reduce.max,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['ROPE_TRUNK_LEAN']!,
    ),
    Rule(
      code: 'ROPE_SINGLE_LEG',
      nameZh: '单脚落地',
      metric: 'foot_gap_ratio',
      thresholdKey: 'rope.foot_gap_max_ratio',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.max,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['ROPE_SINGLE_LEG']!,
    ),
  ];
  return ActionDefinition(
    code: ropeActionCode,
    nameZh: ropeActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: RopeStates.all,
    restingState: RopeStates.ground,
    bottomState: RopeStates.air,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {
      'rope.trunk_lean_max_delta': BaselineOffset(BaselineKey.trunkLean, 1.0),
    },
  );
}
