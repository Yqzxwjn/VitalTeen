/// 屏幕方向的两半：**判哪个方向**（纯函数）与**怎么钉到系统上**（一次通道调用）。
///
/// ## 为什么这一组要存在
///
/// 方向这东西只有在真机上看得出对错，而真机验一次很贵（装包、架手机、
/// 转过来再转回去）。所以 [`orientationFor`] 被写成一个纯函数：它的三个输入
/// 把「哪一屏该是哪个方向」说完了，八种组合在这里全走一遍，真机上就只剩下
/// 「锁住了没有」这一件要人眼看的事。
///
/// 另一半 [`applyOrientation`] 在这里验的是**它真的只走那一条通道、且只传一个
/// 朝向**。单元素是刻意的，理由在 `lib/platform/orientation.dart` 的文件头：
/// 两个横的朝向会被引擎折成 `SCREEN_ORIENTATION_USER_LANDSCAPE`，
/// 也就是「交给传感器决定朝哪边」—— 引导图上那句「往哪边转」就时对时错。
/// 这条断言是那句话的可执行版本。
///
/// 全程走真通道：装的是 `SystemChannels.platform` 那个假 handler，
/// 而不是给 `applyOrientation` 开一个返回值的口子（同 `app_shell_test.dart`
/// 的口径）。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/platform/orientation.dart';

import '../support/orientation_spy.dart';

/// 跑 [body] 并把它引起的调用收下来。
///
/// **需要真的挂一棵树**：平台通道的假 handler 挂在测试绑定的 messenger 上，
/// 而 `testWidgets` 才有那个绑定。用例本身与界面无关，所以挂的是一棵空树。
Future<OrientationSpy> _spy(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final spy = OrientationSpy(tester);
  await body();
  await tester.pump();
  return spy;
}

void main() {
  group('orientationFor —— 哪一屏该是哪个方向', () {
    test('三个条件齐了才是横屏', () {
      expect(
        orientationFor(
          exercise: true,
          reportShown: false,
          requiresLandscape: true,
        ),
        AppOrientation.practice,
      );
    });

    test('不在练习页 → 竖屏（哪怕动作要求横屏）', () {
      // 首页、预览页、壳、欢迎页全走这一支。预览页竖屏是当初定的：
      // 那一屏看的是动作简笔画，横过来没有好处。
      for (final reportShown in [false, true]) {
        expect(
          orientationFor(
            exercise: false,
            reportShown: reportShown,
            requiresLandscape: true,
          ),
          AppOrientation.portrait,
          reason: 'reportShown=$reportShown 时不在练习页也该是竖屏',
        );
      }
    });

    test('报告放着 → 竖屏（报告是练习页里的子状态）', () {
      // **这一条最容易漏。** 报告不是一次换屏（`SetReportView` 与相机在同一个
      // `_stage` 之下），只按 `_stage` 判的话报告页会留在横屏上，
      // 而报告是拿在手里看的。
      expect(
        orientationFor(
          exercise: true,
          reportShown: true,
          requiresLandscape: true,
        ),
        AppOrientation.portrait,
      );
    });

    test('动作不要求横屏 → 竖屏（深蹲在练习页也是竖的）', () {
      // 深蹲、开合跳这类站姿动作竖着拍更满；强制横过来只会把画面浪费在两侧。
      for (final reportShown in [false, true]) {
        expect(
          orientationFor(
            exercise: true,
            reportShown: reportShown,
            requiresLandscape: false,
          ),
          AppOrientation.portrait,
          reason: 'reportShown=$reportShown 时也不要横屏',
        );
      }
    });

    test('八种组合穷举一遍 —— 只有一种落横屏', () {
      var landscape = 0;
      for (final exercise in [false, true]) {
        for (final reportShown in [false, true]) {
          for (final requiresLandscape in [false, true]) {
            final got = orientationFor(
              exercise: exercise,
              reportShown: reportShown,
              requiresLandscape: requiresLandscape,
            );
            if (got == AppOrientation.practice) landscape++;
          }
        }
      }
      expect(
        landscape,
        1,
        reason: '八种组合里**恰好一种**是横屏（练习页 + 没看报告 + 动作要横屏）。'
            '多一种就是某处判宽了，那是「报告页躺着」或「深蹲横着」的来源',
      );
    });
  });

  group('applyOrientation —— 钉到系统上', () {
    testWidgets('竖屏：上下两个朝向都允许', (tester) async {
      final spy = await _spy(
        tester,
        () => applyOrientation(AppOrientation.portrait),
      );

      expect(spy.calls, hasLength(1));
      expect(spy.last, [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });

    testWidgets('横屏：**只有一个**朝向', (tester) async {
      final spy = await _spy(
        tester,
        () => applyOrientation(AppOrientation.practice),
      );

      expect(spy.calls, hasLength(1));
      expect(
        spy.last,
        [DeviceOrientation.landscapeLeft],
        reason: '两个横的朝向会被引擎折成 USER_LANDSCAPE（跟着传感器走），'
            '于是「把手机顶部转到左边」这句引导时对时错',
      );
    });

    testWidgets('两种方向都走同一条通道、同一个方法名', (tester) async {
      // 少了它，哪天有人用原生通道绕过去（计划里那个退路）就没人知道 ——
      // 那时方向会变成两个主人。
      final spy = await _spy(tester, () async {
        await applyOrientation(AppOrientation.practice);
        await applyOrientation(AppOrientation.portrait);
      });

      expect(spy.calls, hasLength(2));
      expect(spy.calls[0], [DeviceOrientation.landscapeLeft]);
      expect(spy.calls[1], [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });
  });
}
