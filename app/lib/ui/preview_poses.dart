//预览人形的姿势表（海报，不是判定依据）
library;

import 'package:flutter/foundation.dart';

enum PreviewView {
  side,
  front,
}

@immutable
class PreviewPose {
  const PreviewPose({
    this.trunk = 0,
    this.hip = 0,
    this.knee = 0,
    this.spread = 0,
    this.shoulder = 0,
    this.elbow = 0,
    this.hipR,
    this.kneeR,
    this.spreadR,
    this.shoulderR,
    this.elbowR,
  });
  final double trunk;
  final double hip;
  final double knee;
  final double spread;
  final double shoulder;
  final double elbow;
  final double? hipR;
  final double? kneeR;
  final double? spreadR;
  final double? shoulderR;
  final double? elbowR;
  double get hipRight => hipR ?? hip;
  double get kneeRight => kneeR ?? knee;
  double get spreadRight => spreadR ?? spread;
  double get shoulderRight => shoulderR ?? shoulder;
  double get elbowRight => elbowR ?? elbow;
}

@immutable
class PreviewFrame {
  const PreviewFrame({
    required this.pose,
    required this.label,
    this.lift = 0,
    this.drift = 0,
  });
  final PreviewPose pose;
  final String label;
  final double lift;
  final double drift;
}

const Map<String, int> kPreviewThumbnailIndex = {
  'SQUAT': 2,
  'SLJ': 3,
  'JJ': 2,
  'ROPE': 1,
  'PU': 2,
  'PULLUP': 2,
  'PLANK': 0,
  'SU': 2,
  'SRT': 2,
};

PreviewFrame? previewThumbnail(String code) {
  final frames = kPreviewFrames[code];
  if (frames == null || frames.isEmpty) return null;
  final index = kPreviewThumbnailIndex[code];
  if (index == null) return null;
  assert(index >= 0 && index < frames.length, '$code 的缩略图索引 $index 越界');
  if (index < 0 || index >= frames.length) return null;
  return frames[index];
}

PreviewView previewViewFor(String code) =>
    code == 'JJ' ? PreviewView.front : PreviewView.side;

const Map<String, List<PreviewFrame>> kPreviewFrames = {
  'SQUAT': [
    PreviewFrame(pose: PreviewPose(), label: '站立'),
    PreviewFrame(
      pose: PreviewPose(trunk: 26, hip: 48, knee: 72, shoulder: 34, elbow: 16),
      label: '下蹲',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 36, hip: 82, knee: 96, shoulder: 78, elbow: 8),
      label: '最低点',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 16, hip: 32, knee: 52, shoulder: 44, elbow: 14),
      label: '起身',
    ),
  ],
  'SLJ': [
    PreviewFrame(pose: PreviewPose(), label: '站立'),
    PreviewFrame(
      pose: PreviewPose(trunk: 34, hip: 58, knee: 78, shoulder: -46, elbow: 12),
      label: '预蹲',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 4, hip: 8, knee: 8, shoulder: 118, elbow: 6),
      label: '蹬伸',
      lift: 0.02,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 12, hip: 52, knee: 64, shoulder: 152, elbow: 16),
      label: '腾空',
      lift: 0.34,
      drift: 0.42,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 30, hip: 62, knee: 84, shoulder: 40, elbow: 20),
      label: '落地缓冲',
      drift: 0.62,
    ),
  ],
  'JJ': [
    PreviewFrame(pose: PreviewPose(), label: '并腿站立'),
    PreviewFrame(
      pose: PreviewPose(shoulder: 42, spread: 20),
      label: '起跳',
      lift: 0.10,
    ),
    PreviewFrame(
      pose: PreviewPose(shoulder: 158, spread: 44),
      label: '分腿展臂',
      lift: 0.26,
    ),
    PreviewFrame(
      pose: PreviewPose(shoulder: 58, spread: 26),
      label: '落地合拢',
      lift: 0.05,
    ),
  ],
  'ROPE': [
    PreviewFrame(
      pose: PreviewPose(shoulder: 8, elbow: 62),
      label: '双脚着地',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 2, hip: 40, knee: 66, shoulder: 4, elbow: 56),
      label: '腾空',
      lift: 0.17,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 10, hip: 32, knee: 60, shoulder: 6, elbow: 58),
      label: '落地缓冲',
      lift: 0.02,
    ),
  ],
  'PU': [
    PreviewFrame(
      pose: PreviewPose(trunk: 70, hip: -70),
      label: '支撑',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 72, hip: -72, shoulder: -18, elbow: 41),
      label: '下放',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 76, hip: -76, shoulder: -35, elbow: 74),
      label: '最低点',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 71, hip: -71, shoulder: -12, elbow: 30),
      label: '撑起',
    ),
  ],
  'PULLUP': [
    PreviewFrame(
      pose: PreviewPose(hip: 6, knee: 26, shoulder: 174, elbow: 6),
      label: '直臂悬垂',
      lift: 0.73,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 6, hip: 26, knee: 40, shoulder: 168, elbow: 62),
      label: '上拉',
      lift: 0.79,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 10, hip: 40, knee: 54, shoulder: 160, elbow: 104),
      label: '顶部',
      lift: 0.87,
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 4, hip: 20, knee: 36, shoulder: 170, elbow: 44),
      label: '下放',
      lift: 0.75,
    ),
  ],
  'PLANK': [
    PreviewFrame(
      pose: PreviewPose(trunk: 88, hip: -78, shoulder: 0, elbow: 92),
      label: '撑住',
    ),
    PreviewFrame(pose: PreviewPose(), label: '没在撑'),
  ],
  'SU': [
    PreviewFrame(
      pose: PreviewPose(trunk: -80, hip: 135, knee: 90, shoulder: 96),
      label: '仰卧',
    ),
    PreviewFrame(
      pose: PreviewPose(
        trunk: -20, hip: 135, knee: 90, shoulder: 60, elbow: 20,
      ),
      label: '起身',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 20, hip: 135, knee: 90, shoulder: 67),
      label: '坐起',
    ),
    PreviewFrame(
      pose: PreviewPose(
        trunk: -46, hip: 135, knee: 90, shoulder: 80, elbow: 10,
      ),
      label: '躺回',
    ),
  ],
  'SRT': [
    PreviewFrame(
      pose: PreviewPose(hip: 90, shoulder: 28),
      label: '坐直',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 34, hip: 90, shoulder: 59),
      label: '前伸',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 62, hip: 90, shoulder: 70, elbow: 10),
      label: '保持',
    ),
    PreviewFrame(
      pose: PreviewPose(trunk: 26, hip: 90, shoulder: 40),
      label: '坐回',
    ),
  ],
};
