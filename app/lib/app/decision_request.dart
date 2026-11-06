///把一组的汇总整理成发给决策服务的那份数据
library;

import '../domain/features.dart' show FrameFeatures;
import '../domain/rules.dart';

const String decisionSchemaVersion = '1.0';

const String poseBackendMlKit = 'mlkit';

const int decisionAgeMin = 5;
const int decisionAgeMax = 25;

enum Sex {
  male('male', '男'),
  female('female', '女');
  const Sex(this.wireName, this.nameZh);
  final String wireName;
  final String nameZh;
}

class DecisionContext {
  const DecisionContext({
    required this.sex,
    required this.age,
    required this.grade,
    required this.standardGroup,
    required this.actionCode,
    required this.cameraView,
    this.actionVariant = 'standard',
    this.poseBackend = poseBackendMlKit,
    this.hasWorldLandmarks = false,
  });
  final Sex sex;
  final int age;
  final String grade;
  final String standardGroup;
  final String actionCode;
  final String actionVariant;
  final String cameraView;
  final String poseBackend;
  final bool hasWorldLandmarks;

  Map<String, dynamic> toJson() => {
        'sex': sex.wireName,
        'age': age,
        'grade': grade,
        'standard_group': standardGroup,
        'action_code': actionCode,
        'action_variant': actionVariant,
        'camera_view': cameraView,
        'pose_backend': poseBackend,
        'has_world_landmarks': hasWorldLandmarks,
      };
}

class PoseQuality {
  const PoseQuality({
    required this.meanVisibility,
    required this.coverageOkRatio,
    required this.fpsMean,
    required this.gapMaxMs,
    required this.viewConfidence,
  });
  final double meanVisibility;
  final double coverageOkRatio;
  final double fpsMean;
  final int gapMaxMs;
  final double viewConfidence;

  Map<String, dynamic> toJson() => {
        'mean_visibility': meanVisibility,
        'coverage_ok_ratio': coverageOkRatio,
        'fps_mean': fpsMean,
        'gap_max_ms': gapMaxMs,
        'view_confidence': viewConfidence,
      };
}

class FaultStatIn {
  const FaultStatIn({required this.code, required this.reps, required this.count});
  final String code;
  final List<int> reps;
  final int count;

  Map<String, dynamic> toJson() =>
      {'code': code, 'reps': reps, 'count': count};
}

class DeviationIn {
  const DeviationIn({
    required this.feature,
    required this.measured,
    required this.threshold,
    required this.deltaSigned,
    required this.severity01,
  });
  final String feature;
  final double measured;
  final double threshold;
  final double deltaSigned;
  final double? severity01;

  Map<String, dynamic> toJson() => {
        'feature': feature,
        'measured': measured,
        'threshold': threshold,
        'delta_signed': deltaSigned,
        'severity_0_1': severity01,
      };
}

class FaultIn {
  const FaultIn({
    required this.code,
    required this.confidence,
    required this.evidenceFrames,
    required this.deviations,
  });
  final String code;
  final double confidence;
  final List<int> evidenceFrames;
  final List<DeviationIn> deviations;

  Map<String, dynamic> toJson() => {
        'code': code,
        'confidence': confidence,
        'evidence_frames': evidenceFrames,
        'deviations': [for (final d in deviations) d.toJson()],
      };
}

class RepIn {
  const RepIn({
    required this.index,
    required this.durationMs,
    required this.phasesMs,
    required this.metrics,
    required this.faults,
    required this.confidence,
  });
  final int index;
  final int durationMs;
  final Map<String, int> phasesMs;
  final Map<String, double?> metrics;
  final List<FaultIn> faults;
  final double? confidence;

  Map<String, dynamic> toJson() => {
        'index': index,
        'duration_ms': durationMs,
        'phases_ms': phasesMs,
        'metrics': metrics,
        'faults': [for (final f in faults) f.toJson()],
        'confidence': confidence,
      };
}

class SetIn {
  const SetIn({
    required this.repCount,
    required this.validRepCount,
    required this.tempoMeanMs,
    required this.romMeanDeg,
    required this.symmetryIndexMean,
    required this.faultStats,
  });
  final int repCount;
  final int validRepCount;
  final double? tempoMeanMs;
  final double? romMeanDeg;
  final double? symmetryIndexMean;
  final List<FaultStatIn> faultStats;

  Map<String, dynamic> toJson() => {
        'rep_count': repCount,
        'valid_rep_count': validRepCount,
        'tempo_mean_ms': tempoMeanMs,
        'rom_mean_deg': romMeanDeg,
        'symmetry_index_mean': symmetryIndexMean,
        'fault_stats': [for (final s in faultStats) s.toJson()],
      };
}

class CandidateIn {
  const CandidateIn({required this.code, required this.triggeredByRule});
  final String code;
  final String triggeredByRule;

  Map<String, dynamic> toJson() =>
      {'code': code, 'triggered_by_rule': triggeredByRule};
}

class DecisionRequest {
  const DecisionRequest({
    required this.requestId,
    required this.context,
    required this.poseQuality,
    required this.set,
    required this.reps,
    required this.candidates,
    required this.thresholdsVersion,
  });
  final String requestId;
  final DecisionContext context;
  final PoseQuality poseQuality;
  final SetIn set;
  final List<RepIn> reps;
  final List<CandidateIn> candidates;
  final String thresholdsVersion;

  Map<String, dynamic> toJson() => {
        'request_id': requestId,
        'schema_version': decisionSchemaVersion,
        'context': context.toJson(),
        'pose_quality': poseQuality.toJson(),
        'set': set.toJson(),
        'reps': [for (final r in reps) r.toJson()],
        'candidates': [for (final c in candidates) c.toJson()],
        'thresholds_version': thresholdsVersion,
      };
}

DecisionRequest buildDecisionRequest({
  required String requestId,
  required DecisionContext context,
  required PoseQuality poseQuality,
  required SetSummary summary,
  required String thresholdsVersion,
  List<RepWindow> windows = const [],
  RuleEngine? engine,
}) {
  if (windows.isNotEmpty && engine == null) {
    throw ArgumentError(
      '提供了 windows 却没有提供 engine：逐次错误无法填充，reps[] 会静默为空。'
      '要么两个都给，要么两个都不给。',
    );
  }
  return DecisionRequest(
    requestId: requestId,
    context: context,
    poseQuality: poseQuality,
    set: SetIn(
      repCount: summary.repCount,
      validRepCount: summary.repCount,
      tempoMeanMs: _meanTempoMs(windows),
      romMeanDeg: null,
      symmetryIndexMean: null,
      faultStats: [
        for (final stat in summary.faultStats)
          FaultStatIn(
            code: stat.code,
            reps: List<int>.of(stat.repIndices),
            count: stat.count,
          ),
      ],
    ),
    reps: [
      for (final window in windows) _repIn(window, engine!),
    ],
    candidates: [
      for (final stat in summary.faultStats)
        CandidateIn(code: stat.code, triggeredByRule: 'rule_engine'),
    ],
    thresholdsVersion: thresholdsVersion,
  );
}

RepIn _repIn(RepWindow window, RuleEngine engine) => RepIn(
      index: window.index,
      durationMs: _durationMs(window),
      phasesMs: _phasesMs(window),
      metrics: const {},
      faults: [
        for (final fault in engine.evaluateRep(window))
          FaultIn(
            code: fault.code,
            confidence: fault.confidence,
            evidenceFrames: List<int>.of(fault.evidenceTimestamps),
            deviations: [
              DeviationIn(
                feature: fault.deviation.feature,
                measured: fault.deviation.measured,
                threshold: fault.deviation.threshold,
                deltaSigned: fault.deviation.deltaSigned,
                severity01: fault.deviation.severity01,
              ),
            ],
          ),
      ],
      confidence: null,
    );

int _durationMs(RepWindow window) => window.durationMs;

Map<String, int> _phasesMs(RepWindow window) {
  final out = <String, int>{};
  for (final entry in window.phaseBounds.entries) {
    final frames = _phaseSlice(window, entry.value);
    out[entry.key.name] = frames.length < 2
        ? 0
        : frames.last.timestampMs - frames.first.timestampMs;
  }
  return out;
}

List<FrameFeatures> _phaseSlice(RepWindow window, PhaseBounds bounds) {
  final start = bounds.start < 0 ? 0 : bounds.start;
  var end = bounds.end + 1;
  if (end > window.frames.length) end = window.frames.length;
  if (start >= end) return const [];
  return window.frames.sublist(start, end);
}

double? _meanTempoMs(List<RepWindow> windows) {
  final durations = [
    for (final window in windows)
      if (window.frames.length >= 2) _durationMs(window),
  ];
  if (durations.isEmpty) return null;
  return durations.reduce((a, b) => a + b) / durations.length;
}
