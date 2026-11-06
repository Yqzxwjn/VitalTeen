//TODO 历史只在本机，导出和云同步都还没做
library;

import 'package:flutter/foundation.dart';

import 'session_record.dart';

@immutable
class HistorySummary {
  const HistorySummary({
    required this.totalCount,
    required this.averageScore,
    required this.streakDays,
  });
  final int totalCount;
  final int? averageScore;
  final int streakDays;
}

HistorySummary summarize(List<SessionRecord> records, DateTime now) {
  final scores = records.map((record) => record.score).whereType<int>();
  final zongfen = scores.fold<int>(0, (heji, score) => heji + score);
  final cishu = scores.length;
  return HistorySummary(
    totalCount: records.length,
    averageScore: cishu == 0 ? null : (zongfen / cishu).round(),
    streakDays: streakDays(records, now),
  );
}

int streakDays(List<SessionRecord> records, DateTime now) {
  if (records.isEmpty) return 0;

  final rizi = <DateTime>{for (final r in records) localDayOf(r.finishedAt)};
  final jintian = localDayOf(now);
  var zhizhen = rizi.contains(jintian) ? jintian : previousDay(jintian);
  var tianshu = 0;
  while (rizi.contains(zhizhen)) {
    tianshu++;
    zhizhen = previousDay(zhizhen);
  }
  return tianshu;
}

List<DayGroup> groupByDay(List<SessionRecord> records) {
  final byDay = <DateTime, List<SessionRecord>>{};
  for (final record in records) {
    (byDay[localDayOf(record.finishedAt)] ??= []).add(record);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in days)
      DayGroup(
        day: day,
        records: byDay[day]!
          ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt)),
      ),
  ];
}

@immutable
class DayGroup {
  const DayGroup({required this.day, required this.records});
  final DateTime day;
  final List<SessionRecord> records;
}

DateTime localDayOf(DateTime at) {
  final local = at.toLocal();
  return DateTime(local.year, local.month, local.day);
}

DateTime previousDay(DateTime day) =>
    DateTime(day.year, day.month, day.day - 1);

String historyDayLabel(DateTime day, DateTime now) {
  final jintian = localDayOf(now);
  if (day == jintian) return '今天';
  if (day == previousDay(jintian)) return '昨天';
  if (day.year == jintian.year) return '${day.month}月${day.day}日';
  return '${day.year}年${day.month}月${day.day}日';
}

String historyClockText(DateTime at) {
  final local = at.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

DateTime nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);

const int heatmapWeeks = 26;

const int heatmapTopLevel = 4;

int heatLevel(int sets) {
  if (sets <= 0) return 0;
  if (sets >= heatmapTopLevel) return heatmapTopLevel;
  return sets;
}

const List<String> _weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String historyWeekdayText(DateTime day) => _weekdayNames[day.weekday - 1];

@immutable
class HeatmapDay {
  const HeatmapDay({
    required this.day,
    required this.sets,
    required this.inWindow,
  });
  final DateTime day;
  final int sets;
  final bool inWindow;
}

@immutable
class HeatmapWeek {
  const HeatmapWeek({required this.days, this.monthLabel});
  final List<HeatmapDay> days;
  final String? monthLabel;
}

@immutable
class HeatmapGrid {
  const HeatmapGrid({
    required this.weeks,
    required this.today,
    required this.activeDays,
  });
  final List<HeatmapWeek> weeks;
  final DateTime today;
  final int activeDays;

  HeatmapDay? dayOf(DateTime day) {
    for (final week in weeks) {
      for (final cell in week.days) {
        if (cell.day == day && cell.inWindow) return cell;
      }
    }
    return null;
  }
}

HeatmapGrid buildHeatmap(
  List<SessionRecord> records,
  DateTime now, {
  int weeks = heatmapWeeks,
}) {
  assert(weeks > 0);
  final jintian = localDayOf(now);
  final lastMonday =
      DateTime(jintian.year, jintian.month, jintian.day - (jintian.weekday - 1));
  final firstMonday = DateTime(
    lastMonday.year,
    lastMonday.month,
    lastMonday.day - 7 * (weeks - 1),
  );

  final sets = <DateTime, int>{};
  for (final record in records) {
    final day = localDayOf(record.finishedAt);
    if (day.isBefore(firstMonday) || day.isAfter(jintian)) continue;
    sets[day] = (sets[day] ?? 0) + 1;
  }
  var zhizhen = firstMonday;
  var labeledMonth = 0;
  var activeDays = 0;
  final grid = <HeatmapWeek>[];

  for (var w = 0; w < weeks; w++) {
    final rizi = <HeatmapDay>[];
    for (var i = 0; i < 7; i++) {
      final inWindow = !zhizhen.isAfter(jintian);
      final cishu = inWindow ? (sets[zhizhen] ?? 0) : 0;
      if (cishu > 0) activeDays++;
      rizi.add(HeatmapDay(day: zhizhen, sets: cishu, inWindow: inWindow));
      zhizhen = nextDay(zhizhen);
    }
    String? monthLabel;
    for (final cell in rizi) {
      if (!cell.inWindow) break;
      if (cell.day.month != labeledMonth) {
        labeledMonth = cell.day.month;
        monthLabel = '${cell.day.month}月';
      }
    }
    grid.add(HeatmapWeek(days: rizi, monthLabel: monthLabel));
  }
  return HeatmapGrid(weeks: grid, today: jintian, activeDays: activeDays);
}

String actionNamesText(List<SessionRecord> records, {int max = 3}) {
  final names = <String>[];
  var more = false;
  for (final record in records) {
    final name = record.actionNameZh;
    if (names.contains(name)) continue;
    if (names.length == max) {
      more = true;
      break;
    }
    names.add(name);
  }
  if (names.isEmpty) return '';
  return more ? '${names.join('、')}等' : names.join('、');
}

String heatmapDayText(HeatmapDay day, List<SessionRecord> records, DateTime now) {
  final head = '${historyDayLabel(day.day, now)} ${historyWeekdayText(day.day)}';
  if (day.sets == 0) return '$head · 这天没有练习';
  final names = actionNamesText([
    for (final record in records)
      if (localDayOf(record.finishedAt) == day.day) record,
  ]);
  return '$head · ${day.sets} 组 · $names';
}

String heatmapOverviewText(HeatmapGrid grid) {
  final weeks = grid.weeks.length;
  if (grid.activeDays == 0) return '近 $weeks 周还没有练习记录 · 点一格看那天';
  return '近 $weeks 周练了 ${grid.activeDays} 天 · 点一格看那天';
}
