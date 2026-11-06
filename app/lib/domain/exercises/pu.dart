//俯卧撑动作定义
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String puActionCode = 'PU';
const String puActionNameZh = '俯卧撑';

abstract final class PuStates {
  static const String top = 'TOP';
  static const String down = 'DOWN';
  static const String bottom = 'BOTTOM';
  static const String up = 'UP';
  static const List<String> all = [top, down, bottom, up];
}

const Map<String, Phase> _stateToPhase = {
  PuStates.down: Phase.descent,
  PuStates.bottom: Phase.bottom,
  PuStates.up: Phase.ascent,
};

const Map<String, double> _severitySpan = {
  'PU_INSUFFICIENT_DEPTH': 40.0,
  'PU_INCOMPLETE_EXTENSION': 15.0,
  'PU_HIP_SAG': 0.15,
  'PU_HIP_PIKE': 0.15,
};

double? _meanElbow(Signals signals) {
  final left = signals['elbow_angle_L'];
  final right = signals['elbow_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildPushUp(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.sagittal,
}) {
  final cfg = config ??
      TrackingConfig(cameraView: cameraView, maxRepFrames: 150);
  final topLine = cfg.pushupTopDeg;
  final depthLine = cfg.pushupDepthDeg;
  final hysteresis = cfg.standingHysteresisDeg;

  if (!(depthLine < topLine)) {
    throw ExerciseException(
      '俯卧撑的分段线顺序非法，必须 pushupDepthDeg(=$depthLine) < '
      'pushupTopDeg(=$topLine)。常见成因：把两条线的含义写反了。',
    );
  }

  bool leftTop(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow < topLine;
  }

  bool atDepthLine(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow <= depthLine;
  }

  bool roseAboveDepthLine(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow > depthLine + hysteresis;
  }

  bool returnedToTop(Signals signals) {
    final elbow = _meanElbow(signals);
    return elbow != null && elbow > topLine;
  }
  final guards = <(String, String, Guard, String)>[
    (PuStates.top, PuStates.down, leftTop, 'top->down'),
    (PuStates.down, PuStates.bottom, atDepthLine, 'down->bottom'),
    (PuStates.down, PuStates.top, returnedToTop, 'down->top(假动作)'),
    (PuStates.bottom, PuStates.up, roseAboveDepthLine, 'bottom->up'),
    (PuStates.up, PuStates.top, returnedToTop, 'up->top'),
    (PuStates.up, PuStates.down, atDepthLine, 'up->down(回压)'),
  ];
  final rules = <Rule>[
    Rule(
      code: 'PU_INSUFFICIENT_DEPTH',
      nameZh: '俯卧撑深度不足',
      metric: 'elbow_angle_L',
      thresholdKey: 'pu.min_depth_elbow_angle',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.min,
      severitySpan: _severitySpan['PU_INSUFFICIENT_DEPTH']!,
    ),
    Rule(
      code: 'PU_INCOMPLETE_EXTENSION',
      nameZh: '顶部手臂未伸直',
      metric: 'elbow_angle_L',
      thresholdKey: 'pu.top_extension_elbow_angle',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.max,
      severitySpan: _severitySpan['PU_INCOMPLETE_EXTENSION']!,
    ),
    Rule(
      code: 'PU_HIP_SAG',
      nameZh: '塌腰',
      metric: 'body_line_offset_ratio',
      thresholdKey: 'pu.hip_sag_ratio_max',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.max,
      severitySpan: _severitySpan['PU_HIP_SAG']!,
    ),
    Rule(
      code: 'PU_HIP_PIKE',
      nameZh: '撅臀',
      metric: 'body_line_offset_ratio',
      thresholdKey: 'pu.hip_pike_ratio_min',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.min,
      severitySpan: _severitySpan['PU_HIP_PIKE']!,
    ),
  ];
  return ActionDefinition(
    code: puActionCode,
    nameZh: puActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: PuStates.all,
    restingState: PuStates.top,
    bottomState: PuStates.bottom,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
  );
}
