//仰卧起坐动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String situpActionCode = 'SU';
const String situpActionNameZh = '仰卧起坐';

abstract final class SitupStates {
  static const String lying = 'LYING';
  static const String rising = 'RISING';
  static const String seated = 'SEATED';
  static const String lowering = 'LOWERING';
  static const List<String> all = [lying, rising, seated, lowering];
}

const Map<String, Phase> _stateToPhase = {
  SitupStates.lowering: Phase.descent,
  SitupStates.lying: Phase.bottom,
  SitupStates.rising: Phase.ascent,
};

const Map<String, double> _severitySpan = {
  'SU_SHOULDER_NOT_GROUND': 0.15,
  'SU_HIP_LIFT': 0.15,
  'SU_KNEE_ANGLE': 30.0,
};

ActionDefinition buildSitUp(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.oblique45,
}) {
  final cfg = config ??
      TrackingConfig(cameraView: cameraView, maxRepFrames: 600);
  final lieLine = cfg.situpLieRatio;
  final seatLine = cfg.situpSeatRatio;
  final hysteresis = cfg.situpHysteresis;

  if (!(lieLine + hysteresis < seatLine - hysteresis)) {
    throw ExerciseException(
      '仰卧起坐的分段线顺序非法，必须 situpLieRatio + situpHysteresis'
      '(=${lieLine + hysteresis}) < situpSeatRatio − situpHysteresis'
      '(=${seatLine - hysteresis})。常见成因：把躺平线抬得太高，或把坐起线压得太低。',
    );
  }
  double? shoulderHeight(Signals signals) => signals['shoulder_height_ratio'];

  bool startedLowering(Signals signals) {
    final value = shoulderHeight(signals);
    return value != null && value < seatLine - hysteresis;
  }

  bool reachedMat(Signals signals) {
    final value = shoulderHeight(signals);
    return value != null && value <= lieLine;
  }

  bool startedRising(Signals signals) {
    final value = shoulderHeight(signals);
    return value != null && value > lieLine + hysteresis;
  }

  bool seatedUp(Signals signals) {
    final value = shoulderHeight(signals);
    return value != null && value >= seatLine;
  }

  bool fellBack(Signals signals) {
    final value = shoulderHeight(signals);
    return value != null && value < lieLine;
  }
  final guards = <(String, String, Guard, String)>[
    (SitupStates.seated, SitupStates.lowering, startedLowering, 'seated->lowering'),
    (SitupStates.lowering, SitupStates.lying, reachedMat, 'lowering->lying'),
    (SitupStates.lowering, SitupStates.seated, seatedUp, 'lowering->seated(假动作)'),
    (SitupStates.lying, SitupStates.rising, startedRising, 'lying->rising'),
    (SitupStates.rising, SitupStates.seated, seatedUp, 'rising->seated'),
    (SitupStates.rising, SitupStates.lying, fellBack, 'rising->lying(回退)'),
  ];
  final rules = <Rule>[
    Rule(
      code: 'SU_SHOULDER_NOT_GROUND',
      nameZh: '肩胛未触垫',
      metric: 'shoulder_height_ratio',
      thresholdKey: 'su.shoulder_to_mat_ratio_max',
      badSide: Direction.above,
      phase: Phase.bottom,
      reduce: Reduce.min,
      severitySpan: _severitySpan['SU_SHOULDER_NOT_GROUND']!,
    ),
    Rule(
      code: 'SU_HIP_LIFT',
      nameZh: '臀离垫借力',
      metric: 'body_line_offset_ratio',
      thresholdKey: 'su.hip_lift_ratio_min',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.min,
      severitySpan: _severitySpan['SU_HIP_LIFT']!,
    ),
    Rule(
      code: 'SU_KNEE_ANGLE',
      nameZh: '屈膝角度不符',
      metric: 'knee_angle_L',
      thresholdKey: 'su.knee_angle_max',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.max,
      severitySpan: _severitySpan['SU_KNEE_ANGLE']!,
    ),
  ];
  return ActionDefinition(
    code: situpActionCode,
    nameZh: situpActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: SitupStates.all,
    restingState: SitupStates.seated,
    bottomState: SitupStates.lying,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
  );
}
