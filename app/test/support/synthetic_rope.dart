/// 合成跳绳帧。
///
/// 与另外五个合成器同一个思路，自变量换成跳绳自己的四个：
///
/// - **离地高度**（[ropePose] 的 `lift`）—— 脚尖抬离站立位置多少（归一化画幅
///   单位）。它是分段信号 `foot_height_ratio` 的唯一来源，也是这个动作里
///   唯一一个**同时改变特征值与它在画面里位置**的自变量（见下面那一节）。
/// - **屈膝角**（`kneeDeg`）—— `knee_angle_L` / `knee_angle_R`，**精确**。
///   它既是 `ROPE_LOW_BUFFER` 的输入，也是 `CUSHION → GROUND` 那条边
///   后半句的输入。
/// - **两脚尖高度差**（`toeGap`）—— `foot_gap_ratio` 的来源，**精确**。
///   `ROPE_SINGLE_LEG` 的输入。
/// - **躯干倾角**（`trunkDeg`）—— `trunk_lean`，**精确**（带符号）。
///   `ROPE_TRUNK_LEAN` 的输入。
///
/// ## 关键的一条构造不变量：屈膝**不动脚尖**
///
/// 这个合成器和别的都不一样：它把**地面接触点钉死**，让屈膝去抬降髋部
/// （`hip = 脚尖 − 踝高 − 2·大腿长·cos((180° − 膝角)/2)`），而不是像
/// `synthetic_su.dart` 那样钉住髋、去解踝。
///
/// 理由是跳绳的分段信号是**脚尖在画面里的高度**：要是屈膝也把脚尖抬高，
/// 「这一跳离了地没有」与「这一跳屈了膝没有」就会互相污染 —— 一次落地缓冲
/// 会被读成一次起跳，而真机上这两件事是独立的（腿弯下去，脚还踩在地上）。
/// 合成帧必须先把这条物理事实摆对，否则下面所有断言验的都是合成器自己的
/// 几何，而不是动作定义。
///
/// 于是：`kneeDeg` 只改髋以上的高度，**一个像素都不动脚尖**。
/// 反过来，`lift` 把整副骨架（含脚尖）一起平移上去 —— 平移不改变任何
/// 关节角、也不改变任何比值，所以两个自变量互不干扰。
///
/// ## 期望值：为什么 `foot_height_ratio` 的闭式值里出现 `scale`
///
/// 别的合成器都能说「`scale` 不改变任何比值」。**这个不行，而且这不是缺陷
/// —— 是这个特征的定义**：`foot_height_ratio` 的分子是「画面下缘到脚尖」的
/// 像素距离，而画面下缘**不跟着人缩放**（缩放以画面中心为原点）。所以同一个
/// 站姿在 `scale` 更大时（人更大、脚尖离画面下缘更近）读数更小。
///
/// [ropeFootHeightRatio] 把这件事算全了，测试拿它当期望值即可，不必自己列式：
///
/// ```
/// 脚尖（像素） = 画面边长 × (0.5 + (y − 0.5)·scale)
/// 比值        = (画面边长 − 脚尖) / (画面边长 × 躯干长 × scale)
/// ```
///
/// 另外三个量（`foot_gap_ratio` 是差值、`knee_angle_*` 与 `trunk_lean` 是夹角）
/// 都**与 `scale` 无关**，与其余合成器一致。
///
/// ## 左右两侧的横向缝
///
/// 与 `synthetic_su.dart` 同款：侧视下两侧几乎重合，留一条 0.01 的缝让
/// `shoulder_width_px` 之类的分母不退化，并让门禁的 `lateralRatio` 落在
/// 「侧视」那一档。缝可以按 `sideGapScale` 放大，用来造「门禁读成正视」的帧
/// （跳绳要拦住那种站位：正视下脚尖的高度差与离地高度都失去意义，
/// 判据是二元的，见 `rope_spec` 的注释）。
///
/// 缝**不改变上面任何一个量**：左右整体平移，中点只跟着平移，差与距离不变。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int ropeFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// **站立时脚尖所在的高度。** 它是这个合成器的地面，也是「离地」的零点。
///
/// 取 0.80 而不是贴着画面下缘：脚尖下方留出五分之一画幅，人才不会一抬脚
/// 就顶到画面边上（门禁的出画判据会跟着响）。真实机位里手机架起来时也是
/// 这样 —— 地面在画面偏下的位置，不是正好贴边。
const double _groundY = 0.80;

/// 踝高于脚尖多少（脚背那一截）。脚尖是接触点，踝在它上方。
const double _ankleRise = 0.06;

/// 大腿长与小腿长。两侧等长，于是膝角有一个闭式解（同 `synthetic_su.dart`）。
/// 站直时踝到髋的竖直距离是 2×它 = 0.26。
const double _legLen = 0.13;

/// 躯干长（归一化画幅单位）。特征用它当分母，所以它必须是真的躯干长：
/// 肩点解在以髋为圆心、半径为它的圆上。
const double _torsoLen = 0.20;

/// 左右同侧点的横向缝隙。侧视下本来就几乎重合，见文件头。
const double ropeSideGap = 0.01;

/// 站立、双腿伸直、躯干竖直、两脚等高的那一帧的三个自变量。
const double ropeStandDeg = 178.0;

/// 腾空高度：比站立时高这么多（归一化画幅单位）才算跳起来。
///
/// 0.06 = 躯干长的 30%，换算成比值是 +0.30 —— 远在分段线
///（`ropeTakeoffRatio` = 0.10）之上，也给真机留了「跳得不高但确实离地」的余地。
const double ropeAirborne = 0.06;

/// 落地缓冲那一段的离地高度：刚够落进落地线与稳定线之间。
///
/// 0.008 换算成比值是站立基线上 +0.04 —— 低于落地线（+0.05）、高于稳定线
/// （+0.02），于是它**只能**落进 `CUSHION`：既不会退回 `AIR`，
/// 也不会立刻封存。
const double ropeCushionLift = 0.008;

/// 缓冲结束、站回地面时的离地高度（比值上 +0.01，低于稳定线 +0.02）。
const double ropeSettledLift = 0.002;

/// 落地缓冲的屈膝角。见 [ropeFlexedDeg] 的说明。
const double ropeFlexedDeg = 150.0;

/// 由离地高度与两脚尖差算出 `foot_height_ratio` 的闭式值。
///
/// 见文件头那一节：**这个量依赖 `scale`**，与别的合成器不同。
double ropeFootHeightRatio({
  double lift = 0.0,
  double toeGap = 0.0,
  double scale = 1.0,
}) {
  final toeMidY = _groundY + toeGap / 2 - lift;
  final toePx = ropeFrameSide * (0.5 + (toeMidY - 0.5) * scale);
  final torsoPx = ropeFrameSide * _torsoLen * scale;
  return (ropeFrameSide - toePx) / torsoPx;
}

/// 由两脚尖高度差算出 `foot_gap_ratio` 的闭式值。**与 `scale` 无关**
/// （分子分母同时被缩放约掉）。
double ropeFootGapRatio({double toeGap = 0.0}) => toeGap / _torsoLen;

/// 造一帧跳绳姿态。
///
/// - [lift]：脚尖抬离站立位置多少（归一化画幅单位）。正 = 离地。**精确**。
/// - [kneeDeg]：`knee_angle_L` 与 `knee_angle_R` 的目标值，**精确**。
///   **它不改脚尖的高度**（见文件头）。
/// - [toeGap]：两只脚尖的高度差（归一化画幅单位），正 = 右脚更低。
///   `foot_gap_ratio` 恰好等于它除以躯干长。**精确**。
/// - [trunkDeg]：躯干与竖直方向的夹角（度），正 = 肩往**画面右侧**偏
///   （`tiltFromVertical(髋中点, 肩中点)` 的正方向）。**精确**。
/// - [scale]：把人整体按画面中心缩放（1.0 = 原样），用来造「离得太远 /
///   太近」的站位。**它改变 `foot_height_ratio`**，理由见文件头。
/// - [sideGapScale]：左右横向缝的倍数，用来造「门禁读成正视」的帧。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame ropePose({
  required int timestampMs,
  double lift = 0.0,
  double kneeDeg = ropeStandDeg,
  double toeGap = 0.0,
  double trunkDeg = 0.0,
  double scale = 1.0,
  double sideGapScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  // 膝角太小会让膝点解不出来（两段腿折成一团），真实动作里不会出现。
  assert(kneeDeg >= 30.0 && kneeDeg <= 180.0, '膝角超出合成几何的范围：$kneeDeg');

  final gap = ropeSideGap * sideGapScale;

  // 地面接触点钉死，屈膝只抬降髋。见文件头那条构造不变量。
  final kneeRad = kneeDeg * math.pi / 180.0;
  final hipToAnkle = 2 * _legLen * math.cos((math.pi - kneeRad) / 2);

  final leftToeY = _groundY - lift;
  final rightToeY = leftToeY + toeGap;
  // 踝与脚尖在同一个水平位置上（合成帧不画脚的前后方向：跳绳的两个判定
  // 都只看脚尖的**高度**，脚尖在前后方向上落在哪里不影响任何特征）。
  final leftAnkleY = leftToeY - _ankleRise;
  final rightAnkleY = rightToeY - _ankleRise;

  // 髋在踝的正上方、相距 `hipToAnkle`。屈膝越深，髋越低 —— 这正是落地缓冲
  // 在真人身上发生的事（脚踩地，身体沉下去）。
  final leftHipY = leftAnkleY - hipToAnkle;
  final rightHipY = rightAnkleY - hipToAnkle;
  final hipY = (leftHipY + rightHipY) / 2;
  const hipX = 0.50;

  // 膝点在髋-踝的中垂线上，向画面右侧（人面朝的方向）鼓出去。两段等长，
  // 于是它到两端的距离都等于 `_legLen`（`knee_angle` 逐位精确）。
  final leftKneeX = hipX + _legLen * math.sin((math.pi - kneeRad) / 2);
  final rightKneeX = leftKneeX + gap;
  final leftKneeY = (leftHipY + leftAnkleY) / 2;
  final rightKneeY = (rightHipY + rightAnkleY) / 2;

  // 躯干：从髋起、按 `trunkDeg` 倾斜、长度恰好是躯干长。于是
  // `trunk_lean` 逐位等于 `trunkDeg`，`torso_length_px` 逐位等于躯干长的像素值。
  final trunkRad = trunkDeg * math.pi / 180.0;
  final shoulderX = hipX + _torsoLen * math.sin(trunkRad);
  final shoulderY = hipY - _torsoLen * math.cos(trunkRad);

  // 头接着躯干往远离髋的那一头长。不参与跳绳的任何特征，给出来只是为了
  // 更接近真实帧、也让「头出没出画」那类门禁测试有反例可用。
  final headX = shoulderX + 0.08 * math.sin(trunkRad);
  final headY = shoulderY - 0.08 * math.cos(trunkRad);

  final points = <L, (double, double)>{
    L.leftShoulder: (shoulderX, shoulderY),
    L.rightShoulder: (shoulderX + gap, shoulderY),
    // 手肘手腕垂在身体两侧。跳绳的三条判定一条都不碰它们，但真实帧里
    // 它们一定在，而且 `shoulder_angle_min`（本动作不用）依赖它们。
    L.leftElbow: (shoulderX + 0.02, shoulderY + 0.07),
    L.rightElbow: (shoulderX + gap + 0.02, shoulderY + 0.07),
    L.leftWrist: (shoulderX + 0.03, shoulderY + 0.14),
    L.rightWrist: (shoulderX + gap + 0.03, shoulderY + 0.14),
    L.leftHip: (hipX, leftHipY),
    L.rightHip: (hipX + gap, rightHipY),
    L.leftKnee: (leftKneeX, leftKneeY),
    L.rightKnee: (rightKneeX, rightKneeY),
    L.leftAnkle: (hipX, leftAnkleY),
    L.rightAnkle: (hipX + gap, rightAnkleY),
    // 脚跟：踮着脚跳的人脚跟是抬起来的，给一点点余量比贴着地面真实。
    // 跳绳没有任何特征用它（`requiredLandmarks` 里也没有右脚跟）。
    L.leftHeel: (hipX - 0.03, leftToeY - 0.01),
    L.rightHeel: (hipX + gap - 0.03, rightToeY - 0.01),
    L.leftFootIndex: (hipX + 0.03, leftToeY),
    L.rightFootIndex: (hipX + gap + 0.03, rightToeY),
  };

  // 以画面中心为原点缩放，**所有点与 `fill` 一起缩**（漏掉 `fill` 的话
  // 头顶那堆点会留在原地，包围盒的上边缘不听缩放）。
  (double, double) at((double, double) p) => (
        0.5 + (p.$1 - 0.5) * scale,
        0.5 + (p.$2 - 0.5) * scale,
      );

  return poseFrameFromPoints(
    frameWidth: ropeFrameSide,
    frameHeight: ropeFrameSide,
    timestampMs: timestampMs,
    fill: at((headX, headY)),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {for (final e in points.entries) e.key: at(e.value)},
  );
}

/// 一个姿态段：连续 [count] 帧，四个自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（落地那一下没屈膝、
/// 整段有一只脚悬着），段读起来与动作一一对应。
class RopeSegment {
  const RopeSegment({
    this.count = 4,
    this.lift = 0.0,
    this.kneeDeg = ropeStandDeg,
    this.toeGap = 0.0,
    this.trunkDeg = 0.0,
    this.scale = 1.0,
  });

  final int count;
  final double lift;
  final double kneeDeg;
  final double toeGap;
  final double trunkDeg;
  final double scale;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> ropeFromSegments(
  List<RopeSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(ropePose(
        timestampMs: start + i * frameIntervalMs,
        lift: segment.lift,
        kneeDeg: segment.kneeDeg,
        toeGap: segment.toeGap,
        trunkDeg: segment.trunkDeg,
        scale: segment.scale,
      ));
    }
  }
  return frames;
}

/// 站着不动的一段。`GROUND` 是跳绳的 `restingState`，开场与两次跳之间都是它。
const RopeSegment ropeStanding = RopeSegment(kneeDeg: ropeStandDeg);

/// 腾空的一段（腿基本伸直，跳起来的人本来也是这样）。
const RopeSegment ropeAir = RopeSegment(
  lift: ropeAirborne,
  kneeDeg: 175.0,
);

/// 落地缓冲的一段：脚尖落回地面附近，**膝角屈到 [ropeFlexedDeg]**。
///
/// 腿弯下去、脚不动 —— 这是跳绳这个动作里唯一一处「屈膝而脚不离地」的地方，
/// `ROPE_LOW_BUFFER` 判的就是它。
const RopeSegment ropeCushion = RopeSegment(
  lift: ropeCushionLift,
  kneeDeg: ropeFlexedDeg,
);

/// 缓冲吃完、站回地面的一段。膝角回到站立值，脚尖落到稳定线以下。
///
/// **这一段是 `CUSHION → GROUND` 那条边的全部输入**，一次都不能省：
/// 少了它，最后一次跳会停在 `CUSHION` 上等超时被丢弃。
const RopeSegment ropeSettled = RopeSegment(
  lift: ropeSettledLift,
  kneeDeg: ropeStandDeg,
);

/// 一次标准跳绳：站 → 腾空 → 落地缓冲 → 站回地面。
///
/// 回到 `GROUND` 的那一帧封存一次 rep。
///
/// 每段 4 帧不是凑数：状态机每次转移都要**在状态内**重新凑满
/// `voteWindow` 帧的票（跳绳把它调到 2），而转移本身还要晚一帧才提交 ——
/// 一段只有 1 帧的话，机器还没离开上一个状态，那一段就过完了。
List<PoseFrame> ropeRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double lift = ropeAirborne,
  double kneeDeg = ropeFlexedDeg,
  double toeGap = 0.0,
  double trunkDeg = 0.0,
  double scale = 1.0,
  int standFrames = 4,
}) =>
    ropeFromSegments(
      [
        RopeSegment(
          count: standFrames,
          kneeDeg: ropeStandDeg,
          scale: scale,
        ),
        RopeSegment(
          lift: lift,
          kneeDeg: 175.0,
          toeGap: toeGap,
          trunkDeg: trunkDeg,
          scale: scale,
        ),
        RopeSegment(
          lift: ropeCushionLift,
          kneeDeg: kneeDeg,
          toeGap: toeGap,
          trunkDeg: trunkDeg,
          scale: scale,
        ),
        RopeSegment(
          lift: ropeSettledLift,
          kneeDeg: ropeStandDeg,
          toeGap: toeGap,
          trunkDeg: trunkDeg,
          scale: scale,
        ),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续站着不动的帧。标定用的就是它，也是领域层分段测试的收势。
List<PoseFrame> ropeStandingFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        ropePose(
          timestampMs: startTimestampMs + i * frameIntervalMs,
          scale: scale,
        ),
    ];

/// 造一批「门禁读成正视」的帧。
///
/// 侧视下缝隙是 0.01，门禁的 `lateralRatio` 算出来是 0.05；放大 [gapScale] 倍
/// 就过 `frontalRatio`（0.62）。**这不是一个物理上站得住的「正视跳绳」**
/// —— 正视看人，脚尖的高度差与离地高度都失去意义，得整副骨架换个投影才画得出。
/// 它只对「门禁给出什么结论」这一件事有意义。
List<PoseFrame> ropeFacingFrontFrames({
  int count = 30,
  double gapScale = 13.0,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        ropePose(
          timestampMs: i * 33,
          sideGapScale: gapScale,
          scale: scale,
        ),
    ];
