//平板支撑动作定义（计时制）
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String plankActionCode = 'PLANK';
const String plankActionNameZh = '平板支撑';

abstract final class PlankStates {
  static const String holdBreak = 'HOLD_BREAK';
  static const String holdOk = 'HOLD_OK';
  static const List<String> all = [holdOk, holdBreak];
}

const Map<String, Phase> _stateToPhase = {};

const Map<String, double> _severitySpan = {
  'PLANK_HIP_SAG': 0.15,
  'PLANK_HIP_PIKE': 0.15,
  'PLANK_ELBOW': 20.0,
};

const int _minViolatingFrames = 8;

double? _meanElbow(Signals signals) {
  final left = signals['elbow_angle_L'];
  final right = signals['elbow_angle_R'];
  final values = <double>[?left, ?right];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

ActionDefinition buildPlank(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.sagittal,
}) {
  final cfg = config ??
      TrackingConfig(cameraView: cameraView, maxRepFrames: 3600);
  final lieDeg = cfg.plankLieDeg;
  final hysteresis = cfg.standingHysteresisDeg;
  final enterRatio = cfg.plankLineEnterRatio;
  final exitRatio = cfg.plankLineExitRatio;
  final elbowMin = cfg.plankElbowMinDeg;
  final elbowMax = cfg.plankElbowMaxDeg;

  if (!(exitRatio > enterRatio)) {
    throw ExerciseException(
      '平板支撑的体线容差顺序非法，必须 plankLineEnterRatio(=$enterRatio) < '
      'plankLineExitRatio(=$exitRatio)。两者之间是滞回带，写反或写等会让髋在'
      '边界上抖一帧就把一次支撑切成两段。',
    );
  }
  if (!(lieDeg > hysteresis)) {
    throw ExerciseException(
      '平板支撑的身体放平线太小：plankLieDeg(=$lieDeg) 必须大于 '
      'standingHysteresisDeg(=$hysteresis)，否则退出线（放平线减滞回）'
      '落到 0 附近，站着的人也会被读成「身体放平了」。',
    );
  }
  if (!(elbowMin < elbowMax)) {
    throw ExerciseException(
      '平板支撑的支撑带上下沿写反了：必须 plankElbowMinDeg(=$elbowMin) < '
      'plankElbowMaxDeg(=$elbowMax)。',
    );
  }
  if (!(elbowMax + hysteresis < 180.0)) {
    throw ExerciseException(
      '平板支撑的支撑带上沿太高：plankElbowMaxDeg(=$elbowMax) 加上滞回 '
      '$hysteresis 之后必须仍低于 180°（手臂伸直）。够到 180° 的话，'
      '站着或趴着放松（肘角≈180°）也会落进支撑带，光靠肘角就分不出'
      '「撑着」与「站着」。',
    );
  }

  bool inSupport(Signals signals, {required double ratio}) {
    final lean = signals['trunk_lean'];
    final offset = signals['body_line_offset_ratio'];
    final elbow = _meanElbow(signals);
    if (lean == null || offset == null || elbow == null) return false;
    return lean.abs() >= lieDeg &&
        offset.abs() <= ratio &&
        elbow >= elbowMin &&
        elbow <= elbowMax;
  }
  bool enteredHold(Signals signals) => inSupport(signals, ratio: enterRatio);

  bool leftHold(Signals signals) {
    final lean = signals['trunk_lean'];
    final offset = signals['body_line_offset_ratio'];
    final elbow = _meanElbow(signals);
    if (lean == null || offset == null || elbow == null) return false;
    final stillHolding = lean.abs() >= lieDeg - hysteresis &&
        offset.abs() <= exitRatio &&
        elbow >= elbowMin - hysteresis &&
        elbow <= elbowMax + hysteresis;
    return !stillHolding;
  }
  final guards = <(String, String, Guard, String)>[
    (PlankStates.holdBreak, PlankStates.holdOk, enteredHold, 'break->ok'),
    (PlankStates.holdOk, PlankStates.holdBreak, leftHold, 'ok->break'),
  ];
  final rules = <Rule>[
    Rule(
      code: 'PLANK_HIP_SAG',
      nameZh: '塌腰',
      metric: 'body_line_offset_ratio',
      thresholdKey: 'plank.hip_sag_ratio_max',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.anyFrame,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PLANK_HIP_SAG']!,
    ),
    Rule(
      code: 'PLANK_HIP_PIKE',
      nameZh: '撅臀',
      metric: 'body_line_offset_ratio',
      thresholdKey: 'plank.hip_pike_ratio_min',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.anyFrame,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PLANK_HIP_PIKE']!,
    ),
    Rule(
      code: 'PLANK_ELBOW',
      nameZh: '肘角偏离',
      metric: 'elbow_angle_L',
      thresholdKey: 'plank.elbow_angle_max',
      badSide: Direction.above,
      phase: Phase.all,
      reduce: Reduce.anyFrame,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PLANK_ELBOW']!,
    ),
    Rule(
      code: 'PLANK_ELBOW',
      nameZh: '肘角偏离',
      metric: 'elbow_angle_L',
      thresholdKey: 'plank.elbow_angle_min',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.anyFrame,
      minViolatingFrames: _minViolatingFrames,
      severitySpan: _severitySpan['PLANK_ELBOW']!,
    ),
  ];
  return ActionDefinition(
    code: plankActionCode,
    nameZh: plankActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: PlankStates.all,
    restingState: PlankStates.holdBreak,
    bottomState: PlankStates.holdOk,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
  );
}
