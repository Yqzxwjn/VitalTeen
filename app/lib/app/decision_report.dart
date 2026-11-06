///把决策服务的返回拼成一份给人看的中文报告
library;

import '../domain/thresholds.dart';
import 'decision_request.dart';
import 'decision_response.dart';
import 'decision_submission.dart';
import 'fault_presentation.dart';
import 'message_catalog.dart';
import 'plan_catalog.dart';

enum ReportKind {
  scored,
  clean,
  abstain,
}

enum HeadlineSource {
  serverTemplate,
  fallbackTemplate,
  clientConstant,
  unavailable,
}

class Disclosure {
  const Disclosure({required this.kind, required this.text, this.count});
  final DisclosureKind kind;
  final String text;
  final int? count;
}

enum DisclosureKind {
  notNationalStandard,
  twoReferenceScores,
  ruleOnly,
  decidedOnDevice,
  provisionalScore,
  thresholdsPending,
  thresholdsVersionMismatch,
  dosageUnratified,
  planSnapshotStale,
  evidenceUnavailable,
  headlineUnavailable,
}

class ReportPrimary {
  const ReportPrimary({
    required this.code,
    required this.title,
    required this.severityLabel,
    required this.repsLabel,
  });
  final String code;
  final String title;
  final String severityLabel;
  final String repsLabel;
}

class ReportFault {
  const ReportFault({
    required this.code,
    required this.title,
    required this.severityLabel,
    required this.repsLabel,
    this.evidenceLine,
  });
  final String code;
  final String title;
  final String severityLabel;
  final String repsLabel;
  final String? evidenceLine;
}

class ReportGate {
  const ReportGate({required this.code, required this.title, required this.ok});
  final String code;
  final String title;
  final bool ok;
}

class ReportPlan {
  const ReportPlan(this.plan);
  final CorrectionPlan plan;
}

class ReportScore {
  const ReportScore({
    required this.formScore,
    required this.rating,
    required this.provisional,
  });
  final int formScore;
  final String rating;
  final bool provisional;
}

enum ReportOrigin {
  server,
  device;
  bool get isDevice => this == ReportOrigin.device;
}

class ReportTech {
  const ReportTech({
    required this.requestId,
    required this.modelVersion,
    required this.thresholdsVersion,
    required this.localThresholdsVersion,
    required this.latencyMs,
    required this.origin,
  });
  final String requestId;
  final String modelVersion;
  final String thresholdsVersion;
  final String localThresholdsVersion;
  final int latencyMs;
  final ReportOrigin origin;
}

class DecisionReport {
  const DecisionReport({
    required this.kind,
    required this.headline,
    required this.headlineSource,
    required this.headlineIsDraft,
    required this.primary,
    required this.serviceScore,
    required this.faults,
    required this.gates,
    required this.plans,
    required this.selectionReason,
    required this.doseNote,
    required this.disclosures,
    required this.abstainReason,
    required this.tech,
    this.fallbackCause,
  });
  final ReportKind kind;
  final String? headline;
  final HeadlineSource headlineSource;
  final bool headlineIsDraft;
  final ReportPrimary? primary;
  final ReportScore? serviceScore;
  final List<ReportFault> faults;
  final List<ReportGate> gates;
  final List<ReportPlan> plans;
  final String selectionReason;
  final String doseNote;
  final List<Disclosure> disclosures;
  final String? abstainReason;
  final ReportTech tech;
  final DeviceFallbackCause? fallbackCause;
  String? get originNotice => tech.origin.isDevice
      ? '本机判定 · ${fallbackCause?.clause ?? '当时没连上决策服务'}'
      : null;
  String get scoreLabel => tech.origin.isDevice ? '本机判定参考分' : '服务端参考分';
  String get abstainAttribution => tech.origin.isDevice ? '本机判定：' : '服务端的判定：';
  String get thresholdsLabel => tech.origin.isDevice ? '判定所用阈值表' : '服务端阈值表';
}

const String abstainHeadline = '这组数据还不够评价这组动作';

const String abstainAdvice = '换一个光线更足、能拍到全身的地方，站稳一秒再开始，'
    '做的时候让膝盖和脚踝都在画面里。';

DecisionReport buildDecisionReport({
  required DecisionResponse response,
  required DecisionRequest request,
  required MessageCatalog messages,
  required PlanCatalog planCatalog,
  required ThresholdTable thresholds,
  required ReportOrigin origin,
  DeviceFallbackCause? fallbackCause,
  LocalFaultContext? local,
}) {
  assert(
    (origin == ReportOrigin.device) == (fallbackCause != null),
    '来源与本机兜底的原因必须同时给出：说这份报告是本机算的却不说为什么，'
    '读报告的人就无从判断该不该信它。',
  );
  final kind = switch (response.status) {
    DecisionStatus.abstain => ReportKind.abstain,
    DecisionStatus.ok => response.faults.isEmpty ? ReportKind.clean : ReportKind.scored,
  };
  final names = _faultNames(response);
  final faults = [
    for (final fault in response.faults) _reportFault(fault, request, local),
  ];
  final missingEvidence = faults.where((f) => f.evidenceLine == null).length;
  final resolved = <ReportPlan>[];
  final unknownPlanIds = <String>[];
  for (final id in response.choice?.selectedPlanIds ?? const <String>[]) {
    final plan = planCatalog.byId(id);
    if (plan == null) {
      unknownPlanIds.add(id);
    } else {
      resolved.add(ReportPlan(plan));
    }
  }
  final headline = _headline(response, messages, kind);
  return DecisionReport(
    kind: kind,
    headline: headline.text,
    headlineSource: headline.source,
    headlineIsDraft: headline.isDraft,
    primary: _primary(response, names),
    serviceScore: response.scores == null
        ? null
        : ReportScore(
            formScore: response.scores!.formScore,
            rating: response.scores!.rating,
            provisional: response.scores!.provisional,
          ),
    faults: faults,
    gates: _gates(response, names, local),
    plans: resolved,
    selectionReason: response.choice?.selectionReason ?? '',
    doseNote: stripMarkdownEmphasis(response.choice?.doseNote ?? ''),
    abstainReason: response.abstainReason,
    fallbackCause: fallbackCause,
    disclosures: _disclosures(
      response: response,
      request: request,
      thresholds: thresholds,
      kind: kind,
      missingEvidence: missingEvidence,
      unknownPlanIds: unknownPlanIds,
      plans: resolved,
      headlineSource: headline.source,
      origin: origin,
      fallbackCause: fallbackCause,
    ),
    tech: ReportTech(
      requestId: response.requestId,
      modelVersion: response.meta.decisionModelVersion,
      thresholdsVersion: response.meta.thresholdsVersion,
      localThresholdsVersion: request.thresholdsVersion,
      latencyMs: response.meta.latencyMs,
      origin: origin,
    ),
  );
}

_Headline _headline(
  DecisionResponse response,
  MessageCatalog messages,
  ReportKind kind,
) {
  if (kind == ReportKind.abstain) {
    return const _Headline(abstainHeadline, HeadlineSource.clientConstant, false);
  }
  final message = response.message;
  if (message == null) {
    return const _Headline(null, HeadlineSource.unavailable, false);
  }
  final params = Map<String, Object>.of(message.params);
  final primary = response.primaryFault;
  if (primary != null && params.containsKey('primary')) {
    params['primary'] = faultTitle(primary.code, primary.name);
  }
  final rendered = messages.render(message.templateId, params);
  if (rendered != null) {
    return _Headline(
      rendered,
      HeadlineSource.serverTemplate,
      !messages.isReviewed(message.templateId),
    );
  }
  final fallback = messages.renderFallback(params);
  return _Headline(
    fallback,
    fallback == null ? HeadlineSource.unavailable : HeadlineSource.fallbackTemplate,
    !messages.isReviewed(messages.fallbackTemplateId),
  );
}

class _Headline {
  const _Headline(this.text, this.source, this.isDraft);
  final String? text;
  final HeadlineSource source;
  final bool isDraft;
}

Map<String, String> _faultNames(DecisionResponse response) {
  final names = <String, String>{};
  final primary = response.primaryFault;
  if (primary != null) names[primary.code] = primary.name;
  for (final fault in response.faults) {
    names.putIfAbsent(fault.code, () => fault.name);
  }
  return names;
}

ReportPrimary? _primary(DecisionResponse response, Map<String, String> names) {
  final primary = response.primaryFault;
  if (primary == null) return null;
  final match = response.faults.where((f) => f.code == primary.code).toList();
  return ReportPrimary(
    code: primary.code,
    title: faultTitle(primary.code, names[primary.code] ?? primary.name),
    severityLabel: _severityLabel(match.isEmpty ? null : match.first.severityLevel),
    repsLabel: _repsLabel(match.isEmpty ? const [] : match.first.evidence.reps),
  );
}

ReportFault _reportFault(
  DecisionFault fault,
  DecisionRequest request,
  LocalFaultContext? local,
) {
  return ReportFault(
    code: fault.code,
    title: faultTitle(fault.code, fault.name),
    severityLabel: _severityLabel(fault.severityLevel),
    repsLabel: _repsLabel(fault.evidence.reps),
    evidenceLine: _joinEvidence(fault.code, fault.evidence.reps, request, local),
  );
}

String _repsLabel(List<int> reps) {
  if (reps.isEmpty) return '次数不详';
  if (reps.length > 5) return '共 ${reps.length} 次';
  return '第 ${reps.join('、')} 次';
}

String _severityLabel(int? level) => switch (level) {
      1 => '轻度',
      2 => '中度',
      3 => '重度',
      _ => '未知档',
    };

String? _joinEvidence(
  String code,
  List<int> reps,
  DecisionRequest request,
  LocalFaultContext? local,
) {
  if (local == null || reps.isEmpty) return null;
  String? best;
  var bestScore = double.negativeInfinity;
  for (final rep in request.reps) {
    if (!reps.contains(rep.index)) continue;
    for (final fault in rep.faults) {
      if (fault.code != code) continue;
      for (final deviation in fault.deviations) {
        final line = local.evidenceLine(
          code: code,
          feature: deviation.feature,
          measured: deviation.measured,
          threshold: deviation.threshold,
        );
        if (line == null) continue;
        final score = deviation.severity01 ?? double.negativeInfinity;
        if (score > bestScore) {
          bestScore = score;
          best = '第 ${rep.index} 次 · $line';
        }
      }
    }
  }
  return best;
}

List<ReportGate> _gates(
  DecisionResponse response,
  Map<String, String> names,
  LocalFaultContext? local,
) {
  final gates = [
    for (final entry in response.gates.entries)
      () {
        final code = _stripOk(entry.key);
        return ReportGate(
          code: code,
          title: faultTitle(
            code,
            names[code] ?? local?.faultName(code) ?? code,
          ),
          ok: entry.value,
        );
      }(),
  ];
  gates.sort((a, b) {
    if (a.ok != b.ok) return a.ok ? 1 : -1;
    return a.code.compareTo(b.code);
  });
  return gates;
}

String _stripOk(String key) =>
    key.endsWith('_ok') ? key.substring(0, key.length - 3) : key;

List<Disclosure> _disclosures({
  required DecisionResponse response,
  required DecisionRequest request,
  required ThresholdTable thresholds,
  required ReportKind kind,
  required int missingEvidence,
  required List<String> unknownPlanIds,
  required List<ReportPlan> plans,
  required HeadlineSource headlineSource,
  required ReportOrigin origin,
  required DeviceFallbackCause? fallbackCause,
}) {
  final device = origin.isDevice;
  final out = <Disclosure>[
    const Disclosure(
      kind: DisclosureKind.notNationalStandard,
      text: '本报告只看动作做得准不准，不是国标体测成绩，也不用于任何评比。',
    ),
  ];

  if (response.meta.isRuleOnly) {
    out.add(const Disclosure(
      kind: DisclosureKind.ruleOnly,
      text: '这份结论由规则引擎直接给出，没有经过决策模型判断。',
    ));
  }

  if (device) {
    final cause = fallbackCause!.clause;
    out.add(Disclosure(
      kind: DisclosureKind.decidedOnDevice,
      text: '这份报告是在这台手机上算出来的 —— $cause，改由本机判定。'
          '用的判定规则与服务端相同，但结论不是服务端给出的。',
    ));
  }
  final scores = response.scores;
  if (scores != null) {
    if (scores.provisional) {
      out.add(const Disclosure(
        kind: DisclosureKind.provisionalScore,
        text: '评分由临时算法产出，各项权重尚未经体育专业核定，只当作刻度看。',
      ));
    }
    out.add(Disclosure(
      kind: DisclosureKind.twoReferenceScores,
      text: '这里的「${device ? '本机判定参考分' : '服务端参考分'}」'
          '与组末那个即时参考分是两套不同的临时算法，'
          '口径不同，数值不一样是正常的。',
    ));
  }
  final pending = thresholds.pendingReview().length;
  if (pending > 0) {
    out.add(Disclosure(
      kind: DisclosureKind.thresholdsPending,
      count: pending,
      text: '本应用有 $pending 条判定阈值尚未经专业核定，相关提示只作参考。',
    ));
  }

  if (response.meta.thresholdsVersion != request.thresholdsVersion) {
    out.add(Disclosure(
      kind: DisclosureKind.thresholdsVersionMismatch,
      text: '服务端判定用的是阈值表 ${response.meta.thresholdsVersion}，'
          '端侧提示用的是 ${request.thresholdsVersion} —— 两者用途不同，'
          '不必一致，但同一处界面上可能看到细微差别。',
    ));
  }

  if (unknownPlanIds.isNotEmpty) {
    out.add(Disclosure(
      kind: DisclosureKind.planSnapshotStale,
      count: unknownPlanIds.length,
      text: '有 ${unknownPlanIds.length} 条建议练习（${unknownPlanIds.join('、')}）'
          '不在本应用的方案库里，可能没能显示——更新应用后再看。',
    ));
  }

  if (plans.any((p) => !p.plan.dosageRatified)) {
    out.add(const Disclosure(
      kind: DisclosureKind.dosageUnratified,
      text: '建议练习的组次与次数尚未经体育专业成员核定，请按自身感觉量力而行。',
    ));
  }

  if (missingEvidence > 0) {
    out.add(Disclosure(
      kind: DisclosureKind.evidenceUnavailable,
      count: missingEvidence,
      text: '有 $missingEvidence 处问题没能取出本机的具体数值，只显示了出现的次数。',
    ));
  }

  if (headlineSource == HeadlineSource.unavailable) {
    out.add(const Disclosure(
      kind: DisclosureKind.headlineUnavailable,
      text: '这一组的总述没能从服务端返回的结果里渲染出来，下面直接从明细开始。',
    ));
  }
  return out;
}
