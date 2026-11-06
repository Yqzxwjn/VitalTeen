/// 历史页的测试。
///
/// **这一页测的是三种「没有」不能被混成一种**，那是它最容易做错的地方：
///
/// - 一条记录都没有 → 整页是空状态，**不是一张写着 0/0/0 的汇总卡**；
/// - 有记录但没有一条打上分 → 平均分是 `—`，不是 0（0 是一次真实的低分）；
/// - 连续天数在「今天没练、昨天也没练」时**真的是 0**，那个 0 是实话。
///
/// 它们在数据上都是「空」，在屏幕上必须长得不一样。三处任何一处退回成
/// 「一律显示 0」，用户就会把「相机没看见我」读成「我练砸了」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/ui/heatmap_card.dart';
import 'package:vitalteen_app/ui/history_page.dart';
import 'package:vitalteen_app/ui/illustration_slot.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 今天 [hour] 点的一刻。
DateTime _today(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

DateTime _daysAgo(int days, {int hour = 10}) {
  final now = DateTime.now();
  // 日历运算，与 `history.dart` 的 `previousDay` 同一个理由：减 24 小时
  // 在有夏令时的地方会把「三天前」算成「两天前的 23 点」。
  return DateTime(now.year, now.month, now.day - days, hour);
}

SessionRecord _record({
  String actionCode = 'SQUAT',
  String actionNameZh = '深蹲',
  required DateTime finishedAt,
  int repCount = 12,
  bool isTimed = false,
  int? score = 85,
  bool provisional = false,
}) {
  return SessionRecord(
    actionCode: actionCode,
    actionNameZh: actionNameZh,
    finishedAt: finishedAt,
    repCount: repCount,
    isTimed: isTimed,
    score: score,
    provisional: provisional,
  );
}

Future<void> _mount(WidgetTester tester, List<SessionRecord> records) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: HistoryPage(records: records),
  ));
}

/// 汇总卡上某一项的数字。
///
/// **不能直接 `find.text('3')`** —— 清单里那些次数与分数也是裸数字，
/// 撞上就变成 `findsNWidgets(2)`，而那条断言会红在一个完全无关的改动上。
/// 所以按「标签所在那一列里的第一个 Text」取：版面怎么改都还认得出来。
String _statValue(WidgetTester tester, String label) {
  final column = find
      .ancestor(of: find.text(label), matching: find.byType(Column))
      .first;
  final texts = tester.widgetList<Text>(
    find.descendant(of: column, matching: find.byType(Text)),
  );
  return texts.first.data!;
}

void main() {
  group('一条记录都没有', () {
    testWidgets('给的是空状态，不是一张 0/0/0 的汇总卡', (tester) async {
      await _mount(tester, const []);

      expect(find.text('还没有练习记录'), findsOneWidget);
      // **这一条比上面那句要紧。** 空表照样能算出一个「0 组、0 分、0 天」的
      // 汇总，而摆出来就是拿三个 0 冒充真数据 —— 那三个 0 里没有一个是
      // 用户练出来的，看起来却像一份成绩单。
      expect(find.text('练习次数'), findsNothing);
      expect(find.text('平均姿势分'), findsNothing);
      expect(find.text('连续天数'), findsNothing);
      expect(find.byType(Card), findsNothing);
      // 热力图也一样：一张一个格子都没亮过的图摆在「还没有练习记录」上面，
      // 说的是一件比空更没有信息量的事。
      expect(find.byType(HeatmapCard), findsNothing);

      // 空状态那张插图读的是它自己的文件名。**断路径而不是断画出来的东西**：
      // 图还没有，兜底现在看得见，而用户把 `empty_history.webp` 丢进
      // `assets/images/` 之后这里就该换成图 —— 那是交付承诺
      //（`docs/brand-assets.md`），测试不该拦着它。
      expect(
        tester.widget<IllustrationSlot>(find.byType(IllustrationSlot)).path,
        'assets/images/empty_history.webp',
      );
    });

    testWidgets('空状态说的是「之后会有什么」，不是「暂无数据」', (tester) async {
      // 一个刚装上的应用必然走到这一屏，而**那是所有用户看到的第一屏历史**。
      // 「暂无数据」读起来像是坏了或者这一版还没做。
      await _mount(tester, const []);
      expect(find.textContaining('练完一组之后'), findsOneWidget);
    });
  });

  group('汇总卡', () {
    testWidgets('三个数分别对得上', (tester) async {
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), score: 88),
        _record(finishedAt: _today(9), score: 92),
        _record(finishedAt: _daysAgo(1), score: 66),
      ]);

      expect(_statValue(tester, '练习次数'), '3');
      // (88 + 92 + 66) / 3 = 82
      expect(_statValue(tester, '平均姿势分'), '82');
      // 今天有、昨天有 → 2 天。
      expect(_statValue(tester, '连续天数'), '2');
    });

    testWidgets('一条有分的都没有时，平均分是「—」不是 0', (tester) async {
      // 「这一组一个 rep 都没数到」是**没有分**，不是 0 分。
      // 把前者显示成 0，用户会以为自己练砸了，其实是相机没看见他。
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), score: null),
        _record(finishedAt: _today(9), score: null),
      ]);

      expect(_statValue(tester, '平均姿势分'), '—');
      expect(_statValue(tester, '练习次数'), '2');
    });

    testWidgets('没有分数的记录既不算 0 也不占分母', (tester) async {
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), score: 80),
        _record(finishedAt: _today(13), score: null),
        _record(finishedAt: _today(12), score: 90),
      ]);

      // 若把那条 null 当 0 算，这里会是 56 —— 用户会因为一次没数到的练习
      // 看到平均分掉一大截。
      expect(_statValue(tester, '平均姿势分'), '85');
    });

    testWidgets('今天没练、昨天也没练：连续天数是 0，不是「—」', (tester) async {
      // 三种「没有」里只有这一个是真的 0，所以它必须显示 0。
      // 用 `—` 顶掉它，等于把这个页面搞得处处都是「没有」，
      // 而这个 0 恰恰是唯一一句实话。
      await _mount(tester, [_record(finishedAt: _daysAgo(5), score: 80)]);

      expect(_statValue(tester, '连续天数'), '0');
      expect(_statValue(tester, '练习次数'), '1');
    });
  });

  group('热力图', () {
    testWidgets('夹在汇总卡与清单之间', (tester) async {
      // 位置是这一页的语义：汇总卡给的是三个数（结论），热力图给的是形状，
      // 清单给的是逐条明细。顺序反过来的话，「这半年勤不勤」这件事要先
      // 翻过一整份记录才看得见。
      await _mount(tester, [
        _record(finishedAt: _today(10)),
        _record(finishedAt: _daysAgo(1)),
      ]);

      expect(find.byType(HeatmapCard), findsOneWidget);

      final summaryBottom = tester
          .getRect(find.ancestor(
            of: find.text('练习次数'),
            matching: find.byType(Card),
          ))
          .bottom;
      final heatmap = tester.getRect(find.byType(HeatmapCard));
      final firstDay = tester.getTopLeft(find.text('今天')).dy;

      expect(heatmap.top, greaterThanOrEqualTo(summaryBottom));
      expect(heatmap.bottom, lessThanOrEqualTo(firstDay));
    });

    testWidgets('默认那一行字里的日期不与清单的标题撞车', (tester) async {
      // 热力图默认说的是「近 26 周练了 N 天」，不点任何一格就不出现日期，
      // 也不出现动作名 —— 否则整份测试文件里那些 `find.text('深蹲')`
      // 与 `find.text('今天')` 的 `findsOneWidget` 会一起变成两个。
      await _mount(tester, [_record(finishedAt: _today(10))]);

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('深蹲'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(HeatmapCard.infoKey)).data,
        startsWith('近 26 周'),
      );
    });
  });

  group('按天分组', () {
    testWidgets('标题是本地日期：今天 / 昨天 / 更早写成几月几日', (tester) async {
      final older = _daysAgo(5);
      await _mount(tester, [
        _record(finishedAt: _today(14, 30)),
        _record(finishedAt: _daysAgo(1)),
        _record(finishedAt: older),
      ]);

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('${older.month}月${older.day}日'), findsOneWidget);
    });

    testWidgets('天倒序：今天在昨天上面', (tester) async {
      await _mount(tester, [
        // 传进去的顺序故意是乱的：排序是 `groupByDay` 的活，
        // 而这一条测的正是它，不是「调用方排好了」。
        _record(finishedAt: _daysAgo(1)),
        _record(finishedAt: _today(14, 30)),
      ]);

      expect(
        tester.getTopLeft(find.text('今天')).dy,
        lessThan(tester.getTopLeft(find.text('昨天')).dy),
      );
    });

    testWidgets('同一天里的记录按时间倒序', (tester) async {
      await _mount(tester, [
        _record(finishedAt: _today(9), actionNameZh: '早上那次'),
        _record(finishedAt: _today(20), actionNameZh: '晚上那次'),
      ]);

      expect(
        tester.getTopLeft(find.text('晚上那次')).dy,
        lessThan(tester.getTopLeft(find.text('早上那次')).dy),
      );
    });
  });

  group('清单里的每一条', () {
    testWidgets('量词跟着动作走：数个还是数段', (tester) async {
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), repCount: 12),
        _record(
          finishedAt: _today(14, 0),
          actionCode: 'PLANK',
          actionNameZh: '平板支撑',
          repCount: 4,
          isTimed: true,
        ),
      ]);

      expect(find.textContaining('12 个'), findsOneWidget);
      expect(find.textContaining('4 段'), findsOneWidget);
    });

    testWidgets('时间写成 24 小时制的 HH:mm', (tester) async {
      await _mount(tester, [_record(finishedAt: _today(14, 30))]);
      expect(find.textContaining('14:30'), findsOneWidget);
    });

    testWidgets('没有分数的记录显示「—」', (tester) async {
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), score: 85),
        _record(finishedAt: _today(9), score: null),
      ]);

      // 一条有分一条没有：平均分是有分那条的值，「—」只出现一次。
      expect(find.text('—'), findsOneWidget);
      expect(_statValue(tester, '平均姿势分'), '85');
    });

    testWidgets('暂定的分数挂一个「暂定」', (tester) async {
      // 一个光秃秃的「72」看起来像正式结论，而它可能只是照着还没核定的
      // 阈值算出来的 —— 与练习页上那个角标是同一件事。
      await _mount(tester, [
        _record(finishedAt: _today(14, 30), score: 72, provisional: true),
        // 第二条只是为了让**平均分不等于 72** —— 否则汇总卡上那个 72 会与
        // 清单里这个 72 撞成 `findsNWidgets(2)`，而那条断言红起来像是
        // 「暂定角标没画」，其实是两处数字重了。
        _record(finishedAt: _today(9), score: 61),
      ]);

      expect(find.text('72'), findsOneWidget);
      expect(find.text('暂定'), findsOneWidget);
    });

    testWidgets('动作名用的是记录里存的那一个，不是现在查表查出来的', (tester) async {
      // 动作改过名或下架之后，旧记录仍然该说自己练的是什么 ——
      // 这正是 `actionNameZh` 冗余存一份的全部理由。
      await _mount(tester, [
        _record(
          finishedAt: _today(14, 30),
          actionCode: 'GONE',
          actionNameZh: '某个已经下架的动作',
        ),
      ]);

      expect(find.text('某个已经下架的动作'), findsOneWidget);
    });
  });
}
