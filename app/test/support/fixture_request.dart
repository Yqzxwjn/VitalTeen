/// 把 fixture 里的请求 JSON 还原成 [DecisionRequest]。
///
/// **只给测试用，不进 `lib/`。** 生产里 `DecisionRequest` 是**只出不进**的：
/// 它由领域流水线构造、序列化发给服务端，没有任何一处生产代码需要把它读回来。
/// 往 `lib/` 加一个 `fromJson`，就等于凭空多一条没人走的解析路径 ——
/// 没人走的代码不会被维护，只会在真要用的时候被发现是坏的。
///
/// 这个文件的存在只为一件事：跨语言一致性测试要拿**真请求**喂本机判定器。
/// 另造一份形状相似的请求，测出来的就是「我造的请求能算出期望的结果」，
/// 而不是「服务端的请求能算出同样的结果」。
///
/// 类型写得很直白（该 `as` 就 `as`）：fixture 形状不对时**当场炸**，
/// 正是这个文件该有的行为 —— 它读的是自己仓库里生成的文件，不是外部输入。
library;

import 'package:vitalteen_app/app/decision_request.dart';

/// 把一个 fixture 场景里的 `request` 对象还原成 [DecisionRequest]。
DecisionRequest requestFromJson(Map<String, dynamic> json) {
  final context = _map(json, 'context');
  final quality = _map(json, 'pose_quality');
  final set = _map(json, 'set');

  return DecisionRequest(
    requestId: json['request_id'] as String,
    context: DecisionContext(
      sex: _sex(context['sex'] as String),
      age: context['age'] as int,
      grade: context['grade'] as String,
      standardGroup: context['standard_group'] as String,
      actionCode: context['action_code'] as String,
      actionVariant: context['action_variant'] as String,
      cameraView: context['camera_view'] as String,
      poseBackend: context['pose_backend'] as String,
      hasWorldLandmarks: context['has_world_landmarks'] as bool,
    ),
    poseQuality: PoseQuality(
      meanVisibility: _double(quality['mean_visibility']),
      coverageOkRatio: _double(quality['coverage_ok_ratio']),
      fpsMean: _double(quality['fps_mean']),
      gapMaxMs: quality['gap_max_ms'] as int,
      viewConfidence: _double(quality['view_confidence']),
    ),
    set: SetIn(
      repCount: set['rep_count'] as int,
      validRepCount: set['valid_rep_count'] as int,
      tempoMeanMs: _optDouble(set['tempo_mean_ms']),
      romMeanDeg: _optDouble(set['rom_mean_deg']),
      symmetryIndexMean: _optDouble(set['symmetry_index_mean']),
      faultStats: [
        for (final item in set['fault_stats'] as List<dynamic>)
          _faultStat(item as Map<String, dynamic>),
      ],
    ),
    reps: [
      for (final item in json['reps'] as List<dynamic>)
        _rep(item as Map<String, dynamic>),
    ],
    candidates: [
      for (final item in json['candidates'] as List<dynamic>)
        CandidateIn(
          code: (item as Map<String, dynamic>)['code'] as String,
          triggeredByRule: item['triggered_by_rule'] as String,
        ),
    ],
    thresholdsVersion: json['thresholds_version'] as String,
  );
}

FaultStatIn _faultStat(Map<String, dynamic> json) => FaultStatIn(
      code: json['code'] as String,
      reps: [for (final rep in json['reps'] as List<dynamic>) rep as int],
      count: json['count'] as int,
    );

RepIn _rep(Map<String, dynamic> json) => RepIn(
      index: json['index'] as int,
      durationMs: json['duration_ms'] as int,
      phasesMs: {
        for (final entry in (json['phases_ms'] as Map).entries)
          entry.key as String: entry.value as int,
      },
      metrics: {
        for (final entry in (json['metrics'] as Map).entries)
          entry.key as String: _optDouble(entry.value),
      },
      faults: [
        for (final item in json['faults'] as List<dynamic>)
          _fault(item as Map<String, dynamic>),
      ],
      confidence: _optDouble(json['confidence']),
    );

FaultIn _fault(Map<String, dynamic> json) => FaultIn(
      code: json['code'] as String,
      confidence: _double(json['confidence']),
      evidenceFrames: [
        for (final frame in json['evidence_frames'] as List<dynamic>) frame as int,
      ],
      deviations: [
        for (final item in json['deviations'] as List<dynamic>)
          _deviation(item as Map<String, dynamic>),
      ],
    );

DeviationIn _deviation(Map<String, dynamic> json) => DeviationIn(
      feature: json['feature'] as String,
      measured: _double(json['measured']),
      threshold: _double(json['threshold']),
      deltaSigned: _double(json['delta_signed']),
      severity01: _optDouble(json['severity_0_1']),
    );

Map<String, dynamic> _map(Map<String, dynamic> json, String key) =>
    json[key] as Map<String, dynamic>;

Sex _sex(String wire) {
  for (final value in Sex.values) {
    if (value.wireName == wire) return value;
  }
  throw ArgumentError.value(wire, 'sex', '协议里出现了未知的取值');
}

double _double(Object? value) => (value as num).toDouble();

double? _optDouble(Object? value) => (value as num?)?.toDouble();
