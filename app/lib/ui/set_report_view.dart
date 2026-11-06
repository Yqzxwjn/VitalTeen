//一组的报告，全屏
library;

import 'package:flutter/material.dart';

import '../app/action_spec.dart';
import '../app/profile.dart';
import '../app/squat_session.dart';
import '../domain/rules.dart' show FaultStat;
import '../app/fault_presentation.dart' show faultTitle;
import 'analysis_panel.dart';
import 'bottom_surface.dart';
import 'score_badge.dart';

class SetReportView extends StatelessWidget {
  const SetReportView({
    super.key,
    required this.view,
    required this.requestBuilder,
    required this.analyze,
    required this.onAnotherSet,
    required this.onRecalibrate,
    this.profile,
    this.discardedReason = squatDiscardedReason,
    this.isTimed = false,
  });
  final SessionView view;
  final String discardedReason;
  final bool isTimed;
  final RequestBuilder requestBuilder;
  final AnalysisRunner analyze;
  final VoidCallback onAnotherSet;
  final VoidCallback onRecalibrate;
  final Profile? profile;
  @visibleForTesting
  static const Key actionBarKey = ValueKey('report-action-bar');

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: _content(context),
              ),
            ),
          ),
        ),
        _actionBar(context),
      ],
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final summary = view.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (summary != null) ...[
          Text(
            '这一组：${summary.repCount}${isTimed ? ' 段' : ' 个'}',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (view.repDurationsMs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '合计 ${_seconds(view.totalRepDurationMs)} 秒'
              '（每段 ${view.repDurationsMs.map(_seconds).join(' / ')} 秒）',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
          if (view.setScore != null) ...[
            const SizedBox(height: 16),
            Center(child: ScoreBadge(score: view.setScore!)),
          ],
          if (view.interrupted) ...[
            const SizedBox(height: 8),
            Text(
              '中途离开过画面，计数可能不准。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (view.discardedReps > 0) ...[
            const SizedBox(height: 8),
            Text(
              '有 ${view.discardedReps} ${isTimed ? '段' : '次'}没计入（$discardedReason）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          if (summary.faultStats.isEmpty)
            Text(
              summary.repCount == 0
                  ? '一次都没数上，这一组没有可评的东西。'
                  : '没有发现需要留意的地方。',
            )
          else
            for (final stat in summary.faultStats) _faultStatTile(context, stat),
          const SizedBox(height: 20),
        ],
        AnalysisPanel(
          build: requestBuilder,
          analyze: analyze,
          profile: profile,
        ),
      ],
    );
  }
  static String _seconds(int ms) =>
      (ms <= 0 ? 0.0 : ms / 1000.0).toStringAsFixed(1);

  Widget _faultStatTile(BuildContext context, FaultStat stat) {
    final theme = Theme.of(context);
    final name = faultTitle(stat.code, stat.nameZh);
    final rate = (stat.rate * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text('${stat.count} 次 · $rate%', style: theme.textTheme.bodyMedium),
          if (!stat.scorable) ...[
            const SizedBox(width: 6),
            Text(
              '待核定',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BottomSurface(
      key: actionBarKey,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: onAnotherSet,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('再来一组'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: onRecalibrate,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('重新标定'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
