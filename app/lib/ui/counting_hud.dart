library;

import 'package:flutter/material.dart';

import '../app/action_spec.dart';
import '../app/squat_session.dart' show SessionView;

const double kneeMinDeg = 60.0;
const double kneeMaxDeg = 180.0;

class CountingHud extends StatelessWidget {
  const CountingHud({
    super.key,
    required this.view,
    this.stateLabels = squatHudStateLabels,
    this.discardedReason = squatDiscardedReason,
    this.isTimed = false,
  });
  final SessionView view;
  final Map<String, String> stateLabels;
  final String discardedReason;
  final bool isTimed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isTimed) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _seconds(view.holdMs),
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text('秒', style: theme.textTheme.titleMedium),
              const Spacer(),
              _phaseChip(context),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '本组 ${view.repCount} 段',
            style: theme.textTheme.titleMedium,
          ),
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${view.repCount}',
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Text('个', style: theme.textTheme.titleMedium),
              const Spacer(),
              _phaseChip(context),
            ],
          ),
          const SizedBox(height: 8),
          _kneeBar(context),
        ],
        if (view.discardedReps > 0) ...[
          const SizedBox(height: 8),
          _note(
            context,
            Icons.filter_alt_off_outlined,
            '有 ${view.discardedReps} ${isTimed ? '段' : '次'}没计入（$discardedReason）。',
          ),
        ],
        if (view.interrupted) ...[
          const SizedBox(height: 8),
          _note(
            context,
            Icons.warning_amber_outlined,
            '刚才离开过画面，这一段计数可能不准。',
          ),
        ],
      ],
    );
  }
  static String _seconds(int ms) =>
      (ms <= 0 ? 0.0 : ms / 1000.0).toStringAsFixed(1);

  Widget _phaseChip(BuildContext context) {
    final label = stateLabels[view.machineState];
    if (label == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  Widget _kneeBar(BuildContext context) {
    final jiaodu = view.kneeAngle;
    final theme = Theme.of(context);
    if (jiaodu == null) {
      return Text(
        '膝角 —',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    final zhanbi =
        ((jiaodu - kneeMinDeg) / (kneeMaxDeg - kneeMinDeg)).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('膝角', style: theme.textTheme.bodyMedium),
            Text(
              '${jiaodu.round()}°',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: zhanbi,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  Widget _note(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}
