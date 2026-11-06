/// [HeatmapCard] 的测试：颜色映射、初始视口、点选、以及「不会长胖」。
///
/// ## 为什么这个控件值得测这么细
///
/// 它有三处**错了也不报错**的地方：
///
/// 1. **色阶**。「1 组是什么颜色」写歪一档，界面一样跑，只是那半年看上去
///    密度不对 —— 而密度正是这张图唯一的信息。
/// 2. **初始视口**。`reverse: true` 的语义反直觉（见 `heatmap_card.dart` 文件头），
///    写错的表现是「一打开看到的是半年前」—— 不崩、不报错、也不空，只是没用了。
/// 3. **固定高度下的文字**。`SizedBox` 把 `Text` 压住**不抛异常**，
///    大字号下后一行会被静默裁掉。
///
/// 挂载方式与页面无关：直接给 `HeatmapCard` 一个 `now`，不经过 `HistoryPage`
/// （它刻意没有 now 注入口，页面的集成由 `history_page_test.dart` 那条
/// `find.byType(HeatmapCard)` 兜着）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/history.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/ui/heatmap_card.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 「现在」：2026 年 10 月 5 日（**周一**）下午两点。
final DateTime _now = DateTime(2026, 10, 5, 14);

/// 目标机器：1080×2400 @ 440dpi → 392.7 × 872.7 逻辑像素。
///
/// 卡片宽度 = `min(页面的 maxWidth 460, 屏宽 − 40)` = 352.7 —— 与历史页上
/// 真实的那一块逐像素相同。用别的宽度测，测的是另一台机器上的版式。
const Size _window = Size(1080, 2400);
const double _dpr = 2.75;
const double _screenWidth = 1080 / _dpr; // 392.7
const double _cardWidth = 392.727 - 40; // 352.7

/// 屏幕高度的四分之一，用户给的尺寸要求就这一个数。
final double _quarterScreen = 2400 / _dpr / 4;

SessionRecord _at(int month, int day, {int hour = 12, bool isTimed = false}) =>
    SessionRecord(
      actionCode: isTimed ? 'PLANK' : 'SQUAT',
      actionNameZh: isTimed ? '平板支撑' : '深蹲',
      finishedAt: DateTime(2026, month, day, hour),
      repCount: isTimed ? 4 : 12,
      isTimed: isTimed,
      score: 88,
      provisional: false,
    );

/// 一份有分档梯度的记录：四天各 1/2/3/9 组，另有一天 4 组。
///
/// 9 组是为了钉住「封顶」——它与 4 组必须是同一个颜色。
/// 9 月 30 日（周三）刻意留空，用来点「这天没有练习」。
List<SessionRecord> _fixture() => [
      for (var i = 0; i < 9; i++) _at(10, 1, hour: 8 + i),
      for (var i = 0; i < 4; i++) _at(10, 2, hour: 8 + i),
      for (var i = 0; i < 3; i++) _at(10, 3, hour: 8 + i, isTimed: i == 2),
      _at(10, 4, hour: 9),
      // 今天：深蹲两次 + 平板支撑一次 → 「今天 周一 · 3 组 · 深蹲、平板支撑」
      _at(10, 5, hour: 8),
      _at(10, 5, hour: 9),
      _at(10, 5, hour: 10, isTimed: true),
    ];

Future<void> _mount(
  WidgetTester tester, {
  List<SessionRecord>? records,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: Scaffold(
      // **用 `copyWith` 而不是新造一个 `MediaQueryData`**：后者会把 size
      // 与 padding 归零，而那是另一件事。
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: Center(
            child: SizedBox(
              width: _cardWidth,
              child: HeatmapCard(
                records: records ?? _fixture(),
                now: _now,
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

/// 信息行那句话本身。**读 key，不用 `textContaining`** ——
/// 这些话里的日期会与页面上的日期标题同时命中。
String _info(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(HeatmapCard.infoKey)).data!;

/// 某一天那一格的**色块**颜色（不含选中环）。
Color _chipColor(WidgetTester tester, DateTime day) {
  final chip = tester.widget<Container>(find.descendant(
    of: find.byKey(HeatmapCard.dayKey(day)),
    matching: find.byType(Container),
  ));
  return (chip.decoration! as BoxDecoration).color!;
}

/// 某一天那一格的外层 `decoration`（选中环画在它上面）。
Decoration? _cellDecoration(WidgetTester tester, DateTime day) =>
    tester.widget<Container>(find.byKey(HeatmapCard.dayKey(day))).decoration;

/// 点某一天，并等一帧。
Future<void> _tap(WidgetTester tester, DateTime day) async {
  await tester.tap(find.byKey(HeatmapCard.dayKey(day)));
  await tester.pump();
}

void main() {
  testWidgets('色阶按组数分档，4 组及以上封顶', (tester) async {
    await _mount(tester);

    // 每个档位都取到一个真实的日子，逐档对着色表核。
    expect(_chipColor(tester, DateTime(2026, 10, 1)), vitalHeatRamp[4], reason: '9 组');
    expect(_chipColor(tester, DateTime(2026, 10, 2)), vitalHeatRamp[4], reason: '4 组');
    expect(_chipColor(tester, DateTime(2026, 10, 3)), vitalHeatRamp[3], reason: '3 组');
    expect(_chipColor(tester, DateTime(2026, 10, 4)), vitalHeatRamp[1], reason: '1 组');
    expect(_chipColor(tester, DateTime(2026, 10, 5)), vitalHeatRamp[3], reason: '3 组');
    // 9 组与 4 组同色：这是刻意的（再往上分档会密到分不出来）。
    expect(
      _chipColor(tester, DateTime(2026, 10, 1)),
      _chipColor(tester, DateTime(2026, 10, 2)),
    );
  });

  testWidgets('没练的一天是最浅一档，不是与卡片同色', (tester) async {
    await _mount(tester);

    // 画成与卡片一样的白，那格看起来就是个「洞」，而不是「这天没练」。
    expect(_chipColor(tester, DateTime(2026, 9, 30)), vitalHeatRamp[0]);
    expect(vitalHeatRamp[0], isNot(vitalCard));
  });

  testWidgets('色表长度与档位数是同一条不变式', (tester) async {
    // `app/history.dart` 不认识 `ui/`（热力图的算法在 app 层，颜色在 ui 层），
    // 所以这条跨层的一致性没有别的地方能钉住 —— `heatLevel` 的返回值直接
    // 拿去下标取色，多一档少一档都会越界或取错。
    expect(vitalHeatRamp.length, heatmapTopLevel + 1);
    expect(heatLevel(heatmapTopLevel), vitalHeatRamp.length - 1);
  });

  testWidgets('一打开停在最近的日子，往左滑才看得见更早的', (tester) async {
    await _mount(tester);

    final viewport = tester.getRect(find.byKey(HeatmapCard.scrollKey));
    final position = tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(HeatmapCard.scrollKey),
          matching: find.byType(Scrollable),
        ))
        .position;

    // `reverse: true` 在横向单子滚动视图里的语义：偏移 0 对齐**内容的最右端**。
    expect(position.axisDirection, AxisDirection.left);
    expect(position.pixels, 0, reason: '初始偏移就是 0，没有 post-frame jumpTo');
    expect(position.maxScrollExtent, greaterThan(0), reason: '26 周比视口宽');

    // 今天那一格在视口里……
    final today = tester.getRect(find.byKey(HeatmapCard.dayKey(DateTime(2026, 10, 5))));
    expect(
      viewport.contains(today.center),
      isTrue,
      reason: '一打开就该看见今天 —— 这一条钉的正是 `reverse` 那条推理，'
          '写反了这里会是「半年前的那几周」',
    );
    // ……而最早那一列不在（它在视口左边外面）。
    final oldest = tester.getRect(find.byKey(HeatmapCard.dayKey(DateTime(2026, 4, 13))));
    expect(oldest.right, lessThanOrEqualTo(viewport.left));

    // 往右拖 = 看更早的（偏移增大）。方向反了这一步会原地不动。
    await tester.drag(find.byKey(HeatmapCard.scrollKey), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(
      tester
          .state<ScrollableState>(find.descendant(
            of: find.byKey(HeatmapCard.scrollKey),
            matching: find.byType(Scrollable),
          ))
          .position
          .pixels,
      greaterThan(0),
    );
    expect(
      tester.getRect(find.byKey(HeatmapCard.dayKey(DateTime(2026, 4, 13)))).right,
      greaterThan(viewport.left),
      reason: '滑到底之后最早那一周应该进来了',
    );
  });

  testWidgets('默认那行字说窗口概况，一个动作名都不出现', (tester) async {
    await _mount(tester);

    // **这条不是文风问题**：`history_page_test.dart` 在同一个页面上断言
    // `find.text('深蹲')` 是 `findsOneWidget`（那条走的是清单），
    // 热力图默认态再多说一次动作名就会多命中一个。
    expect(_info(tester), '近 26 周练了 5 天 · 点一格看那天');
    expect(find.text('深蹲'), findsNothing);
    expect(find.text('平板支撑'), findsNothing);
  });

  testWidgets('点有记录的一格：下面那行字跟着变', (tester) async {
    await _mount(tester);

    await _tap(tester, DateTime(2026, 10, 5));
    expect(_info(tester), '今天 周一 · 3 组 · 深蹲、平板支撑');

    await _tap(tester, DateTime(2026, 10, 3));
    expect(_info(tester), '10月3日 周六 · 3 组 · 深蹲、平板支撑');

    await _tap(tester, DateTime(2026, 10, 2));
    expect(_info(tester), '10月2日 周五 · 4 组 · 深蹲');

    await _tap(tester, DateTime(2026, 10, 4));
    expect(_info(tester), '昨天 周日 · 1 组 · 深蹲');
  });

  testWidgets('点空白的一天：说这天没有练习，不弹任何东西', (tester) async {
    await _mount(tester);

    await _tap(tester, DateTime(2026, 9, 30));
    expect(_info(tester), '9月30日 周三 · 这天没有练习');

    // 没有对话框、没有 SnackBar —— 这一页是只读的（见 `history_page.dart` 文件头）。
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('再点同一格退回概况', (tester) async {
    await _mount(tester);

    await _tap(tester, DateTime(2026, 10, 5));
    expect(_info(tester), startsWith('今天'));

    // 没有这一步的话，点过一次之后没有任何路回到默认那行字。
    await _tap(tester, DateTime(2026, 10, 5));
    expect(_info(tester), startsWith('近 26 周'));
  });

  testWidgets('选中的那格多一圈描边，色块自己的颜色不变', (tester) async {
    await _mount(tester);

    expect(_cellDecoration(tester, DateTime(2026, 10, 3)), isNull);

    final before = _chipColor(tester, DateTime(2026, 10, 3));
    await _tap(tester, DateTime(2026, 10, 3));

    // 环画在**命中盒**上、填色仍然只在色块的 decoration 里 —— 于是
    // 「选中的是哪个颜色」这件事照样能被上面那种断言读出来。
    final ring = _cellDecoration(tester, DateTime(2026, 10, 3))! as BoxDecoration;
    expect((ring.border! as Border).top.width, greaterThan(0));
    expect(_chipColor(tester, DateTime(2026, 10, 3)), before);

    // 再选一格，环跟着走而不是留在原地。
    await _tap(tester, DateTime(2026, 10, 2));
    expect(_cellDecoration(tester, DateTime(2026, 10, 3)), isNull);
    expect(_cellDecoration(tester, DateTime(2026, 10, 2)), isNotNull);
  });

  testWidgets('还没到的那几天没有格子 —— findsNothing 在这里是有意义的', (tester) async {
    // now 是周一，所以末列里周二到周日那六格没到。它们不是「没练」：
    // 画成浅色格子等于说用户那几天没练。
    await _mount(tester);

    expect(find.byKey(HeatmapCard.dayKey(DateTime(2026, 10, 5))), findsOneWidget);
    for (var d = 6; d <= 11; d++) {
      expect(
        find.byKey(HeatmapCard.dayKey(DateTime(2026, 10, d))),
        findsNothing,
        reason: '10 月 $d 日还没到',
      );
    }
    // 整张网跨 182 天，一格不多一格不少。
    expect(
      find.byWidgetPredicate((widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('heatmap-day-')),
      findsNWidgets(26 * 7 - 6),
    );
  });

  testWidgets('横向滚动区不越界：26 周确实比视口宽', (tester) async {
    await _mount(tester);

    final viewport = tester.getRect(find.byKey(HeatmapCard.scrollKey));
    expect(viewport.width, closeTo(_cardWidth - 32 - 16, 0.01),
        reason: '卡内左右各 16 的内边距，再减掉左边那栏星期');
    // 一天一小格 14 + 缝 3，26 周 + 那段给月份标签的余量。
    expect(viewport.width, lessThan(heatmapWeeks * 17.0),
        reason: '内容窄于视口的话这张图就不用滑了 —— 那时它是右对齐的');
  });

  testWidgets('图例把五个档位都画出来，顺序与色表一致', (tester) async {
    await _mount(tester);

    for (var level = 0; level <= heatmapTopLevel; level++) {
      final chip = tester.widget<Container>(find.byKey(HeatmapCard.legendKey(level)));
      expect(
        (chip.decoration! as BoxDecoration).color,
        vitalHeatRamp[level],
        reason: '第 $level 档',
      );
    }
    // 色表若是变长，图例要跟着长 —— 少画一档没人看得出来。
    expect(heatmapTopLevel, vitalHeatRamp.length - 1);
    expect(find.text('较少'), findsOneWidget);
    expect(find.text('较多'), findsOneWidget);
  });

  testWidgets('高度在屏幕的四分之一上下', (tester) async {
    await _mount(tester);

    final height = tester.getSize(find.byType(HeatmapCard)).height;

    // 用户要的是「不要占满一个屏幕，大概 1/4 屏幕即可」。872.7 的四分之一
    // 是 218；这里留到 240 是给不同字体度量留的余量。
    // **超过就说明有什么东西长胖了** —— 多加一行、多一段间距都会顶破它。
    expect(height, lessThan(240), reason: '实际 $height，目标 ≤ ${_quarterScreen * 1.1}');
    expect(height / (_screenWidth / 392.727 * 872.727), lessThan(0.28));
    expect(find.byType(HeatmapCard), findsOneWidget);
  });

  testWidgets('大字号下信息行跟着长，不裁字也不溢出', (tester) async {
    // 系统字号 1.3 倍时两行 bodySmall 装不进一个写死的 34 像素高的框，
    // 而 `SizedBox` 压住 `Text` **不抛异常** —— 后一行会被静默裁掉，
    // 冒烟测试看不出来。所以这里量的是「信息行确实变高了」。
    await _mount(tester, textScale: 1.0);
    final normal = tester.getSize(find.byType(HeatmapCard)).height;

    await _mount(tester, textScale: 1.3);
    final large = tester.getSize(find.byType(HeatmapCard)).height;

    expect(tester.takeException(), isNull);
    expect(large, greaterThan(normal), reason: '信息行的固定高度要跟着字号缩放');

    // 而长句子在这个高度里放得下：取一个最长的那句。
    await _tap(tester, DateTime(2026, 10, 5));
    final info = tester.getRect(find.byKey(HeatmapCard.infoKey));
    final card = tester.getRect(find.byType(HeatmapCard));
    expect(info.bottom, lessThanOrEqualTo(card.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('一整天都没记录：不崩，说「还没有练习记录」', (tester) async {
    await _mount(tester, records: const []);

    expect(_info(tester), '近 26 周还没有练习记录 · 点一格看那天');
    expect(tester.takeException(), isNull);

    // 一片最浅的格子里仍然每一格都点得动。
    await _tap(tester, DateTime(2026, 10, 5));
    expect(_info(tester), '今天 周一 · 这天没有练习');
  });

  testWidgets('记录全在窗口外：不说「练了 0 天」', (tester) async {
    // 停了半年再回来的人会看到这一屏。说「练了 0 天」像是一句指控，
    // 而事实是这半年什么都没记。
    await _mount(tester, records: [_at(1, 5), _at(2, 5)]);
    expect(_info(tester), '近 26 周还没有练习记录 · 点一格看那天');
  });
}
