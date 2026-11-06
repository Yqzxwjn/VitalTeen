library;

import 'package:flutter/material.dart';

import '../app/growth.dart';
import '../app/history.dart' show streakDays;
import '../app/session_record.dart';
import 'app_icons.dart';
import 'design.dart';

/// 首页那张打卡卡：今天走到哪一步了。
///
/// 它只回答一个问题 ——「今天要不要练」。所以最强的那个数字是连练天数，
/// 其次是今日任务；等级放在右边当上下文，不抢主位。
class GrowthCard extends StatelessWidget {
  const GrowthCard({
    super.key,
    required this.records,
    required this.now,
    this.onOpen,
  });
  final List<SessionRecord> records;
  final DateTime now;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final streak = streakDays(records, now);
    final level = levelForStreak(streak);
    final tasks = dailyTasks(records, now);
    final done = doneTaskCount(tasks);
    final checked = checkedInOn(records, now);
    final progress = tasks.isEmpty ? 0.0 : done / tasks.length;

    return AppTappableCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIcon(
                checked ? AppGlyph.flame : AppGlyph.sun,
                size: 20,
                color: checked ? AppColors.orange : AppColors.inkFaint,
              ),
              const SizedBox(width: Space.s75),
              Expanded(
                child: Text(
                  checked ? '连续打卡 $streak 天' : '今天还没练',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title3.copyWith(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                'Lv.${level.level} ${level.title}',
                style: AppText.caption4.copyWith(
                  color: AppColors.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onOpen != null) ...[
                const SizedBox(width: Space.s25),
                const AppIcon(
                  AppGlyph.chevronRight,
                  size: 18,
                  color: AppColors.inkFaint,
                ),
              ],
            ],
          ),
          const SizedBox(height: Space.s100),
          ClipRRect(
            borderRadius: Radii.pillAll,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: Space.s75,
              backgroundColor: AppColors.hairline,
            ),
          ),
          const SizedBox(height: Space.s75),
          Text(
            _taskLine(tasks, done),
            style: AppText.caption5.copyWith(color: AppColors.inkSoft),
          ),
        ],
      ),
    );
  }

  String _taskLine(List<DailyTask> tasks, int done) {
    if (tasks.isEmpty) return '今天没有任务';
    if (done == tasks.length) return '今日任务全部完成，明天再来';
    final next = tasks.firstWhere((task) => !task.done);
    return '今日任务 $done/${tasks.length} · ${next.title}';
  }
}
