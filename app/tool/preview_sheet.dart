/// 把 `kPreviewFrames` 里每个动作的每一拍渲染成一张联系表（contact sheet），
/// 用来**用眼睛检查简笔人形画得对不对**。
///
/// ## 为什么这个工具必须存在
///
/// `preview_poses.dart` 是一张关节角表，而**关节角没有肉眼之外的验证方式**：
/// 读 `hip: -78` 读不出「腿是不是一条线」，算出来也能算对，画出来才发现是
/// 「伏地挺身做到一半」。这一版里有五处错误就是这么被发现的 ——
/// 立定跳远落地被切掉半个身子、引体向上画成了站着举手的正常人、跳绳的手
/// 像端着个托盘、平板支撑的腿斜着往下、正视图里两条腿从同一个点长出来。
/// 五处**没有一处是读代码能看出来的**。
///
/// ## 怎么跑
///
///     cd app
///     flutter test tool/preview_sheet.dart
///
/// 出来的是 `build/preview_dump/all.png`（`build/` 本来就不进仓库）。
/// 改了 `preview_poses.dart` 之后跑一遍，看一眼，再决定改得对不对。
///
/// ## 为什么放在 `tool/` 而不是 `test/`
///
/// `flutter test` 不带参数时会把 `test/` 下**每一个** `*_test.dart` 都跑一遍，
/// 而这个是**渲染工具**不是测试：它不检查任何东西，只写 PNG，在这台机器上
/// 还要跑好几分钟。放在 `test/` 里，每跑一次全套测试就白等它一次。
/// 放在 `tool/` 里它照样被 `flutter analyze` 检查（`check_all.py` 第 15 项），
/// 但不会被当成测试收进去。
///
/// ## 一个已知的坑
///
/// 画布上的中文标签在这个渲染器里是**方块**（测试环境没挂中文字体），
/// 所以标签只能靠**位置**认：左边一列是动作码，每一格左上角是那一拍的相位词。
/// 别去修字体 —— 这不影响看人形，而看人形是这个工具唯一的目的。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/exercise_preview.dart';
import 'package:vitalteen_app/ui/preview_poses.dart';

void main() {
  testWidgets('渲染联系表', (tester) async {
    const cellW = 230.0;
    const cellH = 170.0;
    const labelW = 90.0;

    final codes = kPreviewFrames.keys.toList();
    final maxFrames =
        kPreviewFrames.values.map((f) => f.length).reduce(math.max);

    final width = labelW + maxFrames * cellW;
    final height = codes.length * cellH;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFF080C10),
    );
    for (var c = 0; c <= maxFrames; c++) {
      canvas.drawLine(
        Offset(labelW + c * cellW, 0),
        Offset(labelW + c * cellW, height),
        Paint()
          ..color = const Color(0xFF1A242C)
          ..strokeWidth = 1,
      );
    }

    for (var r = 0; r < codes.length; r++) {
      final code = codes[r];
      final frames = kPreviewFrames[code]!;
      final view = code == 'JJ' ? PreviewView.front : PreviewView.side;
      final box = previewBox(frames, view);
      final showGround = frames.any((f) => f.lift == 0);
      final barY = code == 'PULLUP' ? previewBarY(frames, view) : null;

      _text(canvas, '$code\n${frames.length}拍', Offset(6, r * cellH + 50));

      for (var c = 0; c < frames.length; c++) {
        final frame = frames[c];
        canvas.save();
        canvas.translate(labelW + c * cellW, r * cellH);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, cellW, cellH),
          Paint()
            ..color = const Color(0xFF101A22)
            ..style = PaintingStyle.stroke,
        );
        StickFigurePainter(
          pose: frame.pose,
          view: view,
          lift: frame.lift,
          drift: frame.drift,
          box: box,
          showGround: showGround,
          barY: barY,
          color: const Color(0xFF3BE8FF),
          groundColor: const Color(0xFF3A4A55),
        ).paint(canvas, Size(cellW, cellH));
        canvas.restore();
        _text(canvas, frame.label, Offset(labelW + c * cellW + 6, r * cellH + 4));
      }
    }

    final image =
        await recorder.endRecording().toImage(width.toInt(), height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/preview_dump')..createSync(recursive: true);
    File('${dir.path}/all.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void _text(Canvas canvas, String s, Offset at) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: const TextStyle(color: Color(0xFF88A0AE), fontSize: 11),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, at);
}
