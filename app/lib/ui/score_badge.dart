library;

import 'package:flutter/material.dart';

import '../app/form_score.dart';
import 'outline_tag.dart';
import 'theme.dart';

Color scoreColor(FormRating rating, {required Brightness brightness}) {
  final light = brightness == Brightness.light;
  return switch (rating) {
    FormRating.excellent =>
      light ? const Color(0xFF0F9D77) : const Color(0xFF2AF5C0),
    FormRating.good => light ? const Color(0xFF0B7FB0) : vitalAccent,
    FormRating.fair =>
      light ? const Color(0xFF4257C4) : const Color(0xFF8FA8FF),
    FormRating.pass =>
      light ? const Color(0xFFB5730A) : const Color(0xFFFFC46B),
    FormRating.needsWork =>
      light ? const Color(0xFFC25A16) : const Color(0xFFFF9A5C),
  };
}

class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score, this.compact = false});
  final FormScore score;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = scoreColor(score.rating, brightness: theme.brightness);
    final numberSize = compact ? 26.0 : 52.0;
    final number = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '${score.score}',
          style: TextStyle(
            fontSize: numberSize,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: tabularFigures,
          ),
        ),
        SizedBox(width: compact ? 4 : 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            score.rating.label,
            style: (compact ? theme.textTheme.bodyMedium : theme.textTheme.titleMedium)
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '参考分',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          number,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        number,
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '参考分',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (score.provisional) const ProvisionalTag(),
          ],
        ),
      ],
    );
  }
}

class RepScoreFlash extends StatelessWidget {
  const RepScoreFlash({super.key, required this.score, required this.turn});
  final FormScore score;
  final int turn;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: Tween<double>(begin: 0.7, end: 1.0).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: ScoreBadge(key: ValueKey(turn), score: score, compact: true),
    );
  }
}
