/// 合成仰卧起坐帧。
///
/// 与 `synthetic_squat.dart` / `synthetic_slj.dart` / `synthetic_jj.dart` /
/// `synthetic_pu.dart` 同一个思路，自变量换成仰卧起坐自己的三个：
///
/// - **躯干角**（[suPose] 的 `torsoDeg`）—— 躯干与竖直方向的夹角，**负 = 向头那一侧
///   （躺下），正 = 向脚那一侧（起身前倾）**。它是分段信号 `shoulder_height_ratio`
///   的直接来源。
/// - **髋离垫**（`hipLift`）—— 臀/腰顶起来多少。`SU_HIP_LIFT` 那条规则的输入。
/// - **屈膝角**（`kneeDeg`）—— `knee_angle_L` / `knee_angle_R`，**精确**。
///   `SU_KNEE_ANGLE` 那条规则的输入。
///
/// ## 躯干角与比值的关系是闭式的，所以可以精确断言
///
/// 肩绕**贴在垫上的那个髋位**转（不是抬起来的那份，理由见 [suPose]），
/// 记躯干长为 L、踝所在的高度为 0：
///
/// ```
/// 肩高 = L·cos(torsoDeg)
/// 比值 = 肩高 / 躯干长 = L·cos(torsoDeg) / sqrt(L²sin² + (hipLift − L·cos)²)
/// ```
///
/// 顶髋为 0 时就退化成「比值 = cos(torsoDeg)」—— 于是「躺平」是 ±90°（比值 0）、
/// 「坐直」是 0°（比值 1）。**1 是这个量在臀不离垫前提下的上界**，
/// 理由见 `situp.dart` 文件头。期望值直接调 [suShoulderRatio] 拿，不必自己列式。
///
/// ## 三个量里哪两个是「差不多」的
///
/// - 躯干角与比值：**闭式精确**（上式）。
/// - 屈膝角：**精确**。膝点解在「以髋、踝为圆心、半径各为大腿长/小腿长的两个圆的
///   交点」上（两侧等长，于是它落在中垂线上），`angle3(髋, 膝, 踝)` 逐位等于它。
/// - 髋离垫：**只有近似**。`hipLift` 是髋点单独上移的位移，而
///   `body_line_offset_ratio` 的分母（躯干长）与肩-踝连线的两端都跟着动，
///   所以比值不等于 `hipLift/L`。
///   **测试不要拿它去卡阈值边界**：要么用「明显顶髋」与「平躺」两端，
///   要么直接读特征值再断言。（同 `synthetic_pu.dart` 对 `hipOffset` 的交代。）
///
///   还有一条：`hipLift` 调大会把 `shoulder_height_ratio` 也顶上去（肩不动、
///   躯干长变短），顶到超过分段线时**这一次就压根不进计数了**。所以顶髋那组
///   只能给一个有限的量（0.05 ≈ 躯干长的四分之一），给大了测的就变成分段了。
///
/// ## 为什么左右两侧给同一个值、只差一点点横向
///
/// 侧视机位下身体两侧在画面上几乎重合，真实帧里也是这样。留一条 0.01 的横向缝
/// 是为了两件事：`shoulder_width_px` 之类的分母不退化，以及门禁的
/// `lateralRatio` 算出来是 0.05 —— 稳稳落在「侧视」那一档。
///
/// **缝对上面那三个量一个都不影响**：左右同时平移 `gap`，中点只跟着平移，
/// 差与距离全都不变。所以精确性不因这条缝而打折扣。
///
/// 那条缝可以按 [suPose] 的 `sideGapScale` 放大，用来造出「门禁读成正视」的帧
/// —— 那正是仰卧起坐要拦住的那种站位（正视下身体的长边就是镜头方向本身）。
/// 至于为什么放大缝隙不等于「正视的仰卧起坐」，见那个参数的注释。
///
/// ## [suPose] 的 `scale`：这个人占画幅多大
///
/// 与 `synthetic_squat.dart` / `synthetic_slj.dart` 的 `scale` 同一个东西，
/// 以画面中心为原点等比放大整副骨架。**默认 1.0 时这个人只占画幅的 45%** ——
/// 正好压在门禁 `tooFarBelow`（0.45）那条线上，过是过了，只过 0.1%。
/// 会话层的测试要的是「一个站得住的人」，所以那边显式给一个更大的 `scale`，
/// 免得一条测试靠 0.1% 的余量活着。
///
/// 它**不改变任何比值**（那条缝、躯干长、肩宽全都一起缩），所以
/// [suShoulderRatio] 那个闭式期望值与 `knee_angle_*` 都不受它影响 ——
/// 这正是门禁的「距离」与「机位」两项判据必须互不干扰的那条性质。
library;

import 'dart:math' as math;

import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 合成帧的画幅边长（正方形）。像素坐标按它归一化。
const int suFrameSide = 1000;

// ---- 骨架的固定几何（归一化画幅坐标）----

/// 垫面的高度。**踝自始至终在它上面**，所以它同时是这个量纲的零点。
const double _matY = 0.70;

/// 髋中点的横坐标。臀在整组里钉在这里（起身时只有肩在动）。
const double _hipX = 0.50;

/// 躯干长（归一化画幅单位）。特征用它当分母，所以它必须是真的躯干长：
/// [suPose] 解出来的肩点严格落在以髋为圆心、半径为它的圆上。
const double _torsoLen = 0.20;

/// 大腿长与小腿长。两侧等长，于是膝点落在髋-踝的中垂线上，屈膝角有闭式解。
const double _thighLen = 0.10;
const double _shinLen = 0.10;

/// 左右同侧点的横向缝隙。侧视下本来就几乎重合，见文件头。
const double suSideGap = 0.01;

/// 仰卧平躺的躯干角。
///
/// 取 −87° 而不是 −90°：真实平躺时背弓让肩略高于垫（比值约 0.05），
/// 而正好 −90° 会让肩、髋、踝三点共线，`body_line_angle` 贴着 180° 边界，
/// 也会让「躺平」恰好压在比值的下界上。留 3° 的余量。
const double suLyingDeg = -87.0;

/// 坐起的躯干角。
///
/// 取 +26°（向脚那一侧前倾）而不是 0°：国标的收势是前倾（肘触膝），
/// 而 0°（躯干严格竖直）是比值 1 那个奇点 —— 取它会把合成帧造在阈值边界上，
/// 也会让「起没起来」这件事看起来比真实情况容易。
const double suSeatedDeg = 26.0;

/// 躺下/起身途中经过的躯干角（两条分段线的中间）。
const double suMidDeg = -60.0;

/// 屈膝角。国标要求屈膝约 90°。
const double suKneeDeg = 90.0;

/// 由躯干角与髋离垫算出 `shoulder_height_ratio` 的闭式值。
///
/// 测试拿它当期望值 —— 合成帧上真算出来的特征值应当**逐位**等于它。
double suShoulderRatio({double torsoDeg = suLyingDeg, double hipLift = 0.0}) {
  final rad = torsoDeg * math.pi / 180.0;
  final sin = math.sin(rad);
  final cos = math.cos(rad);
  final dy = hipLift - _torsoLen * cos;
  final torso = math.sqrt(_torsoLen * _torsoLen * sin * sin + dy * dy);
  return _torsoLen * cos / torso;
}

/// 造一帧仰卧起坐姿态。
///
/// - [torsoDeg]：躯干与竖直方向的夹角（度）。负 = 躺下、正 = 前倾坐起，
///   见 [suLyingDeg] / [suSeatedDeg]。**精确**。
/// - [hipLift]：髋抬离垫面多少（归一化画幅单位）。正 = 顶髋借力。
///   与比值的关系是近似的，见文件头。
/// - [kneeDeg]：`knee_angle_L` 与 `knee_angle_R` 的目标值，**精确**。
/// - [scale]：把人整体按画面中心缩放（1.0 = 原样），用来造「离得远 / 太近」
///   的站位。**它同时缩放所有像素距离**，而姿态判别用的全是比值 ——
///   所以缩放不改变任何特征值，只改变人占画幅多大。见文件头。
/// - [sideGapScale]：左右同侧点之间的横向缝隙的倍数（1.0 = 原样）。
///   **它唯一的用途是让门禁把那帧读成正视** —— 门禁的站位判据是
///   `(肩宽 + 髋宽) / (2 × 躯干长)`，缝隙放大到 15 倍左右就过 `frontalRatio`。
///   **这不是一个物理上站得住的「正视仰卧起坐」**：正视看躺着的人，视线沿着
///   身体的长边，得把整副骨架换个投影才画得出，不是缩放一个系数能得到的。
///   所以它只对「门禁给出什么结论」这一件事有意义，别拿它去验姿态类特征。
/// - [visibilityOverrides]：把某些点设成看不见。
PoseFrame suPose({
  required int timestampMs,
  double torsoDeg = suLyingDeg,
  double hipLift = 0.0,
  double kneeDeg = suKneeDeg,
  double scale = 1.0,
  double sideGapScale = 1.0,
  double visibility = 1.0,
  Map<L, double>? visibilityOverrides,
}) {
  // 膝角太小（趋近 0）会让髋-踝距离趋近 0，中垂线的方向就没有定义了。
  // 真实动作里不可能出现，出现即是调用方写错了参数 —— 与其解出一个 NaN，
  // 不如在原地响亮地说清楚。
  assert(kneeDeg >= 1.0, '屈膝角太小，合成几何解不出来（收到 $kneeDeg）');
  // 两侧等长是「膝点落在中垂线上」这个闭式解的前提，下面只用大腿长当半径。
  assert(_shinLen == _thighLen, '大小腿不等长时膝点不落在中垂线上，要另解');

  final gap = suSideGap * sideGapScale;
  final rad = torsoDeg * math.pi / 180.0;

  // 肩解在「以**贴在垫上的那个髋位**为圆心、半径 = 躯干长」的圆上，角度从竖直
  // 方向起算。于是躯干角与（无顶髋时的）比值都逐位可算。
  //
  // 圆心取的是**垫上的那份髋位**而不是抬起来的那份：顶髋借力时肩还留在垫上，
  // 所以抬起来的是髋、不是整个躯干。两个都抬的话造出来的是「人整体飘起来」，
  // 而 `body_line_offset_ratio` 对它**不敏感**（整段平移不改变髋相对连线的位置），
  // 那条规则就会变成一个测不出任何东西的形状。
  final hipY = _matY - hipLift;
  final shoulderX = _hipX + _torsoLen * math.sin(rad);
  final shoulderY = _matY - _torsoLen * math.cos(rad);

  // 踝踩在垫面上。膝角给定了髋-踝距离（两侧等长时 `d = 2·t·sin(θ/2)`），
  // 于是踝的横坐标由它反解 —— 髋抬起来时这个距离里含一个竖直分量，
  // 横坐标要减掉它（顶髋到超过整条腿的极端姿势会无解，夹到 0）。
  final kneeRad = kneeDeg * math.pi / 180.0;
  final hipToAnkle = 2 * _thighLen * math.sin(kneeRad / 2);
  final lift = _matY - hipY;
  final dx2 = hipToAnkle * hipToAnkle - lift * lift;
  final ankleX = _hipX + (dx2 > 0 ? math.sqrt(dx2) : 0.0);
  final ankleY = _matY;

  // 膝点：以髋、踝为圆心、半径各为大腿长/小腿长的两圆交点（两侧等长，
  // 于是它落在中垂线上）。两个交点里取**离垫子更远**的那一个 ——
  // 屈膝的膝盖朝上，不朝垫子。按 y 比大小来选，而不是按某个固定旋向：
  // 髋抬起来之后 u 的方向会翻，固定旋向会掉到垫子下面去。
  final midX = (_hipX + ankleX) / 2;
  final midY = (hipY + ankleY) / 2;
  final ux = ankleX - _hipX;
  final uy = ankleY - hipY;
  final uLen = math.sqrt(ux * ux + uy * uy);
  final half = uLen / 2;
  final hh = _thighLen * _thighLen - half * half;
  final h = hh > 0 ? math.sqrt(hh) : 0.0;
  final k1x = midX + h * uy / uLen;
  final k1y = midY - h * ux / uLen;
  final k2x = midX - h * uy / uLen;
  final k2y = midY + h * ux / uLen;
  final (kneeX, kneeY) = k1y <= k2y ? (k1x, k1y) : (k2x, k2y);

  final leftShoulder = (shoulderX, shoulderY);
  final leftHip = (_hipX, hipY);
  final leftKnee = (kneeX, kneeY);
  final leftAnkle = (ankleX, ankleY);

  // 其余的点（眼、耳、嘴）堆在头前方一点：可见、不参与仰卧起坐的任何特征。
  // 头接着躯干往远离髋的那一头长，于是躺下时在画面左边、坐起时在肩上方 ——
  // 与真人一致，也让「头是不是出画了」这类门禁测试有反例可用。
  final headX = shoulderX + 0.08 * (shoulderX - _hipX) / _torsoLen;
  final headY = shoulderY + 0.08 * (shoulderY - hipY) / _torsoLen;

  final points = <L, (double, double)>{
    L.leftShoulder: leftShoulder,
    L.rightShoulder: (shoulderX + gap, shoulderY),
    L.leftElbow: (shoulderX + gap / 2, shoulderY + 0.06),
    L.rightElbow: (shoulderX + gap / 2 + gap, shoulderY + 0.06),
    L.leftWrist: (shoulderX + gap / 2, shoulderY + 0.02),
    L.rightWrist: (shoulderX + gap / 2 + gap, shoulderY + 0.02),
    L.leftHip: leftHip,
    L.rightHip: (_hipX + gap, hipY),
    L.leftKnee: leftKnee,
    L.rightKnee: (kneeX + gap, kneeY),
    L.leftAnkle: leftAnkle,
    L.rightAnkle: (ankleX + gap, ankleY),
    // 脚跟与脚尖不参与仰卧起坐的任何特征，但给出来更接近真实帧 ——
    // 也正因为它们给了，「某只脚出画会被拦住」那类门禁测试才有反例可用。
    L.leftHeel: (ankleX - 0.02, ankleY + 0.01),
    L.rightHeel: (ankleX - 0.02 + gap, ankleY + 0.01),
    L.leftFootIndex: (ankleX + 0.02, ankleY + 0.01),
    L.rightFootIndex: (ankleX + 0.02 + gap, ankleY + 0.01),
  };

  // 以画面中心为原点缩放。**所有点一起缩、`fill` 也一起缩** ——
  // 漏掉 `fill` 的话头顶那堆点会留在原地，包围盒的上边缘不听缩放的话，
  // 「离得远」就测不出来了。见 [suPose] 的 `scale` 参数。
  //
  // 它放在最后一步、而不是把 `_torsoLen` 那些常量乘一遍：后面那些附加偏移
  // （肘、腕、脚跟）是**绝对量**，逐处乘一遍就会漏掉一两处，而漏掉的表现是
  // 「这张合成脸不合比例」，没人看得出来。
  (double, double) at((double, double) p) => (
        0.5 + (p.$1 - 0.5) * scale,
        0.5 + (p.$2 - 0.5) * scale,
      );

  return poseFrameFromPoints(
    frameWidth: suFrameSide,
    frameHeight: suFrameSide,
    timestampMs: timestampMs,
    fill: at((headX, headY)),
    visibility: visibility,
    visibilityOverrides: visibilityOverrides,
    points: {for (final e in points.entries) e.key: at(e.value)},
  );
}

/// 一个姿态段：连续 [count] 帧，三个自变量固定。
///
/// 用「段」描述而不是逐帧列表：缺陷总是出现在某一个相位里（躺平那一段肩没贴到垫、
/// 整段顶着髋借力），段读起来与动作一一对应。
class SuSegment {
  const SuSegment({
    this.count = 14,
    this.torsoDeg = suLyingDeg,
    this.hipLift = 0.0,
    this.kneeDeg = suKneeDeg,
    this.scale = 1.0,
  });

  final int count;
  final double torsoDeg;
  final double hipLift;
  final double kneeDeg;
  final double scale;
}

/// 把若干段拼成帧流，时间戳连续。
List<PoseFrame> suFromSegments(
  List<SuSegment> segments, {
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
}) {
  final frames = <PoseFrame>[];
  for (final segment in segments) {
    final start = startTimestampMs + frames.length * frameIntervalMs;
    for (var i = 0; i < segment.count; i++) {
      frames.add(suPose(
        timestampMs: start + i * frameIntervalMs,
        torsoDeg: segment.torsoDeg,
        hipLift: segment.hipLift,
        kneeDeg: segment.kneeDeg,
        scale: segment.scale,
      ));
    }
  }
  return frames;
}

/// 坐在垫上的段。`SEATED` 是仰卧起坐的 `restingState`，开场与收尾都用它。
const SuSegment suSeated = SuSegment(torsoDeg: suSeatedDeg);

/// 躺下/起身途中经过的一段。
const SuSegment suMid = SuSegment(torsoDeg: suMidDeg);

/// 仰卧贴垫的一段。
const SuSegment suLying = SuSegment(torsoDeg: suLyingDeg);

/// 一次标准仰卧起坐：坐起 → 躺下 → 躺平 → 起身 → 回到坐起。
///
/// 回到 `SEATED` 的那一帧封存一次 rep。
///
/// 中间那两段（[suMid]）不能省：状态机要在 [TrackingConfig.minDwellFrames]
/// 与投票窗口里攒够同类证据才换相，而 `SEATED→LYING` 不是一条边 ——
/// 少了下放段，躺平那一段会先在 `LOWERING` 里被投票，行为与真实动作对不上。
List<PoseFrame> suRepFrames({
  required int startTimestampMs,
  int frameIntervalMs = 33,
  double torsoDeg = suSeatedDeg,
  double lieTorsoDeg = suLyingDeg,
  double hipLift = 0.0,
  double kneeDeg = suKneeDeg,
  double scale = 1.0,
}) =>
    suFromSegments(
      [
        SuSegment(torsoDeg: torsoDeg, hipLift: hipLift, kneeDeg: kneeDeg, scale: scale),
        SuSegment(torsoDeg: suMidDeg, hipLift: hipLift, kneeDeg: kneeDeg, scale: scale),
        SuSegment(
          torsoDeg: lieTorsoDeg, hipLift: hipLift, kneeDeg: kneeDeg, scale: scale,
        ),
        SuSegment(torsoDeg: suMidDeg, hipLift: hipLift, kneeDeg: kneeDeg, scale: scale),
        SuSegment(torsoDeg: torsoDeg, hipLift: hipLift, kneeDeg: kneeDeg, scale: scale),
      ],
      startTimestampMs: startTimestampMs,
      frameIntervalMs: frameIntervalMs,
    );

/// 连续坐在垫上的帧。`SEATED` 是状态机的 `restingState`，也是「一次做完」
/// 那一刻的姿势 —— 领域层的分段测试用它当收势。
///
/// **它不是产品流程里的标定姿势**：坐着的人在门禁的距离判据下会被判「离得远」
/// （见 [suPose] 的 `scale` 与 `su_session_test.dart` 里那条记账断言）。
/// 会话层的测试用 [suLyingFrames]。
List<PoseFrame> suSeatedFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        suPose(
          timestampMs: startTimestampMs + i * frameIntervalMs,
          torsoDeg: suSeatedDeg,
          scale: scale,
        ),
    ];

/// 连续躺在垫上的帧。
///
/// 这是**产品流程里的起始与标定姿势**：门禁的距离判据拿「躺着的人」量出来的
/// 占比是过得去的，而坐着的人过不去（同理见 [suSeatedFrames]）。
/// 相机页的自动倒计时以「门禁放行」为条件，所以起始姿势必须是躺着的 ——
/// `suSpec.framingHint` 说的正是这句话。
List<PoseFrame> suLyingFrames({
  required int count,
  int startTimestampMs = 0,
  int frameIntervalMs = 33,
  double scale = 1.0,
}) =>
    [
      for (var i = 0; i < count; i++)
        suPose(
          timestampMs: startTimestampMs + i * frameIntervalMs,
          torsoDeg: suLyingDeg,
          scale: scale,
        ),
    ];
