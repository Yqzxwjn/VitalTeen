///打卡、连胜、等级、每日任务，全部从练习记录现算，不另存一份
library;

import 'package:flutter/foundation.dart';

import 'history.dart' show localDayOf, nextDay;
import 'session_record.dart';

const int growthPerSession = 10;

/// 平均分每满 10 分再给 1 点，所以一组最多 10 + 10
const int growthPerScoreTens = 1;

/// 每日任务里「拿到高分」那条的分数线
const int dailyTaskScoreTarget = 80;

int growthOfSession(SessionRecord record) =>
    growthPerSession + growthPerScoreTens * ((record.score ?? 0) ~/ 10);

int totalGrowth(Iterable<SessionRecord> records) =>
    records.fold(0, (sum, record) => sum + growthOfSession(record));

Set<DateTime> checkInDays(Iterable<SessionRecord> records) => {
  for (final record in records) localDayOf(record.finishedAt),
};

bool checkedInOn(Iterable<SessionRecord> records, DateTime day) =>
    checkInDays(records).contains(localDayOf(day));

int longestStreak(Iterable<SessionRecord> records) {
  final days = checkInDays(records).toList()..sort();
  var best = 0;
  var run = 0;
  DateTime? previous;
  for (final day in days) {
    run = (previous != null && day == nextDay(previous)) ? run + 1 : 1;
    if (run > best) best = run;
    previous = day;
  }
  return best;
}

@immutable
class GrowthLevel {
  const GrowthLevel({
    required this.level,
    required this.title,
    required this.streak,
  });
  final int level;
  final String title;

  /// 升到这一级需要的连胜天数
  final int streak;
}

const List<GrowthLevel> kGrowthLevels = [
  GrowthLevel(level: 1, title: '起步', streak: 0),
  GrowthLevel(level: 2, title: '活力新星', streak: 2),
  GrowthLevel(level: 3, title: '坚持之星', streak: 5),
  GrowthLevel(level: 4, title: '训练达人', streak: 10),
  GrowthLevel(level: 5, title: '自律高手', streak: 21),
  GrowthLevel(level: 6, title: '硬核少年', streak: 45),
  GrowthLevel(level: 7, title: '传奇', streak: 90),
];

GrowthLevel levelForStreak(int streak) {
  var current = kGrowthLevels.first;
  for (final level in kGrowthLevels) {
    if (streak >= level.streak) current = level;
  }
  return current;
}

GrowthLevel? nextLevelOf(GrowthLevel level) {
  final index = kGrowthLevels.indexOf(level);
  if (index < 0 || index + 1 >= kGrowthLevels.length) return null;
  return kGrowthLevels[index + 1];
}

/// 距离下一级还差几天连胜；满级返回 null
int? daysToNextLevel(int streak) {
  final next = nextLevelOf(levelForStreak(streak));
  if (next == null) return null;
  return next.streak - streak;
}

@immutable
class DailyTask {
  const DailyTask({
    required this.id,
    required this.title,
    required this.target,
    required this.progress,
  });
  final String id;
  final String title;
  final int target;
  final int progress;

  bool get done => progress >= target;
}

/// 今日任务。**全部从当天的练习记录里算**，没有单独的存储。
List<DailyTask> dailyTasks(Iterable<SessionRecord> records, DateTime now) {
  final today = [
    for (final record in records)
      if (localDayOf(record.finishedAt) == localDayOf(now)) record,
  ];
  return [
    DailyTask(id: 'sets', title: '今天练 1 组', target: 1, progress: today.length),
    DailyTask(
      id: 'actions',
      title: '今天练到 2 个不同动作',
      target: 2,
      progress: {for (final record in today) record.actionCode}.length,
    ),
    DailyTask(
      id: 'score',
      title: '有一组拿到 $dailyTaskScoreTarget 分以上',
      target: 1,
      progress: today
          .where((record) => (record.score ?? 0) >= dailyTaskScoreTarget)
          .length,
    ),
  ];
}

int doneTaskCount(Iterable<DailyTask> tasks) =>
    tasks.where((task) => task.done).length;

@immutable
class Achievement {
  const Achievement({
    required this.id,
    required this.title,
    required this.hint,
    required this.earned,
  });
  final String id;
  final String title;

  /// 没拿到时显示的那句：说清怎么拿到
  final String hint;
  final bool earned;
}

/// 成就。判据全是**已有的记录上的计数**，不另存一份「拿过什么」——
/// 否则两个真相源迟早会打架（删了记录、徽章还亮着）。
///
/// **图标不在这里**：`IconData` 是 material 的东西，这一层到 `foundation` 为止
/// （界面按 `id` 去查那张表，见 `ui/growth_page.dart`）。
List<Achievement> achievementsOf(Iterable<SessionRecord> records) {
  final list = records.toList();
  final best = longestStreak(list);
  final actions = {for (final record in list) record.actionCode}.length;
  final bestScore = list.fold<int>(
    0,
    (top, record) => (record.score ?? 0) > top ? record.score! : top,
  );
  return [
    Achievement(
      id: 'first',
      title: '第一组',
      hint: '练完一组',
      earned: list.isNotEmpty,
    ),
    Achievement(
      id: 'streak3',
      title: '连练 3 天',
      hint: '连续三天打卡',
      earned: best >= 3,
    ),
    Achievement(
      id: 'streak7',
      title: '连练 7 天',
      hint: '连续一周打卡',
      earned: best >= 7,
    ),
    Achievement(
      id: 'streak30',
      title: '连练 30 天',
      hint: '连续一个月打卡',
      earned: best >= 30,
    ),
    Achievement(
      id: 'sets10',
      title: '练满 10 组',
      hint: '累计练到 10 组',
      earned: list.length >= 10,
    ),
    Achievement(
      id: 'sets50',
      title: '练满 50 组',
      hint: '累计练到 50 组',
      earned: list.length >= 50,
    ),
    Achievement(
      id: 'actions6',
      title: '六项动作',
      hint: '练过 6 个不同动作',
      earned: actions >= 6,
    ),
    Achievement(
      id: 'score90',
      title: '一次 90 分',
      hint: '有一组拿到 90 分以上',
      earned: bestScore >= 90,
    ),
  ];
}

/// 打卡格子用的那几天：从 [weeks] 周前那个周一开始，排到今天
List<DateTime> checkInWindow(DateTime now, {int weeks = 4}) {
  final today = localDayOf(now);
  final thisMonday = DateTime(
    today.year,
    today.month,
    today.day - (today.weekday - 1),
  );
  final first = DateTime(
    thisMonday.year,
    thisMonday.month,
    thisMonday.day - 7 * (weeks - 1),
  );
  final days = <DateTime>[];
  var cursor = first;
  while (!cursor.isAfter(today)) {
    days.add(cursor);
    cursor = nextDay(cursor);
  }
  return days;
}
