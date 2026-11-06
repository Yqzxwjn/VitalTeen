//TODO 前摄的镜像只在后摄上验过，真机上前摄还要再看一次
library;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../domain/landmarks.dart';
import '../domain/pose.dart';

const Map<String, String> _renamedByMlKit = {
  'leftMouth': 'mouthLeft',
  'rightMouth': 'mouthRight',
};

List<String> landmarkAlignmentProblems() {
  final problems = <String>[];

  if (PoseLandmarkType.values.length != nLandmarks) {
    problems.add(
      'ML Kit 提供 ${PoseLandmarkType.values.length} 个关键点，'
      '本项目期望 $nLandmarks 个 —— 顺序对齐无从谈起',
    );
    return problems;
  }

  for (final type in PoseLandmarkType.values) {
    final ours = L.values[type.index];
    final expected = _renamedByMlKit[type.name] ?? type.name;
    if (ours.name.toLowerCase() != expected.toLowerCase()) {
      problems.add('第 ${type.index} 位：ML Kit 是 ${type.name}，本项目是 ${ours.name}');
    }
  }
  return problems;
}

PoseFrame? poseFrameFromMlKit(
  Pose pose, {
  required int imageWidth,
  required int imageHeight,
  required InputImageRotation rotation,
  required int timestampMs,
}) {
  if (pose.landmarks.isEmpty) return null;
  final swapAxes =
      rotation == InputImageRotation.rotation90deg ||
      rotation == InputImageRotation.rotation270deg;
  final uprightWidth = swapAxes ? imageHeight : imageWidth;
  final uprightHeight = swapAxes ? imageWidth : imageHeight;
  final points = List<Landmark>.filled(
    nLandmarks,
    const Landmark(x: 0, y: 0, visibility: 0),
  );
  pose.landmarks.forEach((type, landmark) {
    final index = type.index;
    if (index < 0 || index >= nLandmarks) return;
    if (!landmark.x.isFinite || !landmark.y.isFinite) return;
    points[index] = Landmark(
      x: landmark.x / uprightWidth,
      y: landmark.y / uprightHeight,
      z: landmark.z.isFinite ? landmark.z : 0.0,
      visibility: landmark.likelihood.isFinite ? landmark.likelihood : 0.0,
    );
  });
  return PoseFrame(
    landmarks: points,
    frameWidth: uprightWidth,
    frameHeight: uprightHeight,
    timestampMs: timestampMs,
  );
}

int visibleLandmarkCount(Pose pose, {double threshold = 0.5}) =>
    pose.landmarks.values.where((l) => l.likelihood >= threshold).length;
