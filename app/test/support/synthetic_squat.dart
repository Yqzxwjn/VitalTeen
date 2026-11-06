/// 合成深蹲帧：**整个测试套件的共同地基**。
///
/// 从 `test/domain/exercises_test.dart` 提炼出来的。不提炼的代价不是重复几行，
/// 而是**两份几何会各自漂移**：动作层那边改了腿长比例，会话层这边还在用旧的，
/// 于是同一个动作在两层测试里长得不一样，而两边的断言都还是绿的。
///
/// 侧视合成帧的取舍（照抄原实现，附上为什么）：
///
/// - **膝角是唯一自变量。** 两段等长的腿，髋在上、膝在正下方，踝绕膝旋转到
///   指定夹角。于是测试里的「序列」读起来就是「膝角随时间怎么变」，
///   看的人不必反推三角关系。
/// - **躯干竖直、脚掌平放**，于是站立时 `trunk_lean` 与 `heel_rise_ratio`
///   都接近 0，基线干净 —— 想测「脚跟离地」的用例再自己改脚的点。
/// - 未显式指定的关键点（眼、耳、嘴）统统放到头顶上方：可见、两两不重合，
///   免得某个几何算子因为「两点重合」被判退化。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int frameSide = 1000;

/// 站立膝角。与 `squat.dart` 的分段线（减去 `minBend`）配套。
const double standDeg = 175.0;

const double _hipY = 0.30;
const double _legLen = 0.15;
const double _torsoLen = 0.10;

/// 造一帧深蹲姿态。
///
/// [scale] 把人整体按画面中心缩放，用来造「离得太远 / 太近」的站位。
/// 它同时缩放所有像素距离，而站姿判别用的 `lateralRatio` 是个比值 ——
/// 所以缩放**不改变机位判别**，只改变身高占比。这正是会话自检里
/// 「距离」与「机位」两项判据必须互不干扰的那条性质。
PoseFrame squatPose(
  double kneeDeg, {
  required int timestampMs,
  double scale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  const hipX = 0.50;
  const sideGap = 0.02;

  final rad = kneeDeg * math.pi / 180.0;
  final kneeY = _hipY + _legLen;
  final shinX = _legLen * math.sin(rad);
  final shinY = -_legLen * math.cos(rad);

  final leftKnee = (hipX, kneeY);
  final rightKnee = (hipX + sideGap, kneeY);
  final leftAnkle = (leftKnee.$1 + shinX, leftKnee.$2 + shinY);
  final rightAnkle = (rightKnee.$1 + shinX, rightKnee.$2 + shinY);

  // 脚跟略靠后、脚尖略靠前，两者等高 → 站立时 heel_rise_ratio ≈ 0
  (double, double) heelOf((double, double) ankle) =>
      (ankle.$1 - 0.03, ankle.$2 + 0.008);
  (double, double) toeOf((double, double) ankle) =>
      (ankle.$1 + 0.05, ankle.$2 + 0.008);

  final shoulderY = _hipY - _torsoLen;

  // 以画面中心为原点缩放。`fill` 也一起缩 —— 不缩的话头顶那堆点会留在原地，
  // 包围盒的上边缘不听缩放的话，「离得远」就测不出来了。
  (double, double) scaled((double, double) p) => (
        0.5 + (p.$1 - 0.5) * scale,
        0.5 + (p.$2 - 0.5) * scale,
      );

  return poseFrameFromPoints(
    frameWidth: frameSide,
    frameHeight: frameSide,
    timestampMs: timestampMs,
    fill: scaled((0.5, 0.06)),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {
      L.leftShoulder: (hipX, shoulderY),
      L.rightShoulder: (hipX + sideGap, shoulderY),
      L.leftElbow: (hipX - 0.02, shoulderY + 0.05),
      L.rightElbow: (hipX + sideGap + 0.02, shoulderY + 0.05),
      L.leftWrist: (hipX - 0.04, shoulderY + 0.10),
      L.rightWrist: (hipX + sideGap + 0.04, shoulderY + 0.10),
      L.leftHip: (hipX, _hipY),
      L.rightHip: (hipX + sideGap, _hipY),
      L.leftKnee: leftKnee,
      L.rightKnee: rightKnee,
      L.leftAnkle: leftAnkle,
      L.rightAnkle: rightAnkle,
      L.leftHeel: heelOf(leftAnkle),
      L.rightHeel: heelOf(rightAnkle),
      L.leftFootIndex: toeOf(leftAnkle),
      L.rightFootIndex: toeOf(rightAnkle),
    }.map((landmark, point) => MapEntry(landmark, scaled(point))),
  );
}

/// 一次完整深蹲的膝角序列：站立 → 下蹲 → 底部 → 起身 → 站立。
///
/// 每段都保持足够多帧 —— 状态机有投票窗口（5 帧）与最短停留（3 帧），
/// 一段只有一两帧的话，转移还没提交就过去了。
///
/// 分段线 = 站立 175 − minBend 45 = 130°，回升线 = 130 + 滞回 8 = 138°。
List<double> squatSequence({required double bottomDeg}) => [
      ...List.filled(16, standDeg), // STANDING
      ...List.filled(12, 140.0), // DESCENT（140 > 130，尚未到分段线）
      ...List.filled(12, bottomDeg), // BOTTOM
      ...List.filled(12, 145.0), // ASCENT（145 > 138，越过回升线）
      ...List.filled(16, standDeg), // STANDING
    ];

/// 连续站立的帧。开场与收尾都用它 —— 状态机需要足够多的静止帧才会换相。
List<PoseFrame> standFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) =>
    [
      for (var i = 0; i < count; i++)
        squatPose(standDeg, timestampMs: startTimestampMs + i * frameIntervalMs),
    ];

/// 把一串膝角变成帧流。
List<PoseFrame> framesForAngles(
  List<double> angles, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) =>
    [
      for (var i = 0; i < angles.length; i++)
        squatPose(angles[i], timestampMs: startTimestampMs + i * frameIntervalMs),
    ];

/// 一次完整深蹲的帧流。
List<PoseFrame> squatRepFrames({
  required double bottomDeg,
  required int startTimestampMs,
  int frameIntervalMs = 33,
}) =>
    framesForAngles(
      squatSequence(bottomDeg: bottomDeg),
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );
