//开合跳动作定义（正面机位）
library;

import '../features.dart';
import '../rules.dart';
import '../state_machine.dart';
import 'base.dart';

const String jjActionCode = 'JJ';
const String jjActionNameZh = '开合跳';

abstract final class JjStates {
  static const String closed = 'CLOSED';
  static const String opening = 'OPENING';
  static const String open = 'OPEN';
  static const String closing = 'CLOSING';
  static const List<String> all = [closed, opening, open, closing];
}

const Map<String, Phase> _stateToPhase = {
  JjStates.closing: Phase.contact,
};

const Map<String, double> _severitySpan = {
  'JJ_INSUFFICIENT_SPREAD': 0.5,
  'JJ_INSUFFICIENT_ARM': 30.0,
  'JJ_KNEE_VALGUS': 10.0,
};

ActionDefinition buildJj(
  Calibration calibration, {
  TrackingConfig? config,
  CameraView cameraView = CameraView.frontal,
}) {
  final cfg = config ??
      TrackingConfig(
        cameraView: cameraView,
        maxRepFrames: 90,
      );
  final stand = BaselineKey.legSpread.of(calibration);
  final h = cfg.spreadHysteresis;
  final standLine = stand + h;
  final openLine = stand + cfg.spreadEnterDelta;
  final fullLine = stand + cfg.spreadFullDelta;

  if (!(standLine < openLine && openLine < fullLine)) {
    throw ExerciseException(
      '开合跳的分段线顺序非法，必须 standLine(=$standLine) < '
      'openLine(=$openLine) < fullLine(=$fullLine)。常见成因：'
      'spreadHysteresis 大于等于 spreadEnterDelta（没有起步空间，'
      'CLOSED 与 OPENING 会逐帧来回跳），或 spreadFullDelta 太小'
      '（开到位线与起步线贴住，OPEN 一闪而过）。',
    );
  }
  double? spread(Signals signals) => signals['leg_spread_ratio'];

  bool openedEnough(Signals signals) {
    final value = spread(signals);
    return value != null && value > openLine;
  }

  bool fullyOpen(Signals signals) {
    final value = spread(signals);
    return value != null && value > fullLine;
  }

  bool closing(Signals signals) {
    final value = spread(signals);
    return value != null && value < openLine;
  }

  bool backTogether(Signals signals) {
    final value = spread(signals);
    return value != null && value < standLine;
  }
  final guards = <(String, String, Guard, String)>[
    (JjStates.closed, JjStates.opening, openedEnough, 'closed->opening（起跳）'),
    (
      JjStates.opening,
      JjStates.closed,
      backTogether,
      'opening->closed（开一半又合上）',
    ),
    (JjStates.opening, JjStates.open, fullyOpen, 'opening->open（展开）'),
    (JjStates.open, JjStates.closing, closing, 'open->closing（合拢）'),
    (JjStates.closing, JjStates.open, fullyOpen, 'closing->open（回弹）'),
    (
      JjStates.closing,
      JjStates.closed,
      backTogether,
      'closing->closed（封存）',
    ),
  ];
  final rules = <Rule>[
    Rule(
      code: 'JJ_INSUFFICIENT_SPREAD',
      nameZh: '分腿幅度不足',
      metric: 'leg_spread_ratio',
      thresholdKey: 'jj.spread_min_ratio',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.max,
      severitySpan: _severitySpan['JJ_INSUFFICIENT_SPREAD']!,
    ),
    Rule(
      code: 'JJ_INSUFFICIENT_ARM',
      nameZh: '手臂上举幅度不足',
      metric: 'shoulder_angle_min',
      thresholdKey: 'jj.arm_min_angle',
      badSide: Direction.below,
      phase: Phase.all,
      reduce: Reduce.max,
      severitySpan: _severitySpan['JJ_INSUFFICIENT_ARM']!,
    ),
    Rule(
      code: 'JJ_KNEE_VALGUS',
      nameZh: '落地膝内扣',
      metric: 'frontal_knee_angle_max',
      thresholdKey: 'jj.knee_valgus_angle_notice',
      badSide: Direction.above,
      phase: Phase.contact,
      reduce: Reduce.max,
      severitySpan: _severitySpan['JJ_KNEE_VALGUS']!,
    ),
  ];
  return ActionDefinition(
    code: jjActionCode,
    nameZh: jjActionNameZh,
    cameraView: cameraView,
    config: cfg,
    states: JjStates.all,
    restingState: JjStates.closed,
    bottomState: JjStates.open,
    transitions: [
      for (final (src, dst, guard, label) in guards)
        Transition(src: src, dst: dst, guard: guard, label: label),
    ],
    rules: rules,
    stateToPhase: _stateToPhase,
    thresholdOffsets: const {},
    lossRecovery: const {JjStates.closing: JjStates.closed},
  );
}
