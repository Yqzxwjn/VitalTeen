//决策报告的排版，只吃 view-model
library;

import 'package:flutter/material.dart';

import '../app/decision_report.dart';
import '../app/plan_catalog.dart';
import 'outline_tag.dart';
import 'theme.dart';

class AnalysisReport extends StatelessWidget {
  const AnalysisReport({super.key, required this.report});
  final DecisionReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final abstain = report.kind == ReportKind.abstain;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _originNotice(theme),
        _headline(theme),
        if (abstain) ...[
          const SizedBox(height: 8),
          if (report.abstainReason != null && report.abstainReason!.isNotEmpty)
            Text('${report.abstainAttribution}${report.abstainReason}',
                style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(abstainAdvice, style: theme.textTheme.bodyMedium),
        ] else ...[
          if (report.primary != null) _primary(theme, report.primary!),
          if (report.serviceScore != null) _score(theme, report.serviceScore!),
          if (report.faults.isNotEmpty) _faults(theme),
          if (report.kind == ReportKind.clean) ...[
            const SizedBox(height: 12),
            const Text('没有发现需要留意的地方。', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
          if (report.gates.isNotEmpty) _gates(theme),
          if (report.plans.isNotEmpty) _plans(theme),
        ],
        if (report.disclosures.isNotEmpty) _disclosures(theme),
        if (report.tech.requestId.isNotEmpty) _tech(theme),
      ],
    );
  }

  Widget _originNotice(ThemeData theme) {
    final notice = report.originNotice;
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.smartphone_outlined,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                notice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headline(ThemeData theme) {
    final text = report.headline;
    if (text == null) {
      return Text(
        '这一段总述没能显示出来，请从下面的明细看起。',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (report.headlineIsDraft) ...[
          const SizedBox(height: 4),
          Text(
            '这句话的文案还在评审中。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ],
    );
  }

  Widget _primary(ThemeData theme, ReportPrimary primary) {
    final match = report.faults.where((f) => f.code == primary.code);
    final evidence = match.isEmpty ? null : match.first.evidenceLine;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('最值得先改的一处',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      primary.title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  _severityChip(theme, primary.severityLabel),
                ],
              ),
              const SizedBox(height: 2),
              Text(primary.repsLabel, style: theme.textTheme.bodyMedium),
              if (evidence != null) ...[
                const SizedBox(height: 2),
                Text(evidence, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _score(ThemeData theme, ReportScore score) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            report.scoreLabel,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Text(
            '${score.formScore}',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              fontFeatures: tabularFigures,
            ),
          ),
          const SizedBox(width: 6),
          Text(score.rating,
              style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600)),
          if (score.provisional) ...[
            const SizedBox(width: 6),
            const OutlineTag('临时算法'),
          ],
        ],
      ),
    );
  }

  Widget _faults(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('需要留意的 ${report.faults.length} 处',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          for (final fault in report.faults)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          fault.title,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _severityChip(theme, fault.severityLabel),
                    ],
                  ),
                  Text(fault.repsLabel, style: theme.textTheme.bodySmall),
                  if (fault.evidenceLine != null)
                    Text(fault.evidenceLine!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _gates(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('达标情况',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          for (final gate in report.gates)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    gate.ok
                        ? Icons.check_circle_outline
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: gate.ok
                        ? theme.colorScheme.outline
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      gate.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: gate.ok
                            ? theme.colorScheme.outline
                            : theme.colorScheme.onSurface,
                        fontWeight: gate.ok ? null : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _plans(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('可以这样练',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          for (final item in report.plans) _planCard(theme, item.plan),
          if (report.selectionReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('为什么是这几条：${report.selectionReason}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (report.doseNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(report.doseNote, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _planCard(ThemeData theme, CorrectionPlan plan) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(plan.nameZh,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(plan.goal, style: theme.textTheme.bodyMedium),
              if (plan.instructions.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (var i = 0; i < plan.instructions.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${i + 1}. ${plan.instructions[i]}',
                        style: theme.textTheme.bodyMedium),
                  ),
              ],
              if (plan.keyCues.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final cue in plan.keyCues)
                  Text('· $cue',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
              if (plan.equipment.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('需要：${plan.equipment.join('、')}',
                    style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('组次：${plan.dosageText}',
                        style: theme.textTheme.bodySmall),
                  ),
                  if (!plan.dosageRatified) ...[
                    const SizedBox(width: 6),
                    const OutlineTag('剂量待核定'),
                  ],
                ],
              ),
              for (final item in plan.contraindications)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: theme.colorScheme.error.withValues(alpha: 0.6),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(item,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _disclosures(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(),
          const SizedBox(height: 6),
          Text('看这份报告前请知道',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          for (final item in report.disclosures)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('· ${item.text}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  Widget _tech(ThemeData theme) {
    final tech = report.tech;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('技术信息', style: theme.textTheme.labelSmall),
        children: [
          _techRow(theme, '请求编号', tech.requestId),
          _techRow(theme, '判定来源', tech.modelVersion),
          _techRow(theme, report.thresholdsLabel, tech.thresholdsVersion),
          if (!tech.origin.isDevice)
            _techRow(theme, '端侧阈值表', tech.localThresholdsVersion),
          if (!tech.origin.isDevice)
            _techRow(theme, '服务端耗时', '${tech.latencyMs} 毫秒'),
        ],
      ),
    );
  }

  Widget _techRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _severityChip(ThemeData theme, String label) {
    final scheme = theme.colorScheme;
    final strong = label == '重度';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: strong ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: strong ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
