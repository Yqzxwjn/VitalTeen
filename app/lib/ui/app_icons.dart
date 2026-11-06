//应用自己画的一套线性图标
//
//**为什么不用 Material 图标。** 那个字形集是成套的，但它的笔画粗细、圆角
//与端点都是为「通用 Android 应用」调的：24 像素里那一套会把同一个界面拉回
//模板感。这里按 24 网格、1.6 笔画、圆头圆角重画了一套，线条更松，跟应用
//自己的卡片与字阶更合。
//
//只用在前台的导航、分区与操作行上。相机 HUD 与报告页里那些功能性小图标
//（开关、箭头、警告）仍然用 Material —— 它们长在深色相机画面上，换一套
//只会让那两屏与应用其余部分脱节，而它们是全应用最不能改版的两屏。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design.dart';

enum AppGlyph {
  workout,
  history,
  posture,
  profile,
  chevronRight,
  chevronLeft,
  arrowLeft,
  camera,
  edit,
  info,
  trash,
  flame,
  sun,
  check,
  warning,
  lock,
  sparkle,
  timer,
  chart,
  plus,
  close,
  play,
}

class AppIcon extends StatelessWidget {
  const AppIcon(
    this.glyph, {
    super.key,
    this.size = 24,
    this.color = AppColors.ink,
    this.strokeWidth = 1.6,
  });

  final AppGlyph glyph;
  final double size;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph: glyph,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
  });

  final AppGlyph glyph;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // 所有坐标都写在 24×24 的网格上，最后缩放到实际尺寸 ——
    // 于是同一个图标在 20 与 24 上笔画比例一致。
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    void line(double x1, double y1, double x2, double y2) {
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
    }

    void dot(double x, double y, [double r = 1.15]) {
      canvas.drawCircle(Offset(x, y), r, fill);
    }

    void circle(double x, double y, double r) {
      canvas.drawCircle(Offset(x, y), r, stroke);
    }

    switch (glyph) {
      case AppGlyph.workout:
        // 一个正在下蹲的人：头、躯干、一前一后两条腿、一条摆臂。
        circle(12.6, 5.0, 2.0);
        line(12.4, 7.1, 11.2, 12.2);
        line(11.2, 12.2, 7.4, 14.2);
        line(7.4, 14.2, 7.9, 18.8);
        line(11.2, 12.2, 15.0, 14.4);
        line(15.0, 14.4, 15.2, 18.8);
        line(11.9, 8.6, 8.4, 10.8);
      case AppGlyph.history:
        // 表盘 + 逆时针的回拨箭头：这一页是「回头看」。
        const center = Offset(12, 12.6);
        const radius = 7.4;
        final arc = Rect.fromCircle(center: center, radius: radius);
        canvas.drawArc(arc, -0.55, 5.35, false, stroke);
        final tip = Offset(
          center.dx + radius * math.cos(-0.55),
          center.dy + radius * math.sin(-0.55),
        );
        line(tip.dx, tip.dy, tip.dx - 2.6, tip.dy - 0.2);
        line(tip.dx, tip.dy, tip.dx + 0.4, tip.dy + 2.7);
        line(center.dx, center.dy, 12, 8.4);
        line(center.dx, center.dy, 15.0, 14.2);
      case AppGlyph.posture:
        // 站直的人 + 一条重力垂线：看的是「有没有对上线」。
        circle(10.6, 4.9, 2.0);
        line(10.6, 7.0, 10.6, 16.6);
        line(7.2, 9.6, 14.0, 9.6);
        line(10.6, 16.6, 8.8, 20.2);
        line(10.6, 16.6, 12.4, 20.2);
        line(18.0, 4.4, 18.0, 19.6);
        line(16.4, 6.2, 18.0, 4.4);
        line(19.6, 6.2, 18.0, 4.4);
        line(16.4, 17.8, 18.0, 19.6);
        line(19.6, 17.8, 18.0, 19.6);
      case AppGlyph.profile:
        circle(12, 8.2, 3.5);
        final shoulders = Path()
          ..moveTo(4.9, 19.8)
          ..cubicTo(5.6, 14.4, 8.4, 13.0, 12, 13.0)
          ..cubicTo(15.6, 13.0, 18.4, 14.4, 19.1, 19.8);
        canvas.drawPath(shoulders, stroke);
      case AppGlyph.chevronRight:
        final path = Path()
          ..moveTo(9.6, 6.4)
          ..lineTo(15.2, 12)
          ..lineTo(9.6, 17.6);
        canvas.drawPath(path, stroke);
      case AppGlyph.chevronLeft:
        final path = Path()
          ..moveTo(14.4, 6.4)
          ..lineTo(8.8, 12)
          ..lineTo(14.4, 17.6);
        canvas.drawPath(path, stroke);
      case AppGlyph.arrowLeft:
        line(19.2, 12, 5.4, 12);
        line(10.0, 6.8, 5.4, 12);
        line(10.0, 17.2, 5.4, 12);
      case AppGlyph.camera:
        final body = RRect.fromRectAndRadius(
          const Rect.fromLTRB(3.4, 7.0, 20.6, 19.6),
          const Radius.circular(3.2),
        );
        canvas.drawRRect(body, stroke);
        final hump = Path()
          ..moveTo(8.8, 7.0)
          ..lineTo(9.9, 5.0)
          ..lineTo(14.1, 5.0)
          ..lineTo(15.2, 7.0);
        canvas.drawPath(hump, stroke);
        circle(12, 13.2, 3.7);
      case AppGlyph.edit:
        final pencil = Path()
          ..moveTo(5.2, 18.8)
          ..lineTo(6.2, 14.3)
          ..lineTo(15.5, 5.0)
          ..lineTo(19.0, 8.5)
          ..lineTo(9.7, 17.8)
          ..close();
        canvas.drawPath(pencil, stroke);
        line(14.0, 6.5, 17.5, 10.0);
      case AppGlyph.info:
        circle(12, 12, 8.2);
        dot(12, 8.3);
        line(12, 11.2, 12, 16.4);
      case AppGlyph.trash:
        line(4.6, 6.4, 19.4, 6.4);
        final handle = Path()
          ..moveTo(9.6, 6.4)
          ..lineTo(9.6, 4.6)
          ..lineTo(14.4, 4.6)
          ..lineTo(14.4, 6.4);
        canvas.drawPath(handle, stroke);
        final can = Path()
          ..moveTo(6.6, 6.4)
          ..lineTo(7.5, 19.2)
          ..cubicTo(7.6, 20.0, 8.2, 20.5, 9.0, 20.5)
          ..lineTo(15.0, 20.5)
          ..cubicTo(15.8, 20.5, 16.4, 20.0, 16.5, 19.2)
          ..lineTo(17.4, 6.4);
        canvas.drawPath(can, stroke);
        line(10.2, 10.2, 10.6, 16.4);
        line(13.8, 10.2, 13.4, 16.4);
      case AppGlyph.flame:
        final flame = Path()
          ..moveTo(12, 3.4)
          ..cubicTo(12.4, 6.4, 12.4, 8.6, 11.6, 11.0)
          ..cubicTo(10.4, 9.9, 9.6, 8.6, 9.8, 6.4)
          ..cubicTo(7.8, 8.4, 6.2, 10.8, 6.2, 13.8)
          ..cubicTo(6.2, 17.6, 8.8, 20.5, 12, 20.5)
          ..cubicTo(15.2, 20.5, 17.8, 17.6, 17.8, 13.8)
          ..cubicTo(17.8, 10.2, 15.2, 7.2, 12, 3.4)
          ..close();
        canvas.drawPath(flame, stroke);
      case AppGlyph.sun:
        circle(12, 12, 4.0);
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4;
          final from = Offset(
            12 + 6.4 * math.cos(angle),
            12 + 6.4 * math.sin(angle),
          );
          final to = Offset(
            12 + 9.0 * math.cos(angle),
            12 + 9.0 * math.sin(angle),
          );
          canvas.drawLine(from, to, stroke);
        }
      case AppGlyph.check:
        final path = Path()
          ..moveTo(5.2, 12.6)
          ..lineTo(9.8, 17.2)
          ..lineTo(18.8, 6.8);
        canvas.drawPath(path, stroke);
      case AppGlyph.warning:
        final triangle = Path()
          ..moveTo(12, 4.0)
          ..lineTo(21.0, 19.6)
          ..lineTo(3.0, 19.6)
          ..close();
        canvas.drawPath(triangle, stroke);
        line(12, 9.6, 12, 14.2);
        dot(12, 16.9);
      case AppGlyph.lock:
        final body = RRect.fromRectAndRadius(
          const Rect.fromLTRB(5.4, 10.4, 18.6, 20.2),
          const Radius.circular(2.6),
        );
        canvas.drawRRect(body, stroke);
        final shackle = Path()
          ..addArc(
            Rect.fromCircle(center: const Offset(12, 10.2), radius: 4.2),
            math.pi,
            math.pi,
          );
        canvas.drawPath(shackle, stroke);
      case AppGlyph.sparkle:
        final star = Path()
          ..moveTo(12, 3.4)
          ..lineTo(13.9, 10.1)
          ..lineTo(20.6, 12)
          ..lineTo(13.9, 13.9)
          ..lineTo(12, 20.6)
          ..lineTo(10.1, 13.9)
          ..lineTo(3.4, 12)
          ..lineTo(10.1, 10.1)
          ..close();
        canvas.drawPath(star, stroke);
      case AppGlyph.timer:
        circle(12, 13.4, 7.5);
        line(10.2, 3.4, 13.8, 3.4);
        line(12, 13.4, 12, 9.4);
        line(12, 13.4, 14.8, 15.0);
      case AppGlyph.chart:
        line(3.8, 19.6, 20.2, 19.6);
        final bars = [
          [6.4, 13.0],
          [11.0, 8.2],
          [15.6, 10.8],
        ];
        for (final bar in bars) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(bar[0], bar[1], 2.8, 19.6 - bar[1]),
              const Radius.circular(1.2),
            ),
            fill,
          );
        }
      case AppGlyph.plus:
        line(12, 5.4, 12, 18.6);
        line(5.4, 12, 18.6, 12);
      case AppGlyph.close:
        line(6.6, 6.6, 17.4, 17.4);
        line(17.4, 6.6, 6.6, 17.4);
      case AppGlyph.play:
        final play = Path()
          ..moveTo(9.2, 6.4)
          ..lineTo(18.2, 12)
          ..lineTo(9.2, 17.6)
          ..close();
        canvas.drawPath(play, fill);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
