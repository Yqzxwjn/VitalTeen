/// 打卡卡、成长页与「我的」页那张等级卡。
///
/// 这里验的是**界面上说不说得出来**：数字算得对不对在 `test/app/growth_test.dart`，
/// 那一边穷尽了边界；这一边只钉「算出来的东西有没有被显示、有没有显示错」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/growth.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/ui/growth_card.dart';
import 'package:vitalteen_app/ui/growth_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

SessionRecord _at(int day, {int? score, String code = 'SQUAT'}) =>
    SessionRecord(
      actionCode: code,
      actionNameZh: '深蹲',
      finishedAt: DateTime(2026, 10, day, 12),
      repCount: 12,
      isTimed: false,
      score: score,
      provisional: false,
    );

final DateTime _now = DateTime(2026, 10, 5, 14);

/// 挂一页。**传进来的就是一整页**（成长页自带 `Scaffold`），
/// 外面再包一层滚动视图会让它拿到无限高度。
Future<void> _show(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: buildVitalTeenTheme(), home: page),
  );
  await tester.pumpAndSettle();
}

/// 单独挂那张卡（它是首页上的一块，不是一页）。
Future<void> _showCard(WidgetTester tester, GrowthCard card) => _show(
  tester,
  Scaffold(
    body: SafeArea(
      child: Padding(padding: const EdgeInsets.all(20), child: card),
    ),
  ),
);

void main() {
  group('首页那张打卡卡', () {
    testWidgets('没练过：说「今天还没练」，等级还是第一级', (tester) async {
      await _showCard(tester, GrowthCard(records: const [], now: _now));

      expect(find.text('今天还没练'), findsOneWidget);
      expect(find.text('Lv.1 起步'), findsOneWidget);
      expect(find.textContaining('今日任务 0/3'), findsOneWidget);
    });

    testWidgets('今天练过：连胜与任务进度都跟着动', (tester) async {
      await _showCard(
        tester,
        GrowthCard(records: [_at(4), _at(5, score: 90)], now: _now),
      );

      expect(find.text('连续打卡 2 天'), findsOneWidget);
      expect(find.text('Lv.2 活力新星'), findsOneWidget);
      expect(find.textContaining('今日任务 2/3'), findsOneWidget);
    });

    testWidgets('三条都做完时说「全部完成」，不再催', (tester) async {
      await _showCard(
        tester,
        GrowthCard(
          records: [
            _at(5, score: 90),
            _at(5, score: 85, code: 'PLANK'),
          ],
          now: _now,
        ),
      );

      expect(find.textContaining('全部完成'), findsOneWidget);
    });
  });

  group('成长页', () {
    testWidgets('等级、连胜、今日任务、累计四块都在', (tester) async {
      await _show(
        tester,
        GrowthPage(
          records: [_at(1), _at(2), _at(3), _at(4), _at(5, score: 88)],
          now: _now,
          onBack: () {},
        ),
      );

      expect(find.text('我的成长'), findsOneWidget);
      expect(find.text('Lv.3 坚持之星'), findsOneWidget);
      expect(find.textContaining('已连续 5 天'), findsOneWidget);
      // 10 天是 Lv.4 的门槛，从 5 天算起还差 5 天
      expect(find.textContaining('再连练 5 天升到 Lv.4 训练达人'), findsOneWidget);

      expect(find.text('今日任务'), findsOneWidget);
      expect(find.text('今天练 1 组'), findsOneWidget);
      expect(find.text('今天练到 2 个不同动作'), findsOneWidget);
      expect(find.text('有一组拿到 80 分以上'), findsOneWidget);

      expect(find.text('累计'), findsOneWidget);
      expect(find.text('5 组'), findsOneWidget);
      expect(find.text('5 天'), findsWidgets);
      expect(
        find.text('58'),
        findsOneWidget,
        reason: '成长值 = 四组无分 10×4 + 一组 88 分的 18',
      );
    });

    testWidgets('打卡格子的个数就是窗口的天数', (tester) async {
      // 4 周窗口、今天是 10 月 5 日（周一）→ 22 格。
      await _show(
        tester,
        GrowthPage(records: const [], now: _now, onBack: () {}),
      );

      final days = checkInWindow(_now);
      expect(days, hasLength(22));
      // 每一格是一个 26×26 的圆角方块；练过的那几格多一个勾。
      // 这里只数「有勾的」—— 一条记录都没有时应当是 0 个。
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('练过的日子在格子上打勾', (tester) async {
      await _show(
        tester,
        GrowthPage(records: [_at(4), _at(5)], now: _now, onBack: () {}),
      );

      expect(find.byIcon(Icons.check), findsNWidgets(2));
    });

    testWidgets('成就：没拿到的显示「怎么拿到」，不是空着', (tester) async {
      await _show(
        tester,
        GrowthPage(records: const [], now: _now, onBack: () {}),
      );

      expect(find.text('成就'), findsOneWidget);
      expect(find.text('0/8'), findsOneWidget);
      expect(find.text('连续三天打卡'), findsOneWidget);
      expect(find.text('累计练到 50 组'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(8));
    });

    testWidgets('拿到一条就亮一个，标题换成名字', (tester) async {
      await _show(
        tester,
        GrowthPage(records: [_at(5)], now: _now, onBack: () {}),
      );

      expect(find.text('1/8'), findsOneWidget);
      expect(find.text('第一组'), findsOneWidget);
      expect(find.text('练完一组'), findsNothing, reason: '拿到了就不再说怎么拿');
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(7));
    });

    testWidgets('返回按钮接回调', (tester) async {
      var backs = 0;
      await _show(
        tester,
        GrowthPage(records: const [], now: _now, onBack: () => backs++),
      );

      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(backs, 1);
    });
  });
}
