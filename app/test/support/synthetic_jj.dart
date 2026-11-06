/// 合成开合跳帧。
///
/// 与 `synthetic_squat.dart` / `synthetic_slj.dart` 同一个思路，但主自变量换了：
/// 开合跳的三个判据都在**额状面**（画面左右方向），而前两个动作的自变量全在
/// 矢状面（画面前后/深度，用膝角表达）。所以这里能独立调的是：
///
/// - **分腿幅度**（`leg_spread_ratio`）—— 两条踝的横向间距除以肩宽。
///   它是分段信号，也是「开合到不到位」那条规则的输入。
/// - **手臂上举角度**（`shoulder_angle_min`）—— 肩点处「髋–肩–肘」的夹角，
///   180° 是举过头顶、接近 0° 是垂在体侧。
/// - **膝内扣量** —— 膝点相对「髋–踝连线」往中线偏多少。它**不是**膝角：
///   额状面的膝角（`frontal_knee_angle_*`）量的是画面里膝的折角，
///   直腿时为 0°，内扣越大越大 —— 与 `knee_angle_*`（直腿 180°）正好相反。
///
/// ## 三个量是精确造出来的，不是"差不多"
///
/// 判定测试要断的是「越没越过阈值」，所以造出来的值必须能算得准：
///
/// - 分腿幅度：踝点直接摆在 `±spread × 肩半宽` 处，肩与踝都只差横向，
///   于是 `|Δx踝| / 肩宽` 逐位等于传入的 [spread]。
/// - 手臂角度：把「髋−肩」的单位向量绕肩点精确旋转 [armDeg] 度得到肘点，
///   夹角于是逐位等于 [armDeg]（膝点那个式子做不到这一点，见下）。
/// - 膝内扣：**这一项只有近似**。膝点按「髋踝连线的中点再往中线挪
///   `kneeInward`」摆，产生的额状面膝角与挪动量近乎线性（0.02 ≈ 11.4°，
///   实现在 `features.dart` 里量过）。**所以测试不要拿它去卡阈值边界**：
///   要么用「明显内扣」与「明显直腿」两端，要么直接读特征值再断言。
///
/// ## 为什么膝点不学 `synthetic_slj.dart` 那样用旋转解出来
///
/// 立定跳远的踝是**算出来**的（绕膝旋转，保证膝角精确）。这里反过来：
/// 开合跳的**踝位置就是分段信号本身**，它必须是精确的那个 ——
/// 绕膝旋转会让踝的横坐标跟着膝内扣一起漂，于是"分腿不足"与"膝内扣"
/// 两个自变量纠缠在一起，一条测试红了分不清是谁的毛病。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int jjFrameSide = 1000;

/// 站立时的分腿比：双脚基本并拢再往外一点点。
///
/// 0.12 对应画幅上两条踝相距 0.024（约 4 厘米量级）—— 比真实站姿窄一点，
/// 但这是**刻意的**：基线越小，「相对本人基线」的四条分段线越靠近画面中轴，
/// 而判定那三条用的是绝对阈值，于是「站姿窄的人更容易进 OPEN、却更容易被
/// 判幅度不足」这件事在测试里就是常态而不是边角。
const double jjStandSpread = 0.12;

/// 站立膝角，与其它合成器取同一个值 —— 两侧的 `standDeg` 不该各说各话。
const double jjStandDeg = 175.0;

/// 默认配置（`spreadEnterDelta` 0.30 / `spreadFullDelta` 0.80 /
/// `spreadHysteresis` 0.08）下四条线在 [jjStandSpread] 上的位置。
///
/// 注解在这里算一遍，是为了让下面那些序列读起来能直接对上号；真值由
/// `buildJj` 里的顺序不变式保证。
///
/// ```
/// standLine  0.20 = 0.12 + 0.08 (spreadHysteresis)
/// openLine   0.42 = 0.12 + 0.30 (spreadEnterDelta)
/// fullLine   0.92 = 0.12 + 0.80 (spreadFullDelta)
/// ```
const double jjStandLine = 0.20;
const double jjOpenLine = 0.42;
const double jjFullLine = 0.92;

/// 一次标准开合跳的分腿峰值：远高于 [jjFullLine]。
const double jjJumpSpread = 2.0;

/// 只开到一半的分腿峰值：过了 [jjOpenLine]、没到 [jjFullLine]。
///
/// 它是「跳了但没跳完」那一类，用来钉住「不算一次」。
const double jjHalfSpread = 0.60;

// ---- 骨架的固定几何（归一化画幅坐标）----

const double _midX = 0.5;
const double _shoulderHalf = 0.10;
const double _hipHalf = 0.06;
const double _armLen = 0.10;

const double _shoulderY = 0.24;
const double _hipY = 0.34;
const double _kneeY = 0.53;
const double _ankleY = 0.72;

/// 手臂垂在体侧时的肩角：约 8°。
///
/// 不是 0° —— 手垂下来时「髋−肩」与「肘−肩」本来就差着几度，
/// 造一个 0° 反而要求肘点落在髋肩连线上，那是把手臂折进身体里。
const double jjArmDownDeg = 8.0;

/// 手臂举过头顶时的肩角。
///
/// 取 175 而不是 180：180 要求肘、肩、髋严格共线，`angle3` 的 `clamp`
/// 虽然兜得住，但一个正好落在 180.0 上的合成值会把「阈值取 175」这类
/// 边界的测试变成浮点比较。
const double jjArmUpDeg = 175.0;

/// 造一帧开合跳姿态。
///
/// - [spread]：`leg_spread_ratio` 的目标值，**精确**。
/// - [armDeg]：左臂的 `shoulder_angle_L`，**精确**。[rightArmDeg] 不给就对称。
/// - [kneeInward]：膝点相对「髋踝连线中点」往中线挪多少（归一化画幅单位）。
///   近似线性，见文件头。
/// - [lateralScale]：整个人绕画面中轴「转过去」多少 —— 所有点的**横向**偏移
///   乘以这个系数（1.0 = 正对镜头，0.0 = 完全侧对）。
/// - [visibilityOverrides]：把某些点设成看不见（门禁与覆盖率测试用）。
PoseFrame jjPose({
  required int timestampMs,
  double spread = jjStandSpread,
  double armDeg = jjArmDownDeg,
  double? rightArmDeg,
  double kneeInward = 0.0,
  double lateralScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  final leftArm = armDeg;
  final rightArm = rightArmDeg ?? armDeg;

  // 两条踝横向相距 2 × spread × 肩半宽 → 比值逐位等于 spread。
  final ankleHalf = spread * _shoulderHalf;

  (double, double) hipOf(double sign) => (_midX + sign * _hipHalf, _hipY);
  (double, double) ankleOf(double sign) =>
      (_midX + sign * ankleHalf, _ankleY);

  /// 膝点在髋踝连线的中点，**再往中线挪 [kneeInward]**。
  ///
  /// `sign` 是这一侧的符号（左 −1、右 +1），中线在 `_midX`，
  /// 所以「往中线挪」对两侧都是减去 `sign × kneeInward`。
  (double, double) kneeOf(double sign) {
    final hip = hipOf(sign);
    final ankle = ankleOf(sign);
    return (
      (hip.$1 + ankle.$1) / 2 - sign * kneeInward,
      _kneeY,
    );
  }

  /// 由「髋−肩」方向绕肩旋转得到肘。夹角于是精确等于 [deg]。
  ///
  /// 两侧的旋转方向相反（左逆时针、右顺时针），这样对称的姿态得到对称的肘点 ——
  /// 若同号旋转，两条手臂会一上一下，而 `shoulder_angle_min` 取的是较小的那个，
  /// 于是「手臂举到位了」会被判成不足，而原因与用户无关。
  (double, double) elbowOf((double, double) shoulder, (double, double) hip, double deg, double sign) {
    final dx = hip.$1 - shoulder.$1;
    final dy = hip.$2 - shoulder.$2;
    final len = math.sqrt(dx * dx + dy * dy);
    final rad = sign * deg * math.pi / 180.0;
    final vx = dx / len;
    final vy = dy / len;
    final rx = vx * math.cos(rad) - vy * math.sin(rad);
    final ry = vx * math.sin(rad) + vy * math.cos(rad);
    return (shoulder.$1 + _armLen * rx, shoulder.$2 + _armLen * ry);
  }

  final leftShoulder = (_midX - _shoulderHalf, _shoulderY);
  final rightShoulder = (_midX + _shoulderHalf, _shoulderY);
  final leftHip = hipOf(-1);
  final rightHip = hipOf(1);
  final leftElbow = elbowOf(leftShoulder, leftHip, leftArm, -1);
  final rightElbow = elbowOf(rightShoulder, rightHip, rightArm, 1);

  (double, double) wristOf((double, double) shoulder, (double, double) elbow) => (
        elbow.$1 + (elbow.$1 - shoulder.$1),
        elbow.$2 + (elbow.$2 - shoulder.$2),
      );

  final leftAnkle = ankleOf(-1);
  final rightAnkle = ankleOf(1);

  /// 横向压缩：绕画面中轴把人「转过去」。
  ///
  /// **只缩放横向偏移，不动纵向** —— 这正是正交投影下绕竖直轴旋转的结果，
  /// 而它有一个用得上得很漂亮的副作用：`leg_spread_ratio` 的分子（两踝横向
  /// 间距）与分母（肩宽，横向的欧氏距离）乘的是同一个系数，**比值逐位不变**。
  /// 这条恰好就是领域层把 `leg_spread_ratio` 声明成 `views: [frontal]` 的
  /// 那半理由（一阶相消）—— 而门禁要拦住的正是「比值看着没变、姿态已经错了」
  /// 这种情形，所以测试里这个自变量必须有。
  (double, double) turned((double, double) p) =>
      (_midX + (p.$1 - _midX) * lateralScale, p.$2);

  return poseFrameFromPoints(
    frameWidth: jjFrameSide,
    frameHeight: jjFrameSide,
    timestampMs: timestampMs,
    // 其余的点（嘴、眼、耳）堆在头顶上方一点：可见、不参与任何开合跳特征，
    // 但门禁要拿「头在不在画面里」当提示级判据。
    fill: (_midX, _shoulderY - 0.06),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {
      L.leftShoulder: turned(leftShoulder),
      L.rightShoulder: turned(rightShoulder),
      L.leftElbow: turned(leftElbow),
      L.rightElbow: turned(rightElbow),
      L.leftWrist: turned(wristOf(leftShoulder, leftElbow)),
      L.rightWrist: turned(wristOf(rightShoulder, rightElbow)),
      L.leftHip: turned(leftHip),
      L.rightHip: turned(rightHip),
      L.leftKnee: turned(kneeOf(-1)),
      L.rightKnee: turned(kneeOf(1)),
      L.leftAnkle: turned(leftAnkle),
      L.rightAnkle: turned(rightAnkle),
      // 脚跟与脚尖不参与开合跳的任何特征，但给出来更接近真实帧 ——
      // 少一个点就少一处「万一哪天有人加了依赖它」的意外。
      L.leftHeel: turned((leftAnkle.$1 - 0.02, leftAnkle.$2 + 0.008)),
      L.rightHeel: turned((rightAnkle.$1 + 0.02, rightAnkle.$2 + 0.008)),
      L.leftFootIndex: turned((leftAnkle.$1 + 0.03, leftAnkle.$2 + 0.008)),
      L.rightFootIndex: turned((rightAnkle.$1 - 0.03, rightAnkle.$2 + 0.008)),
    },
  );
}

/// 一个姿态段：连续 [count] 帧，三个自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（起跳段手臂没举够、
/// 落地段膝内扣），段读起来与动作一一对应，而 `List.filled(14, 0.6)` 出现在
/// 第几个位置需要数帧才看得懂。
class JjSegment {
  const JjSegment({
    this.count = 14,
    required this.spread,
    this.armDeg = jjArmDownDeg,
    this.rightArmDeg,
    this.kneeInward = 0.0,
  });

  final int count;
  final double spread;
  final double armDeg;
  final double? rightArmDeg;
  final double kneeInward;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> jjFromSegments(
  List<JjSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(jjPose(
        timestampMs: start + i * frameIntervalMs,
        spread: segment.spread,
        armDeg: segment.armDeg,
        rightArmDeg: segment.rightArmDeg,
        kneeInward: segment.kneeInward,
      ));
    }
  }
  return frames;
}

/// 合腿站立段。开场与收尾都用它 —— 状态机要攒够静止帧才换相，也要靠它封存一次。
const JjSegment jjClosed = JjSegment(spread: jjStandSpread);

/// 张开到顶峰、双臂举过头顶的那一段。
///
/// 段长给到 14 帧而不是「刚好够提交一次转移」：`OPENING → OPEN` 与
/// `CLOSING → CLOSED` 各自都要在投票窗口里攒够 4 帧同类证据，
/// 而 **[OPEN] 是计数门槛**（`bottomState`）—— 段短了就变成「这一次没数上」，
/// 而那是另一条测试要证的事，不该在这里偶然发生。
const JjSegment jjOpenFull = JjSegment(
  spread: jjJumpSpread,
  armDeg: jjArmUpDeg,
);

/// 一次标准开合跳：合腿站立 → 张开到位 → 合拢。
///
/// 回到 `CLOSED` 的那一帧封存一次 rep（设计文档 §4.3）。
List<PoseFrame> jjRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double kneeInward = 0.0,
  double peakSpread = jjJumpSpread,
  double peakArmDeg = jjArmUpDeg,
}) =>
    jjFromSegments(
      [
        jjClosed,
        JjSegment(
          spread: peakSpread,
          armDeg: peakArmDeg,
          kneeInward: kneeInward,
        ),
        // 落地段单独给膝内扣：这条规则判的正是**触地那一刻**之后的膝朝向，
        // 把内扣加在张开段上测的就不是它了。
        JjSegment(spread: jjStandSpread, kneeInward: kneeInward),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续合腿站立的帧。
///
/// [lateralScale] 是给门禁测试用的：站立不动的人「转个身」在画面上就只是
/// 横向压缩，而门禁判的正是这个比例。见 [jjPose] 里那一项的说明。
List<PoseFrame> jjStandFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double lateralScale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        jjPose(
          timestampMs: startTimestampMs + i * frameIntervalMs,
          spread: jjStandSpread,
          lateralScale: lateralScale,
        ),
    ];
