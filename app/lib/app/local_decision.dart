///本地计算数据报告
library;

import 'dart:math' as math;

import 'decision_request.dart';
import 'decision_response.dart';
import 'plan_catalog.dart';
import 'python_math.dart';
import 'rule_settings.dart';

const String _doseNote =
    '本建议由规则引擎按覆盖面排序产出（决策模型当时不可用）；剂量待体育专业成员核定。';

DecisionResponse decideLocally({
  required DecisionRequest request,
  required PlanCatalog planCatalog,
  required RuleSettings settings,
  required String? Function(String code) faultName,
  List<String> availableEquipment = const [],
}) {
  final problem = _qualityProblem(request, settings);
  if (problem != null) {
    return _abstain(request, problem, settings);
  }

  if (request.candidates.isEmpty) {
    return _clean(request, settings, faultName);
  }
  return _ruleOnly(
    request: request,
    planCatalog: planCatalog,
    settings: settings,
    faultName: faultName,
    availableEquipment: availableEquipment,
  );
}

String? _qualityProblem(DecisionRequest request, RuleSettings settings) {
  final quality = request.poseQuality;
  if (quality.meanVisibility < settings.minMeanVisibility) {
    return '关键点可见性过低（${pyFixed2(quality.meanVisibility)}），画面质量不足以判断动作';
  }
  if (quality.coverageOkRatio < settings.minCoverageRatio) {
    return '有效帧占比过低（${pyFixed2(quality.coverageOkRatio)}），动作序列不完整';
  }
  if (request.set.repCount == 0) {
    return '本组未记录到任何完整动作';
  }
  return null;
}

DecisionResponse _abstain(DecisionRequest request, String reason, RuleSettings settings) =>
    DecisionResponse(
      requestId: request.requestId,
      status: DecisionStatus.abstain,
      abstainReason: reason,
      faults: const [],
      gates: const {},
      meta: _meta(request, settings),
    );

DecisionResponse _clean(
  DecisionRequest request,
  RuleSettings settings,
  String? Function(String) faultName,
) =>
    DecisionResponse(
      requestId: request.requestId,
      status: DecisionStatus.ok,
      faults: const [],
      gates: const {},
      scores: Scores(
        formScore: 100,
        rating: settings.ratingLabels.first,
        provisional: true,
      ),
      message: _buildMessage(request, null, faultName),
      meta: _meta(request, settings),
    );

DecisionResponse _ruleOnly({
  required DecisionRequest request,
  required PlanCatalog planCatalog,
  required RuleSettings settings,
  required String? Function(String) faultName,
  required List<String> availableEquipment,
}) {
  final severity = _maxSeverityByCode(request);
  final repsByCode = <String, List<int>>{
    for (final stat in request.set.faultStats) stat.code: List<int>.from(stat.reps),
  };
  final confidence = pyRoundTo(
    math.min(request.poseQuality.meanVisibility, request.poseQuality.coverageOkRatio),
    4,
  );
  final faults = <DecisionFault>[
    for (final candidate in request.candidates)
      () {
        final code = candidate.code;
        final value = _severityFor(request, code, severity);
        return DecisionFault(
          code: code,
          name: faultName(code) ?? code,
          severityLevel: settings.levelOf(value),
          severityScore: pyRound(value * 100),
          confidence: confidence,
          evidence: FaultEvidence(reps: repsByCode[code] ?? const []),
        );
      }(),
  ];
  final primaryCode = _rulePrimary(request);

  final gates = <String, bool>{for (final fault in faults) '${fault.code}_ok': false};
  final selection = planCatalog.selectForFaults(
    [for (final candidate in request.candidates) candidate.code],
    age: request.context.age,
    availableEquipment: availableEquipment,
    limit: settings.maxPlans,
  );
  final choice = selection.plans.isEmpty
      ? null
      : PlanChoice(
          selectedPlanIds: [for (final plan in selection.plans) plan.planId],
          selectionReason: _selectionReason(selection.plans, selection.includesUnreviewed),
          doseNote: _doseNote,
        );
  return DecisionResponse(
    requestId: request.requestId,
    status: DecisionStatus.ok,
    faults: faults,
    gates: gates,
    scores: _provisionalScores(faults, settings),
    primaryFault: primaryCode == null
        ? null
        : FaultRef(code: primaryCode, name: faultName(primaryCode) ?? primaryCode),
    choice: choice,
    message: _buildMessage(request, primaryCode, faultName),
    meta: _meta(request, settings),
  );
}

Map<String, double?> _maxSeverityByCode(DecisionRequest request) {
  final worst = <String, double?>{};
  for (final rep in request.reps) {
    for (final fault in rep.faults) {
      for (final deviation in fault.deviations) {
        final value = deviation.severity01;
        if (value == null) continue;
        final current = worst[fault.code];
        worst[fault.code] = current == null ? value : math.max(current, value);
      }
    }
  }

  for (final stat in request.set.faultStats) {
    worst.putIfAbsent(stat.code, () => null);
  }
  return worst;
}

double _severityFor(
  DecisionRequest request,
  String code,
  Map<String, double?> severity,
) {
  final value = severity[code];
  if (value != null) return value;
  for (final stat in request.set.faultStats) {
    if (stat.code != code) continue;
    if (request.set.repCount <= 0) return 0.0;
    final ratio = stat.count / request.set.repCount;
    return ratio < 1.0 ? ratio : 1.0;
  }
  return 0.0;
}

String? _rulePrimary(DecisionRequest request) {
  if (request.candidates.isEmpty) return null;
  final allowed = {for (final candidate in request.candidates) candidate.code};
  final stats = [
    for (final stat in request.set.faultStats)
      if (allowed.contains(stat.code)) stat,
  ];
  if (stats.isEmpty) {
    return request.candidates.first.code;
  }
  var best = stats.first;
  for (final stat in stats.skip(1)) {
    if (stat.count > best.count) best = stat;
  }
  return best.code;
}

Scores _provisionalScores(List<DecisionFault> faults, RuleSettings settings) {
  if (faults.isEmpty) {
    return Scores(
      formScore: 100,
      rating: settings.ratingLabels.first,
      provisional: true,
    );
  }
  final severities = [for (final fault in faults) fault.severityScore / 100];
  final worst = severities.reduce(math.max);
  final mean = severities.reduce((a, b) => a + b) / severities.length;
  final penalty =
      settings.scoreWorstWeight * worst + settings.scoreMeanWeight * mean;
  final score = pyRound(math.max(0.0, math.min(1.0, 1.0 - penalty)) * 100);
  return Scores(
    formScore: score,
    rating: settings.ratingOf(score),
    provisional: true,
  );
}

String _selectionReason(List<CorrectionPlan> plans, bool unreviewed) {
  final goals = plans.take(2).map((plan) => plan.goal).join('；');
  final prefix = unreviewed ? '（方案未核定，仅供参考）' : '';
  if (goals.isNotEmpty) return '$prefix以覆盖当前主要问题为优先：$goals';
  return prefix.isNotEmpty ? prefix : '按覆盖面排序';
}

Message _buildMessage(
  DecisionRequest request,
  String? primaryCode,
  String? Function(String) faultName,
) {
  final params = <String, Object>{
    'total': request.set.repCount,
    'valid': request.set.validRepCount,
  };
  if (primaryCode != null) {
    params['primary'] = faultName(primaryCode) ?? primaryCode;
    for (final stat in request.set.faultStats) {
      if (stat.code == primaryCode) {
        params['primary_count'] = stat.count;
        break;
      }
    }
  }
  final template = 'msg_${request.context.actionCode.toLowerCase()}_'
      '${(primaryCode ?? 'clean').toLowerCase()}_teen_v1';
  return Message(templateId: template, params: params);
}

DecisionMeta _meta(DecisionRequest request, RuleSettings settings) => DecisionMeta(
      decisionModelVersion: settings.fallbackModelVersion,
      thresholdsVersion: request.thresholdsVersion,
      latencyMs: 0,
      shuffled: false,
    );
