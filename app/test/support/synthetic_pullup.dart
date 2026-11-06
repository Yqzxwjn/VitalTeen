/// 合成引体向上帧。
///
/// 与 `synthetic_squat.dart` / `synthetic_slj.dart` / `synthetic_jj.dart` /
/// `synthetic_pu.dart` 同一个思路，自变量换成了引体向上自己的三个：
///
/// - **肘角**（`elbow_angle_L`）—— 肩-肘-腕的夹角，**180° 是直臂悬垂、90° 是直角**。
///   它既是分段信号，也是「有没有回到直臂悬垂」那条规则的输入。
/// - **嘴相对腕的高差**（`mouth_wrist_dy`）—— 负 = 嘴高过腕 = 下颌过杠。
///   带符号，所以阈值是个负数；这是「下颌过杠」那条规则的输入。
/// - **躯干倾角**（`trunk_lean`）—— 正 = 肩在髋的右侧。判摆动借力。
///
/// ## 支点选在手腕上，这一点与俯卧撑相反
///
/// `synthetic_pu.dart` 把**肩**钉住、让腕绕肘转；引体向上反过来：
/// **双手握在杠上，腕是不动的那一个**。所以腕点固定在 `(wristX, barY)`，
/// 肘点固定在腕点正下方，肩点由「肘→腕」方向绕肘点**精确旋转** [elbowDeg] 得到。
///
/// 这不只是「更像真的」：`mouth_wrist_dy` 的分母是躯干长、分子是嘴与腕的
/// y 之差，而**腕的高度就是杠的高度**。腕一动，这个量就不再是「下颌过没过杠」
/// 而是「手往上挪了多少」—— 明明是同一个姿式，读数却随手臂位置漂。
/// 钉住腕点之后，这个量才逐位等于下面 [mouthWristDy] 给的值。
///
/// ## 三个量都是精确造出来的（与俯卧撑那两项「只有近似」不同）
///
/// - 肘角：绕肘点精确旋转，`angle3(肩, 肘, 腕)` 逐位等于 [elbowDeg]。
/// - 嘴高差：嘴中点直接放在 `腕_y + mouthWristDy × 躯干长` 上 ——
///   而躯干长在本文件里恰好等于 [_torsoLen]（肩中点到髋中点，构造保证），
///   所以 `mouth_wrist_dy` 逐位等于 [mouthWristDy]。
///   代价是**头的位置由这个比值决定**，而不是由「头长在脖子上」决定 ——
///   合成帧里没有头的解剖学，只有这个比值。这是刻意的：测试要断的是
///   「越没越过阈值」，自变量必须算得准。
/// - 躯干倾角：髋点由「肩点 − 躯干长 × (sin θ, −cos θ)」放置，
///   `tilt_from_vertical(髋, 肩)` 逐位等于 [trunkLeanDeg]。
///
/// 三个量互不干扰（各自的几何支点独立），所以可以任意组合出
/// 「拉到位但身体在荡」「不荡但没回到直臂」这类交叉用例。
///
/// ## 为什么左右两侧给同一个值、只差一点点横向
///
/// 与 `synthetic_pu.dart` 逐字相同的理由：45° 下两条手臂在画面上几乎重合，
/// 留一条 0.01 的缝是为了 `shoulder_width_px` 之类的分母不退化，
/// 以及门禁的 `lateralRatio` 算出来落在「侧视」那一档。
///
/// 那条缝可以按 [pullupPose] 的 [sideGapScale] 放大，用来造出
/// 「门禁读成正视」的帧。引体向上**要的正是侧视那一档**（`requiresFrontal`
/// 为假），所以放大缝隙在引体向上这边是用来造**该被拦住**的帧。
///
/// 其余同 `synthetic_pu.dart`：那个放大不等于「正视的引体向上」，
/// 只对「门禁给出什么结论」这一件事有意义。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int pullupFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// 单杠的高度 —— 也就是两手手腕的高度。
///
/// 整个骨架从这里往下长：肘在腕下 [pullupForeArmLen]、肩再由肘角决定，
/// 人在下面悬着。取 0.25 是为了给「头顶高过杠」（下颌过杠那一帧的嘴点）
/// 留出画面上方的余地。
const double pullupBarY = 0.25;

/// 手腕的横坐标（左右手的中点）。
const double _wristX = 0.50;

/// 上臂与前臂长（归一化画幅单位）。等长即可，值本身不参与任何判定。
const double pullupUpperArmLen = 0.10;
const double pullupForeArmLen = 0.10;

/// 躯干长：肩中点到髋中点的距离。**它同时是 `mouth_wrist_dy` 的分母**，
/// 所以这个数一旦改了，所有以比值为单位的用例都要跟着看一遍。
/// 取 0.20 与俯卧撑、深蹲那几份合成骨架一致。
const double pullupTorsoLen = 0.20;

/// 大腿与小腿长。只为了让骨架落在画面里，不参与任何判定。
const double _upperLegLen = 0.14;
const double _lowerLegLen = 0.14;

/// 左右同侧点的横向缝隙。侧视下本来就几乎重合，见文件头。
const double pullupSideGap = 0.01;

/// 直臂悬垂时的肘角。
///
/// 取 175 而不是 180：180 要求肩、肘、腕严格共线，虽然 `angle3` 的 `clamp`
/// 兜得住，但一个正好落在边界上的合成值会把「阈值取 170」这类测试变成
/// 浮点比较。同 `synthetic_pu.dart` 对 175 的交代。
const double pullupHangElbowDeg = 175.0;

/// 拉到顶时的肘角。
const double pullupTopElbowDeg = 80.0;

/// 上拉/下放途中经过的肘角（两条分段线 90 与 165 之间）。
const double pullupMidElbowDeg = 130.0;

/// 直臂悬垂时嘴相对腕的高度（正值 = 嘴在杠**下方**）。
///
/// 0.30 意味着嘴低于杠 `0.30 × 0.20 = 0.06` 个画幅高度 —— 悬着的人的头顶
/// 大致在杠附近，嘴在头的中下段，这个数量级是对的。
const double pullupHangMouthDy = 0.30;

/// 拉到顶时嘴相对腕的高度。**负值 = 嘴在杠上方 = 下颌过杠。**
///
/// -0.15 而不是贴着 0：下颌过杠是「明显过」，合成帧给一个贴着阈值线的值
/// 会让用例断在边界上。
const double pullupTopMouthDy = -0.15;

/// 上拉/下放途中经过的嘴高差（嘴正在接近杠）。
const double pullupMidMouthDy = 0.10;

/// 造一帧引体向上姿态。
///
/// - [elbowDeg]：`elbow_angle_L` 与 `elbow_angle_R` 的目标值，**精确**。
/// - [mouthWristDy]：`mouth_wrist_dy` 的目标值，**精确**。负 = 嘴高过腕。
/// - [trunkLeanDeg]：`trunk_lean` 的目标值，**精确**。正 = 肩在髋的右侧。
/// - [sideGapScale]：左右同侧点之间的横向缝隙的倍数（1.0 = 原样）。
///   用途同 `synthetic_pu.dart` —— 只对「门禁给出什么结论」有意义。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame pullupPose({
  required int timestampMs,
  double elbowDeg = pullupHangElbowDeg,
  double mouthWristDy = pullupHangMouthDy,
  double trunkLeanDeg = 0.0,
  double sideGapScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  final gap = pullupSideGap * sideGapScale;
  final rad = elbowDeg * math.pi / 180.0;
  final leanRad = trunkLeanDeg * math.pi / 180.0;

  // 手腕固定在杠上，左右各让出半条缝 —— 中点是精确的 (wristX, barY)。
  final leftWrist = (_wristX - gap / 2, pullupBarY);
  final rightWrist = (_wristX + gap / 2, pullupBarY);

  // 肘在腕的正下方。这是「手臂从杠下垂下来」的骨架前提，与肘角无关 ——
  // 肘角改的是肩落在哪儿。
  final elbowY = pullupBarY + pullupForeArmLen;
  final leftElbow = (leftWrist.$1, elbowY);
  final rightElbow = (rightWrist.$1, elbowY);

  // 肩由「肘→腕」方向（图像里是 (0, -1)，朝上）绕肘点精确旋转 elbowDeg 得到：
  // 旋转后是 (sin θ, -cos θ)。
  //   θ = 180° → 肩在肘的正下方（直臂悬垂）
  //   θ = 90°  → 肩与肘等高（上臂水平）
  // 于是 angle3(肩, 肘, 腕) 逐位等于 θ。
  final upperDir = (math.sin(rad), -math.cos(rad));
  final leftShoulder = (
    leftElbow.$1 + pullupUpperArmLen * upperDir.$1,
    leftElbow.$2 + pullupUpperArmLen * upperDir.$2,
  );
  final rightShoulder = (
    rightElbow.$1 + pullupUpperArmLen * upperDir.$1,
    rightElbow.$2 + pullupUpperArmLen * upperDir.$2,
  );

  final shoulderMid = (
    (leftShoulder.$1 + rightShoulder.$1) / 2,
    (leftShoulder.$2 + rightShoulder.$2) / 2,
  );

  // 髋由「肩点 − 躯干长 × (sin θ, -cos θ)」放置：
  // tilt_from_vertical(髋, 肩) 逐位等于 trunkLeanDeg，且躯干长逐位等于 _torsoLen。
  final hipMid = (
    shoulderMid.$1 - pullupTorsoLen * math.sin(leanRad),
    shoulderMid.$2 + pullupTorsoLen * math.cos(leanRad),
  );

  final kneeMid = (hipMid.$1, hipMid.$2 + _upperLegLen);
  final ankleMid = (kneeMid.$1, kneeMid.$2 + _lowerLegLen);

  // 嘴中点：直接由比值反推 y。分母（躯干长）构造上就等于 _torsoLen，
  // 所以 mouth_wrist_dy 逐位等于 mouthWristDy。见文件头。
  final mouthMid = (
    shoulderMid.$1,
    pullupBarY + mouthWristDy * pullupTorsoLen,
  );

  return poseFrameFromPoints(
    frameWidth: pullupFrameSide,
    frameHeight: pullupFrameSide,
    timestampMs: timestampMs,
    // 其余的点（眼、耳、鼻）跟着嘴走：头就长在那儿。它们不参与引体向上的
    // 任何特征，但要可见（`headNotVisible` 那条提示判的就是它们）。
    fill: mouthMid,
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {
      // 肩与肘**不再另外平移**那半条缝：它们是从已经带缝的腕点推出来的，
      // 相对几何因此逐位保持（肘角才等于 [elbowDeg]）。
      // 再平移一次会让「肘-肩」与「肘-腕」两条边错开半个缝宽，
      // 一个 175° 的直臂悬垂会被读成 172.1° —— 而 3° 足够跨过分段线。
      L.leftShoulder: leftShoulder,
      L.rightShoulder: rightShoulder,
      L.leftElbow: leftElbow,
      L.rightElbow: rightElbow,
      L.leftWrist: leftWrist,
      L.rightWrist: rightWrist,
      // 髋、膝、踝是左右对称地绕中点摆的，中点必须逐位落在 hipMid 上 ——
      // `torso_length()` 取的就是两个中点的距离。
      L.leftHip: (hipMid.$1 - gap / 2, hipMid.$2),
      L.rightHip: (hipMid.$1 + gap / 2, hipMid.$2),
      L.leftKnee: (kneeMid.$1 - gap / 2, kneeMid.$2),
      L.rightKnee: (kneeMid.$1 + gap / 2, kneeMid.$2),
      L.leftAnkle: (ankleMid.$1 - gap / 2, ankleMid.$2),
      L.rightAnkle: (ankleMid.$1 + gap / 2, ankleMid.$2),
      L.leftHeel: (ankleMid.$1 - gap / 2 + 0.02, ankleMid.$2 + 0.01),
      L.rightHeel: (ankleMid.$1 + gap / 2 + 0.02, ankleMid.$2 + 0.01),
      L.leftFootIndex: (ankleMid.$1 - gap / 2 + 0.04, ankleMid.$2 + 0.01),
      L.rightFootIndex: (ankleMid.$1 + gap / 2 + 0.04, ankleMid.$2 + 0.01),
      L.mouthLeft: (mouthMid.$1 - gap / 2, mouthMid.$2),
      L.mouthRight: (mouthMid.$1 + gap / 2, mouthMid.$2),
    },
  );
}

/// 一个姿态段：连续 [count] 帧，三个自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（到了顶但嘴没过杠、
/// 落回来时手臂没伸直），段读起来与动作一一对应。
class PullupSegment {
  const PullupSegment({
    this.count = 14,
    this.elbowDeg = pullupHangElbowDeg,
    this.mouthWristDy = pullupHangMouthDy,
    this.trunkLeanDeg = 0.0,
    this.visibilityOverrides,
  });

  final int count;
  final double elbowDeg;
  final double mouthWristDy;
  final double trunkLeanDeg;

  /// 这一段里固定看不见的点。`null` ＝ 全都正常可见。
  ///
  /// 用段来描述遮挡，遮挡就被摆在与姿态同一层上：`pullup.dart` 里有两处
  /// 「某个点读不到时规则该怎么办」的取舍（下颌过杠那条切窗口、手看不见时
  /// 肘角消失），两处要造的都是「某一段看不见」而不是「某一帧看不见」。
  final Map<L, double>? visibilityOverrides;
}

/// 把一段复制一份，但嘴点在整段上不可见。
///
/// 给的是「复制」而不是让调用方另写一段：遮挡是加在段上的一层，
/// 段本身的姿态数值必须与原来那一份**逐位相同**，否则「只有遮挡变了」
/// 这个前提就不成立，用例也就证不了任何事。
PullupSegment pullupMouthHidden(PullupSegment segment) => PullupSegment(
      count: segment.count,
      elbowDeg: segment.elbowDeg,
      mouthWristDy: segment.mouthWristDy,
      trunkLeanDeg: segment.trunkLeanDeg,
      visibilityOverrides: const {L.mouthLeft: 0.0, L.mouthRight: 0.0},
    );

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> pullupFromSegments(
  List<PullupSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(pullupPose(
        timestampMs: start + i * frameIntervalMs,
        elbowDeg: segment.elbowDeg,
        mouthWristDy: segment.mouthWristDy,
        trunkLeanDeg: segment.trunkLeanDeg,
        visibilityOverrides: segment.visibilityOverrides,
      ));
    }
  }
  return frames;
}

/// 直臂悬垂段。开场与收尾都用它。
const PullupSegment pullupHang = PullupSegment();

/// 上拉/下放途中经过的一段。
const PullupSegment pullupMid = PullupSegment(
  elbowDeg: pullupMidElbowDeg,
  mouthWristDy: pullupMidMouthDy,
);

/// 拉到顶（嘴过杠）。
const PullupSegment pullupTop = PullupSegment(
  elbowDeg: pullupTopElbowDeg,
  mouthWristDy: pullupTopMouthDy,
);

/// 一次标准引体向上：悬垂 → 上拉 → 顶部 → 下放 → 回到直臂悬垂。
///
/// 回到 `HANG` 的那一帧封存一次 rep。
///
/// 中间那两段（[pullupMid]）不能省，理由同俯卧撑：状态机要在
/// [TrackingConfig.minDwellFrames] 与投票窗口里攒够同类证据才换相，
/// 而 `HANG→TOP` 不是一条边 —— 少了上拉段，顶部那一段会先在 `PULLING`
/// 里被投票，行为与真实动作对不上。
List<PoseFrame> pullupRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double topElbowDeg = pullupTopElbowDeg,
  double topMouthWristDy = pullupTopMouthDy,
  double hangElbowDeg = pullupHangElbowDeg,
  double trunkLeanDeg = 0.0,
  Map<L, double>? visibilityOverrides,
}) =>
    pullupFromSegments(
      [
        PullupSegment(
          elbowDeg: hangElbowDeg,
          trunkLeanDeg: trunkLeanDeg,
          visibilityOverrides: visibilityOverrides,
        ),
        PullupSegment(
          elbowDeg: pullupMidElbowDeg,
          mouthWristDy: pullupMidMouthDy,
          trunkLeanDeg: trunkLeanDeg,
          visibilityOverrides: visibilityOverrides,
        ),
        PullupSegment(
          elbowDeg: topElbowDeg,
          mouthWristDy: topMouthWristDy,
          trunkLeanDeg: trunkLeanDeg,
          visibilityOverrides: visibilityOverrides,
        ),
        PullupSegment(
          elbowDeg: pullupMidElbowDeg,
          mouthWristDy: pullupMidMouthDy,
          trunkLeanDeg: trunkLeanDeg,
          visibilityOverrides: visibilityOverrides,
        ),
        PullupSegment(
          elbowDeg: hangElbowDeg,
          trunkLeanDeg: trunkLeanDeg,
          visibilityOverrides: visibilityOverrides,
        ),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续挂在杠上的帧（标定与热身阶段用）。
List<PoseFrame> pullupHangFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) =>
    [
      for (var i = 0; i < count; i++)
        pullupPose(timestampMs: startTimestampMs + i * frameIntervalMs),
    ];
