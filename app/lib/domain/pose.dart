//姿态帧对象，坐标铁律的执行点
library;

import 'dart:convert';

import 'geometry.dart';
import 'landmarks.dart';

class PoseFrameException implements Exception {
  const PoseFrameException(this.message);
  final String message;
  @override
  String toString() => 'PoseFrameException: $message';
}

class Landmark {
  const Landmark({
    required this.x,
    required this.y,
    this.z = 0.0,
    this.visibility = 1.0,
  });
  final double x;
  final double y;
  final double z;
  final double visibility;
  @override
  String toString() => 'Landmark($x, $y, z=$z, vis=$visibility)';
}

class PoseFrame {
  factory PoseFrame({
    required List<Landmark> landmarks,
    required int frameWidth,
    required int frameHeight,
    required int timestampMs,
    List<Landmark>? worldLandmarks,
  }) {
    if (landmarks.length != nLandmarks) {
      throw PoseFrameException(
        'landmarks 必须是 $nLandmarks 个，收到 ${landmarks.length} 个',
      );
    }
    if (worldLandmarks != null && worldLandmarks.length != nLandmarks) {
      throw PoseFrameException(
        'worldLandmarks 必须是 $nLandmarks 个，收到 ${worldLandmarks.length} 个',
      );
    }
    if (frameWidth <= 0 || frameHeight <= 0) {
      throw const PoseFrameException('frameWidth / frameHeight 必须为正数');
    }
    return PoseFrame._(
      landmarks: landmarks,
      worldLandmarks: worldLandmarks,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      timestampMs: timestampMs,
    );
  }
  const PoseFrame._({
    required this.landmarks,
    required this.worldLandmarks,
    required this.frameWidth,
    required this.frameHeight,
    required this.timestampMs,
  });
  final List<Landmark> landmarks;
  final List<Landmark>? worldLandmarks;
  final int frameWidth;
  final int frameHeight;
  final int timestampMs;

  PixelPoint pixel(L index) {
    final lm = landmarks[index.index];
    return PixelPoint(lm.x * frameWidth, lm.y * frameHeight);
  }

  PixelPoint pixelMid(L a, L b) {
    final pa = pixel(a);
    final pb = pixel(b);
    return PixelPoint((pa.x + pb.x) / 2.0, (pa.y + pb.y) / 2.0);
  }
  double pixelSpan(L a, L b) => distance(pixel(a), pixel(b));
  bool get hasWorld => worldLandmarks != null;

  (double, double, double)? world(L index) {
    final world = worldLandmarks;
    if (world == null) return null;
    final lm = world[index.index];
    return (lm.x, lm.y, lm.z);
  }
  double visibility(L index) => landmarks[index.index].visibility;
  bool isVisible(L index, double threshold) =>
      landmarks[index.index].visibility >= threshold;
  bool allVisible(Iterable<L> indices, double threshold) =>
      indices.every((i) => isVisible(i, threshold));

  double meanVisibility([Iterable<L>? indices]) {
    final idxs = indices?.toList() ?? L.values;
    if (idxs.isEmpty) {
      throw const PoseFrameException('meanVisibility 的指标集合为空，均值无定义');
    }
    var sum = 0.0;
    for (final i in idxs) {
      sum += visibility(i);
    }
    return sum / idxs.length;
  }
  double torsoLength() => distance(
        pixelMid(L.leftShoulder, L.rightShoulder),
        pixelMid(L.leftHip, L.rightHip),
      );
  double shoulderWidth() => pixelSpan(L.leftShoulder, L.rightShoulder);
}

double jointAngle(PoseFrame frame, L a, L vertex, L c) =>
    angle3(frame.pixel(a), frame.pixel(vertex), frame.pixel(c));

List<PoseFrame> framesFromJson(
  List<dynamic> payload, {
  required int frameWidth,
  required int frameHeight,
}) {
  return payload.map((raw) {
    final map = raw as Map<String, dynamic>;
    return PoseFrame(
      landmarks: _landmarksFromJson(map['landmarks'] as List<dynamic>),
      worldLandmarks: map['world_landmarks'] == null
          ? null
          : _landmarksFromJson(map['world_landmarks'] as List<dynamic>),
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      timestampMs: (map['timestamp_ms'] as num?)?.toInt() ?? 0,
    );
  }).toList();
}

List<Landmark> _landmarksFromJson(List<dynamic> items) => items.map((item) {
      final p = item as Map<String, dynamic>;
      return Landmark(
        x: (p['x'] as num).toDouble(),
        y: (p['y'] as num).toDouble(),
        z: (p['z'] as num?)?.toDouble() ?? 0.0,
        visibility: (p['visibility'] as num?)?.toDouble() ?? 1.0,
      );
    }).toList();

List<PoseFrame> framesFromJsonString(
  String source, {
  required int frameWidth,
  required int frameHeight,
}) =>
    framesFromJson(
      jsonDecode(source) as List<dynamic>,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );

PoseFrame poseFrameFromPoints({
  required Map<L, (double, double)> points,
  required int frameWidth,
  required int frameHeight,
  int timestampMs = 0,
  (double, double) fill = (0.5, 0.5),
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  final landmarks = <Landmark>[];
  for (final index in L.values) {
    final point = points[index] ?? fill;
    landmarks.add(Landmark(
      x: point.$1,
      y: point.$2,
      visibility: visibilityOverrides?[index] ?? visibility,
    ));
  }
  return PoseFrame(
    landmarks: landmarks,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
    timestampMs: timestampMs,
  );
}
