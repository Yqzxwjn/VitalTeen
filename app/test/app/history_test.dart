/// 历史汇总、连续天数与分组的测试。
///
/// **这一组测试里最值钱的是连续天数那几条。** 它有三个各自独立、而且都很容易
/// 写错的地方：`null` 分不能当 0、今天还没练不能算断、换日要按日历不能按 24 小时。
/// 三条都只在特定日期/时刻才现形，靠手点是碰不到的 —— 所以它们必须在这里被穷尽。
///
/// 时间一律**显式构造**（`DateTime(2026, 10, 5, 14)`），不用 `DateTime.now()`：
/// 一个依赖当天真实日期的测试会在某个月末悄悄红一次，而那时候没人知道
/// 它红的是什么。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/history.dart';
import 'package:vitalteen_app/app/session_record.dart';

/// 一条记录。
SessionRecord _record({
  required DateTime finishedAt,
  int? score,
  int repCount = 12,
  bool isTimed = false,
}) {
  return SessionRecord(
    actionCode: isTimed ? 'PLANK' : 'SQUAT',
    actionNameZh: isTimed ? '平板支撑' : '深蹲',
    finishedAt: finishedAt,
    repCount: repCount,
    isTimed: isTimed,
    score: score,
    provisional: false,
  );
}

/// 一条落在某天某点的记录。绝大多数用例只关心「哪一天」。
SessionRecord _at(
  int year,
  int month,
  int day, {
  int hour = 12,
  int? score,
  int repCount = 12,
  bool isTimed = false,
}) =>
    _record(
      finishedAt: DateTime(year, month, day, hour),
      score: score,
      repCount: repCount,
      isTimed: isTimed,
    );

/// 「现在」：2026 年 10 月 5 日下午两点。
final DateTime _now = DateTime(2026, 10, 5, 14);

void main() {
  group('汇总', () {
    test('空表：三个数都是「没有」', () {
      final summary = summarize(const [], _now);
      expect(summary.totalCount, 0);
      // **不是 0 分。** 一条记录都没有时「平均姿势分」这个数不存在，
      // 界面显示 `—`。显示 0 会让新用户以为自己的平均分是 0。
      expect(summary.averageScore, isNull);
      expect(summary.streakDays, 0);
    });

    test('有分的算平均', () {
      final summary = summarize([
        _at(2026, 10, 5, hour: 10, score: 90),
        _at(2026, 10, 5, hour: 11, score: 80),
      ], _now);
      expect(summary.totalCount, 2);
      expect(summary.averageScore, 85);
    });

    test('没有分的记录不参与平均，但算一组', () {
      // **这一条是整个汇总里最容易写错的地方。** 把 `null` 当 0 算，平均分
      // 会从 85 掉到 56 —— 用户会因为一次「相机没看见我」而以为自己退步了。
      final summary = summarize([
        _at(2026, 10, 5, hour: 10, score: 90),
        _at(2026, 10, 5, hour: 11),
        _at(2026, 10, 5, hour: 12, score: 80),
      ], _now);

      expect(summary.averageScore, 85, reason: 'null 既不算 0，也不占分母');
      expect(summary.totalCount, 3, reason: '但它确实是一次练习');
    });

    test('全是没分的：平均分是 null，不是 0', () {
      final summary = summarize([
        _at(2026, 10, 5, hour: 10),
        _at(2026, 10, 5, hour: 11),
      ], _now);
      expect(summary.averageScore, isNull);
      expect(summary.totalCount, 2);
    });

    test('0 分是一条真实的记录，要算进去', () {
      // 与上面那条 `null` 是一对：0 分是「每一项都扣满了」，是一个真实的低分。
      // 把这两种情形混起来，是这段代码唯一会犯的错。
      final summary = summarize([
        _at(2026, 10, 5, hour: 10, score: 0),
        _at(2026, 10, 5, hour: 11, score: 90),
      ], _now);
      expect(summary.averageScore, 45);
    });

    test('平均值四舍五入到整数', () {
      // 分数本身是整数（`form_score.dart` 里取整的理由是「显示出来的数」与
      // 「评级用的数」要是同一个），平均值保留小数会让汇总卡上出现一个
      // 比任何一次练习都精确的数。
      expect(
        summarize([
          _at(2026, 10, 5, hour: 10, score: 90),
          _at(2026, 10, 5, hour: 11, score: 85),
        ], _now).averageScore,
        88, // 87.5 → 88
      );
      expect(
        summarize([
          _at(2026, 10, 5, hour: 10, score: 90),
          _at(2026, 10, 5, hour: 11, score: 80),
        ], _now).averageScore,
        85,
      );
    });

    test('不同动作混在一起也各算一组', () {
      // `totalCount` 不是把 rep 加起来：深蹲 12 个与平板支撑 4 段不是同一种
      // 东西，相加没有量纲。用户问「我练了多少」时，他要的是「多少组」。
      final summary = summarize([
        _at(2026, 10, 5, hour: 10, score: 90),
        _at(2026, 10, 5, hour: 11, score: 70, repCount: 4, isTimed: true),
      ], _now);
      expect(summary.totalCount, 2);
      expect(summary.averageScore, 80);
    });
  });

  group('连续天数', () {
    test('今天练了一次：1', () {
      expect(streakDays([_at(2026, 10, 5)], _now), 1);
    });

    test('今天、昨天、前天：3', () {
      expect(
        streakDays([
          _at(2026, 10, 5),
          _at(2026, 10, 4),
          _at(2026, 10, 3),
        ], _now),
        3,
      );
    });

    test('今天还没练、昨天练了：1（宽限）', () {
      // 早上打开应用时今天确实还没练 —— 这时候显示 0 会让用户以为记录坏了
      //（他昨天明明练了），也会让「连续」每天挨一次耳光。
      expect(streakDays([_at(2026, 10, 4)], _now), 1);
    });

    test('今天没练、昨天也没练：0', () {
      expect(streakDays([_at(2026, 10, 3)], _now), 0);
    });

    test('中间断了一天：只数到断的地方', () {
      expect(
        streakDays([
          _at(2026, 10, 5),
          _at(2026, 10, 4),
          // 10 月 3 日缺
          _at(2026, 10, 2),
          _at(2026, 10, 1),
        ], _now),
        2,
      );
    });

    test('同一天练了三次：还是 1', () {
      // 去重按**日历日**，不是按条数。不去重的表现是「连续 3 天」，
      // 而用户昨天根本没打开过这个应用。
      expect(
        streakDays([
          _at(2026, 10, 5, hour: 8),
          _at(2026, 10, 5, hour: 12),
          _at(2026, 10, 5, hour: 20),
        ], _now),
        1,
      );
    });

    test('跨零点的那两组算两天', () {
      // 23:50 与次日 00:10 间隔 20 分钟，但那是**两天**。按 24 小时算的话
      // 这里是 1，而用户会觉得自己明明连着两天都练了。
      expect(
        streakDays([
          _record(finishedAt: DateTime(2026, 10, 4, 23, 50)),
          _record(finishedAt: DateTime(2026, 10, 5, 0, 10)),
        ], _now),
        2,
      );
    });

    test('跨月的那两天也数得下去', () {
      // 9 月 30 日 → 10 月 1 日。这里考的是 `previousDay` 的月份借位。
      expect(
        streakDays([
          _at(2026, 10, 1),
          _at(2026, 9, 30),
        ], DateTime(2026, 10, 1, 14)),
        2,
      );
    });

    test('跨年的那两天也数得下去', () {
      // 12 月 31 日 → 1 月 1 日，年份借位。
      expect(
        streakDays([
          _at(2026, 1, 1),
          _at(2025, 12, 31),
        ], DateTime(2026, 1, 1, 14)),
        2,
      );
    });

    test('连续天数不看分数，也不看动作', () {
      // 「连续」这个词说的是「有没有练」，不是「练得怎么样」。
      // 一组没分、一次平板支撑，都算这一天没断。
      expect(
        streakDays([
          _at(2026, 10, 5, score: null, isTimed: true, repCount: 3),
          _at(2026, 10, 4, score: 0),
        ], _now),
        2,
      );
    });
  });

  group('换日', () {
    test('归到当天的零点', () {
      expect(localDayOf(DateTime(2026, 10, 5, 23, 59)), DateTime(2026, 10, 5));
      expect(localDayOf(DateTime(2026, 10, 5)), DateTime(2026, 10, 5));
    });

    test('前一天是日历运算，不是减 24 小时', () {
      // **`DateTime(y, m, d - 1)` 而不是 `subtract(Duration(days: 1))`。**
      // 后者减的是 24 小时，而在有夏令时的地区一年里有两天不是 24 小时 ——
      // 那两天会被算错，把「昨天」算成「前天」，连续天数断在半路上。
      expect(previousDay(DateTime(2026, 10, 5)), DateTime(2026, 10, 4));
      expect(previousDay(DateTime(2026, 3, 1)), DateTime(2026, 2, 28));
      expect(previousDay(DateTime(2026, 1, 1)), DateTime(2025, 12, 31));
      // 闰年二月。
      expect(previousDay(DateTime(2028, 3, 1)), DateTime(2028, 2, 29));
    });
  });

  group('按天分组', () {
    test('空表 → 没有分组', () {
      expect(groupByDay(const []), isEmpty);
    });

    test('天倒序，今天在最前', () {
      final groups = groupByDay([
        _at(2026, 10, 3),
        _at(2026, 10, 5),
        _at(2026, 10, 4),
      ]);

      expect(groups.map((g) => g.day).toList(), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 4),
        DateTime(2026, 10, 3),
      ]);
    });

    test('组内时间倒序', () {
      final groups = groupByDay([
        _at(2026, 10, 5, hour: 8),
        _at(2026, 10, 5, hour: 20),
        _at(2026, 10, 5, hour: 12),
      ]);

      expect(groups.length, 1);
      expect(groups.first.records.map((r) => r.finishedAt.hour).toList(),
          [20, 12, 8]);
    });

    test('同一天的全部归到一组，组的日期是零点', () {
      // 组的键是**日历日零点**，不是「这一天的第一条记录」。用后者的话，
      // 同一天的记录会因为时刻不同而分到不同的组里。
      final groups = groupByDay([
        _at(2026, 10, 5, hour: 23),
        _at(2026, 10, 5, hour: 0),
      ]);

      expect(groups.length, 1);
      expect(groups.first.day, DateTime(2026, 10, 5));
      expect(groups.first.records.length, 2);
    });

    test('跨零点的那两组分成两天', () {
      final groups = groupByDay([
        _record(finishedAt: DateTime(2026, 10, 5, 0, 10)),
        _record(finishedAt: DateTime(2026, 10, 4, 23, 50)),
      ]);

      expect(groups.map((g) => g.day).toList(), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 4),
      ]);
    });
  });

  group('热力图', () {
    // 2026-10-05 是**周一**（这一组里很多条都靠这个前提，写错日期会一起错）。
    // 对应的那张网跨 2026-04-13 ～ 2026-10-11，末列是 10/05..10/11。

    /// 一整张网里出现过的月份标签，按列的顺序。
    List<String> labels(HeatmapGrid grid) => [
          for (final week in grid.weeks) ?week.monthLabel,
        ];

    /// 网里所有格子的日子。
    List<DateTime> days(HeatmapGrid grid) => [
          for (final week in grid.weeks)
            for (final cell in week.days) cell.day,
        ];

    test('形状：26 列 × 7 天，每列从周一起', () {
      final grid = buildHeatmap(const [], _now);

      expect(grid.weeks.length, 26);
      expect(heatmapWeeks, 26, reason: '上头那条断言依赖这个默认值');
      for (final week in grid.weeks) {
        expect(week.days.length, 7);
        expect(
          week.days.first.day.weekday,
          DateTime.monday,
          reason: '中文日历的周首是周一，不是 GitHub 那张图的周日',
        );
      }
    });

    test('首列是 2026-04-13 —— 「半年」是 26 周，不是 6 个月', () {
      // 往前退 25 个整周（175 天），得到 4 月 13 日。用「减 6 个月」写的话
      // 这里是 4 月 5 日，而 4 月 5 日那一周会被切掉一半。
      expect(days(buildHeatmap(const [], _now)).first, DateTime(2026, 4, 13));
    });

    test('跨年也对：now = 2026-01-02 时首列落在 2025 年 7 月', () {
      final grid = buildHeatmap(const [], DateTime(2026, 1, 2, 14));
      expect(days(grid).first, DateTime(2025, 7, 7));
      expect(grid.weeks.last.days.last.day, DateTime(2026, 1, 4));
    });

    test('末列含今天：今天是周一 → 末列第一格就是今天', () {
      final grid = buildHeatmap(const [], _now);

      expect(grid.today, DateTime(2026, 10, 5));
      expect(grid.weeks.last.days.first.day, DateTime(2026, 10, 5));
      expect(
        grid.weeks.last.days.every((cell) => !cell.inWindow || cell.day == grid.today),
        isTrue,
        reason: '今天落在末列第一行时，整张网里只有它一格是「已过去」的',
      );
    });

    test('末列含今天：今天是周日 → 末列最后一格是今天，一个未来格都没有', () {
      final grid = buildHeatmap(const [], DateTime(2026, 10, 11, 14));

      expect(grid.weeks.last.days.last.day, DateTime(2026, 10, 11));
      expect(
        days(grid).every((day) => !day.isAfter(grid.today)),
        isTrue,
        reason: '整张网跨 182 天，周日时最后一格正好是今天',
      );
    });

    test('今天在周三 → 末列后面 4 格是未来，不是「没练」', () {
      // 这一点在界面上表现为「那几格画不画得出来」：画成最浅一档等于说
      // 用户周四到周日没练，而那几天还没到。
      final grid = buildHeatmap(const [], DateTime(2026, 10, 7, 14));

      final last = grid.weeks.last.days;
      expect(last[2].day, DateTime(2026, 10, 7));
      expect(last.take(3).every((cell) => cell.inWindow), isTrue);
      expect(last.skip(3).every((cell) => !cell.inWindow), isTrue);
      expect(last.length, 7, reason: '未来格要占位，否则末列会短一截');
    });

    test('同一天有几条记录就是几组', () {
      final grid = buildHeatmap([
        _at(2026, 10, 5, hour: 8),
        _at(2026, 10, 5, hour: 12),
        _at(2026, 10, 5, hour: 20),
      ], _now);

      expect(grid.dayOf(DateTime(2026, 10, 5))!.sets, 3);
      expect(grid.activeDays, 1, reason: 'activeDays 数的是天，不是组');
    });

    test('相邻两天互不串', () {
      final grid = buildHeatmap([
        _at(2026, 10, 5, hour: 23, score: 90),
        _at(2026, 10, 4, hour: 1, score: 60),
      ], _now);

      expect(grid.dayOf(DateTime(2026, 10, 5))!.sets, 1);
      expect(grid.dayOf(DateTime(2026, 10, 4))!.sets, 1);
      expect(grid.activeDays, 2);
    });

    test('没记录的日子是 0 组，不是一个没有格子', () {
      // 界面上这格的画法与「还没到的那天」完全不同（一个是浅色方块、
      // 一个是空白），所以这两种「0」在数据层就必须分开。
      final grid = buildHeatmap(const [], _now);
      final cell = grid.dayOf(DateTime(2026, 10, 5))!;

      expect(cell.sets, 0);
      expect(cell.inWindow, isTrue);
      expect(grid.activeDays, 0);
    });

    test('窗口外的老记录落在网外，不进 activeDays', () {
      // 26 周 ≈ 182 天。停在半年之前再回来的人，旧记录不该挤掉现在的格子。
      final grid = buildHeatmap([
        _at(2026, 4, 12), // 首列前一天
        _at(2025, 12, 1), // 远在窗口外
        _at(2026, 10, 5),
      ], _now);

      expect(grid.activeDays, 1);
      expect(grid.dayOf(DateTime(2026, 4, 12)), isNull);
      expect(days(grid).first, DateTime(2026, 4, 13));
    });

    test('未来的记录也丢 —— 它只可能来自改过系统时间的机器', () {
      final grid = buildHeatmap([
        _at(2026, 10, 6), // 明天
        _at(2027, 1, 1),
      ], _now);

      expect(grid.activeDays, 0);
      expect(grid.dayOf(DateTime(2026, 10, 6)), isNull);
    });

    test('首列必然有一个月份标签', () {
      // 不打的话，最早那一个月在界面上是一片没有名字的格子。
      expect(buildHeatmap(const [], _now).weeks.first.monthLabel, '4月');
    });

    test('同一个月里相邻的列不重复打标签', () {
      final grid = buildHeatmap(const [], _now);
      final all = labels(grid);

      expect(all, all.toSet().toList(), reason: '每个月份只该打一次');
      expect(all.first, '4月');
      expect(all.last, '10月');
    });

    test('跨月那一列拿到新标签', () {
      // 2026-11-01 是周日，末列跨 10/26..11/01。这一条钉的是一个**真写错过**
      // 的 bug：拿「这列的周一与上列的周一比月份」时，两列的周一都在 10 月，
      // 于是「11月」永远不会出现，而 11 月 1 日那格顶着「10月」。
      final grid = buildHeatmap(const [], DateTime(2026, 11, 1, 14));

      expect(grid.weeks.last.days.last.day, DateTime(2026, 11, 1));
      expect(grid.weeks.last.monthLabel, '11月');
      expect(labels(grid), contains('11月'));
    });

    test('还没到的月份不打标签', () {
      // 10 月 20 日时，末列仍然是 10/19..10/25，11 月还没来。
      final grid = buildHeatmap(const [], DateTime(2026, 10, 20, 14));
      expect(labels(grid), isNot(contains('11月')));
    });

    test('weeks 参数真的改变列数', () {
      expect(buildHeatmap(const [], _now, weeks: 1).weeks.length, 1);
      expect(buildHeatmap(const [], _now, weeks: 1).weeks.single.days.first.day,
          DateTime(2026, 10, 5));
    });
  });

  group('色阶档位', () {
    test('0 组是最浅一档，1..3 组各占一档', () {
      expect(heatLevel(0), 0);
      expect(heatLevel(1), 1);
      expect(heatLevel(2), 2);
      expect(heatLevel(3), 3);
    });

    test('4 组及以上封顶', () {
      // 再往上分档会密到分不出来，而「这天练得很足」这个意思已经传到了。
      expect(heatLevel(4), heatmapTopLevel);
      expect(heatLevel(9), heatmapTopLevel);
      expect(heatLevel(100), heatmapTopLevel);
    });

    test('负数当 0 —— 它只可能来自坏数据，不该越界取色', () {
      expect(heatLevel(-1), 0);
    });
  });

  group('星期文案', () {
    test('周一是「周一」，周日是「周日」', () {
      expect(historyWeekdayText(DateTime(2026, 10, 5)), '周一');
      expect(historyWeekdayText(DateTime(2026, 10, 11)), '周日');
      expect(historyWeekdayText(DateTime(2026, 10, 9)), '周五');
    });

    test('七天各不相同', () {
      final names = [
        for (var d = 5; d <= 11; d++)
          historyWeekdayText(DateTime(2026, 10, d)),
      ];
      expect(names.toSet().length, 7);
    });
  });

  group('动作名那一行', () {
    test('去重、保持出现顺序', () {
      // 顺序按记录给的顺序（清单已经是新的在前），不排序 —— 排了的话
      // 这里会变成「平板支撑、深蹲」，而用户最近练的那个不在最前面了。
      expect(
        actionNamesText([
          _at(2026, 10, 5, hour: 20),
          _at(2026, 10, 5, hour: 12, isTimed: true),
          _at(2026, 10, 5, hour: 8),
        ]),
        '深蹲、平板支撑',
      );
    });

    test('超过三个动作以「等」收尾', () {
      SessionRecord named(String name) => SessionRecord(
            actionCode: name,
            actionNameZh: name,
            finishedAt: DateTime(2026, 10, 5, 12),
            repCount: 5,
            isTimed: false,
            score: 80,
            provisional: false,
          );

      expect(
        actionNamesText([named('A'), named('B'), named('C'), named('D')]),
        'A、B、C等',
        reason: '第四个不显示，但要让用户知道后面还有',
      );
      expect(actionNamesText([named('A'), named('B'), named('C')]), 'A、B、C');
    });

    test('一个动作都没有时是空串', () {
      expect(actionNamesText(const []), '');
    });
  });

  group('信息行', () {
    test('没点过：说窗口概况', () {
      expect(
        heatmapOverviewText(buildHeatmap(const [], _now)),
        '近 26 周还没有练习记录 · 点一格看那天',
      );
      expect(
        heatmapOverviewText(buildHeatmap([
          _at(2026, 10, 5),
          _at(2026, 10, 4),
        ], _now)),
        '近 26 周练了 2 天 · 点一格看那天',
      );
    });

    test('点了有记录的一天：日期 + 星期 + 组数 + 动作名', () {
      final grid = buildHeatmap([_at(2026, 10, 5, hour: 8)], _now);
      expect(
        heatmapDayText(grid.dayOf(DateTime(2026, 10, 5))!, [_at(2026, 10, 5, hour: 8)], _now),
        '今天 周一 · 1 组 · 深蹲',
      );
    });

    test('点了空白的一天：说这天没有练习', () {
      final grid = buildHeatmap(const [], _now);
      expect(
        heatmapDayText(grid.dayOf(DateTime(2026, 10, 2))!, const [], _now),
        '10月2日 周五 · 这天没有练习',
      );
    });

    test('这一天没练但同一天别的日子有记录：不串', () {
      // 判据与 `buildHeatmap` 分桶用的必须是同一条，否则会出现「字说 1 组、
      // 格子却是最浅一档」这种没法解释的错位。
      final records = [_at(2026, 10, 5, hour: 8)];
      final grid = buildHeatmap(records, _now);

      expect(
        heatmapDayText(grid.dayOf(DateTime(2026, 10, 4))!, records, _now),
        '昨天 周日 · 这天没有练习',
      );
    });

    test('信息行里不出现量词「个」「段」', () {
      // `history_page_test.dart` 里有 `find.textContaining('12 个')` 与
      // `'4 段'` 的 findsOneWidget —— 同一句话在热力图里再说一次就会多命中一个，
      // 而那两条断言会红在一个与热力图毫无关系的改动上。
      final records = [
        _at(2026, 10, 5, hour: 8, repCount: 12),
        _at(2026, 10, 5, hour: 9, repCount: 4, isTimed: true),
      ];
      final grid = buildHeatmap(records, _now);

      final text = heatmapDayText(grid.dayOf(DateTime(2026, 10, 5))!, records, _now);
      expect(text, isNot(contains('个')));
      expect(text, isNot(contains('段')));
      expect(text, '今天 周一 · 2 组 · 深蹲、平板支撑');
    });

    test('不出现时刻 —— 清单里已经有「14:30」了', () {
      final records = [_at(2026, 10, 5, hour: 14)];
      final grid = buildHeatmap(records, _now);
      final text = heatmapDayText(grid.dayOf(DateTime(2026, 10, 5))!, records, _now);

      expect(text, isNot(matches(RegExp(r'\d\d:\d\d'))));
    });
  });
}
