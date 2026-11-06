/// 动作预览页的测试。
///
/// 这一屏的全部价值在于**它在「开始」之前**。所以这里测的不是排版，
/// 是那条分岔：已上线的动作给出真的「开始」，没上线的动作**一个按钮都不给**、
/// 换成一句实话 —— 而不是一个置灰的按钮。
///
/// 置灰的按钮和一句说明对用户不是一回事：前者看起来像「你现在的状态不对，
/// 弄好就能点」，后者才是在说「这个功能根本不存在」。
///
/// **注意 `pump` 而不是 `pumpAndSettle`**：页面里的 `ExercisePreview` 是
/// `repeat()` 的动画，永远 settle 不了，用 `pumpAndSettle` 会直接挂住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/app_icons.dart';
import 'package:vitalteen_app/ui/exercise_catalog.dart';
import 'package:vitalteen_app/ui/preview_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

Future<void> _mount(
  WidgetTester tester,
  ExerciseEntry entry, {
  VoidCallback? onStart,
  VoidCallback? onBack,
  String? framingHint,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: PreviewPage(
      entry: entry,
      onBack: onBack ?? () {},
      onStart: onStart,
      framingHint: framingHint,
    ),
  ));
}

/// 页面上某个自绘图标。ind.byIcon 只认 Material 的字形，这里按枚举找。
Finder _glyph(AppGlyph glyph) =>
    find.byWidgetPredicate((w) => w is AppIcon && w.glyph == glyph);

void main() {
  testWidgets('已上线的动作：给出「开始」，点了就回调', (tester) async {
    var starts = 0;
    await _mount(tester, exerciseByCode('SQUAT')!, onStart: () => starts++);

    expect(find.text('开始'), findsOneWidget);
    await tester.tap(find.text('开始'));
    await tester.pump();

    expect(starts, 1);
  });

  testWidgets('未上线的动作：没有「开始」，而且说明白为什么没有', (tester) async {
    // 七项里挑一项。逐项遍历没必要 —— 走的是同一个分支，
    // 而「七项都进得来」是首页测试在管的事。
    await _mount(tester, exerciseByCode('JJ')!);

    expect(find.text('开始'), findsNothing);
    expect(find.textContaining('没有能跟着练的版本'), findsOneWidget);
  });

  testWidgets('两种页面上都画得出预览，不存在一个空框', (tester) async {
    // 预览页的头号失败模式是「进来了，但上面什么都没有」——
    // `ExercisePreview` 对没姿势的动作码画的是那句兜底文案，
    // 而一个空框在用户眼里和加载失败没有区别。
    for (final code in ['SQUAT', 'JJ']) {
      await _mount(tester, exerciseByCode(code)!);
      expect(find.text('这个动作还没有预览'), findsNothing, reason: code);
    }
  });

  testWidgets('动作名在标题上，一眼看得出点进来的是哪个', (tester) async {
    await _mount(tester, exerciseByCode('PLANK')!);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('平板支撑')),
      findsOneWidget,
    );
  });

  testWidgets('传了站位提示就显示出来 —— 和自检清单是同一句话', (tester) async {
    // 这句由调用方传进来（`ActionSpec.framingHint`），页面自己不另写一句：
    // 三处各说一套，用户会以为在做三件不同的事。
    await _mount(
      tester,
      exerciseByCode('SLJ')!,
      onStart: () {},
      framingHint: '手机放在侧前方，人要能整个进画面。',
    );

    expect(find.text('手机放在侧前方，人要能整个进画面。'), findsOneWidget);
  });

  testWidgets('没传站位提示就不空出一行', (tester) async {
    await _mount(tester, exerciseByCode('SQUAT')!, onStart: () {});
    expect(_glyph(AppGlyph.camera), findsNothing);
  });

  testWidgets('已上线的动作仍然写着它测不出什么', (tester) async {
    // 预览页比首页更该留着这句话：卡片上那句话还可能没读，
    // 而这一屏是「决定要不要开始」的地方。
    await _mount(tester, exerciseByCode('SLJ')!, onStart: () {});
    expect(find.textContaining('测不出'), findsOneWidget);
  });

  testWidgets('返回键回调出去', (tester) async {
    var backs = 0;
    await _mount(tester, exerciseByCode('SQUAT')!, onBack: () => backs++);

    await tester.tap(_glyph(AppGlyph.arrowLeft));
    await tester.pump();

    expect(backs, 1);
  });
}
