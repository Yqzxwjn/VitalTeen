/// 合成平板支撑帧。
///
/// 与 `synthetic_pu.dart` 同一个思路（骨架形状也确实一样），自变量换成平板支撑
/// 自己的那三个：
///
/// - **身体倾角**（`trunk_lean`）—— 躯干与竖直方向的夹角。**90° 是支撑（身体放平）、
///   0° 是站立**。它是把「站着的人体线也是直的」这条挡在外面的那条判据，
///   所以合成器必须能把这两个姿势都造出来。
/// - **髋点相对体线的偏离**（`body_line_offset_ratio`）—— 正 = 髋更低 = 塌腰，
///   负 = 髋更高 = 撅臀。与 `synthetic_pu.dart` 里那一项同源、连几何都一样。
/// - **肘角**（`elbow_angle_L/R`）—— 支撑（≈90°）、
///   或者手臂伸直（≈175°，趴着放松的姿势，用来验支撑带真的把它挡住了）。
///
/// ## 只有肘角是精确造出来的
///
/// 肘角与 `synthetic_pu.dart` 一样是**精确**的：肘点在肩的「地面方向」上，
/// 腕点由旋转得到，于是 `angle3(肩, 肘, 腕)` 逐位等于它。
///
/// **髋偏离只有近似**，读到的那一篇写在 `synthetic_pu.dart` 的文件头里
/// （δ=0.04 → 比值 ≈ 0.196），这里不再重复：**测试不要拿它去卡阈值边界**。
///
/// ## 为什么把「站立」也放进这个合成器
///
/// 平板支撑的分段判据是三条的合取（见 `plank.dart` 文件头），其中**两条单独看
/// 都会把站立读成支撑**：站着的人体线也直（偏移 ≈ 0）。所以这个文件必须能造出
/// 一个「体线笔直、肘角也在支撑带上、但人是站着的」帧 —— 它是守卫那道题的
/// **反例**，没有它，「站着不会被计成支撑」就没被验过。
///
/// ## 它与真实平板支撑的差距（别拿这个合成器去验姿态类的东西）
///
/// 趴着的人从侧面看，肩点离地约一臂高；这副骨架把它放在画面中央、肘点朝下 ——
/// **它没有地面**，也就没有「离地多高」这个自由度。这正好对应 `plank.dart`
/// 文件头写下的那条能力边界：单目投影下「趴着摆同样的关节构型」与真正的
/// 平板支撑同形，两者只差离地高度。合成器造不出那个差别，是因为**画面上本来
/// 就没有那个差别**。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int plankFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// 肩中点的位置。身体从它出发、沿着身体方向伸展。
const double _shoulderX = 0.30;
const double _shoulderY = 0.50;

/// 肩中点到髋中点、以及到踝中点的距离。躯干长 0.20，身体全长 0.42。
const double _torsoLen = 0.20;
const double _bodyLen = 0.42;

/// 左右同侧点的横向缝隙。侧视下两条手臂、两条腿几乎重合，真实帧里也是这样；
/// 留一条 0.01 的缝是为了 `shoulder_width_px` 之类的分母不退化。
const double plankSideGap = 0.01;

/// 上臂与前臂长（归一化画幅单位）。等长即可，值本身不参与任何判定。
const double _upperArmLen = 0.10;
const double _foreArmLen = 0.10;

/// 支撑时躯干与竖直方向的夹角：**身体放平**。
const double plankHeldAngleDeg = 90.0;

/// 站立时躯干与竖直方向的夹角。
const double plankStandingAngleDeg = 0.0;

/// 支撑时撑地那条手臂的肘角（前臂与前臂撑地的夹角，直角）。
const double plankHoldElbowDeg = 90.0;

/// 手臂伸直（趴着放松、或者站着）。**落在支撑带之外**，正是用来验
/// `plankElbowMaxDeg` 那条判据真的在起作用的那个值。
const double plankStraightArmDeg = 175.0;

/// 明显塌腰 / 明显撅臀的髋点下移量（归一化画幅单位，正 = 更低）。
///
/// 0.06 对上去的比值约 0.287，**比资产表里的塌腰阈值（0.20）大、比
/// `plankLineEnterRatio`（0.45）小** —— 于是它正好落在「还在支撑位上、但已经被
/// 判错」那一段里。这正是规则有活干的那一段（见 `plank.dart` 文件头那段
/// 「门槛比判据宽」），也是 `plank_test.dart` 里合规组与违规组能同时立得住的原因。
///
/// **0.04 不够**：那个位移对上去只有约 0.196，比 0.20 还小一点 —— 于是
/// 「塌腰组」会安安静静地通过，而测试仍然全绿（规则没命中是因为人塌得不够，
/// 不是因为规则坏了）。这类「差一点」的合成值正是最容易把一条断言变成复述的。
const double plankSagOffset = 0.06;

/// 造一帧平板支撑姿态。
///
/// - [bodyAngleDeg]：躯干与竖直方向的夹角。90° = 身体放平（支撑），0° = 站立。
/// - [elbowDeg]：`elbow_angle_L` 与 `elbow_angle_R` 的目标值，**精确**。
/// - [hipOffset]：髋点整体沿画面 y 方向下移多少（归一化画幅单位，正 = 更低 =
///   塌腰）。**在站立姿势下它对比值没有影响**（肩-踝连线是竖直的，髋在这条线上
///   滑动不改变 y 方向的偏离）—— 这不是 bug，是那个特征的定义使然，
///   也正是「站立的体线也直」这句话的算式版本。
/// - [sideGapScale]：左右同侧点之间的横向缝隙的倍数（1.0 = 原样）。
///   **它的用途只有一个**：造出「门禁读成正视」的帧。45° 机位下两侧只差
///   一条 [plankSideGap] 的缝，放大它就够过 `frontalRatio` —— 那不是一帧
///   物理上站得住的平板支撑，只对「门禁给出什么结论」有意义
///  （同 `synthetic_pullup.dart` 的 [sideGapScale]）。
/// - [visibility]：整体可见性。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame plankPose({
  required int timestampMs,
  double bodyAngleDeg = plankHeldAngleDeg,
  double elbowDeg = plankHoldElbowDeg,
  double hipOffset = 0.0,
  double sideGapScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  final rad = bodyAngleDeg * math.pi / 180.0;

  /// 肩 → 踝的方向。0° 时是 (0, 1)（髋在肩的正下方，人站着）；
  /// 90° 时是 (1, 0)（髋在肩的正右方，人横躺着、头在左）。
  final alongX = math.sin(rad);
  final alongY = math.cos(rad);

  /// 从肩点出发、沿身体方向走 [len] 得到的点，再沿地面方向压 [dy]。
  (double, double) at(double len, {double dy = 0.0}) =>
      (_shoulderX + len * alongX, _shoulderY + len * alongY + dy);

  final gap = plankSideGap * sideGapScale;
  final leftShoulder = at(0.0);
  final rightShoulder = (leftShoulder.$1 + gap, leftShoulder.$2);
  final leftHip = at(_torsoLen, dy: hipOffset);
  final rightHip = (leftHip.$1 + gap, leftHip.$2);
  final leftAnkle = at(_bodyLen);
  final rightAnkle = (leftAnkle.$1 + gap, leftAnkle.$2);

  /// 膝点放在髋 → 踝的连线下方四成处。
  ///
  /// 与 `synthetic_pu.dart` 那一处不同（那边把膝点放在髋的高度上）：平板支撑
  /// 的腿是伸直的，膝落在髋踝连线上更接近真实帧。**它与任何判定都无关** ——
  /// 这个动作一条规则都不用膝角，放对了只是为了让这一帧读起来像个人。
  final leftKnee = (
    leftHip.$1 + (leftAnkle.$1 - leftHip.$1) * 0.4,
    leftHip.$2 + (leftAnkle.$2 - leftHip.$2) * 0.4,
  );
  final rightKnee = (leftKnee.$1 + gap, leftKnee.$2);

  /// 手臂：上臂**始终朝画面下方**（+y），腕点绕肘点旋转 [deg] 得到。
  ///
  /// **「下方」取的是画面方向而不是身体方向**，这是刻意的，也是这个合成器与
  /// 真实机位唯一对得上的地方：手机架在身体侧前方、水平不俯仰，于是「朝着地面」
  /// 在两种姿势下都是画面的 +y —— 站着的人手臂垂在身侧、撑着的人上臂指向垫子，
  /// 两者的上臂方向在画面上是同一个。
  ///
  /// 旋转式与 `synthetic_pu.dart` 相同（那边的上臂也朝画面下方），只有**取哪一支**
  /// 不同：那边的手臂朝画面右（俯卧撑的人趴着、头在左，前臂因此朝脚的方向），
  /// 这里取的是朝画面左 —— 前臂支撑的人前臂朝头的方向。两支的 `angle3` 完全
  /// 相同（对称解），所以**这个选择不影响任何特征**，只影响这张图读起来对不对。
  (double, double) wristOf((double, double) elbow, double deg) {
    final r = deg * math.pi / 180.0;
    return (
      elbow.$1 - _foreArmLen * math.sin(r),
      elbow.$2 - _foreArmLen * math.cos(r),
    );
  }

  final leftElbow = (leftShoulder.$1, leftShoulder.$2 + _upperArmLen);
  final rightElbow = (leftElbow.$1 + gap, leftElbow.$2);

  return poseFrameFromPoints(
    frameWidth: plankFrameSide,
    frameHeight: plankFrameSide,
    timestampMs: timestampMs,
    // 头画在身体方向的**反**方向（身体从肩往踝伸，头在另一头）。
    // 眼、耳、嘴三个点堆在那里：可见、且不参与平板支撑的任何特征。
    fill: at(-0.08),
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
      L.leftKnee: leftKnee,
      L.rightKnee: rightKnee,
      L.leftAnkle: leftAnkle,
      L.rightAnkle: rightAnkle,
      // 脚跟与脚尖不参与平板支撑的任何特征，但给出来更接近真实帧。
      L.leftHeel: (leftAnkle.$1 + 0.02, leftAnkle.$2 + 0.01),
      L.rightHeel: (leftAnkle.$1 + 0.02 + gap, leftAnkle.$2 + 0.01),
      L.leftFootIndex: (leftAnkle.$1 + 0.04, leftAnkle.$2 + 0.01),
      L.rightFootIndex: (leftAnkle.$1 + 0.04 + gap, leftAnkle.$2 + 0.01),
    },
  );
}

/// 一个姿态段：连续 [count] 帧，三个自变量固定。
///
/// 用「段」描述而不是逐帧列表，理由同 `synthetic_pu.dart`：一段支撑里的问题
/// 总是「有一段时间塌下去了」，段读起来与动作一一对应。
class PlankSegment {
  const PlankSegment({
    this.count = 30,
    this.bodyAngleDeg = plankHeldAngleDeg,
    this.elbowDeg = plankHoldElbowDeg,
    this.hipOffset = 0.0,
    this.hidden = const {},
  });

  final int count;
  final double bodyAngleDeg;
  final double elbowDeg;
  final double hipOffset;

  /// 这一段里**看不见**的关键点。
  ///
  /// 它的用途只有一个：验「撑住的过程中被挡住一会儿，不该把一次支撑切成两段」——
  /// 那条断言对应 `plank.dart` 里 `leftHold` 的取舍（读不到就**维持**撑住，
  /// 而不是「读不到就结束」）。别的动作没有这一条。
  final Set<L> hidden;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> plankFromSegments(
  List<PlankSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(plankPose(
        timestampMs: start + i * frameIntervalMs,
        bodyAngleDeg: segment.bodyAngleDeg,
        elbowDeg: segment.elbowDeg,
        hipOffset: segment.hipOffset,
        visibilityOverrides: {
          for (final landmark in segment.hidden) landmark: 0.0,
        },
      ));
    }
  }
  return frames;
}

/// 标准支撑的一段。默认 30 帧（≈1 秒）—— 一段支撑的时长由段数拼出来，
/// 不是由这个默认值决定。
const PlankSegment plankHold = PlankSegment();

/// 塌腰的支撑段：体线偏移明显超阈值，但仍在支撑位上（见 [plankSagOffset]）。
const PlankSegment plankSag = PlankSegment(hipOffset: plankSagOffset);

/// 撅臀的支撑段。
const PlankSegment plankPike = PlankSegment(hipOffset: -plankSagOffset);

/// 肘角偏离的支撑段（撑得太塌 / 撑得太直各一个）。
const PlankSegment plankElbowCollapsed = PlankSegment(elbowDeg: 60.0);
const PlankSegment plankElbowTooStraight = PlankSegment(elbowDeg: 120.0);

/// 站立的一段 —— 标定用它，也是「站着不该被读成支撑」那条断言的反例。
const PlankSegment plankStanding = PlankSegment(
  count: 15,
  bodyAngleDeg: plankStandingAngleDeg,
);

/// 连续支撑的帧流（撑住不动）。
List<PoseFrame> plankHoldFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double hipOffset = 0.0,
  double elbowDeg = plankHoldElbowDeg,
  Set<L> hidden = const {},
}) =>
    plankFromSegments(
      [
        PlankSegment(
          count: count,
          hipOffset: hipOffset,
          elbowDeg: elbowDeg,
          hidden: hidden,
        ),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 一次完整的支撑：站好 →（离开站立）→ 撑住 →（回到站立）。
///
/// **`repCount` 只会是 1，而它代表「撑了 [holdCount] 帧」** —— 这是这个动作与
/// 前面七个最不一样的地方，也是 `plank_test.dart` 里那条时长断言要钉住的东西。
/// 前后各留一段站立：状态机在**离开** `HOLD_BREAK` 那一帧开窗、在**回到**它的
/// 那一帧封存，两段站立都是必要的边界。
List<PoseFrame> plankOneHoldFrames({
  int holdCount = 90,
  int standingCount = 10,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double hipOffset = 0.0,
  double elbowDeg = plankHoldElbowDeg,
}) =>
    plankFromSegments(
      [
        PlankSegment(count: standingCount, bodyAngleDeg: plankStandingAngleDeg),
        PlankSegment(count: holdCount, hipOffset: hipOffset, elbowDeg: elbowDeg),
        PlankSegment(count: standingCount, bodyAngleDeg: plankStandingAngleDeg),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续站立的帧（标定阶段用）。
List<PoseFrame> plankStandingFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) =>
    plankFromSegments(
      [PlankSegment(count: count, bodyAngleDeg: plankStandingAngleDeg)],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );
