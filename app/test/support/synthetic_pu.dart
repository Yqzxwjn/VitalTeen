/// 合成俯卧撑帧。
///
/// 与 `synthetic_squat.dart` / `synthetic_slj.dart` / `synthetic_jj.dart`
/// 同一个思路，自变量换成了俯卧撑自己的两个：
///
/// - **肘角**（`elbow_angle_L`）—— 肩-肘-腕的夹角，**180° 是全伸直、90° 是直角**。
///   它既是分段信号，也是「下得够不够深」「顶部撑直了没有」两条规则的输入。
/// - **髋点相对体线的偏离**（`body_line_offset_ratio`）—— 正 = 髋更低 = 塌腰，
///   负 = 髋更高 = 撅臀。**它带符号，而 `body_line_angle` 不带** ——
///   这一项存在本身就是这两条规则能被分开的原因（见 `features.dart`）。
///
/// ## 两个量是精确造出来的，不是「差不多」
///
/// - 肘角：肘点固定在肩点正下方，腕点由「肩→肘」方向绕肘点**精确旋转**
///   [elbowDeg] 得到，于是 `angle3(肩, 肘, 腕)` 逐位等于它。
/// - 髋偏离：**这一项只有近似**。髋点整体下移 [hipOffset]，
///   而 `body_line_offset_ratio` 的分母是躯干长（肩中点到髋中点），
///   髋一动这个分母也跟着动，所以比值不等于 [hipOffset] 本身：
///   肩中点在 (0.30, 0.50)、髋在 (0.50, 0.50 + δ) 时比值约为
///   `δ / sqrt(0.04 + δ²)` —— δ=0.04 时约 0.196。**所以测试不要拿它去卡阈值
///   边界**：要么用「明显塌腰」与「平直」两端，要么直接读特征值再断言。
///   （同 `synthetic_jj.dart` 对膝内扣那一项的交代。）
///
/// ## 为什么左右两侧给同一个值、只差一点点横向
///
/// 侧视机位下两条手臂在画面上几乎重合，真实帧里也是这样。留一条 0.01 的横向缝
/// 是为了两件事：`shoulder_width_px` 之类的分母不退化，以及门禁的
/// `lateralRatio = (肩宽 + 髋宽) / (2 × 躯干长)` 算出来是 0.05 —— 稳稳落在
/// 「侧视」那一档。两点完全重合的话，门禁会拿到一个 0 宽度，站姿判别就成了
/// 靠退化路径兜底。
///
/// 那条缝可以按 [puPose] 的 `sideGapScale` 放大，用来造出「门禁读成正视」的帧
/// —— 那正是俯卧撑要拦住的那种站位。至于为什么放大缝隙不等于「正视的俯卧撑」，
/// 见那个参数的注释。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int puFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// 肩中点、髋中点、踝中点的横坐标。三段大致等长，躯干长 0.20。
const double _shoulderX = 0.30;
const double _hipX = 0.50;
const double _ankleX = 0.72;

/// 体线所在的高度。平直时肩、髋、踝都在它上面。
const double _bodyY = 0.50;

/// 左右同侧点的横向缝隙。侧视下本来就几乎重合，见文件头。
const double puSideGap = 0.01;

/// 上臂与前臂长（归一化画幅单位）。等长即可，值本身不参与任何判定。
const double _upperArmLen = 0.10;
const double _foreArmLen = 0.10;

/// 撑起（伸直）时的肘角。
///
/// 取 175 而不是 180：180 要求肩、肘、腕严格共线，虽然 `angle3` 的 `clamp`
/// 兜得住，但一个正好落在边界上的合成值会把「阈值取 170」这类测试变成
/// 浮点比较。同 `synthetic_jj.dart` 对 175 的交代。
const double puTopElbowDeg = 175.0;

/// 下到最低时的肘角。
const double puBottomElbowDeg = 80.0;

/// 下放/撑起途中经过的肘角（两条分段线的中间）。
const double puMidElbowDeg = 130.0;

/// 造一帧俯卧撑姿态。
///
/// - [elbowDeg]：`elbow_angle_L` 与 `elbow_angle_R` 的目标值，**精确**。
/// - [hipOffset]：髋点整体下移多少（归一化画幅单位）。正 = 塌腰、负 = 撅臀。
///   与比值的关系是近似的，见文件头。
/// - [sideGapScale]：左右同侧点之间的横向缝隙的倍数（1.0 = 原样）。
///   **它唯一的用途是让门禁把那帧读成正视** —— 门禁的站位判据是
///   `(肩宽 + 髋宽) / (2 × 躯干长)`，缝隙放大到 15 倍左右就过 `frontalRatio`。
///   **这不是一个物理上站得住的「正视俯卧撑」**：正视看趴着的人，视线沿着
///   躯干，得把整副骨架换个投影才画得出，不是缩放一个系数能得到的。
///   所以它只对「门禁给出什么结论」这一件事有意义，别拿它去验姿态类特征。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame puPose({
  required int timestampMs,
  double elbowDeg = puTopElbowDeg,
  double hipOffset = 0.0,
  double sideGapScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  final hipY = _bodyY + hipOffset;
  final gap = puSideGap * sideGapScale;

  /// 由「肩→肘」方向绕肘点精确旋转 [deg] 得到腕点。
  ///
  /// 肘点在肩点正下方，所以「肩→肘」是 (0, +1)（图像 y 向下），
  /// 旋转后是 `(sin θ, -cos θ)`。θ=180° 时腕落在肘的正下方（手臂伸直朝下），
  /// θ=90° 时落在肘的正右方（上臂与前臂成直角）。
  (double, double) wristOf((double, double) elbow, double deg) {
    final rad = deg * math.pi / 180.0;
    return (
      elbow.$1 + _foreArmLen * math.sin(rad),
      elbow.$2 - _foreArmLen * math.cos(rad),
    );
  }

  final leftShoulder = (_shoulderX, _bodyY);
  final rightShoulder = (_shoulderX + gap, _bodyY);
  final leftElbow = (leftShoulder.$1, leftShoulder.$2 + _upperArmLen);
  final rightElbow = (rightShoulder.$1, rightShoulder.$2 + _upperArmLen);
  final leftHip = (_hipX, hipY);
  final rightHip = (_hipX + gap, hipY);
  final leftAnkle = (_ankleX, _bodyY);
  final rightAnkle = (_ankleX + gap, _bodyY);

  return poseFrameFromPoints(
    frameWidth: puFrameSide,
    frameHeight: puFrameSide,
    timestampMs: timestampMs,
    // 其余的点（眼、耳、嘴）堆在头前方一点：可见、不参与俯卧撑的任何特征。
    // 俯卧撑是趴着的，头在肩的前面（画面左侧），所以放在肩左边而不是头顶。
    fill: (_shoulderX - 0.08, _bodyY),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {
      L.leftShoulder: leftShoulder,
      L.rightShoulder: rightShoulder,
      L.leftElbow: leftElbow,
      L.rightElbow: rightElbow,
      L.leftWrist: wristOf(leftElbow, elbowDeg),
      L.rightWrist: wristOf(rightElbow, elbowDeg),
      L.leftHip: leftHip,
      L.rightHip: rightHip,
      L.leftKnee: (_hipX + 0.10, hipY),
      L.rightKnee: (_hipX + 0.10 + gap, hipY),
      L.leftAnkle: leftAnkle,
      L.rightAnkle: rightAnkle,
      // 脚跟与脚尖不参与俯卧撑的任何特征，但给出来更接近真实帧 ——
      // 也正因为它们给了，「左脚出画会被拦住」那类门禁测试才有反例可用。
      L.leftHeel: (leftAnkle.$1 + 0.02, leftAnkle.$2 + 0.01),
      L.rightHeel: (rightAnkle.$1 + 0.02 + gap, rightAnkle.$2 + 0.01),
      L.leftFootIndex: (leftAnkle.$1 + 0.04, leftAnkle.$2 + 0.01),
      L.rightFootIndex: (rightAnkle.$1 + 0.04 + gap, rightAnkle.$2 + 0.01),
    },
  );
}

/// 一个姿态段：连续 [count] 帧，两个自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（最低点段下得不够深、
/// 撑起段顶部没伸直），段读起来与动作一一对应。
class PuSegment {
  const PuSegment({
    this.count = 14,
    this.elbowDeg = puTopElbowDeg,
    this.hipOffset = 0.0,
  });

  final int count;
  final double elbowDeg;
  final double hipOffset;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> puFromSegments(
  List<PuSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(puPose(
        timestampMs: start + i * frameIntervalMs,
        elbowDeg: segment.elbowDeg,
        hipOffset: segment.hipOffset,
      ));
    }
  }
  return frames;
}

/// 撑在顶部的段。开场与收尾都用它。
const PuSegment puTop = PuSegment();

/// 下放/撑起途中经过的一段。
const PuSegment puMid = PuSegment(elbowDeg: puMidElbowDeg);

/// 最低点。
const PuSegment puBottom = PuSegment(elbowDeg: puBottomElbowDeg);

/// 一次标准俯卧撑：撑住 → 下放 → 最低点 → 撑起 → 回到顶部。
///
/// 回到 `TOP` 的那一帧封存一次 rep。
///
/// 中间那两段（[puMid]）不能省：状态机要在 [TrackingConfig.minDwellFrames]
/// 与投票窗口里攒够同类证据才换相，而 `TOP→BOTTOM` 不是一条边 ——
/// 少了下放段，最低点那一段会先在 DOWN 里被投票，行为与真实动作对不上。
List<PoseFrame> puRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double bottomElbowDeg = puBottomElbowDeg,
  double topElbowDeg = puTopElbowDeg,
  double hipOffset = 0.0,
}) =>
    puFromSegments(
      [
        PuSegment(elbowDeg: topElbowDeg, hipOffset: hipOffset),
        PuSegment(elbowDeg: puMidElbowDeg, hipOffset: hipOffset),
        PuSegment(elbowDeg: bottomElbowDeg, hipOffset: hipOffset),
        PuSegment(elbowDeg: puMidElbowDeg, hipOffset: hipOffset),
        PuSegment(elbowDeg: topElbowDeg, hipOffset: hipOffset),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续撑在顶部的帧（标定与热身阶段用）。
List<PoseFrame> puTopFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) =>
    [
      for (var i = 0; i < count; i++)
        puPose(timestampMs: startTimestampMs + i * frameIntervalMs),
    ];
