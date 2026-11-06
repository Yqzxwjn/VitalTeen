library;

enum SourceType {
  nationalStandard('national_standard'),
  literature('literature'),
  pendingReview('pending_review');
  const SourceType(this.wire);
  final String wire;
  static SourceType fromWire(String value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    throw ThresholdException('未知的 source_type：$value');
  }
}

class ThresholdException implements Exception {
  const ThresholdException(this.message);
  final String message;
  @override
  String toString() => 'ThresholdException: $message';
}

class Threshold {
  const Threshold({
    required this.key,
    required this.actionCode,
    required this.featureCode,
    required this.value,
    required this.unit,
    required this.sourceType,
    required this.version,
    this.standardGroup,
    this.sex,
    this.ageMin,
    this.ageMax,
    this.severityBreakpoints = const [],
    this.sourceUrl,
    this.reviewer,
    this.reviewedAt,
  });
  final String key;
  final String actionCode;
  final String featureCode;
  final double value;
  final String unit;
  final SourceType sourceType;
  final String version;
  final String? standardGroup;
  final String? sex;
  final int? ageMin;
  final int? ageMax;
  final List<double> severityBreakpoints;
  final String? sourceUrl;
  final String? reviewer;
  final String? reviewedAt;
  bool get mayDriveScoring => sourceType != SourceType.pendingReview;

  String get provenance {
    switch (sourceType) {
      case SourceType.pendingReview:
        return '待体育专业核定';
      case SourceType.nationalStandard:
        return sourceUrl == null ? '国家学生体质健康标准' : '国家学生体质健康标准（$sourceUrl）';
      case SourceType.literature:
        return sourceUrl == null ? '运动科学文献' : '运动科学文献（$sourceUrl）';
    }
  }
  Threshold withValue(double newValue) => Threshold(
        key: key,
        actionCode: actionCode,
        featureCode: featureCode,
        value: newValue,
        unit: unit,
        sourceType: sourceType,
        version: version,
        standardGroup: standardGroup,
        sex: sex,
        ageMin: ageMin,
        ageMax: ageMax,
        severityBreakpoints: severityBreakpoints,
        sourceUrl: sourceUrl,
        reviewer: reviewer,
        reviewedAt: reviewedAt,
      );

  static Threshold fromJson(Map<String, dynamic> json, {required String version}) {
    try {
      return Threshold(
        key: json['key'] as String,
        actionCode: json['action_code'] as String,
        featureCode: (json['feature_code'] as String?) ?? '',
        value: (json['value'] as num).toDouble(),
        unit: json['unit'] as String,
        sourceType: SourceType.fromWire(json['source_type'] as String),
        version: version,
        standardGroup: json['standard_group'] as String?,
        sex: json['sex'] as String?,
        ageMin: (json['age_min'] as num?)?.toInt(),
        ageMax: (json['age_max'] as num?)?.toInt(),
        severityBreakpoints: ((json['severity_breakpoints'] as List<dynamic>?) ?? const [])
            .map((v) => (v as num).toDouble())
            .toList(),
        sourceUrl: json['source_url'] as String?,
        reviewer: json['reviewer'] as String?,
        reviewedAt: json['reviewed_at'] as String?,
      );
    } on Object catch (error) {
      throw ThresholdException('阈值条目缺少字段或类型不符：$error');
    }
  }
}

abstract interface class ThresholdSource {
  String get version;
  Threshold get(String key);
}

class ThresholdTable implements ThresholdSource {
  ThresholdTable(List<Threshold> thresholds, {required this.version}) {
    for (final threshold in thresholds) {
      if (_table.containsKey(threshold.key)) {
        throw ThresholdException('阈值键重复：${threshold.key}');
      }
      _table[threshold.key] = threshold;
    }
  }

  factory ThresholdTable.fromJson(Map<String, dynamic> raw) {
    final version = raw['version'];
    if (version is! String) {
      throw const ThresholdException('阈值文件缺少 version 字段');
    }
    final items = raw['thresholds'];
    if (items is! List) {
      throw const ThresholdException('阈值文件缺少 thresholds 数组');
    }
    final thresholds = items
        .map((item) => Threshold.fromJson(item as Map<String, dynamic>, version: version))
        .toList();
    return ThresholdTable(thresholds, version: version);
  }

  final Map<String, Threshold> _table = {};
  @override
  final String version;
  int get length => _table.length;
  bool contains(String key) => _table.containsKey(key);

  @override
  Threshold get(String key) {
    final threshold = _table[key];
    if (threshold == null) {
      throw ThresholdException('阈值不存在：$key');
    }
    return threshold;
  }
  double value(String key) => get(key).value;

  Threshold requireScorable(String key) {
    final threshold = get(key);
    if (!threshold.mayDriveScoring) {
      throw ThresholdException(
        '阈值 $key 尚未经体育专业成员核定，只能用于提示、不能驱动扣分。'
        '若确实要出提示，请改用 get() 并显式处理 pendingReview 情形。',
      );
    }
    return threshold;
  }
  List<Threshold> pendingReview() =>
      _table.values.where((t) => !t.mayDriveScoring).toList();
}
