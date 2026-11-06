/// 合成立定跳远帧。
///
/// 与 `synthetic_squat.dart` 同一个思路（膝角是主自变量、躯干竖直、脚掌平放），
/// 但多了三个**立定跳远特有的自由度**，因为它的分段与判定要看这三样：
///
/// - **左右膝角可以不同** —— 两条「双脚不同步」的规则判的是膝角对称度，
///   造不出不对称就测不了它们。
/// - **膝可以抬高（收腿）** —— `hip_height_ratio` 是「髋高出膝多少」，
///   收腹举腿会把它压成负值。这是落地判定里那道剔除门槛的**唯一**自变量，
///   造不出收腿就证明不了那道门槛真的在挡东西。
/// - **可以前倾、可以抬脚跟** —— 躯干控制与前掌离地两条规则的输入。
///
/// ## 踝的位置是算出来的，不是摆出来的
///
/// `squatPose` 把膝固定在髋正下方，于是「髋→膝」方向恒为竖直，踝直接按
/// `(sinθ, −cosθ)` 摆即可。**这里不能这么写**：一旦膝被抬到别处，
/// 「髋→膝」就不再竖直，照搬那个式子会让实际膝角与传入的 [sljPose] 参数对不上 ——
/// 而这种错**不会报错**，只会让「收腿时膝角是多少」变成一个没人知道的数。
///
/// 所以这里按定义算：把「髋→膝」方向的单位向量绕膝旋转 θ，得到「膝→踝」方向。
/// 无论膝在哪，夹角都精确等于 θ。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int sljFrameSide = 1000;

/// 站立膝角，与 `synthetic_squat.dart` 取同一个值 —— 两侧的 `standDeg`
/// 不该各说各话，否则「深蹲站立」与「跳远站立」在测试里就是两个人。
const double sljStandDeg = 175.0;

/// 五条分段线在 `standDeg = 175`、默认配置下的位置。
///
/// 注释在这里算一遍，是为了让下面那些序列读起来能直接对上号；
/// 真值由 `buildSlj` 里的顺序不变式保证。
///
/// ```
/// bend  150 = 175 − 25 (minBendDeg)
/// rise  158 = 150 + 8  (standingHysteresisDeg)
/// land  163 = 175 − 12 (landingFlexDeg)
/// stand 167 = 175 − 8  (standingHysteresisDeg)
/// fly   171 = 175 − 4  (flightExtensionDeg)
/// ```
const double sljBendLine = 150.0;
const double sljRiseLine = 158.0;
const double sljLandLine = 163.0;
const double sljStandLine = 167.0;
const double sljFlyLine = 171.0;

const double _hipY = 0.30;
const double _legLen = 0.15;
const double _torsoLen = 0.10;

/// 造一帧立定跳远姿态。
///
/// - [leftKneeDeg] / [rightKneeDeg]：左右膝角。不给右腿就与左腿相同。
/// - [kneeLift]：把膝整体抬高多少（归一化画幅单位）。0 = 站立时膝在髋正下方
///   一个腿长处；抬到 0.18 左右膝就会跑到髋上方，`hip_height_ratio` 转负 ——
///   这就是收腹举腿。
/// - [trunkLeanDeg]：躯干前倾角。肩相对髋水平偏移 `躯干长 × tan(角)`，
///   于是量出来的 `trunk_lean` 精确等于这个角度。
/// - [heelRise]：**左脚**跟抬升比（`heel_rise_ratio_L` 的目标值）。
///   精确解出让脚跟抬高多少才能得到这个比值，理由同文件头。
/// - [sideGap]：左右肩/左右髋的水平间距（归一化画幅单位）。
///   **它是「画面上看起来是不是正对镜头」的唯一自变量**：门禁算的侧向比
///   `(肩宽 + 髋宽) / (2 × 躯干长)` 在这里恰好等于 `10 × sideGap`
///   （两段跨度都是 `sideGap × 画幅边长`，躯干长恒为 0.10 画幅边长）。
///   默认 0.02 得 0.20，落在侧视档；取 0.07 得 0.70，落在正视档。
///   除此以外它不影响任何一个特征 —— 膝角、对称度、躯干倾角、髋高比、脚跟
///   抬升比全都只跟矢状面内的点有关。这正是门禁必须存在的理由。
PoseFrame sljPose(
  double leftKneeDeg, {
  required int timestampMs,
  double? rightKneeDeg,
  double kneeLift = 0.0,
  double trunkLeanDeg = 0.0,
  double heelRise = 0.0,
  double sideGap = 0.02,
  double scale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  const hipX = 0.50;
  final rightDeg = rightKneeDeg ?? leftKneeDeg;

  final kneeY = _hipY + _legLen - kneeLift;

  /// 由「髋→膝」方向绕膝旋转 [deg] 得到踝。
  ///
  /// 旋转用标准逆时针式 `R(θ)(x, y) = (x·cosθ − y·sinθ, x·sinθ + y·cosθ)`。
  /// 可以直接验算：膝在髋正下方时「髋→膝」= (0, −1)，转 θ 后得
  /// `(sinθ, −cosθ)` —— 与 `squatPose` 里那个手写的踝位置逐位相同。
  (double, double) ankleOf((double, double) knee, (double, double) hip, double deg) {
    final dx = hip.$1 - knee.$1;
    final dy = hip.$2 - knee.$2;
    final len = math.sqrt(dx * dx + dy * dy);
    final vx = dx / len;
    final vy = dy / len;
    final rad = deg * math.pi / 180.0;
    final rx = vx * math.cos(rad) - vy * math.sin(rad);
    final ry = vx * math.sin(rad) + vy * math.cos(rad);
    return (knee.$1 + _legLen * rx, knee.$2 + _legLen * ry);
  }

  final hip = (hipX, _hipY);
  final leftKnee = (hipX, kneeY);
  final rightKnee = (hipX + sideGap, kneeY);
  final leftHip = hip;
  final rightHip = (hipX + sideGap, _hipY);
  final leftAnkle = ankleOf(leftKnee, leftHip, leftKneeDeg);
  final rightAnkle = ankleOf(rightKnee, rightHip, rightDeg);

  // 脚跟略靠后、脚尖略靠前，两者等高 → 站立时 heel_rise_ratio ≈ 0。
  // 要抬脚跟时把脚跟往上挪 d：抬升比 = d / √(L² + d²)，其中 L 是脚的水平长度。
  // 反解 d = rL/√(1−r²) —— 因为 d 自己也进了分母（抬高脚跟会同时改变足长），
  // 直接按 r×L 挪会得到一个比目标略小的比值。测试要断言的是「越没越过阈值」，
  // 差一点就可能落在阈值同侧，所以这里解精确。
  const footSpan = 0.08;
  final heelDy = heelRise == 0
      ? 0.0
      : heelRise * footSpan / math.sqrt(1 - heelRise * heelRise);

  (double, double) heelOf((double, double) ankle) =>
      (ankle.$1 - 0.03, ankle.$2 + 0.008 - heelDy);
  (double, double) toeOf((double, double) ankle) =>
      (ankle.$1 + 0.05, ankle.$2 + 0.008);

  // 躯干前倾：肩相对髋水平偏移 躯干长×tan(角)。量出来的倾角精确等于该角度。
  final leanDx = trunkLeanDeg == 0
      ? 0.0
      : _torsoLen * math.tan(trunkLeanDeg * math.pi / 180.0);
  final shoulderY = _hipY - _torsoLen;
  final shoulderX = hipX + leanDx;

  (double, double) scaled((double, double) p) => (
        0.5 + (p.$1 - 0.5) * scale,
        0.5 + (p.$2 - 0.5) * scale,
      );

  return poseFrameFromPoints(
    frameWidth: sljFrameSide,
    frameHeight: sljFrameSide,
    timestampMs: timestampMs,
    fill: scaled((0.5, 0.06)),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {
      L.leftShoulder: (shoulderX, shoulderY),
      L.rightShoulder: (shoulderX + sideGap, shoulderY),
      L.leftElbow: (shoulderX - 0.02, shoulderY + 0.05),
      L.rightElbow: (shoulderX + sideGap + 0.02, shoulderY + 0.05),
      L.leftWrist: (shoulderX - 0.04, shoulderY + 0.10),
      L.rightWrist: (shoulderX + sideGap + 0.04, shoulderY + 0.10),
      L.leftHip: leftHip,
      L.rightHip: rightHip,
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

/// 一次完整立定跳远的膝角序列：站立 → 蓄力下蹲 → 蹬伸 → 落地 → 站立。
///
/// 每段都保持足够多帧：状态机有投票窗口（5 帧，需 4 帧同类）与最短停留
/// （3 帧），**每提交一次转移大约要 5 帧**，一段只有两三帧的话转移还没提交
/// 就过去了。
///
/// 蹬伸段给得尤其长（16 帧），因为它要**连提交两次**：PREP→LAUNCH 与
/// LAUNCH→FLIGHT。这是本设计里最容易被低估的一处 —— 一个「不蹬直」的跳
/// 只提交得起第一次，那正是它不计数的机制。
List<double> sljSequence({
  double crouchDeg = 95.0,
  double toeOffDeg = 178.0,
  double landDeg = 115.0,
}) =>
    [
      ...List.filled(16, sljStandDeg), // STANDING
      ...List.filled(12, crouchDeg), // PREP（95 ≤ 150）
      ...List.filled(16, toeOffDeg), // LAUNCH → FLIGHT（178 > 171）
      ...List.filled(12, landDeg), // LAND（115 < 163）
      ...List.filled(16, sljStandDeg), // STANDING → 封存
    ];

/// 一个姿态段：连续 [count] 帧，左右膝角固定，其余参数逐段可选。
///
/// 缺陷通常只出现在某一个相位里 —— 蓄力段抬了脚跟、蹬伸段躯干前倾。
/// 用「段」描述，测试读起来就与动作本身一一对应；换成逐帧列表，
/// 一个 `List.filled(14, 40.0)` 出现在第几个位置需要数帧才看得懂。
class SljSegment {
  const SljSegment(
    this.leftKneeDeg, {
    this.count = 12,
    this.rightKneeDeg,
    this.kneeLift = 0.0,
    this.trunkLeanDeg = 0.0,
    this.heelRise = 0.0,
  });

  final double leftKneeDeg;
  final int count;
  final double? rightKneeDeg;
  final double kneeLift;
  final double trunkLeanDeg;
  final double heelRise;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> sljFromSegments(
  List<SljSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(sljPose(
        segment.leftKneeDeg,
        timestampMs: start + i * frameIntervalMs,
        rightKneeDeg: segment.rightKneeDeg,
        kneeLift: segment.kneeLift,
        trunkLeanDeg: segment.trunkLeanDeg,
        heelRise: segment.heelRise,
      ));
    }
  }
  return frames;
}

/// 把一串膝角变成帧流。
List<PoseFrame> sljFramesForAngles(
  List<double> angles, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double kneeLift = 0.0,
  double trunkLeanDeg = 0.0,
  double heelRise = 0.0,
  double? rightKneeDeg,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < angles.length; i++)
        sljPose(
          angles[i],
          timestampMs: startTimestampMs + i * frameIntervalMs,
          rightKneeDeg: rightKneeDeg,
          kneeLift: kneeLift,
          trunkLeanDeg: trunkLeanDeg,
          heelRise: heelRise,
          scale: scale,
        ),
    ];

/// 连续站立的帧。开场与收尾都用它 —— 状态机需要足够多的静止帧才会换相。
///
/// [sideGap] 见 [sljPose]：改它只改画面上看起来的机位，不改任何一个特征。
List<PoseFrame> sljStandFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double sideGap = 0.02,
}) =>
    [
      for (var i = 0; i < count; i++)
        sljPose(
          sljStandDeg,
          timestampMs: startTimestampMs + i * frameIntervalMs,
          sideGap: sideGap,
        ),
    ];

/// 一次完整立定跳远的帧流。
List<PoseFrame> sljRepFrames({
  required int startTimestampMs,
  double crouchDeg = 95.0,
  double toeOffDeg = 178.0,
  double landDeg = 115.0,
  int frameIntervalMs = 33,
}) =>
    sljFramesForAngles(
      sljSequence(
        crouchDeg: crouchDeg,
        toeOffDeg: toeOffDeg,
        landDeg: landDeg,
      ),
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );
