///一局的会话流程：自检 → 标定 → 计数 → 本组结束
library;

import 'package:flutter/foundation.dart';

import '../domain/exercises/base.dart';
import '../domain/features.dart';
import '../domain/pose.dart';
import 'action_spec.dart';
import 'decision_request.dart';
import 'form_score.dart';
import 'pose_quality_tracker.dart';
import '../domain/rules.dart';
import '../domain/thresholds.dart';
import 'camera_position_check.dart';
import 'fault_presentation.dart';

enum SessionPhase {
  position,
  calibrating,
  counting,
  finished,
}

@immutable
class SessionView {
  const SessionView({
    required this.phase,
    required this.position,
    required this.calibrationFrames,
    required this.calibrationTarget,
    required this.repCount,
    required this.discardedReps,
    required this.machineState,
    required this.kneeAngle,
    required this.holdMs,
    required this.repDurationsMs,
    required this.lastRep,
    required this.lastRepScore,
    required this.summary,
    required this.setScore,
    required this.interrupted,
    required this.sawFrame,
  });
  static const SessionView initial = SessionView(
    phase: SessionPhase.position,
    position: PositionReport.empty(),
    calibrationFrames: 0,
    calibrationTarget: 0,
    repCount: 0,
    discardedReps: 0,
    machineState: '',
    kneeAngle: null,
    holdMs: 0,
    repDurationsMs: [],
    lastRep: null,
    lastRepScore: null,
    summary: null,
    setScore: null,
    interrupted: false,
    sawFrame: false,
  );
  final SessionPhase phase;
  final PositionReport position;
  final int calibrationFrames;
  final int calibrationTarget;
  final int repCount;
  final int discardedReps;
  final String machineState;
  final double? kneeAngle;
  final int holdMs;
  final List<int> repDurationsMs;
  int get totalRepDurationMs =>
      repDurationsMs.fold(0, (sum, ms) => sum + ms);
  final RepFeedbackView? lastRep;
  final FormScore? lastRepScore;
  final SetSummary? summary;
  final FormScore? setScore;
  final bool interrupted;
  final bool sawFrame;
  bool get canBeginCalibration =>
      phase == SessionPhase.position && position.canStart;
  double get calibrationProgress => calibrationTarget <= 0
      ? 0
      : (calibrationFrames / calibrationTarget).clamp(0.0, 1.0);
  SessionView copyWith({
    SessionPhase? phase,
    PositionReport? position,
    int? calibrationFrames,
    int? calibrationTarget,
    int? repCount,
    int? discardedReps,
    String? machineState,
    RepFeedbackView? lastRep,
    SetSummary? summary,
    bool? interrupted,
    bool? sawFrame,
  }) =>
      SessionView(
        phase: phase ?? this.phase,
        position: position ?? this.position,
        calibrationFrames: calibrationFrames ?? this.calibrationFrames,
        calibrationTarget: calibrationTarget ?? this.calibrationTarget,
        repCount: repCount ?? this.repCount,
        discardedReps: discardedReps ?? this.discardedReps,
        machineState: machineState ?? this.machineState,
        kneeAngle: kneeAngle,
        holdMs: holdMs,
        repDurationsMs: repDurationsMs,
        lastRep: lastRep ?? this.lastRep,
        lastRepScore: lastRepScore,
        summary: summary ?? this.summary,
        setScore: setScore,
        interrupted: interrupted ?? this.interrupted,
        sawFrame: sawFrame ?? this.sawFrame,
      );
}

class SquatSession {
  SquatSession({
    required ThresholdTable thresholds,
    this.spec = squatSpec,
    this.minCalibrationFrames = 15,
    this.publishIntervalMs = 100,
    this.interruptionThresholdMs = 1500,
    this.autoFinishRestMs = 10000,
  })
      // ignore: prefer_initializing_formals
      : _thresholds = thresholds;
  final ActionSpec spec;
  final int minCalibrationFrames;
  final int publishIntervalMs;
  final int interruptionThresholdMs;
  final int autoFinishRestMs;
  final ThresholdTable _thresholds;
  final ValueNotifier<SessionView> view =
      ValueNotifier<SessionView>(SessionView.initial);
  late final CameraPositionMonitor _monitor = CameraPositionMonitor(
    requiresFrontal: spec.requiresFrontal,
    blockingAdvice: spec.blockingAdvice,
    advisoryAdvice: spec.advisoryAdvice,
    requiredLandmarks: spec.requiredLandmarks ?? defaultRequiredLandmarks,
  );
  late final PoseQualityTracker _quality = PoseQualityTracker(
    requiredLandmarks: spec.requiredLandmarks ?? defaultRequiredLandmarks,
  );
  late final FeatureExtractor _displayExtractor =
      FeatureExtractor(cameraView: spec.cameraView);
  late Calibrator _calibrator = _newCalibrator();
  ActionRunner? _runner;
  FaultPresenter? _presenter;
  FormScorer? _scorer;
  ActionDefinition? _definition;
  SetSummary? _summary;
  Calibrator _newCalibrator() => Calibrator(
        required: spec.calibrationBaselines,
        minFrames: minCalibrationFrames,
      );
  int _calibrationFrames = 0;
  bool _interrupted = false;
  int _lastPublishMs = 0;
  int _lastSeenMs = 0;
  int? _lostSinceMs;
  int? _restingSinceMs;
  bool _wasLost = false;
  bool _sawFrame = false;

  void feed(PoseFrame? frame) {
    if (view.value.phase == SessionPhase.finished) {
      return;
    }
    if (frame == null) {
      _onLostFrame();
      return;
    }
    final firstAfterLoss = _wasLost;
    _wasLost = false;
    _sawFrame = true;
    _lastSeenMs = frame.timestampMs;
    _monitor.add(frame);
    _noteRecovery(frame);
    SessionPhase? phase;
    int? calibrationFrames;
    int? calibrationTarget;
    int? repCount;
    int? discardedReps;
    String? machineState;
    double? kneeAngle;
    int? holdMs;
    List<int>? repDurationsMs;
    RepFeedbackView? lastRep;
    FormScore? lastRepScore;
    var force = firstAfterLoss;
    switch (view.value.phase) {
      case SessionPhase.position:
        break;
      case SessionPhase.calibrating:
        final calibration = _calibrator.feed(_displayExtractor.extract(frame));
        if (calibration != null) {
          _runner = _buildRunner(calibration);
          _quality.reset();
          _quality.add(frame, viewStable: _monitor.report.viewStable);
          phase = SessionPhase.counting;
          force = true;
          break;
        }
        if (!_monitor.report.blocking) {
          calibrationFrames = ++_calibrationFrames;
        }
        break;
      case SessionPhase.counting:
        final runner = _runner!;
        _quality.add(frame, viewStable: _monitor.report.viewStable);
        final features = _displayExtractor.extract(frame);
        final left = features.get('knee_angle_L');
        final right = features.get('knee_angle_R');
        kneeAngle =
            (left == null || right == null) ? null : (left + right) / 2.0;
        machineState = runner.currentState;
        discardedReps = runner.discardedReps;
        final window = runner.feed(frame);
        if (window != null) {
          final faults = runner.engine.evaluateRep(window);
          lastRep = _presenter!.present(runner.repCount, faults);
          lastRepScore = _scorer!.scoreRep(faults);
          repCount = runner.repCount;
          force = true;
          if (spec.isTimed) {
            repDurationsMs = [
              for (final sealed in runner.windows) sealed.durationMs,
            ];
          }
        }
        if (spec.isTimed) holdMs = _holdElapsedMs(frame, runner);
        if (_shouldAutoFinish(frame, runner)) {
          _summary = runner.finishSet();
          _publish(
            force: true,
            phase: SessionPhase.finished,
            summary: _summary,
            setScore: _scorer!.scoreSet(_summary!),
          );
          return;
        }
        break;
      case SessionPhase.finished:
        break;
    }
    _publish(
      force: force,
      phase: phase,
      calibrationFrames: calibrationFrames,
      calibrationTarget: calibrationTarget,
      repCount: repCount,
      discardedReps: discardedReps,
      machineState: machineState,
      kneeAngle: kneeAngle,
      holdMs: holdMs,
      repDurationsMs: repDurationsMs,
      lastRep: lastRep,
      lastRepScore: lastRepScore,
    );
  }

  bool beginCalibration() {
    if (!view.value.canBeginCalibration) return false;
    _calibrator = _newCalibrator();
    _calibrationFrames = 0;
    _publish(
      force: true,
      phase: SessionPhase.calibrating,
      calibrationFrames: 0,
      calibrationTarget: minCalibrationFrames,
    );
    return true;
  }

  void finishSet() {
    if (view.value.phase != SessionPhase.counting) return;
    _summary = _runner!.finishSet();
    _publish(
      force: true,
      phase: SessionPhase.finished,
      summary: _summary,
      setScore: _scorer!.scoreSet(_summary!),
    );
  }

  DecisionRequest? buildRequest({
    required String requestId,
    required Sex sex,
    required int age,
    required String grade,
    required String standardGroup,
  }) {
    final summary = _summary;
    final runner = _runner;
    final definition = _definition;
    if (summary == null || runner == null || definition == null) return null;
    final quality = _quality.quality;
    if (quality == null) return null;
    return buildDecisionRequest(
      requestId: requestId,
      context: DecisionContext(
        sex: sex,
        age: age,
        grade: grade,
        standardGroup: standardGroup,
        actionCode: definition.code,
        cameraView: spec.cameraView.name,
      ),
      poseQuality: quality,
      summary: summary,
      thresholdsVersion: _thresholds.version,
      windows: runner.windows,
      engine: runner.engine,
    );
  }
  LocalFaultContext? get localFaults => _presenter;
  ThresholdTable get thresholds => _thresholds;

  void startNewSet() {
    final calibration = _calibrator.calibration;
    if (calibration == null) {
      reset();
      return;
    }
    _runner = _buildRunner(calibration);
    _summary = null;
    _interrupted = false;
    _lostSinceMs = null;
    _restingSinceMs = null;
    _wasLost = false;
    _monitor.reset();
    _quality.reset();
    _publish(
      force: true,
      fresh: true,
      phase: SessionPhase.position,
      calibrationTarget: minCalibrationFrames,
      machineState: '',
    );
  }

  void reset() {
    _monitor.reset();
    _quality.reset();
    _calibrator = _newCalibrator();
    _runner = null;
    _presenter = null;
    _scorer = null;
    _definition = null;
    _summary = null;
    _calibrationFrames = 0;
    _interrupted = false;
    _lostSinceMs = null;
    _restingSinceMs = null;
    _wasLost = false;
    _sawFrame = false;
    _lastPublishMs = 0;
    _lastSeenMs = 0;
    view.value = SessionView.initial;
  }
  void dispose() => view.dispose();

  void _onLostFrame() {
    final first = !_wasLost;
    _wasLost = true;
    _monitor.add(null);
    if (view.value.phase == SessionPhase.calibrating) {
      _calibrator = _newCalibrator();
      _calibrationFrames = 0;
      _publish(
        force: true,
        phase: SessionPhase.position,
        calibrationFrames: 0,
        calibrationTarget: 0,
      );
      return;
    }
    if (view.value.phase == SessionPhase.counting) {
      _lostSinceMs ??= _lastSeenMs;
    }
    _publish(force: first, machineState: '');
  }

  bool _shouldAutoFinish(PoseFrame frame, ActionRunner runner) {
    if (runner.repCount == 0 ||
        runner.currentState != _definition?.restingState) {
      _restingSinceMs = null;
      return false;
    }
    if (frame.timestampMs <= 0) return false;
    final since = _restingSinceMs ??= frame.timestampMs;
    return frame.timestampMs - since >= autoFinishRestMs;
  }

  void _noteRecovery(PoseFrame frame) {
    final lostSince = _lostSinceMs;
    _lostSinceMs = null;
    if (lostSince == null || lostSince <= 0) return;
    if (frame.timestampMs - lostSince < interruptionThresholdMs) return;
    _runner?.recoverFromLoss();
    final state = _runner?.currentState;
    if (state == null || state == _definition?.restingState) {
      return;
    }
    _interrupted = true;
  }

  static int _holdElapsedMs(PoseFrame frame, ActionRunner runner) {
    final startMs = runner.openRepStartMs;
    if (startMs == null) return 0;
    final span = frame.timestampMs - startMs;
    return span > 0 ? span : 0;
  }

  ActionRunner _buildRunner(Calibration calibration) {
    final definition = spec.build(calibration);
    _definition = definition;
    _presenter = FaultPresenter(definition: definition, thresholds: _thresholds);
    _scorer = FormScorer(definition: definition, thresholds: _thresholds);
    return ActionRunner(
      definition,
      thresholds: _thresholds,
      calibration: calibration,
    );
  }

  void _publish({
    bool force = false,
    bool fresh = false,
    SessionPhase? phase,
    int? calibrationFrames,
    int? calibrationTarget,
    int? repCount,
    int? discardedReps,
    String? machineState,
    double? kneeAngle,
    int? holdMs,
    List<int>? repDurationsMs,
    RepFeedbackView? lastRep,
    FormScore? lastRepScore,
    SetSummary? summary,
    FormScore? setScore,
  }) {
    final now = _lastSeenMs;
    final canThrottle = now > 0;
    if (!force && canThrottle && now - _lastPublishMs < publishIntervalMs) {
      return;
    }
    if (canThrottle) _lastPublishMs = now;
    final previous = fresh ? SessionView.initial : view.value;
    view.value = SessionView(
      phase: phase ?? previous.phase,
      position: _monitor.report,
      calibrationFrames: calibrationFrames ?? previous.calibrationFrames,
      calibrationTarget: calibrationTarget ?? previous.calibrationTarget,
      repCount: repCount ?? previous.repCount,
      discardedReps: discardedReps ?? previous.discardedReps,
      machineState: machineState ?? previous.machineState,
      kneeAngle: kneeAngle,
      holdMs: holdMs ?? 0,
      repDurationsMs: repDurationsMs ?? previous.repDurationsMs,
      lastRep: lastRep ?? previous.lastRep,
      lastRepScore: lastRepScore ?? previous.lastRepScore,
      summary: summary ?? previous.summary,
      setScore: setScore ?? previous.setScore,
      interrupted: _interrupted,
      sawFrame: _sawFrame,
    );
  }
}
