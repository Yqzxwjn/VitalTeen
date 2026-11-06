/// 打卡、连胜、等级与每日任务的测试。
///
/// 时间一律**显式构造**，不用 `DateTime.now()`：依赖当天真实日期的测试会在某个月末
/// 悄悄红一次，那时候没人知道它红的是什么。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/growth.dart';
import 'package:vitalteen_app/app/history.dart' show streakDays;
import 'package:vitalteen_app/app/session_record.dart';

SessionRecord _at(
  int year,
  int month,
  int day, {
  int hour = 12,
  String actionCode = 'SQUAT',
  String actionNameZh = '深蹲',
  int? score,
}) => SessionRecord(
  actionCode: actionCode,
  actionNameZh: actionNameZh,
  finishedAt: DateTime(year, month, day, hour),
  repCount: 12,
  isTimed: false,
  score: score,
  provisional: false,
);

/// 「现在」：2026 年 10 月 5 日（周一）下午两点。
final DateTime _now = DateTime(2026, 10, 5, 14);

void main() {
  group('成长值', () {
    test('一组 = 10 + 平均分每 10 分 1 点', () {
      expect(growthOfSession(_at(2026, 10, 5)), 10);
      expect(growthOfSession(_at(2026, 10, 5, score: 0)), 10);
      expect(growthOfSession(_at(2026, 10, 5, score: 59)), 15);
      expect(growthOfSession(_at(2026, 10, 5, score: 100)), 20);
    });

    test('总分是逐组相加', () {
      final records = [
        _at(2026, 10, 4, score: 90),
        _at(2026, 10, 5, score: 50),
      ];
      expect(totalGrowth(records), 19 + 15);
      expect(totalGrowth(const []), 0);
    });
  });

  group('打卡', () {
    test('打卡日是「练过的那几个本地日期」，同一天练几组只算一天', () {
      final records = [
        _at(2026, 10, 5, hour: 9),
        _at(2026, 10, 5, hour: 20),
        _at(2026, 10, 3),
      ];
      expect(checkInDays(records), {
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 3),
      });
      expect(checkedInOn(records, _now), isTrue);
      expect(checkedInOn(records, DateTime(2026, 10, 4, 23)), isFalse);
    });
  });

  group('连胜', () {
    test('今天练了：从今天往回数', () {
      final records = [_at(2026, 10, 3), _at(2026, 10, 4), _at(2026, 10, 5)];
      expect(streakDays(records, _now), 3);
    });

    test('今天还没练不算断 —— 今天还没过完', () {
      final records = [_at(2026, 10, 3), _at(2026, 10, 4)];
      expect(streakDays(records, _now), 2);
    });

    test('昨天也没练就断了', () {
      final records = [_at(2026, 10, 1), _at(2026, 10, 2)];
      expect(streakDays(records, _now), 0);
    });

    test('最长连胜取历史最长那一段，不受当前连胜影响', () {
      final records = [
        _at(2026, 9, 20),
        _at(2026, 9, 21),
        _at(2026, 9, 22),
        _at(2026, 9, 23),
        _at(2026, 10, 5),
      ];
      expect(longestStreak(records), 4);
      expect(streakDays(records, _now), 1);
    });

    test('空表没有连胜', () {
      expect(longestStreak(const []), 0);
      expect(streakDays(const [], _now), 0);
    });
  });

  group('等级', () {
    test('连胜越多等级越高', () {
      expect(levelForStreak(0).level, 1);
      expect(levelForStreak(1).level, 1);
      expect(levelForStreak(2).level, 2);
      expect(levelForStreak(4).level, 2);
      expect(levelForStreak(5).level, 3);
      expect(levelForStreak(21).level, 5);
      expect(levelForStreak(90).level, 7);
      expect(levelForStreak(999).level, 7, reason: '到顶了不再涨');
    });

    test('等级表的门槛严格递增，没有写反的档', () {
      for (var i = 1; i < kGrowthLevels.length; i++) {
        expect(
          kGrowthLevels[i].streak,
          greaterThan(kGrowthLevels[i - 1].streak),
        );
        expect(kGrowthLevels[i].level, kGrowthLevels[i - 1].level + 1);
      }
      expect(kGrowthLevels.first.streak, 0, reason: '零连胜也得有级');
    });

    test('距离下一级还差几天；满级没有下一级', () {
      expect(daysToNextLevel(0), 2);
      expect(daysToNextLevel(3), 2);
      expect(daysToNextLevel(89), 1);
      expect(daysToNextLevel(200), isNull);
      expect(nextLevelOf(kGrowthLevels.last), isNull);
    });
  });

  group('每日任务', () {
    test('今天什么都没做：三条全没完成', () {
      final tasks = dailyTasks([_at(2026, 10, 4, score: 99)], _now);
      expect(tasks, hasLength(3));
      expect(doneTaskCount(tasks), 0);
    });

    test('练了一组高分：三条一起完成', () {
      final tasks = dailyTasks([_at(2026, 10, 5, score: 85)], _now);
      expect(doneTaskCount(tasks), 2, reason: '「两个不同动作」还差一个');
      expect(tasks[0].done, isTrue);
      expect(tasks[2].done, isTrue);
    });

    test('两个不同动作：三条一起完成', () {
      final tasks = dailyTasks([
        _at(2026, 10, 5, score: 85),
        _at(2026, 10, 5, actionCode: 'PLANK', actionNameZh: '平板支撑', score: 85),
      ], _now);
      expect(doneTaskCount(tasks), 3);
      expect(tasks[1].progress, 2);
    });

    test('任务只按当天算，昨天的高分不算', () {
      final tasks = dailyTasks([
        _at(2026, 10, 4, score: 100),
        _at(2026, 10, 5, score: 50),
      ], _now);
      expect(tasks[2].done, isFalse);
    });
  });

  group('成就', () {
    test('一条记录都没有：一个都没亮', () {
      final list = achievementsOf(const []);
      expect(list, hasLength(8));
      expect(list.where((a) => a.earned), isEmpty);
    });

    test('每条判据各自独立地亮', () {
      final first = achievementsOf([_at(2026, 10, 5)]);
      expect(first.firstWhere((a) => a.id == 'first').earned, isTrue);
      expect(first.firstWhere((a) => a.id == 'streak3').earned, isFalse);

      final three = achievementsOf([
        _at(2026, 10, 3),
        _at(2026, 10, 4),
        _at(2026, 10, 5),
      ]);
      expect(three.firstWhere((a) => a.id == 'streak3').earned, isTrue);
      expect(three.firstWhere((a) => a.id == 'streak7').earned, isFalse);

      final tenSets = achievementsOf([
        for (var i = 1; i <= 10; i++) _at(2026, 9, i),
      ]);
      expect(tenSets.firstWhere((a) => a.id == 'sets10').earned, isTrue);
      expect(tenSets.firstWhere((a) => a.id == 'sets50').earned, isFalse);

      final manyActions = achievementsOf([
        for (final code in ['A', 'B', 'C', 'D', 'E', 'F'])
          _at(2026, 10, 5, actionCode: code),
      ]);
      expect(manyActions.firstWhere((a) => a.id == 'actions6').earned, isTrue);

      final high = achievementsOf([_at(2026, 10, 5, score: 90)]);
      expect(high.firstWhere((a) => a.id == 'score90').earned, isTrue);
      expect(
        achievementsOf([_at(2026, 10, 5, score: 89)])
            .firstWhere((a) => a.id == 'score90')
            .earned,
        isFalse,
      );
    });

    test('id 不重复，没拿到的都有「怎么拿到」那句话', () {
      // 界面上没拿到的徽章显示的是 hint：空着的话那一格就是一个没有字的灰圈。
      final list = achievementsOf(const []);
      expect({for (final a in list) a.id}.length, list.length);
      for (final item in list) {
        expect(item.hint, isNotEmpty, reason: item.id);
        expect(item.title, isNotEmpty, reason: item.id);
      }
    });
  });

  group('打卡窗', () {
    test('四周：从三周前的周一到今天', () {
      final days = checkInWindow(_now);
      expect(days.first, DateTime(2026, 9, 14), reason: '第一个格子是周一');
      expect(days.last, DateTime(2026, 10, 5));
      expect(days, hasLength(22), reason: '三个整周 + 今天这一天');
    });

    test('窗口长度 = 整周 + 本周已过的天数', () {
      // 9 月 14 日也是周一：只要一周的话就是这一格，不多不少。
      final oneWeek = checkInWindow(DateTime(2026, 9, 14, 9), weeks: 1);
      expect(oneWeek, hasLength(1));
      expect(oneWeek.single, DateTime(2026, 9, 14));

      // 周三看：周一到周三三格。
      final midWeek = checkInWindow(DateTime(2026, 9, 16, 9), weeks: 1);
      expect(midWeek, hasLength(3));
    });
  });
}
