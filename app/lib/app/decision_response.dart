///决策响应模型（手写，带跨语言 fixture 校验）
library;

import 'dart:convert';

class DecisionResponseException implements Exception {
  const DecisionResponseException(this.message);
  final String message;
  @override
  String toString() => 'DecisionResponseException: $message';
}

enum DecisionStatus {
  ok('ok'),
  abstain('abstain');
  const DecisionStatus(this.wire);
  final String wire;
  static DecisionStatus fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    throw DecisionResponseException(
      'status 的值「$value」不在已知的两个之内（ok / abstain）。'
      '它决定整份响应的读法，不能按 ok 猜着读 —— 请更新端侧模型。',
    );
  }
}

class FaultRef {
  const FaultRef({required this.code, required this.name});
  final String code;
  final String name;
  static FaultRef fromJson(Map<String, dynamic> json, String path) => FaultRef(
        code: _str(json, 'code', path),
        name: _str(json, 'name', path),
      );

  Map<String, dynamic> toJson() => {'code': code, 'name': name};
}

class FaultEvidence {
  const FaultEvidence({
    this.reps = const [],
    this.metric,
    this.meanDeviation,
  });
  final List<int> reps;
  final String? metric;
  final double? meanDeviation;

  static FaultEvidence fromJson(Map<String, dynamic> json, String path) {
    final reps = _list(json, 'reps', path, optional: true) ?? const [];
    return FaultEvidence(
      reps: [
        for (var i = 0; i < reps.length; i++)
          _asInt(reps[i], '$path.reps[$i]'),
      ],
      metric: _optStr(json, 'metric', path),
      meanDeviation: _optDouble(json, 'mean_deviation', path),
    );
  }

  Map<String, dynamic> toJson() => {
        'reps': reps,
        'metric': metric,
        'mean_deviation': meanDeviation,
      };
}

class DecisionFault {
  const DecisionFault({
    required this.code,
    required this.name,
    required this.severityLevel,
    required this.severityScore,
    required this.confidence,
    required this.evidence,
  });
  final String code;
  final String name;
  final int severityLevel;
  final int severityScore;
  final double confidence;
  final FaultEvidence evidence;
  static DecisionFault fromJson(Map<String, dynamic> json, String path) =>
      DecisionFault(
        code: _str(json, 'code', path),
        name: _str(json, 'name', path),
        severityLevel: _int(json, 'severity_level', path),
        severityScore: _int(json, 'severity_score', path),
        confidence: _double(json, 'confidence', path),
        evidence: FaultEvidence.fromJson(
          _map(json, 'evidence', path, optional: true) ?? const {},
          '$path.evidence',
        ),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'severity_level': severityLevel,
        'severity_score': severityScore,
        'confidence': confidence,
        'evidence': evidence.toJson(),
      };
}

class Scores {
  const Scores({
    required this.formScore,
    required this.rating,
    required this.provisional,
  });
  final int formScore;
  final String rating;
  final bool provisional;
  static Scores fromJson(Map<String, dynamic> json, String path) => Scores(
        formScore: _int(json, 'form_score', path),
        rating: _str(json, 'rating', path),
        provisional: _bool(json, 'provisional', path, optional: true),
      );

  Map<String, dynamic> toJson() => {
        'form_score': formScore,
        'rating': rating,
        'provisional': provisional,
      };
}

class PlanChoice {
  const PlanChoice({
    required this.selectedPlanIds,
    required this.selectionReason,
    required this.doseNote,
  });
  final List<String> selectedPlanIds;
  final String selectionReason;
  final String doseNote;
  static PlanChoice fromJson(Map<String, dynamic> json, String path) => PlanChoice(
        selectedPlanIds: [
          for (final id in _list(json, 'selected_plan_ids', path, optional: true) ?? const [])
            _asString(id, '$path.selected_plan_ids'),
        ],
        selectionReason: _optStr(json, 'selection_reason', path) ?? '',
        doseNote: _optStr(json, 'dose_note', path) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'selected_plan_ids': selectedPlanIds,
        'selection_reason': selectionReason,
        'dose_note': doseNote,
      };
}

class Message {
  const Message({required this.templateId, required this.params});
  final String templateId;
  final Map<String, Object> params;

  static Message fromJson(Map<String, dynamic> json, String path) {
    final raw = _map(json, 'params', path, optional: true) ?? const {};
    final params = <String, Object>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is String) {
        params[entry.key] = value;
      } else if (value is int) {
        params[entry.key] = value;
      } else if (value is double) {
        params[entry.key] = value;
      } else {
        throw DecisionResponseException(
          '$path.params.${entry.key} 的类型是 ${value.runtimeType}，契约只允许 '
          'string / int / number。',
        );
      }
    }
    return Message(templateId: _str(json, 'template_id', path), params: params);
  }

  Map<String, dynamic> toJson() => {'template_id': templateId, 'params': params};
}

class DecisionMeta {
  const DecisionMeta({
    required this.decisionModelVersion,
    required this.thresholdsVersion,
    required this.latencyMs,
    required this.shuffled,
    this.shuffleSeed,
  });
  final String decisionModelVersion;
  final String thresholdsVersion;
  final int latencyMs;
  final bool shuffled;
  final int? shuffleSeed;
  bool get isRuleOnly =>
      decisionModelVersion == ruleOnlyModelVersion || !shuffled;
  static DecisionMeta fromJson(Map<String, dynamic> json, String path) => DecisionMeta(
        decisionModelVersion: _str(json, 'decision_model_version', path),
        thresholdsVersion: _str(json, 'thresholds_version', path),
        latencyMs: _int(json, 'latency_ms', path),
        shuffled: _bool(json, 'shuffled', path, optional: true),
        shuffleSeed: _optInt(json, 'shuffle_seed', path),
      );

  Map<String, dynamic> toJson() => {
        'decision_model_version': decisionModelVersion,
        'thresholds_version': thresholdsVersion,
        'latency_ms': latencyMs,
        'shuffled': shuffled,
        'shuffle_seed': shuffleSeed,
      };
}

const String ruleOnlyModelVersion = 'rule-only';

class DecisionResponse {
  const DecisionResponse({
    required this.requestId,
    required this.status,
    required this.faults,
    required this.gates,
    required this.meta,
    this.abstainReason,
    this.primaryFault,
    this.scores,
    this.choice,
    this.message,
  });
  final String requestId;
  final DecisionStatus status;
  final String? abstainReason;
  final FaultRef? primaryFault;
  final List<DecisionFault> faults;
  final Map<String, bool> gates;
  final Scores? scores;
  final PlanChoice? choice;
  final Message? message;
  final DecisionMeta meta;

  factory DecisionResponse.fromJson(Map<String, dynamic> json) {
    final path = 'response';
    final gates = <String, bool>{};
    for (final entry in (_map(json, 'gates', path, optional: true) ?? const {}).entries) {
      final value = entry.value;
      if (value is! bool) {
        throw DecisionResponseException('$path.gates.${entry.key} 不是布尔值');
      }
      gates[entry.key] = value;
    }
    final rawFaults = _list(json, 'faults', path, optional: true) ?? const [];
    final faults = <DecisionFault>[
      for (var i = 0; i < rawFaults.length; i++)
        DecisionFault.fromJson(_asMap(rawFaults[i], '$path.faults[$i]'), '$path.faults[$i]'),
    ];
    final primary = _map(json, 'primary_fault', path, optional: true);
    final scores = _map(json, 'scores', path, optional: true);
    final choice = _map(json, 'choice', path, optional: true);
    final message = _map(json, 'message', path, optional: true);
    final response = DecisionResponse(
      requestId: _str(json, 'request_id', path),
      status: DecisionStatus.fromWire(_str(json, 'status', path)),
      abstainReason: _optStr(json, 'abstain_reason', path),
      primaryFault: primary == null ? null : FaultRef.fromJson(primary, '$path.primary_fault'),
      faults: faults,
      gates: gates,
      scores: scores == null ? null : Scores.fromJson(scores, '$path.scores'),
      choice: choice == null ? null : PlanChoice.fromJson(choice, '$path.choice'),
      message: message == null ? null : Message.fromJson(message, '$path.message'),
      meta: DecisionMeta.fromJson(_map(json, 'meta', path)!, '$path.meta'),
    );
    if (response.status == DecisionStatus.abstain && (response.abstainReason ?? '').isEmpty) {
      throw const DecisionResponseException(
        'status=abstain 却没有 abstain_reason —— 契约要求弃权必须说明原因。',
      );
    }
    return response;
  }

  factory DecisionResponse.decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw DecisionResponseException('响应不是合法的 JSON：${error.message}');
    }
    return DecisionResponse.fromJson(_asMap(decoded, 'response'));
  }

  Map<String, dynamic> toJson() => {
        'request_id': requestId,
        'status': status.wire,
        'abstain_reason': abstainReason,
        'primary_fault': primaryFault?.toJson(),
        'faults': [for (final fault in faults) fault.toJson()],
        'gates': gates,
        'scores': scores?.toJson(),
        'choice': choice?.toJson(),
        'message': message?.toJson(),
        'meta': meta.toJson(),
      };
}

String stripMarkdownEmphasis(String text) => text.replaceAll('**', '');

Map<String, dynamic> _asMap(Object? value, String path) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return {for (final entry in value.entries) '${entry.key}': entry.value};
  }
  throw DecisionResponseException('$path 应当是对象，实际是 ${value.runtimeType}');
}

String _asString(Object? value, String path) {
  if (value is String) return value;
  throw DecisionResponseException('$path 应当是字符串，实际是 ${value.runtimeType}');
}

int _asInt(Object? value, String path) {
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw DecisionResponseException('$path 应当是整数，实际是 $value');
}

String _str(Map<String, dynamic> json, String field, String path) {
  if (!json.containsKey(field)) {
    throw DecisionResponseException('$path.$field 缺失');
  }
  return _asString(json[field], '$path.$field');
}

String? _optStr(Map<String, dynamic> json, String field, String path) {
  final value = json[field];
  return value == null ? null : _asString(value, '$path.$field');
}

int _int(Map<String, dynamic> json, String field, String path) {
  if (!json.containsKey(field)) {
    throw DecisionResponseException('$path.$field 缺失');
  }
  return _asInt(json[field], '$path.$field');
}

int? _optInt(Map<String, dynamic> json, String field, String path) {
  final value = json[field];
  return value == null ? null : _asInt(value, '$path.$field');
}

double _double(Map<String, dynamic> json, String field, String path) {
  if (!json.containsKey(field)) {
    throw DecisionResponseException('$path.$field 缺失');
  }
  return _asDouble(json[field], '$path.$field');
}

double? _optDouble(Map<String, dynamic> json, String field, String path) {
  final value = json[field];
  return value == null ? null : _asDouble(value, '$path.$field');
}

double _asDouble(Object? value, String path) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  throw DecisionResponseException('$path 应当是数字，实际是 ${value.runtimeType}');
}

bool _bool(Map<String, dynamic> json, String field, String path, {bool optional = false}) {
  final value = json[field];
  if (value == null && optional) return false;
  if (value is! bool) {
    throw DecisionResponseException('$path.$field 应当是布尔值，实际是 $value');
  }
  return value;
}

List<dynamic>? _list(
  Map<String, dynamic> json,
  String field,
  String path, {
  bool optional = false,
}) {
  final value = json[field];
  if (value == null && optional) return null;
  if (value is! List) {
    throw DecisionResponseException('$path.$field 应当是数组，实际是 $value');
  }
  return value;
}

Map<String, dynamic>? _map(
  Map<String, dynamic> json,
  String field,
  String path, {
  bool optional = false,
}) {
  final value = json[field];
  if (value == null && optional) return null;
  return _asMap(value, '$path.$field');
}
