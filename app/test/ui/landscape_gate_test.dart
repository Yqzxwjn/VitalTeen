/// 横屏引导那一层浮层的测试。
///
/// 它有两个职责，两条都在这里验：
///
/// 1. **说清往哪边转。** 只有一个横的朝向（`platform/orientation.dart`），
///    转反了屏幕是上下颠倒的、不会自己翻回来 —— 所以「往哪边转」和
///    「转过来之后字是不是正的」这两句必须同时在场。这是那一层唯一的
///    兜底手段：系统层面读不出手机的实际朝向（强制横屏之后
///    `Display.getRotation()` 报的是锁定后的方向），只能靠用户自己看一眼。
/// 2. **它同时是一道闸。** 确认之前，「立即开始」虽然看不见，却仍然会被点到 ——
///    少了那层吞点击的手势层，用户会在一个躺倒的界面上按下一个他自己
///    看不太清的按钮。本文件第一条用例就是这一条的可执行版本。
///
/// 「进练习页会不会出这一层」与「方向有没有被切」在 `app_shell_test.dart`
/// 的「方向与横屏引导」组里，那里有走真通道进练习页的全套基建。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/landscape_gate.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 架一层引导，底下压着一个「立即开始」。
///
/// 底下那个按钮是**道具**，不是被验的对象：它代表练习页浮层上那个真的
/// 「立即开始」。摆在这一层正下方，才验得出「点不到」这件事。
///
/// [onAcknowledge] 与 [onUnderneathTap] 都写成回调而不是计数器的返回值 ——
/// `int` 按值传，把计数留在这一层里、外面拿到的永远是 `0`（本文件第一版
/// 就是这么错的，测试红了而代码是对的）。
Future<void> _mount(
  WidgetTester tester, {
  required VoidCallback onAcknowledge,
  VoidCallback? onUnderneathTap,
  bool landscape = false,
}) async {
  tester.view.physicalSize =
      landscape ? const Size(2400, 1080) : const Size(1080, 2340);
  tester.view.devicePixelRatio = landscape ? 2.75 : 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: Scaffold(
      body: Stack(
        children: [
          // 铺满整屏的兜底手势层 —— 用来验「卡片外面那一片黑」也吞点击。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onUnderneathTap?.call(),
              child: const ColoredBox(color: Color(0xFF202020)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: FilledButton(
                onPressed: () => onUnderneathTap?.call(),
                child: const Text('立即开始'),
              ),
            ),
          ),
          LandscapeGuide(onAcknowledge: onAcknowledge),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('三句话都在：横过来、为什么、往哪边转', (tester) async {
    await _mount(tester, onAcknowledge: () {});

    expect(find.text('把手机横过来'), findsOneWidget);
    expect(
      find.textContaining('身体是横着铺开的'),
      findsOneWidget,
      reason: '「为什么」这句是这一层存在的理由 —— 少了他只会以为是随便要求的',
    );
    expect(
      find.textContaining('逆时针'),
      findsOneWidget,
      reason: '往哪边转必须说出来：只有一个横的朝向，转反了屏幕是倒的',
    );
    expect(
      find.textContaining('如果字是倒的'),
      findsOneWidget,
      reason: '方向这个词本身对用户没有意义，能核对的是「字正不正」',
    );
    expect(find.text('已经横过来了'), findsOneWidget);
  });

  testWidgets('横屏一屏放得下：按钮不滑动就够得着', (tester) async {
    // 这一层出现的时候手机**已经是横的**——竖屏那份版式在这里高度只剩一半，
    // 卡片会溢出、按钮要滑动才看得见。全部既有用例都跑在竖屏下，
    // 所以这件事只有这一条挡得住。
    await _mount(tester, onAcknowledge: () {}, landscape: true);

    expect(tester.takeException(), isNull, reason: '横屏下有溢出');
    expect(find.text('把手机横过来'), findsOneWidget);
    expect(find.textContaining('逆时针'), findsOneWidget);

    // 量整张卡片：老版式在这里高 428、屏高 392.7，按钮下半截被切掉。
    // 只量按钮里的文字不够 —— 文字底边 390 还在屏内，老版式能蒙混过去。
    final card = tester.getRect(find.byKey(LandscapeGuide.cardKey));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      card.bottom <= screen.height && card.right <= screen.width,
      isTrue,
      reason: '引导卡片没有一屏放下：$card / 屏幕 $screen',
    );
  });

  testWidgets('点「已经横过来了」回调一次', (tester) async {
    var acknowledged = 0;
    await _mount(tester, onAcknowledge: () => acknowledged++);

    await tester.tap(find.text('已经横过来了'));
    await tester.pump();

    expect(
      acknowledged,
      1,
      reason: '外层那圈吞点击的手势层**不能连自己卡片上的按钮也吞掉** ——'
          '这条红了，真机上就永远确认不了',
    );
  });

  testWidgets('卡片外面的点击被吞掉 —— 底下那个「立即开始」按不到', (tester) async {
    var underneath = 0;
    await _mount(
      tester,
      onAcknowledge: () {},
      onUnderneathTap: () => underneath++,
    );

    // 点在左上角：卡片居中、限宽 460，这一点必然落在卡片外面。
    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    expect(underneath, 0, reason: '黑底那一片也要吞点击，不然「看不见但点得到」');

    // 再点底下那个按钮——**它就是练习页上那个真的「立即开始」**。
    // 引导层在上面，命中测试先到它，所以这一下到不了按钮。
    await tester.tap(find.text('立即开始'), warnIfMissed: false);
    await tester.pump();
    expect(
      underneath,
      0,
      reason: '确认之前按不到「立即开始」是这一层的**闸**职能，不是副作用',
    );
  });

  testWidgets('对照组：没有引导层时，同一个按钮点得到', (tester) async {
    // 少了它，上面那条在「按钮压根就点不动」时也会绿。
    var underneath = 0;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: buildVitalTeenTheme(),
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => underneath++,
            child: const Text('立即开始'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即开始'));
    await tester.pump();
    expect(underneath, 1);
  });
}
