///矫正方案库的查询
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'asset_catalog.dart';

const String _assetDir = 'assets/plans/';

class PlanCatalogException implements Exception {
  const PlanCatalogException(this.message);
  final String message;
  @override
  String toString() => 'PlanCatalogException: $message';
}

class CorrectionPlan {
  const CorrectionPlan({
    required this.planId,
    required this.nameZh,
    required this.goal,
    required this.instructions,
    required this.keyCues,
    required this.equipment,
    required this.contraindications,
    required this.status,
    required this.dosageText,
    required this.dosageRatified,
    required this.targetFaultCodes,
    required this.difficulty,
    required this.ageMin,
    required this.ageMax,
  });
  final String planId;
  final String nameZh;
  final String goal;
  final List<String> instructions;
  final List<String> keyCues;
  final List<String> equipment;
  final List<String> contraindications;
  final String status;
  final String dosageText;
  final bool dosageRatified;
  bool get isRatified => status == 'active';
  final List<String> targetFaultCodes;
  final int difficulty;
  final int ageMin;
  final int ageMax;
  bool get isDeprecated => status == 'deprecated';

  static CorrectionPlan fromJson(Map<String, dynamic> json) {
    try {
      return CorrectionPlan(
        planId: json['plan_id'] as String,
        nameZh: json['name_zh'] as String,
        goal: json['goal'] as String,
        instructions: _strings(json['instructions']),
        keyCues: _strings(json['key_cues']),
        equipment: _strings(json['equipment']),
        contraindications: _strings(json['contraindications']),
        status: json['status'] as String,
        dosageText: json['dosage_text'] as String,
        dosageRatified: json['dosage_ratified'] as bool,
        targetFaultCodes: _strings(json['target_fault_codes']),
        difficulty: json['difficulty'] as int,
        ageMin: json['age_min'] as int,
        ageMax: json['age_max'] as int,
      );
    } on Object catch (error) {
      throw PlanCatalogException('方案条目缺少字段或类型不符：$error');
    }
  }
}

List<String> _strings(Object? value) {
  if (value is! List) {
    throw PlanCatalogException('期望一个字符串数组，实际是 ${value.runtimeType}');
  }
  return [for (final item in value) item as String];
}

typedef PlanSelection = ({List<CorrectionPlan> plans, bool includesUnreviewed});

class PlanCatalog {
  PlanCatalog(List<CorrectionPlan> plans)
      : _all = List.unmodifiable(plans) {
    final byId = <String, CorrectionPlan>{};
    for (final plan in plans) {
      if (byId.containsKey(plan.planId)) {
        throw PlanCatalogException('方案编码重复：${plan.planId}');
      }
      byId[plan.planId] = plan;
    }
    _byId = byId;
  }

  factory PlanCatalog.fromJson(Map<String, dynamic> raw) {
    final items = raw['plans'];
    if (items is! List) {
      throw const PlanCatalogException('方案库文件缺少 plans 数组');
    }
    return PlanCatalog([
      for (final item in items) CorrectionPlan.fromJson(item as Map<String, dynamic>),
    ]);
  }
  final List<CorrectionPlan> _all;
  late final Map<String, CorrectionPlan> _byId;
  int get length => _all.length;
  List<CorrectionPlan> get all => _all;
  CorrectionPlan? byId(String planId) => _byId[planId];

  List<CorrectionPlan> _forFaults(
    Set<String> wanted, {
    required int age,
    required List<String> availableEquipment,
    required bool includeUnreviewed,
    required int limit,
  }) {
    final held = availableEquipment.toSet();
    final eligible = [
      for (final plan in _all)
        if ((plan.isRatified || includeUnreviewed) &&
            !plan.isDeprecated &&
            age >= plan.ageMin &&
            age <= plan.ageMax &&
            plan.equipment.every(held.contains) &&
            plan.targetFaultCodes.any(wanted.contains))
          plan,
    ];
    eligible.sort((a, b) {
      final overlap = _overlap(b, wanted).compareTo(_overlap(a, wanted));
      if (overlap != 0) return overlap;
      final difficulty = a.difficulty.compareTo(b.difficulty);
      if (difficulty != 0) return difficulty;
      return a.planId.compareTo(b.planId);
    });
    return eligible.length > limit ? eligible.sublist(0, limit) : eligible;
  }

  static int _overlap(CorrectionPlan plan, Set<String> wanted) {
    var count = 0;
    for (final code in plan.targetFaultCodes) {
      if (wanted.contains(code)) count++;
    }
    return count;
  }

  PlanSelection selectForFaults(
    Iterable<String> faultCodes, {
    required int age,
    List<String> availableEquipment = const [],
    required int limit,
  }) {
    final wanted = faultCodes.toSet();
    final reviewed = _forFaults(
      wanted,
      age: age,
      availableEquipment: availableEquipment,
      includeUnreviewed: false,
      limit: limit,
    );
    if (reviewed.isNotEmpty) {
      return (plans: reviewed, includesUnreviewed: false);
    }
    final fallback = _forFaults(
      wanted,
      age: age,
      availableEquipment: availableEquipment,
      includeUnreviewed: true,
      limit: limit,
    );
    return (plans: fallback, includesUnreviewed: fallback.isNotEmpty);
  }
}

@visibleForTesting
String selectPlanAsset(Iterable<String> manifestKeys) {
  try {
    return selectUniqueJsonAsset(manifestKeys, directory: _assetDir, label: '方案库');
  } on AssetCatalogException catch (error) {
    throw PlanCatalogException(error.message);
  }
}

@visibleForTesting
PlanCatalog parsePlanAsset({required String path, required String raw}) {
  final Map<String, dynamic> decoded;
  try {
    decoded = decodeAssetObject(path: path, raw: raw);
  } on AssetCatalogException catch (error) {
    throw PlanCatalogException(error.message);
  }
  try {
    return PlanCatalog.fromJson(decoded);
  } on PlanCatalogException catch (error) {
    throw PlanCatalogException('$path：${error.message}');
  }
}

Future<PlanCatalog> loadPlanCatalog({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  final path = selectPlanAsset(manifest.listAssets());
  return parsePlanAsset(path: path, raw: await assets.loadString(path));
}
