/// `AvatarImage` 与 `initialAvatar` 的测试。
///
/// 这两样各自只有一条规则，而两条都有个**用户能看见的坏结果**：
///
/// - **没有用户图就画兜底** —— 兜底画不出来时那块地方是空白的，
///   而空白的头像位看起来像渲染失败；
/// - **文件读不出来也要画兜底，而且不许把异常抛出去** ——
///   路径是「上次读到的」，不保证文件还在（系统清缓存、换设备、
///   原生侧写坏了）。一条失效的路径不该把整个页面炸掉：
///   那是「一张图没了」和「应用打不开了」的区别。
///
/// 那三层排队（用户图 > `avatar.webp` > 首字母）里，这个文件管的是
/// **最外面那一层判断**，中间那层是调用方传进来的 [AvatarImage.fallback]，
/// 所以这里用一个哨兵控件当兜底，断言的是「轮到谁上场」，与图的真假无关。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/avatar_image.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 兜底那个哨兵。它是什么不重要，重要的是「屏幕上是不是它」。
const Widget _sentinel = Placeholder(key: ValueKey('fallback'));

Finder get _sentinelFinder => find.byKey(const ValueKey('fallback'));

Future<void> _pump(WidgetTester tester, String? path) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: Center(
      child: SizedBox(
        width: 96,
        height: 96,
        // 圆是位置的属性、不是图的属性，所以调用方自己套 —— 与两处真实调用
        //（`me_page.dart` / `home_page.dart`）一致，免得这里测的是一个
        // 真机上不存在的形状。
        child: ClipOval(child: AvatarImage(path: path, fallback: _sentinel)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('AvatarImage', () {
    testWidgets('没选过头像（path 为 null）：画兜底，一个 Image 都不建', (tester) async {
      await _pump(tester, null);

      expect(_sentinelFinder, findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('选了头像：画的是那个文件', (tester) async {
      // 路径编的，文件不存在 —— 但这一条只关心**轮到 `Image.file` 上场**。
      await _pump(tester, '/nonexistent/vitalteen-avatar.png');

      expect(_sentinelFinder, findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as FileImage).file.path,
        '/nonexistent/vitalteen-avatar.png',
      );
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('文件不见了：退回兜底，而且不许把异常抛给上层', (tester) async {
      // **这一条是这个文件存在的理由。** 路径只保证「上次读到的」，
      // 不保证文件还在。没有 `errorBuilder` 的话，这里会是一屏红色报错。
      await _pump(tester, '/nonexistent/vitalteen-avatar-gone.png');

      // `FileImage` 读盘走的是**真异步**，fake-async 的 `pump` 推不动它 ——
      // 不借 `runAsync` 的话 `errorBuilder` 永远不会被调到，这条就变成
      // 在测一个「什么都没发生」。路径带后缀是为了不和上一条共用缓存项。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      // **要两帧。** 第一帧把读盘失败那个未来跑完（`Image` 收到 onError），
      // 第二帧才画出 `errorBuilder` 返回的兜底 —— 一帧的话断言会落空，
      // 而那是测试自己少 pump 了一下，不是控件的问题。
      await tester.pumpAndSettle();

      expect(_sentinelFinder, findsOneWidget);
      // **错误必须被 `errorBuilder` 吃掉**，不能冒泡成一处崩溃 ——
      // 真机上那就是整个页面一片红。
      expect(tester.takeException(), isNull);
    });

    testWidgets('铺满外面给的那个盒子，不自己撑尺寸', (tester) async {
      // 两处调用都把尺寸定在 `SizedBox` 上（96 与 56），图跟着走。
      // 图自己撑尺寸的话，同一个控件在两处会长得不一样。
      await _pump(tester, '/nonexistent/vitalteen-avatar.png');

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, double.infinity);
      expect(image.height, double.infinity);
    });
  });

  group('initialAvatar', () {
    testWidgets('首字母是称呼的第一个字', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: Center(child: SizedBox(
          width: 96,
          height: 96,
          child: initialAvatar(name: '小北', size: 96),
        )),
      ));

      expect(find.text('小'), findsOneWidget);
      expect(find.text('小北'), findsNothing);
    });

    testWidgets('昵称以 emoji 开头时，取到的是整个 emoji 不是半个', (tester) async {
      // `name[0]` 取到的是代理对的前一半，画出来是一个「口」——
      // 而那个「口」会永远挂在用户头像上。
      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: Center(child: initialAvatar(name: '🏃阿哲', size: 96)),
      ));

      expect(find.text('🏃'), findsOneWidget);
    });

    testWidgets('字号跟着 size 走 —— 56 与 96 两处不会各写一个数', (tester) async {
      // 写死字号的话，其中一处调大时另一处不会跟着动，看上去就是两个 App。
      Future<double> fontSize(double size) async {
        await tester.pumpWidget(MaterialApp(
          theme: buildVitalTeenTheme(),
          home: Center(child: initialAvatar(name: '小北', size: size)),
        ));
        return tester.widget<Text>(find.text('小')).style!.fontSize!;
      }

      final small = await fontSize(56);
      final big = await fontSize(96);
      expect(big, greaterThan(small));
      expect(big / small, closeTo(96 / 56, 0.001));
    });
  });
}
