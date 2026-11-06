library;

import 'package:flutter/material.dart';

import '../app/growth.dart';
import '../app/history.dart' show streakDays;
import '../app/session_record.dart';
import 'design.dart';
import 'theme.dart';

class GrowthPage extends StatelessWidget {
  const GrowthPage({
    super.key,
    required this.records,
    required this.now,
    required this.onBack,
  });
  final List<SessionRecord> records;
  final DateTime now;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streak = streakDays(records, now);
    final level = levelForStreak(streak);
    final next = nextLevelOf(level);
    final tasks = dailyTasks(records, now);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的成长'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            Space.s200,
            Space.s100,
            Space.s200,
            Space.s400,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LevelCard(
                    level: level,
                    next: next,
                    streak: streak,
                    growth: totalGrowth(records),
                  ),
                  const SizedBox(height: Space.s200),
                  _Card(title: '最近四周', child: _grid(theme)),
                  const SizedBox(height: Space.s200),
                  _Card(
                    title: '今日任务',
                    child: Column(
                      children: [
                        for (final task in tasks) _taskRow(theme, task),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s200),
                  _Card(
                    title: '成就',
                    trailing:
                        '${_earnedCount()}/${achievementsOf(records).length}',
                    child: _achievements(theme),
                  ),
                  const SizedBox(height: Space.s200),
                  _Card(title: '累计', child: _totals(theme, streak)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grid(ThemeData theme) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    final days = checkInWindow(now);
    final checked = checkInDays(records);
    final today = DateTime(now.year, now.month, now.day);
    return Column(
      children: [
        Row(
          children: [
            for (final label in labels)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var row = 0; row * 7 < days.length; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _cell(
                      theme,
                      index: row * 7 + col,
                      days: days,
                      checked: checked,
                      today: today,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(
    ThemeData theme, {
    required int index,
    required List<DateTime> days,
    required Set<DateTime> checked,
    required DateTime today,
  }) {
    if (index >= days.length) return const SizedBox(height: 26);
    final day = days[index];
    final on = checked.contains(day);
    return Center(
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: on ? vitalBlue : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: day == today
              ? Border.all(color: vitalOrange, width: 2)
              : null,
        ),
        child: on
            ? const Icon(Icons.check, size: 15, color: vitalOnBrand)
            : null,
      ),
    );
  }

  Widget _taskRow(ThemeData theme, DailyTask task) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            task.done ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
            color: task.done ? vitalBlue : theme.colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              task.title,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: task.done ? theme.colorScheme.outline : vitalInk,
              ),
            ),
          ),
          if (task.target > 1)
            Text(
              '${task.progress}/${task.target}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
    );
  }

  int _earnedCount() => achievementsOf(records).where((a) => a.earned).length;

  Widget _achievements(ThemeData theme) {
    return Wrap(
      spacing: 12,
      runSpacing: 14,
      children: [
        for (final item in achievementsOf(records)) _badge(theme, item),
      ],
    );
  }

  /// 徽章图标按 `id` 查 —— 图标是界面的事，`app/growth.dart` 里没有 `IconData`。
  IconData _badgeIcon(String id) => switch (id) {
    'first' => Icons.play_circle_outline,
    'streak3' => Icons.local_fire_department_outlined,
    'streak7' => Icons.whatshot_outlined,
    'streak30' => Icons.military_tech_outlined,
    'sets10' => Icons.fitness_center_outlined,
    'sets50' => Icons.workspace_premium_outlined,
    'actions6' => Icons.grid_view_outlined,
    _ => Icons.auto_awesome_outlined,
  };

  Widget _badge(ThemeData theme, Achievement item) {
    const size = 60.0;
    return SizedBox(
      width: 76,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: item.earned
                  ? vitalBlue
                  : theme.colorScheme.surfaceContainerHighest,
            ),
            alignment: Alignment.center,
            child: Icon(
              item.earned ? _badgeIcon(item.id) : Icons.lock_outline,
              size: 24,
              color: item.earned ? vitalOnBrand : theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.earned ? item.title : item.hint,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: theme.textTheme.bodySmall?.copyWith(
              color: item.earned ? vitalInk : theme.colorScheme.outline,
              fontWeight: item.earned ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _totals(ThemeData theme, int streak) {
    final rows = <(String, String)>[
      ('累计练习', '${records.length} 组'),
      ('打卡天数', '${checkInDays(records).length} 天'),
      ('最长连胜', '${longestStreak(records)} 天'),
      ('当前连胜', '$streak 天'),
      ('成长值', '${totalGrowth(records)}'),
    ];
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: vitalInk,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.next,
    required this.streak,
    required this.growth,
  });
  final GrowthLevel level;
  final GrowthLevel? next;
  final int streak;
  final int growth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upcoming = next;
    final progress = upcoming == null
        ? 1.0
        : ((streak - level.streak) / (upcoming.streak - level.streak)).clamp(
            0.0,
            1.0,
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: vitalBlue,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${level.level}',
                    style: AppText.heading6.copyWith(
                      color: vitalOnBrand,
                    ),
                  ),
                ),
                const SizedBox(width: Space.s100),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Lv.${level.level} ${level.title}',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: vitalInk,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '成长值 $growth',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              upcoming == null
                  ? '已经到顶了，保持住就行'
                  : '已连续 $streak 天 · 再连练 '
                        '${upcoming.streak - streak} 天升到 Lv.${upcoming.level} '
                        '${upcoming.title}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tail = trailing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.s200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: AppText.title3.copyWith(
                      color: vitalInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (tail != null)
                  Text(
                    tail,
                    style: AppText.caption5.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.s100),
            child,
          ],
        ),
      ),
    );
  }
}
