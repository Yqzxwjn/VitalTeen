/// [BottomSurface] 那条规则：**底色到屏幕最下沿，内容让开手势条。**
///
/// ## 为什么这件事值得单独测
///
/// 它是一条**看不见的**规则，而且两种写法都能编译、都不报错：
///
/// - 让位让在**外面**（`SafeArea` 包住整块底面）时，跟着一起被抬起来的还有
///   底面的底色，屏幕最下沿露出一条只有相机画面的缝 —— 那一条被 `_Scrim`
///   压暗成近黑，真机上看起来就是「底下多了一条黑边」。
///   2026-10-05 用户报的就是这个。
/// - 让位让在**里面**时，底色铺到边，字和按钮仍然整个站在手势条上面。
///
/// 两个方向都要量：只量「到边」的话，「内容也一起压到最下面」会漏过去 ——
/// 那是另一种坏法，按钮压在导航手势上，手势就抢不回来了。
///
/// ## 尺寸用的是这台目标机器上量到的
///
/// 1080×2400 @ 440dpi，手势导航那条 44 物理像素（= 16 逻辑像素），
/// 取自 `dumpsys window` 里 `NavigationBar0` 的 inset frame。
/// 拿别的数字测，测的是另一台机器上不会发生的事。
///
/// ## 练习页那个调用点挂不上来（试过了）
///
/// `SquatPage` 启动时先 `loadThresholds()` 读随包资源，而 `rootBundle`
/// 那条路在 `testWidgets` 的假时钟里**永远不回来**：`tester.pump` 推不动它，
/// 先在 `runAsync` 里预热一遍也没用，把 `flutter/assets` 换成同步读盘的假处理器
/// 更是连调都调不到（`rootBundle` 在测试里不走那条通道）。
/// 结果就是屏幕上一直停在加载转圈上，浮层根本不在树上。
///
/// 所以这里量两件事：**规则本身**（第一条）与**报告页那个真实调用点**（第二条）。
/// 练习页那半截由这两条加 `_body` 里那句「这一层不套 SafeArea」的注释兜着。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/analysis.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/decision_submission.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/rules.dart' show SetSummary;
import 'package:vitalteen_app/ui/bottom_surface.dart';
import 'package:vitalteen_app/ui/set_report_view.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 目标机器：1080×2400 @ 440dpi，底下那条手势栏 44 物理像素。
///
/// [bottomInsetPhysical] 传 0 就是三键导航那种机器 —— 那条规则在两种机器上
/// 都得成立，只测有手势条的那种会漏掉「没手势条时不该凭空多出 16」。
void _targetPhone(WidgetTester tester, {double bottomInsetPhysical = 44}) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  tester.view.padding = FakeViewPadding(bottom: bottomInsetPhysical);
  addTearDown(tester.view.reset);
}

/// 屏幕最下沿（逻辑像素）—— 872.727…
double _screenBottom(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

/// 手势条那一条（逻辑像素）—— 44 ÷ 2.75 = 16。
double _gestureBar(WidgetTester tester) =>
    tester.view.padding.bottom / tester.view.devicePixelRatio;

const Key _surfaceKey = ValueKey('surface');
const Key _contentKey = ValueKey('surface-content');

/// 底部 12 的内边距，底面自己声明的量（不含手势条）。
const double _ownPadding = 12;

/// 一个贴着屏幕底部的 [BottomSurface]，里面放一块 48 高的内容。
Future<void> _mountSurface(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildCameraTheme(),
    home: Scaffold(
      body: Column(
        children: [
          const Expanded(child: ColoredBox(color: Color(0xFF101418))),
          BottomSurface(
            key: _surfaceKey,
            decoration: const BoxDecoration(color: Color(0xCC080C10)),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, _ownPadding),
            child: const SizedBox(key: _contentKey, height: 48),
          ),
        ],
      ),
    ),
  ));
}

/// 一份做完的组。报告体只认 `finished` 相位。
SessionView _finishedView() => SessionView(
      phase: SessionPhase.finished,
      position: const PositionReport.empty(),
      calibrationFrames: 15,
      calibrationTarget: 15,
      repCount: 12,
      discardedReps: 0,
      machineState: 'finished',
      kneeAngle: null,
      holdMs: 0,
      repDurationsMs: const [],
      lastRep: null,
      lastRepScore: null,
      summary: const SetSummary(repCount: 12, faultStats: []),
      setScore: FormScore(
        score: 86,
        rating: FormRating.good,
        provisional: true,
        penalty: 0.14,
        terms: const [],
      ),
      interrupted: false,
      sawFrame: true,
    );

void main() {
  testWidgets('有手势条：底色到屏幕最下沿，内容让开那 16 个逻辑像素', (tester) async {
    _targetPhone(tester);
    await _mountSurface(tester);

    final bottom = _screenBottom(tester);
    final inset = _gestureBar(tester);
    expect(inset, moreOrLessEquals(16), reason: '手势条那一条应该正好 16 逻辑像素');

    final surface = tester.getRect(find.byKey(_surfaceKey));
    expect(
      surface.bottom,
      moreOrLessEquals(bottom, epsilon: 0.01),
      reason: '底面的下沿离屏幕下沿还差 ${bottom - surface.bottom} 逻辑像素 —— '
          '那一条缝只有相机画面，练习页上会被压暗成近黑，看着就是一条黑边',
    );

    final content = tester.getRect(find.byKey(_contentKey));
    expect(
      content.bottom,
      moreOrLessEquals(bottom - inset - _ownPadding, epsilon: 0.01),
      reason: '内容的下沿应该是「屏幕下沿 − 手势条 − 自己的内边距」',
    );
  });

  testWidgets('没有手势条（三键导航）：内容只让开自己的内边距，不多留', (tester) async {
    _targetPhone(tester, bottomInsetPhysical: 0);
    await _mountSurface(tester);

    final bottom = _screenBottom(tester);
    final surface = tester.getRect(find.byKey(_surfaceKey));
    expect(surface.bottom, moreOrLessEquals(bottom, epsilon: 0.01));
    expect(
      tester.getRect(find.byKey(_contentKey)).bottom,
      moreOrLessEquals(bottom - _ownPadding, epsilon: 0.01),
    );
  });

  testWidgets('报告页那条操作栏：底色到屏幕最下沿，两个按钮站在手势条上面', (tester) async {
    _targetPhone(tester);

    await tester.pumpWidget(MaterialApp(
      theme: buildCameraTheme(),
      home: Scaffold(
        // 与 `_report()` 里那层 `SafeArea(top: false, bottom: false)` 之后的效果
        // 一致：body 一直铺到屏幕最下沿，手势条那一条由底栏自己吃。
        body: SetReportView(
          view: _finishedView(),
          requestBuilder: (sex, age, grade, group) => null,
          analyze: (request, endpoint) async => const AnalysisFailed(
            DecisionFailure(kind: DecisionFailureKind.unreachable),
          ),
          onAnotherSet: () {},
          onRecalibrate: () {},
        ),
      ),
    ));

    final bar = find.byKey(SetReportView.actionBarKey);
    expect(bar, findsOneWidget);

    final bottom = _screenBottom(tester);
    final inset = _gestureBar(tester);

    expect(
      tester.getRect(bar).bottom,
      moreOrLessEquals(bottom, epsilon: 0.01),
      reason: '底栏的下沿离屏幕下沿还差 ${bottom - tester.getRect(bar).bottom} 逻辑像素',
    );

    for (final label in ['再来一组', '重新标定']) {
      expect(
        tester.getRect(find.text(label)).bottom,
        lessThanOrEqualTo(bottom - inset),
        reason: '「$label」压在手势条上了',
      );
    }
  });
}
