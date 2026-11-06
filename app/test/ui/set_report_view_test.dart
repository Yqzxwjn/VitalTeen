/// 全屏报告体的测试。
///
/// ## 为什么它值得单独测
///
/// 这一块是从 `squat_page.dart` 里搬出来的，而**`SquatPage` 自带相机，
/// 本仓库从来没在主机测试里挂过它** —— 也就是说搬动之前，下面这些断言
/// 一条都写不出来。搬出来之后它们才第一次可测，所以这份测试同时也是
/// 「搬的时候有没有掉东西」的验收。
///
/// 盯住的是三件容易在搬动中丢掉的事：
///
/// 1. **可滚动的父级。** `AnalysisPanel` 自己不带滚动（见它的类注释），
///    漏掉外面那层不会编译报错，只会在展开时表现为一条 overflow 条纹。
/// 2. **两个按钮。** 它们原来长在相机面板的 `_actions` 里，相机体一换就没了 ——
///    而那是做完一组之后仅有的两个去处。
/// 3. **`AnalysisPanel` 还在。** 报告的一半价值在它里面（原始数据、
///    服务设置、重试），漏掉它整页照样画得出来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/analysis.dart';
import 'package:vitalteen_app/app/decision_submission.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/rules.dart' show FaultStat, SetSummary;
import 'package:vitalteen_app/ui/analysis_panel.dart';
import 'package:vitalteen_app/ui/set_report_view.dart';
import 'package:vitalteen_app/ui/theme.dart';

FormScore _score(int score) => FormScore(
      score: score,
      rating: FormRating.good,
      provisional: false,
      penalty: (100 - score) / 100,
      terms: const [],
    );

FaultStat _stat({
  String code = 'knee_valgus',
  String nameZh = '膝内扣',
  bool scorable = true,
  int count = 3,
  double rate = 0.3,
}) =>
    FaultStat(
      code: code,
      nameZh: nameZh,
      scorable: scorable,
      count: count,
      rate: rate,
      repIndices: const [1, 4, 7],
      worstDelta: 12,
    );

SessionView _view({
  int repCount = 12,
  List<int> repDurationsMs = const [],
  List<FaultStat> faults = const [],
  FormScore? setScore,
  bool interrupted = false,
  SetSummary? summary,
}) =>
    SessionView(
      phase: SessionPhase.finished,
      position: const PositionReport.empty(),
      calibrationFrames: 15,
      calibrationTarget: 15,
      repCount: repCount,
      discardedReps: 0,
      machineState: 'finished',
      kneeAngle: null,
      holdMs: 0,
      repDurationsMs: repDurationsMs,
      lastRep: null,
      lastRepScore: null,
      summary: summary ?? SetSummary(repCount: repCount, faultStats: faults),
      setScore: setScore,
      interrupted: interrupted,
      sawFrame: true,
    );

/// 挂上去。[onAnotherSet] / [onRecalibrate] 各记一笔，用来验两个按钮接对了没有。
Future<(List<String>, List<String>)> _mount(
  WidgetTester tester, {
  SessionView? view,
  bool isTimed = false,
}) async {
  final another = <String>[];
  final recalibrate = <String>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildCameraTheme(),
    home: Scaffold(
      body: SetReportView(
        view: view ?? _view(),
        requestBuilder: (sex, age, grade, group) => null,
        analyze: (request, endpoint) async => const AnalysisFailed(
          DecisionFailure(kind: DecisionFailureKind.unreachable),
        ),
        onAnotherSet: () => another.add('再来一组'),
        onRecalibrate: () => recalibrate.add('重新标定'),
        isTimed: isTimed,
      ),
    ),
  ));
  return (another, recalibrate);
}

void main() {
  testWidgets('计数、组级分数与错误统计都摆上来', (tester) async {
    await _mount(
      tester,
      view: _view(
        repCount: 12,
        setScore: _score(86),
        faults: [_stat()],
      ),
    );

    expect(find.text('这一组：12 个'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('膝内扣'), findsOneWidget);
    // 「3 次 · 30%」两个数各有各的用处：次数说这一组里犯了几次，
    // 占比说它在整组里有多普遍。只给一个都读不出严重程度。
    expect(find.text('3 次 · 30%'), findsOneWidget);
  });

  testWidgets('计时制动作说「段」，并把每段撑了多久摆上来', (tester) async {
    // 平板支撑（`ActionSpec.isTimed`）。报告里那句「这一组：3 个」在这个动作上
    // 读起来是「撑了 3 次」—— 而「撑了多久」一个数都没有，
    // 偏偏那是这个动作唯一会被记住的成绩。
    await _mount(
      tester,
      isTimed: true,
      view: _view(
        repCount: 3,
        repDurationsMs: const [41000, 30200, 21300],
        faults: const [],
      ),
    );

    expect(find.text('这一组：3 段'), findsOneWidget);
    expect(find.text('合计 92.5 秒（每段 41.0 / 30.2 / 21.3 秒）'), findsOneWidget);
  });

  testWidgets('非计时制动作不出现时长那一行 —— 那是另一个动作的量', (tester) async {
    // `repDurationsMs` 在别的动作里恒为空（见 `SessionView.repDurationsMs`），
    // 所以这一条同时也是「它没被顺手填上」的哨兵。
    await _mount(tester, view: _view(repCount: 12));

    expect(find.textContaining('合计'), findsNothing);
  });

  testWidgets('没有问题时也说得出口，而不是留一片白', (tester) async {
    // 一片空白会被读成「报告没出来」。
    await _mount(tester, view: _view(faults: const []));

    expect(find.text('没有发现需要留意的地方。'), findsOneWidget);
  });

  testWidgets('中途离开过就要说，否则计数看起来就是错的', (tester) async {
    await _mount(tester, view: _view(interrupted: true));

    expect(find.textContaining('中途离开过画面'), findsOneWidget);
  });

  testWidgets('没中断就不提这件事', (tester) async {
    // 反过来的那一半：恒说的话，上面那条测试照样绿，
    // 而每一次正常的报告上都会挂一句吓人的话。
    await _mount(tester, view: _view(interrupted: false));

    expect(find.textContaining('中途离开过画面'), findsNothing);
  });

  testWidgets('未核定的错误项挂「待核定」，而不是混进可扣分的那些里', (tester) async {
    await _mount(
      tester,
      view: _view(faults: [_stat(scorable: false, nameZh: '落地缓冲不足')]),
    );

    expect(find.text('落地缓冲不足'), findsOneWidget);
    expect(find.text('待核定'), findsOneWidget);
  });

  testWidgets('两个按钮都在，而且各自接对了', (tester) async {
    // 它们原来在相机面板的 `_actions` 里，相机体一换就消失了 ——
    // 而做完一组之后仅有的两个去处就是它们。
    final (another, recalibrate) = await _mount(tester);

    await tester.tap(find.text('再来一组'));
    await tester.pump();
    await tester.tap(find.text('重新标定'));
    await tester.pump();

    expect(another, ['再来一组']);
    expect(recalibrate, ['重新标定']);
  });

  testWidgets('分析面板在，且外面有一个能滚的父级', (tester) async {
    // `AnalysisPanel` 自己不带滚动：**漏掉外面那层不会编译报错**，
    // 只会在展开时表现为一条 overflow 条纹。
    await _mount(tester);

    expect(find.byType(AnalysisPanel), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(AnalysisPanel),
        matching: find.byType(SingleChildScrollView),
      ),
      findsWidgets,
    );
  });

  testWidgets('分析面板默认是折起来的', (tester) async {
    // 做完一组的人第一眼看的是结果，不是表单。展开是 `initiallyExpanded`
    // 一行的事，但默认值不该改 —— 扑面而来的表单会把结果挤到屏幕外。
    await _mount(tester);

    expect(find.text('分析这一组'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '年龄'), findsNothing);
  });

  testWidgets('报告比一屏长的时候不 overflow —— 内容全都滚得动', (tester) async {
    // 真机上报告常常超过一屏（分数 + 一串错误项 + 展开后的表单）。
    // 这条在默认的 800×600 窗口上跑，正好是一台矮手机的等价物。
    await _mount(
      tester,
      view: _view(
        setScore: _score(72),
        faults: [
          for (var i = 0; i < 8; i++)
            _stat(code: 'fault_$i', nameZh: '问题$i', count: i + 1, rate: 0.1 * (i + 1)),
        ],
      ),
    );

    // overflow 会以异常的形式冒出来，`takeException` 拿得到。
    expect(tester.takeException(), isNull);
    // 而两个按钮**固定在底部**，不跟着内容滚出屏幕 ——
    // 做完一组的人要做的下一个决定就是这两个之一。
    expect(find.text('再来一组'), findsOneWidget);
  });
}
