//单次 rep 做完后的反馈卡片
library;

import 'package:flutter/material.dart';

import '../app/fault_presentation.dart';
import '../app/form_score.dart';
import 'score_badge.dart';

class RepFeedbackCard extends StatelessWidget {
  const RepFeedbackCard({super.key, required this.feedback, this.score});
  final RepFeedbackView feedback;
  final FormScore? score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  feedback.clean
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  size: 18,
                  color: feedback.clean
                      ? scoreColor(FormRating.excellent,
                          brightness: theme.brightness)
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    feedback.headline,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (score != null) ...[
                  const SizedBox(width: 10),
                  RepScoreFlash(score: score!, turn: feedback.repIndex),
                ],
              ],
            ),
            for (final fault in feedback.faults) _faultTile(context, fault),
          ],
        ),
      ),
    );
  }

  Widget _faultTile(BuildContext context, FaultView fault) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  fault.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _severityChip(context, fault.severityLabel),
              if (fault.notice != null) ...[
                const SizedBox(width: 6),
                _noticeChip(context, fault.notice!),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(fault.detail, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _severityChip(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    final strong = label == '明显';
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

  Widget _noticeChip(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
    );
  }
}
