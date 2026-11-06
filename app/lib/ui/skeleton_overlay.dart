//骨架叠加层，也是坐标映射的校验工具
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../domain/landmarks.dart';
import '../domain/pose.dart';

const Color _boneColor = Color(0xFFFF2D55);

const Color _faintColor = Color(0x99FF9800);

const Color _haloColor = Color(0xCCFFFFFF);

const double _boneWidth = 1.8;
const double _jointRadius = 2.6;

final Paint _headPaint = Paint()
  ..color = _boneColor
  ..strokeWidth = 2.0
  ..strokeJoin = StrokeJoin.round
  ..style = PaintingStyle.stroke;

const List<L> headLandmarks = [
  L.nose,
  L.leftEyeInner,
  L.leftEye,
  L.leftEyeOuter,
  L.rightEyeInner,
  L.rightEye,
  L.rightEyeOuter,
  L.leftEar,
  L.rightEar,
  L.mouthLeft,
  L.mouthRight,
];

const List<L> _eyeLandmarks = [
  L.leftEyeInner,
  L.leftEye,
  L.leftEyeOuter,
  L.rightEyeInner,
  L.rightEye,
  L.rightEyeOuter,
];

const List<(L, L)> skeletonBones = [
  (L.leftShoulder, L.rightShoulder),
  (L.leftShoulder, L.leftHip),
  (L.rightShoulder, L.rightHip),
  (L.leftHip, L.rightHip),
  (L.leftShoulder, L.leftElbow),
  (L.leftElbow, L.leftWrist),
  (L.leftWrist, L.leftPinky),
  (L.leftWrist, L.leftIndex),
  (L.leftWrist, L.leftThumb),
  (L.leftPinky, L.leftIndex),
  (L.rightShoulder, L.rightElbow),
  (L.rightElbow, L.rightWrist),
  (L.rightWrist, L.rightPinky),
  (L.rightWrist, L.rightIndex),
  (L.rightWrist, L.rightThumb),
  (L.rightPinky, L.rightIndex),
  (L.leftHip, L.leftKnee),
  (L.leftKnee, L.leftAnkle),
  (L.leftAnkle, L.leftHeel),
  (L.leftAnkle, L.leftFootIndex),
  (L.leftHeel, L.leftFootIndex),
  (L.rightHip, L.rightKnee),
  (L.rightKnee, L.rightAnkle),
  (L.rightAnkle, L.rightHeel),
  (L.rightAnkle, L.rightFootIndex),
  (L.rightHeel, L.rightFootIndex),
];

class SkeletonPainter extends CustomPainter {
  SkeletonPainter(
    this.pose, {
    required this.mirror,
    required this.visibilityThreshold,
  }) : super(repaint: pose);
  final ValueListenable<PoseFrame?> pose;
  final bool mirror;
  final double visibilityThreshold;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = pose.value;
    if (frame == null) return;
    canvas.clipRect(Offset.zero & size);
    Offset project(L index) {
      final lm = frame.landmarks[index.index];
      return Offset(
        (mirror ? 1.0 - lm.x : lm.x) * size.width,
        lm.y * size.height,
      );
    }

    bool confident(L index) => frame.visibility(index) >= visibilityThreshold;
    _paintHead(canvas, project, confident);
    final bonePaint = Paint()
      ..color = _boneColor
      ..strokeWidth = _boneWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (a, b) in skeletonBones) {
      if (!confident(a) || !confident(b)) continue;
      canvas.drawLine(project(a), project(b), bonePaint);
    }
    final dotPaint = Paint()..color = _boneColor;
    final haloPaint = Paint()..color = _haloColor;
    final faintPaint = Paint()
      ..color = _faintColor
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (final index in L.values) {
      if (headLandmarks.contains(index)) continue;
      final center = project(index);
      if (confident(index)) {
        canvas.drawCircle(center, _jointRadius + 1.4, haloPaint);
        canvas.drawCircle(center, _jointRadius, dotPaint);
      } else {
        canvas.drawCircle(center, _jointRadius, faintPaint);
      }
    }
  }

  void _paintHead(
    Canvas canvas,
    Offset Function(L) project,
    bool Function(L) confident,
  ) {
    if (!confident(L.leftEar) || !confident(L.rightEar)) return;
    final leftEar = project(L.leftEar);
    final rightEar = project(L.rightEar);
    final earSpan = (leftEar.dx - rightEar.dx).abs();
    if (earSpan < 1) return;
    final headWidth = earSpan / 0.9;
    final headHeight = headWidth * 1.43;
    final eyeYs = <double>[];
    for (final index in _eyeLandmarks) {
      if (confident(index)) eyeYs.add(project(index).dy);
    }
    final eyeY = eyeYs.isNotEmpty
        ? eyeYs.reduce((a, b) => a + b) / eyeYs.length
        : (leftEar.dy + rightEar.dy) / 2;
    final centerX = (leftEar.dx + rightEar.dx) / 2;
    final box = Rect.fromLTRB(
      centerX - headWidth * 0.52,
      eyeY - headHeight * 0.5,
      centerX + headWidth * 0.52,
      eyeY + headHeight * 0.5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(box.width * 0.18)),
      _headPaint,
    );
  }

  @override
  bool shouldRepaint(SkeletonPainter oldDelegate) =>
      oldDelegate.mirror != mirror ||
      oldDelegate.visibilityThreshold != visibilityThreshold ||
      !identical(oldDelegate.pose, pose);
}
