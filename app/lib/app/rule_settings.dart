///离线模式参数
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'asset_catalog.dart';

const String _assetDir = 'assets/decision/';

class RuleSettingsException implements Exception {
  const RuleSettingsException(this.message);
  final String message;
  @override
  String toString() => 'RuleSettingsException: $message';
}

@immutable
class RuleSettings {
  const RuleSettings({
    required this.minMeanVisibility,
    required this.minCoverageRatio,
    required this.maxPlans,
    required this.severityLevelBreakpoints,
    required this.scoreWorstWeight,
    required this.scoreMeanWeight,
    required this.ratingCutoffs,
    required this.ratingLabels,
    required this.fallbackModelVersion,
  });
  final double minMeanVisibility;
  final double minCoverageRatio;
  final int maxPlans;
  final ({double low, double high}) severityLevelBreakpoints;
  final double scoreWorstWeight;
  final double scoreMeanWeight;
  final List<int> ratingCutoffs;
  final List<String> ratingLabels;
  final String fallbackModelVersion;

  String ratingOf(int score) {
    for (var index = 0; index < ratingCutoffs.length; index++) {
      if (score >= ratingCutoffs[index]) return ratingLabels[index];
    }
    return ratingLabels.last;
  }

  int levelOf(double? severity0To1) {
    if (severity0To1 == null) return 1;
    if (severity0To1 < severityLevelBreakpoints.low) return 1;
    if (severity0To1 < severityLevelBreakpoints.high) return 2;
    return 3;
  }

  static RuleSettings fromJson(Map<String, dynamic> json) {
    final breakpoints = _doubles(json, 'severity_level_breakpoints');
    if (breakpoints.length != 2) {
      throw RuleSettingsException(
        'severity_level_breakpoints 必须恰好两个切点，实际 ${breakpoints.length} 个',
      );
    }
    final settings = RuleSettings(
      minMeanVisibility: _double(json, 'min_mean_visibility'),
      minCoverageRatio: _double(json, 'min_coverage_ratio'),
      maxPlans: _int(json, 'max_plans'),
      severityLevelBreakpoints: (low: breakpoints[0], high: breakpoints[1]),
      scoreWorstWeight: _double(json, 'score_worst_weight'),
      scoreMeanWeight: _double(json, 'score_mean_weight'),
      ratingCutoffs: _ints(json, 'rating_cutoffs'),
      ratingLabels: _strings(json, 'rating_labels'),
      fallbackModelVersion: _string(json, 'fallback_model_version'),
    );
    _validate(settings);
    return settings;
  }

  static void _validate(RuleSettings settings) {
    final low = settings.severityLevelBreakpoints.low;
    final high = settings.severityLevelBreakpoints.high;
    if (!(low > 0.0 && low < high && high < 1.0)) {
      throw RuleSettingsException('severity_level_breakpoints 必须严格递增且落在 (0,1)：[$low, $high]');
    }
    if (settings.maxPlans < 0) {
      throw RuleSettingsException('max_plans 不能为负：${settings.maxPlans}');
    }
    if (settings.ratingLabels.length != settings.ratingCutoffs.length + 1) {
      throw RuleSettingsException(
        'rating_labels 必须比 rating_cutoffs 多一个（最后一档没有下界）：'
        '${settings.ratingLabels.length} vs ${settings.ratingCutoffs.length}',
      );
    }
    for (var index = 1; index < settings.ratingCutoffs.length; index++) {
      if (settings.ratingCutoffs[index - 1] <= settings.ratingCutoffs[index]) {
        throw RuleSettingsException('rating_cutoffs 必须严格递减：${settings.ratingCutoffs}');
      }
    }
    final total = settings.scoreWorstWeight + settings.scoreMeanWeight;
    if (!(total > 0.0 && total <= 1.0 + 1e-9)) {
      throw RuleSettingsException(
        '评分权重之和必须落在 (0,1]：${settings.scoreWorstWeight} + ${settings.scoreMeanWeight}',
      );
    }
  }
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw RuleSettingsException(_describe(json, key, '字符串', value));
}

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw RuleSettingsException(_describe(json, key, '整数', value));
}

double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  throw RuleSettingsException(_describe(json, key, '数字', value));
}

List<T> _list<T>(Map<String, dynamic> json, String key, String label, T Function(Object) cast) {
  final value = json[key];
  if (value is! List) {
    throw RuleSettingsException(_describe(json, key, '$label数组', value));
  }
  try {
    return [for (final item in value) cast(item as Object)];
  } on Object catch (error) {
    throw RuleSettingsException('字段 $key 的某个元素类型不符：$error');
  }
}

List<double> _doubles(Map<String, dynamic> json, String key) =>
    _list(json, key, '数字', (item) => (item as num).toDouble());

List<int> _ints(Map<String, dynamic> json, String key) =>
    _list(json, key, '整数', (item) => item as int);

List<String> _strings(Map<String, dynamic> json, String key) =>
    _list(json, key, '字符串', (item) => item as String);

String _describe(Map<String, dynamic> json, String key, String expected, Object? value) =>
    json.containsKey(key)
        ? '字段 $key 类型不符：期望$expected，实际是 ${value.runtimeType}'
        : '缺少字段 $key';

@visibleForTesting
String selectRuleSettingsAsset(Iterable<String> manifestKeys) {
  try {
    return selectUniqueJsonAsset(manifestKeys, directory: _assetDir, label: '规则参数');
  } on AssetCatalogException catch (error) {
    throw RuleSettingsException(error.message);
  }
}

@visibleForTesting
RuleSettings parseRuleSettingsAsset({required String path, required String raw}) {
  final Map<String, dynamic> decoded;
  try {
    decoded = decodeAssetObject(path: path, raw: raw);
  } on AssetCatalogException catch (error) {
    throw RuleSettingsException(error.message);
  }
  try {
    return RuleSettings.fromJson(decoded);
  } on RuleSettingsException catch (error) {
    throw RuleSettingsException('$path：${error.message}');
  }
}

Future<RuleSettings> loadRuleSettings({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  final path = selectRuleSettingsAsset(manifest.listAssets());
  return parseRuleSettingsAsset(path: path, raw: await assets.loadString(path));
}
