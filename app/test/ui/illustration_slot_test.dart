/// 插图位与卡片缩略图的测试。
///
/// 两条主线：
///
/// 1. **「图不在就画兜底」这件事必须真的成立。** 它是这一轮「版式先行、
///    图位留空」的全部机制 —— 它要是坏了，用户把图丢进 `assets/images/`
///    之后什么都不会发生，而那是这一轮交付的核心承诺。反过来，图在的时候
///    兜底也不能再露出来。
/// 2. **缩略图索引的机械校验。** 挑错了那一拍不会报错，只会画出一张认不出来的
///    小图（`PLANK` 取中间那拍就是「一个站着的人」）。所以这里逐码检查：
///    每个动作都有索引、索引在范围内、**且那一拍不是默认站姿**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/exercise_preview.dart';
import 'package:vitalteen_app/ui/illustration_slot.dart';
import 'package:vitalteen_app/ui/preview_poses.dart';
import 'package:vitalteen_app/ui/splash_page.dart';

/// 一个**永远不会有**的路径。
///
/// 这里原来用的是 `assets/images/hero_home.webp`（首页横幅那一张），图省事
/// 顺便钉住「横幅去哪个路径找图」。**那是个陷阱**：这一轮「图位留空」的交付
/// 承诺就是用户随时可以把那四张图丢进来，而那一天这个文件会红两条 ——
/// 红的还是「图不在：画兜底」这种与改动毫无关系的断言。
///
/// 所以这里用一个明说不会存在的名字，那个路径的断言搬去了它该在的地方
///（`test/ui/home_page_test.dart` 的「顶部横幅」那一组，断的是控件读的路径，
/// 与文件在不在无关）。
const String _notYetDrawn = 'assets/images/没有这张图.webp';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('插图位', () {
    testWidgets('图不在：画兜底', (tester) async {
      await tester.pumpWidget(_host(const IllustrationSlot(
        path: _notYetDrawn,
        fallback: Text('兜底'),
      )));
      // 缺文件的错误是异步回来的，要给它一次 pump 才能落到 errorBuilder。
      await tester.pumpAndSettle();

      expect(find.text('兜底'), findsOneWidget);
    });

    testWidgets('图在：画图，兜底不露面', (tester) async {
      // 拿一张**真的存在**的品牌图来验另一条分支。用假路径的话，这条测试
      // 与上一条走的是同一条路，等于没测。
      await tester.pumpWidget(_host(const IllustrationSlot(
        path: SplashPage.artworkPath,
        fallback: Text('兜底'),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('兜底'), findsNothing,
          reason: '图都出来了还留着占位符，等于两张图叠在一起');
    });

    testWidgets('兜底可以是一个控件树，不只是文字', (tester) async {
      // 五处图位的兜底都不是纯文字（渐变块 + 简笔小人 + 图标），
      // 所以这里要确认 slot 没有对 fallback 的形状做任何假设。
      await tester.pumpWidget(_host(const SizedBox(
        width: 56,
        height: 56,
        child: IllustrationSlot(
          path: _notYetDrawn,
          fallback: ColoredBox(
            color: Color(0xFF0B3D91),
            child: Icon(Icons.directions_run),
          ),
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.directions_run), findsOneWidget);
    });
  });

  group('缩略图索引的机械校验', () {
    test('每个有预览的动作都有一个索引', () {
      // 少一个的表现是那张卡片上没有小人（退回通用图标），而它有预览动画 ——
      // 用户会在卡片与点进去之后看到两个不一样的东西。
      for (final code in kPreviewFrames.keys) {
        expect(
          kPreviewThumbnailIndex.containsKey(code),
          isTrue,
          reason: '$code 有预览动画却没有缩略图索引',
        );
      }
    });

    test('没有多余的索引', () {
      // 反向的那一条。一个指向不存在动作的索引，最可能的原因是动作码改了名
      // 而索引表没跟着改 —— 那同时也是「新码没有索引」，但两条一起报出来
      // 才能一眼看出是改名而不是漏加。
      for (final code in kPreviewThumbnailIndex.keys) {
        expect(
          kPreviewFrames.containsKey(code),
          isTrue,
          reason: '$code 有缩略图索引却没有预览动画',
        );
      }
    });

    test('索引都在范围内，而且那一拍是个真的姿势', () {
      kPreviewThumbnailIndex.forEach((code, index) {
        final frames = kPreviewFrames[code]!;
        expect(index, inInclusiveRange(0, frames.length - 1),
            reason: '$code 的索引 $index 越界（它只有 ${frames.length} 拍）');

        // **这一条拦的是「取中间那一拍」那类错误。** 默认站姿是
        // `PreviewPose()`（所有角度为 0），而几张最有辨识度的缩略图里
        // 最容易被选错的那一张就是 `PLANK` —— 它只有两拍，
        // `1` 是「没在撑」（站着的人）。取到它，卡片上会是一个站着的人
        // 配着「平板支撑」四个字。
        expect(
          _isRestPose(frames[index].pose),
          isFalse,
          reason: '$code 缩略图取到了第 $index 拍「${frames[index].label}」'
              '—— 那一拍是默认站姿（站着），认不出这是什么动作',
        );
      });
    });

    test('平板支撑取的是「撑住」那一拍', () {
      // 上一条已经从「不是站姿」这个角度拦住了它，这一条把结论写死 ——
      // 因为它是注释里点名的那个反例，将来有人改成 1 时应该在这一行停下。
      expect(kPreviewThumbnailIndex['PLANK'], 0);
      expect(previewThumbnail('PLANK')!.label, '撑住');
    });
  });

  group('取缩略图', () {
    test('正常的码取得到那一拍', () {
      expect(previewThumbnail('SQUAT')!.label, '最低点');
      expect(previewThumbnail('PULLUP')!.label, '顶部');
    });

    test('不认识的码给 null，不抛', () {
      // 调用方是首页的卡片，它拿到的 code 来自清单数据本身。查不到是数据问题，
      // 该做的是退回通用图标，而不是让整个首页崩掉。
      for (final code in const ['', 'NOPE', 'squat']) {
        expect(() => previewThumbnail(code), returnsNormally, reason: code);
        expect(previewThumbnail(code), isNull, reason: code);
      }
    });

    testWidgets('缩略图控件对不认识的码什么都不画', (tester) async {
      await tester.pumpWidget(_host(const SizedBox(
        width: 56,
        height: 56,
        child: StickFigureThumbnail(code: 'NOPE', color: Colors.white),
      )));

      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('认识的码画得出来，不抛', (tester) async {
      for (final code in kPreviewFrames.keys) {
        await tester.pumpWidget(_host(SizedBox(
          width: 56,
          height: 56,
          child: StickFigureThumbnail(code: code, color: Colors.white),
        )));
        expect(tester.takeException(), isNull, reason: code);
      }
    });
  });
}

/// 这一拍是不是默认站姿（所有角度为 0、没有左右差异）。
///
/// 写在这里而不是给 `PreviewPose` 加一个 getter：它是**测试的判据**，
/// 不是产品概念 —— 产品里没有任何一处需要问「这一拍是不是站着」。
bool _isRestPose(PreviewPose pose) =>
    pose.trunk == 0 &&
    pose.hip == 0 &&
    pose.knee == 0 &&
    pose.spread == 0 &&
    pose.shoulder == 0 &&
    pose.elbow == 0 &&
    pose.hipR == null &&
    pose.kneeR == null &&
    pose.spreadR == null &&
    pose.shoulderR == null &&
    pose.elbowR == null;
