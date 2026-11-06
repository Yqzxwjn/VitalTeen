//动作定义的共享基础设施
library;

import '../features.dart';
import '../pose.dart';
import '../rules.dart';
import '../state_machine.dart';
import '../stats.dart';
import '../thresholds.dart';

class ExerciseException implements Exception {
  const ExerciseException(this.message);
  final String message;
  @override
  String toString() => 'ExerciseException: $message';
}

class Calibration {
  const Calibration({
    required this.kneeAngle,
    required this.trunkLean,
    required this.heelRiseRatio,
    required this.frames,
    this.legSpread,
    this.footHeight,
  });
  final double kneeAngle;
  final double trunkLean;
  final double? heelRiseRatio;
  final int frames;
  final double? legSpread;
  final double? footHeight;
}

enum BaselineKey {
  kneeAngle,
  trunkLean,
  heelRiseRatio,
  legSpread,
  footHeight;
  static const Set<BaselineKey> defaultRequired = {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
    BaselineKey.heelRiseRatio,
  };

  static const Set<BaselineKey> alwaysRequired = {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  };

  double of(Calibration calibration) => switch (this) {
        BaselineKey.kneeAngle => calibration.kneeAngle,
        BaselineKey.trunkLean => calibration.trunkLean,
        BaselineKey.heelRiseRatio => calibration.heelRiseRatio ??
            (throw const ExerciseException('这个动作没有采集脚跟抬升基线')),
        BaselineKey.legSpread => calibration.legSpread ??
            (throw const ExerciseException('这个动作没有采集分腿幅度基线')),
        BaselineKey.footHeight => calibration.footHeight ??
            (throw const ExerciseException('这个动作没有采集脚尖高度基线')),
      };
}

sealed class ThresholdOffset {
  const ThresholdOffset();
  double resolve(Calibration calibration);
}

final class FixedOffset extends ThresholdOffset {
  const FixedOffset(this.value);
  final double value;
  @override
  double resolve(Calibration calibration) => value;
}

final class BaselineOffset extends ThresholdOffset {
  const BaselineOffset(this.baseline, this.scale);
  final BaselineKey baseline;
  final double scale;
  @override
  double resolve(Calibration calibration) => baseline.of(calibration) * scale;
}

double? _collectBaseline(BaselineKey key, FrameFeatures features) {
  switch (key) {
    case BaselineKey.kneeAngle:
      final l = features.get('knee_angle_L');
      final r = features.get('knee_angle_R');
      if (l == null || r == null) return null;
      return (l + r) / 2.0;
    case BaselineKey.trunkLean:
      return features.get('trunk_lean')?.abs();
    case BaselineKey.heelRiseRatio:
      return features.get('heel_rise_ratio_L');
    case BaselineKey.legSpread:
      return features.get('leg_spread_ratio');
    case BaselineKey.footHeight:
      return features.get('foot_height_ratio');
  }
}

class Calibrator {
  Calibrator({
    Set<BaselineKey>? required,
    this.minFrames = 15,
  }) : required = Set.unmodifiable(required ?? BaselineKey.defaultRequired) {
    if (minFrames < 1) {
      throw const ExerciseException('minFrames 必须 >= 1');
    }
    final missing = BaselineKey.alwaysRequired.difference(this.required);
    if (missing.isNotEmpty) {
      throw ExerciseException(
        '这些基线量每个动作都要：${missing.map((k) => k.name).join('、')}',
      );
    }
    for (final key in this.required) {
      _samples[key] = [];
    }
  }
  final int minFrames;
  final Set<BaselineKey> required;

  final Map<BaselineKey, List<double>> _samples = {};
  Calibration? _result;
  bool get isReady => _result != null;
  Calibration? get calibration => _result;

  Calibration? feed(FrameFeatures features) {
    final existing = _result;
    if (existing != null) return existing;
    for (final key in required) {
      final value = _collectBaseline(key, features);
      if (value == null) return null;
      _samples[key]!.add(value);
    }
    final frames = _samples[BaselineKey.kneeAngle]!.length;
    if (frames < minFrames) return null;
    _result = Calibration(
      kneeAngle: medianOf(_samples[BaselineKey.kneeAngle]!),
      trunkLean: medianOf(_samples[BaselineKey.trunkLean]!),
      heelRiseRatio: _medianOrNull(BaselineKey.heelRiseRatio),
      frames: frames,
      legSpread: _medianOrNull(BaselineKey.legSpread),
      footHeight: _medianOrNull(BaselineKey.footHeight),
    );
    return _result;
  }

  double? _medianOrNull(BaselineKey key) {
    final values = _samples[key];
    return (values == null || values.isEmpty) ? null : medianOf(values);
  }

  void reset() {
    for (final values in _samples.values) {
      values.clear();
    }
    _result = null;
  }
}

class TrackingConfig {
  const TrackingConfig({
    this.cameraView = CameraView.sagittal,
    this.visibilityThreshold = 0.5,
    this.calibrationFrames = 15,
    this.minBendDeg = 45.0,
    this.standingHysteresisDeg = 8.0,
    this.minDwellFrames = 3,
    this.voteWindow = 5,
    this.voteRequired = 4,
    this.maxRepFrames = 300,
    this.flightExtensionDeg = 4.0,
    this.landingFlexDeg = 12.0,
    this.landingHipFloor = 0.2,
    this.spreadEnterDelta = 0.30,
    this.spreadFullDelta = 0.80,
    this.spreadHysteresis = 0.08,
    this.pushupTopDeg = 165.0,
    this.pushupDepthDeg = 100.0,
    this.situpLieRatio = 0.25,
    this.situpSeatRatio = 0.75,
    this.situpHysteresis = 0.06,
    this.sitReachUprightDeg = 75.0,
    this.sitReachHoldingDeg = 55.0,
    this.sitReachHysteresisDeg = 8.0,
    this.ropeTakeoffRatio = 0.10,
    this.ropeLandRatio = 0.05,
    this.ropeSettleRatio = 0.02,
    this.pullupHangDeg = 165.0,
    this.pullupTopDeg = 90.0,
    this.plankLieDeg = 60.0,
    this.plankLineEnterRatio = 0.45,
    this.plankLineExitRatio = 0.60,
    this.plankElbowMinDeg = 50.0,
    this.plankElbowMaxDeg = 130.0,
  });
  final CameraView cameraView;
  final double visibilityThreshold;
  final int calibrationFrames;
  final double minBendDeg;
  final double standingHysteresisDeg;
  final int minDwellFrames;
  final int voteWindow;
  final int voteRequired;
  final int maxRepFrames;
  final double flightExtensionDeg;
  final double landingFlexDeg;
  final double landingHipFloor;
  final double spreadEnterDelta;
  final double spreadFullDelta;
  final double spreadHysteresis;
  final double pushupTopDeg;
  final double pushupDepthDeg;
  final double situpLieRatio;
  final double situpSeatRatio;
  final double situpHysteresis;
  final double sitReachUprightDeg;
  final double sitReachHoldingDeg;
  final double sitReachHysteresisDeg;
  final double ropeTakeoffRatio;
  final double ropeLandRatio;
  final double ropeSettleRatio;
  final double pullupHangDeg;
  final double pullupTopDeg;
  final double plankLieDeg;
  final double plankLineEnterRatio;
  final double plankLineExitRatio;
  final double plankElbowMinDeg;
  final double plankElbowMaxDeg;
}

class BaselineAdjustedThresholds implements ThresholdSource {
  BaselineAdjustedThresholds(this._inner, Map<String, double> offsets)
      : _offsets = Map.of(offsets);
  final ThresholdSource _inner;
  final Map<String, double> _offsets;
  @override
  String get version => _inner.version;

  @override
  Threshold get(String key) {
    final threshold = _inner.get(key);
    final offset = _offsets[key];
    if (offset == null) return threshold;
    return threshold.withValue(threshold.value + offset);
  }
}

class _Span {
  _Span(this.state, this.start, this.end);
  final String state;
  final int start;
  final int end;
}

class RepTracker {
  RepTracker(
    this.machine, {
    required String restingState,
    required String bottomState,
    required this.config,
    required Map<String, Phase> stateToPhase,
    Map<String, String> lossRecovery = const {},
  })  : _resting = restingState,
        _bottom = bottomState,
        _lossRecovery = Map.of(lossRecovery),
        _stateToPhase = Map.of(stateToPhase) {
    if (bottomState == restingState) {
      throw const ExerciseException('bottomState 不能等于 restingState');
    }
  }
  final StateMachine machine;
  final String _resting;
  final String _bottom;
  final TrackingConfig config;
  final Map<String, Phase> _stateToPhase;
  final Map<String, String> _lossRecovery;
  final List<FrameFeatures> _buffer = [];
  final List<_Span> _spans = [];
  int _currentStart = 0;
  int? _repStart;
  bool _reachedBottom = false;
  int _discarded = 0;
  final List<RepWindow> completed = [];
  String get currentState => machine.state;
  int get discardedReps => _discarded;
  int? get openRepStartMs =>
      _repStart == null || _buffer.isEmpty ? null : _buffer.first.timestampMs;

  RepWindow? feed(FrameFeatures features) {
    final update = machine.update(features.asSignals(), features.timestampMs);
    if (_repStart == null) {
      _buffer.clear();
      _spans.clear();
      if (update.changed && update.left == _resting) {
        _repStart = 0;
        _currentStart = 0;
        _reachedBottom = false;
        _buffer.add(features);
        if (update.entered == _bottom) _reachedBottom = true;
      }
      return null;
    }
    final index = _buffer.length;
    _buffer.add(features);
    if (update.changed) {
      _spans.add(_Span(update.left!, _currentStart, index - 1));
      _currentStart = index;
      if (update.entered == _bottom) _reachedBottom = true;
      if (update.entered == _resting) return _seal(index);
    }
    if (index > config.maxRepFrames) _abandon();
    return null;
  }

  bool recoverFromLoss() {
    if (_repStart == null) return false;
    final target = _lossRecovery[machine.state];
    if (target == null) return false;
    _spans.add(_Span(machine.state, _currentStart, _buffer.length - 1));
    _currentStart = _buffer.length;
    machine.reset(target: target);
    return true;
  }

  void _abandon() {
    _discarded += 1;
    _resetRepState();
    machine.reset(target: _resting);
  }

  RepWindow? _seal(int index) {
    final frames = _buffer.sublist(0, index + 1);
    final bounds = _phaseBounds();
    final reached = _reachedBottom;
    _resetRepState();
    if (frames.isEmpty || !reached) {
      _discarded += 1;
      return null;
    }
    final window = RepWindow(
      index: completed.length + 1,
      frames: frames,
      phaseBounds: bounds,
    );
    completed.add(window);
    return window;
  }

  Map<Phase, PhaseBounds> _phaseBounds() {
    final bounds = <Phase, PhaseBounds>{};
    for (final span in _spans) {
      final phase = _stateToPhase[span.state];
      if (phase == null || bounds.containsKey(phase)) {
        continue;
      }
      if (span.end >= span.start && span.start >= 0) {
        bounds[phase] = (start: span.start, end: span.end);
      }
    }
    return bounds;
  }

  void _resetRepState() {
    _buffer.clear();
    _spans.clear();
    _currentStart = 0;
    _repStart = null;
    _reachedBottom = false;
  }

  void reset() {
    _resetRepState();
    completed.clear();
    _discarded = 0;
    machine.reset();
  }
}

class ActionDefinition {
  const ActionDefinition({
    required this.code,
    required this.nameZh,
    required this.cameraView,
    required this.config,
    required this.states,
    required this.restingState,
    required this.bottomState,
    required this.transitions,
    required this.rules,
    required this.stateToPhase,
    required this.thresholdOffsets,
    this.lossRecovery = const {},
  });
  final String code;
  final String nameZh;
  final CameraView cameraView;
  final TrackingConfig config;
  final List<String> states;
  final String restingState;
  final String bottomState;
  final List<Transition> transitions;
  final List<Rule> rules;
  final Map<String, Phase> stateToPhase;
  final Map<String, ThresholdOffset> thresholdOffsets;
  final Map<String, String> lossRecovery;
  Map<String, Phase> get phaseOf => Map.of(stateToPhase);
}

class ActionRunner {
  ActionRunner(
    ActionDefinition definition, {
    required ThresholdTable thresholds,
    required Calibration calibration,
  }) : _config = definition.config {
    _extractor = FeatureExtractor(
      visibilityThreshold: _config.visibilityThreshold,
      cameraView: definition.cameraView,
    );
    _engine = RuleEngine(
      definition.rules,
      BaselineAdjustedThresholds(
        thresholds,
        _calibrationOffsets(definition, calibration),
      ),
    );
    _tracker = RepTracker(
      StateMachine(
        initialState: definition.restingState,
        transitions: definition.transitions,
        minDwellFrames: _config.minDwellFrames,
        voteWindow: _config.voteWindow,
        voteRequired: _config.voteRequired,
      ),
      restingState: definition.restingState,
      bottomState: definition.bottomState,
      config: _config,
      stateToPhase: definition.stateToPhase,
      lossRecovery: definition.lossRecovery,
    );
  }
  final TrackingConfig _config;
  late final FeatureExtractor _extractor;
  late final RuleEngine _engine;
  late final RepTracker _tracker;
  String get currentState => _tracker.currentState;
  int get repCount => _tracker.completed.length;
  int get discardedReps => _tracker.discardedReps;
  int? get openRepStartMs => _tracker.openRepStartMs;
  RepWindow? feed(PoseFrame frame) => _tracker.feed(_extractor.extract(frame));
  bool recoverFromLoss() => _tracker.recoverFromLoss();
  SetSummary finishSet() => _engine.evaluateSet(_tracker.completed);
  List<RepWindow> get windows => List.unmodifiable(_tracker.completed);
  RuleEngine get engine => _engine;
}

Map<String, double> _calibrationOffsets(
  ActionDefinition definition,
  Calibration calibration,
) =>
    {
      for (final entry in definition.thresholdOffsets.entries)
        entry.key: entry.value.resolve(calibration),
    };
