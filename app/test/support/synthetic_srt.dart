/// 合成坐位体前屈帧。
///
/// 与 `synthetic_su.dart` / `synthetic_squat.dart` 同一个思路，自变量换成
/// 坐位体前屈自己的两个：
///
/// - **前折角**（[srtPose] 的 `torsoLeanDeg`）—— 躯干偏离竖直多少度，
///   **0 = 坐直、越大越往前折**。它是分段信号 `hip_angle_L` 的直接来源。
/// - **膝角**（`kneeDeg`）—— `knee_angle_L` / `knee_angle_R`，**精确**。
///   `SRT_KNEE_BENT` 那条规则的输入。
///
/// ## 两个量都是闭式精确的，所以可以逐位断言
///
/// 骨架这样摆（画幅坐标，y 向下，垫面在 [srtMatY]）：
///
/// ```
///        肩
///        |  torsoLen ，与竖直方向夹角 = torsoLeanDeg
///        |
///   髋 ───┴── 膝 ────── 踝        ← 髋、膝钉在垫面线上
/// ```
///
/// - **膝点在垫面线上、在髋的正前方**，于是「髋 → 膝」这个向量恒为 +x 方向。
///   `hip_angle_L` 是肩—髋—膝那个夹角，也就是「髋 → 肩」与 +x 方向的夹角：
///   **它逐位等于 `90 − torsoLeanDeg`**（[srtHipAngleDeg]）。坐直（0°）读 90°，
///   与 `TrackingConfig.sitReachUprightDeg` 那一带的量纲对得上。
/// - **踝由膝角反解**：`踝 = 膝 + 小腿长 × (−cosθ, −sinθ)`，于是
///   `angle3(髋, 膝, 踝)` 逐位等于 `θ`。θ = 180° 时踝继续往前（腿伸直），
///   θ 变小则踝往上抬 —— 一个「把脚抬起来一点」的屈膝，形状不常见，
///   但**它要的只是那个角度**，而两条分段/判定都不看踝在哪里。
///
/// **为什么不像 `synthetic_su.dart` 那样用两圆交点解膝点**：那边是非解不可
/// （髋与踝的连线是斜的），而这里把膝钉在垫面线上之后两个量同时变成闭式解 ——
/// 测试就不必再复算一遍几何，期望值是一行减法。代价是上面那个「踝抬起来」
/// 的姿势，它对本文件要验的东西没有影响。
///
/// ## 为什么左右两侧给同一个值、只差一点点横向
///
/// 与 `synthetic_su.dart` 完全同一条理由：侧视机位下身体两侧在画面上几乎重合，
/// 留一条 [srtSideGap] 的缝是为了让分母不退化。缝只沿横向平移，**对上面那两个
/// 角一个都不影响**。
///
/// ## [srtPose] 的 `scale`：这个人占画幅多大
///
/// 与其余合成帧里的 `scale` 同一个东西，以画面中心为原点等比放大整副骨架。
/// **它不改变任何角度**，只改变人占画幅多大。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int srtFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// 垫面的高度。**髋与膝自始至终在它上面**（腿贴着垫子前伸），
/// 所以它同时是这个量纲的零点。
const double srtMatY = 0.70;

/// 髋中点的横坐标。臀在整个动作里钉在这里，腿往前（+x）伸出去。
const double srtHipX = 0.32;

/// 躯干长（归一化画幅单位）。`hip_angle_L` 只用方向、不用长度，
/// 但肩的位置与头的位置都要靠它摆，而且它决定这个人占画幅多大。
const double srtTorsoLen = 0.20;

/// 大腿长与小腿长。**与 `hip_angle_L` 无关**（那只用方向），
/// 只决定腿伸出去多远、以及屈膝时踝抬多高。
const double srtThighLen = 0.12;
const double srtShinLen = 0.12;

/// 左右同侧点的横向缝隙。侧视下本来就几乎重合，见文件头。
const double srtSideGap = 0.01;

/// 坐直（躯干竖直）。
const double srtUprightDeg = 0.0;

/// 前伸到底。
///
/// 取 50° 而不是更大：`hip_angle_L` = 90 − 50 = 40°，落在
/// `TrackingConfig.sitReachHoldingDeg`（55°）**明显之下**，
/// 于是这一帧稳稳地在「保持」那一段里，不会贴在阈值边界上。
const double srtReachDeg = 50.0;

/// 前伸途中经过的角度（两条分段线中间）。
///
/// `hip_angle_L` = 90 − 25 = 65°：低于「离开坐直」那条线（67°）、
/// 高于「开始坐回」那条线（63°）—— 它正好落在滞回带里，这是刻意的：
/// 这个姿势在真实动作里就是「正在动」，而它**不能**被读成任何一个终点。
const double srtMidDeg = 25.0;

/// 弹振借力时来回摆的两个姿势 —— **都落在前伸途中**（髋角 65° 与 57°）。
///
/// 这两条线之间才有空间摆：髋角低到 [TrackingConfig.sitReachHoldingDeg]（55°）
/// 就是「已经前伸到底」（进 `HOLDING`），高到「离开坐直」那条线（67°）就退回
/// `SIT_UPRIGHT` —— 摆动跨过任一条，状态机都会在相位之间来回跳，
/// 那时测的就成了分段本身，而不是弹振。
///
/// 所以摆幅只有 8°，但它仍然远大于 [reversalDeadband]（2°），够用。
///
/// **它们同时是 `SRT_BALLISTIC` 窗口取 `Phase.all` 的直接理由**：
/// 摆动整个发生在 `REACHING` 那一段里，前伸到底之后（`HOLDING`）人是静的。
/// [srtBallisticFrames] 摆的就是这个形状，下面「两条规则」那一组拿封存下来的
/// rep 窗口直接对比了两个相位各自数出来的掉头次数。
const double srtBallisticNearDeg = 25.0; // 髋角 65°（与 [srtMidDeg] 同姿势）
const double srtBallisticFarDeg = 33.0; // 髋角 57°

/// 腿伸直时的膝角。取 175° 而不是 180°：180° 是三点共线的奇异位置，
/// 而真人伸直的腿本来就差几度。
const double srtStraightKneeDeg = 175.0;

/// 屈膝。国标要求腿伸直，这是走形的常见做法（膝盖一弯，上身就够得更远）。
const double srtBentKneeDeg = 140.0;

/// 由前折角算出 `hip_angle_L` 的闭式值。**测试拿它当期望值** ——
/// 合成帧上真算出来的特征值应当逐位等于它。
///
/// 推导见文件头：髋→膝恒为 +x 方向，所以这个夹角就是「髋→肩」与 +x 的夹角，
/// 而「髋→肩」与竖直方向的夹角是 `torsoLeanDeg`。
double srtHipAngleDeg({double torsoLeanDeg = srtUprightDeg}) =>
    90.0 - torsoLeanDeg;

/// 造一帧坐位体前屈姿态。
///
/// - [torsoLeanDeg]：驱干偏离竖直多少度（0 = 坐直、越大越往前折）。
///   **精确**，`hip_angle_L` 逐位等于 [srtHipAngleDeg]。
/// - [kneeDeg]：`knee_angle_L` 与 `knee_angle_R` 的目标值。**精确**。
/// - [scale]：把人整体按画面中心缩放（1.0 = 原样），用来造「离得远 / 太近」
///   的站位。**它不改变任何角度**，见文件头。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame srtPose({
  required int timestampMs,
  double torsoLeanDeg = srtUprightDeg,
  double kneeDeg = srtStraightKneeDeg,
  double scale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  // 膝角 0 与 180 都会让踝退到膝上或与髋膝共线，闭式解的两个端点没有意义。
  // 真实动作里不会出现，出现即是调用方写错了参数 —— 与其造出一个退化的
  // 姿势让下游静默算错，不如在原地响亮地说清楚。
  assert(
    kneeDeg > 1.0 && kneeDeg < 180.0,
    '屈膝角必须落在 (1, 180) 开区间里（收到 $kneeDeg），'
    '两端会让踝退到膝上或三点共线',
  );

  final gap = srtSideGap;
  final leanRad = torsoLeanDeg * math.pi / 180.0;
  final kneeRad = kneeDeg * math.pi / 180.0;

  // 髋、膝都钉在垫面线上，腿沿 +x 伸出去 —— 见文件头的示意图。
  final hipX = srtHipX;
  final kneeX = hipX + srtThighLen;

  // 踝由膝角反解：膝→踝 与 膝→髋（即 −x）的夹角就是膝角。
  final ankleX = kneeX - srtShinLen * math.cos(kneeRad);
  final ankleY = srtMatY - srtShinLen * math.sin(kneeRad);

  // 肩绕髋转：前折角就是从竖直方向往 +x 那一侧转过的角度。
  final shoulderX = hipX + srtTorsoLen * math.sin(leanRad);
  final shoulderY = srtMatY - srtTorsoLen * math.cos(leanRad);

  // 头接着躯干往远离髋的那一头长一点。它不参与任何特征，但给出来更接近
  // 真实帧（也让「头顶出画了」这类门禁测试有反例可用）。
  final headX = shoulderX + 0.08 * (shoulderX - hipX) / srtTorsoLen;
  final headY = shoulderY + 0.08 * (shoulderY - srtMatY) / srtTorsoLen;

  final points = <L, (double, double)>{
    L.leftShoulder: (shoulderX, shoulderY),
    L.rightShoulder: (shoulderX + gap, shoulderY),
    // 手臂往前下方伸出去一点（够向脚尖），不参与任何特征。
    L.leftElbow: (shoulderX + 0.06, shoulderY + 0.04),
    L.rightElbow: (shoulderX + 0.06 + gap, shoulderY + 0.04),
    L.leftWrist: (shoulderX + 0.12, shoulderY + 0.06),
    L.rightWrist: (shoulderX + 0.12 + gap, shoulderY + 0.06),
    L.leftHip: (hipX, srtMatY),
    L.rightHip: (hipX + gap, srtMatY),
    L.leftKnee: (kneeX, srtMatY),
    L.rightKnee: (kneeX + gap, srtMatY),
    L.leftAnkle: (ankleX, ankleY),
    L.rightAnkle: (ankleX + gap, ankleY),
    // 脚跟与脚尖不参与坐位体前屈的任何特征，但给出来更接近真实帧。
    L.leftHeel: (ankleX - 0.02, ankleY - 0.01),
    L.rightHeel: (ankleX - 0.02 + gap, ankleY - 0.01),
    L.leftFootIndex: (ankleX + 0.02, ankleY - 0.01),
    L.rightFootIndex: (ankleX + 0.02 + gap, ankleY - 0.01),
  };

  // 以画面中心为原点缩放。**所有点一起缩** —— 漏掉哪一处，那一处在
  // 「离得远」的合成帧里就会留在原地，包围盒不听缩放的话，距离就测不出来了。
  // 与 `synthetic_su.dart` 同一条：放在最后一步，而不是把那些长度常量
  // 逐个乘一遍（那样迟早漏一处附加偏移）。
  (double, double) at((double, double) p) => (
        0.5 + (p.$1 - 0.5) * scale,
        0.5 + (p.$2 - 0.5) * scale,
      );

  return poseFrameFromPoints(
    frameWidth: srtFrameSide,
    frameHeight: srtFrameSide,
    timestampMs: timestampMs,
    fill: at((headX, headY)),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {for (final e in points.entries) e.key: at(e.value)},
  );
}

/// 一个姿态段：连续 [count] 帧，自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（前伸途中膝盖松了、
/// 保持那一段在抖），段读起来与动作一一对应。
class SrtSegment {
  const SrtSegment({
    this.count = 14,
    this.torsoLeanDeg = srtUprightDeg,
    this.kneeDeg = srtStraightKneeDeg,
    this.scale = 1.0,
  });

  final int count;
  final double torsoLeanDeg;
  final double kneeDeg;
  final double scale;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> srtFromSegments(
  List<SrtSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(srtPose(
        timestampMs: start + i * frameIntervalMs,
        torsoLeanDeg: segment.torsoLeanDeg,
        kneeDeg: segment.kneeDeg,
        scale: segment.scale,
      ));
    }
  }
  return frames;
}

/// 坐直的一段。`SIT_UPRIGHT` 是坐位体前屈的 `restingState`，
/// 开场与收尾都用它。
const SrtSegment srtUpright = SrtSegment(torsoLeanDeg: srtUprightDeg);

/// 前伸途中经过的一段（两条分段线之间）。
const SrtSegment srtMid = SrtSegment(torsoLeanDeg: srtMidDeg);

/// 前伸到底的一段。
const SrtSegment srtReach = SrtSegment(torsoLeanDeg: srtReachDeg);

/// 一次标准坐位体前屈：坐直 → 前伸 → 保持 → 坐回 → 坐直。
///
/// 回到 `SIT_UPRIGHT` 的那一帧封存一次 rep。
///
/// 中间那两段（[srtMid]）不能省：状态机要在 [TrackingConfig.minDwellFrames]
/// 与投票窗口里攒够同类证据才换相，而 `SIT_UPRIGHT→HOLDING` 不是一条边 ——
/// 少了前伸段，保持那一段会先在 `REACHING` 里被投票，行为与真实动作对不上。
///
/// [kneeDeg] 对**所有**段生效。要造「只有某一段屈膝」，用 [srtFromSegments]
/// 自己拼，或者用 [srtKneeBentInReachingFrames]。
List<PoseFrame> srtRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double uprightDeg = srtUprightDeg,
  double reachDeg = srtReachDeg,
  double kneeDeg = srtStraightKneeDeg,
  double scale = 1.0,
}) =>
    srtFromSegments(
      [
        SrtSegment(torsoLeanDeg: uprightDeg, kneeDeg: kneeDeg, scale: scale),
        SrtSegment(torsoLeanDeg: srtMidDeg, kneeDeg: kneeDeg, scale: scale),
        SrtSegment(torsoLeanDeg: reachDeg, kneeDeg: kneeDeg, scale: scale),
        SrtSegment(torsoLeanDeg: srtMidDeg, kneeDeg: kneeDeg, scale: scale),
        SrtSegment(torsoLeanDeg: uprightDeg, kneeDeg: kneeDeg, scale: scale),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 一次「前伸途中膝盖松了一下、到底之后又伸直了」的动作。
///
/// **这一份是 `SRT_KNEE_BENT` 那条规则窗口取 `Phase.bottom` 的理由。**
/// 膝盖只在前伸段弯，保持段是直的 —— 窗口取整段的话它会被判屈膝，
/// 而前伸途中膝盖松一下根本不影响成绩。
List<PoseFrame> srtKneeBentInReachingFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
}) =>
    srtFromSegments(
      [
        const SrtSegment(),
        const SrtSegment(torsoLeanDeg: srtMidDeg, kneeDeg: srtBentKneeDeg),
        const SrtSegment(torsoLeanDeg: srtReachDeg),
        const SrtSegment(torsoLeanDeg: srtMidDeg),
        const SrtSegment(),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 一次「靠来回弹把上身甩出去」的动作。
///
/// 形状与 [srtRepFrames] **只有一处不同**：前伸途中的那一段来回摆
///（每条边 3 帧、在 [srtBallisticNearDeg] 与 [srtBallisticFarDeg] 之间摆，
/// 8° 的摆幅远大于 2° 死区）。于是两种人**前伸到底的角度完全一样**
///（都到 [srtReachDeg]），只有序列的形状分得开 —— 这正是 `SRT_BALLISTIC`
/// 必须存在、而不能拿一条深度类规则顶替的理由。
///
/// **摆动只出现在 `REACHING` 那一段里**（理由见 [srtBallisticNearDeg]），
/// 前伸到底之后人是静的 —— 所以「只看 `Phase.bottom`」的窗口在这条序列上
/// 数出来一次掉头都没有。这个形状是 `sit_reach.dart` 文件头那句
/// 「抖到够远了就停住」的可执行版本。
List<PoseFrame> srtBallisticFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  int swings = 3,
}) =>
    srtFromSegments(
      [
        const SrtSegment(),
        const SrtSegment(torsoLeanDeg: srtMidDeg),
        for (var i = 0; i < swings * 2; i++)
          SrtSegment(
            count: 3,
            torsoLeanDeg:
                i.isEven ? srtBallisticNearDeg : srtBallisticFarDeg,
          ),
        const SrtSegment(torsoLeanDeg: srtReachDeg),
        const SrtSegment(torsoLeanDeg: srtMidDeg),
        const SrtSegment(),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续坐直的帧。`SIT_UPRIGHT` 是状态机的 `restingState`，
/// 也是「一次做完」那一刻的姿势 —— 领域层的分段测试用它当收势。
List<PoseFrame> srtUprightFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        srtPose(
          timestampMs: startTimestampMs + i * frameIntervalMs,
          scale: scale,
        ),
    ];
