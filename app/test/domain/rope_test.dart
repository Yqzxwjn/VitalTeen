/// 跳绳动作定义测试。
///
/// 这里钉住六类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **防抖参数必须是引擎允许的最小那一组（2/2/1）。** 引擎默认的 5/4/3 在
///    跳绳上不是「稳一点」，而是**让状态机永远走不出 `GROUND`** —— 下面那条
///    「同一批帧，换默认参数就一次都数不出来」的用例量的就是这件事，而它在
///    屏幕上什么错都不报（HUD 一直显示「双脚着地」）。
/// 2. **`CUSHION` 是结构上必需的，不是多绕一步。** 两态环（`GROUND ⇄ AIR`）下
///    封存发生在脚尖刚碰到地面的那一帧，落地缓冲整个落在 rep 窗口之外 ——
///    于是下面那条「屈膝 170° 判缓冲不足」的用例会**变成永远不命中**。
///    封存窗口的帧数断言是这条结论的直接证据。
/// 3. **`CUSHION → GROUND` 必须同时看脚尖与膝角。** 只看脚尖的话触地那一帧就
///    成立（回到第 2 条）；只看膝角的话腾空时腿是伸直的、这条在半空恒真。
///    下面那条「落地后一直蹲着不站直」的用例专判后半句：它必须**卡在 CUSHION
///    直到超时被丢弃**，而不是在半空中或者刚触地时草草封存。
/// 4. **三条规则各自只在违规时命中，且两个方向都断言。** 只断言「违规时命中」
///    的话，一条永远命中的规则也是绿的；只断言「合规时不命中」的话，一条永远
///    不命中的规则也是绿的。
/// 5. **站立基线缺席就抛，不取 0。** 取 0 的话三条分段线全部落在「贴着画面
///    下缘」上，每一帧都会被读成腾空 —— 状态机在 `AIR` 与 `CUSHION` 之间空转。
/// 6. **`rope.buffer_max_knee_angle` 必须低于「膝回到站立线」那条分段线。**
///    这是本动作独有的一条阈值-分段关系：封存的门槛保证了每一次被计数的 rep
///    膝角一定回到过站立线附近，而缓冲不足规则量的正是这一段里的**最小值**。
///    阈值高过那条线的话，「合规」的人反而会被判命中。
///
/// 阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
/// 与真实资产的对照在「真实阈值表」那组里（那一组在资产落地后才加）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/rope.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_rope.dart';

/// 站立基线。跳绳**只读其中的 `footHeight`**，但另外三个仍然是
/// `Calibrator` 的必采项（它们在任何机位下都算得出），所以照实填上。
Calibration _standingCalibration() => Calibration(
      kneeAngle: 175.0,
      trunkLean: 0,
      heelRiseRatio: 0.0,
      frames: 15,
      footHeight: ropeFootHeightRatio(),
    );

/// 内联阈值表。取值刻意离合成帧的读数远一点，免得断在阈值同侧的边界上：
///
/// - 缓冲不足：合规的落地屈到 140°、违规的只屈到 170°，阈 150°；
/// - 躯干前倾：合规 4°、违规 20°，阈 10°（相对本人站立基线 0°）；
/// - 单脚落地：合规两脚等高、违规差 0.04（比值 0.20），阈 0.10。
///
/// 三个都是正数：三条规则问的都是「这个量**够不够小**」，方向统一朝上。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: ropeActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('rope.buffer_max_knee_angle', 150.0, 'knee_angle_L',
            unit: 'deg'),
        _threshold('rope.trunk_lean_max_delta', 10.0, 'trunk_lean', unit: 'deg'),
        _threshold('rope.foot_gap_max_ratio', 0.10, 'foot_gap_ratio'),
      ],
      version: 'test',
    );

/// 与产品一致：跳绳走 45° 主链路，**防抖参数取默认值**（`buildRope` 自己覆盖）。
ActionDefinition _definition({TrackingConfig? config}) =>
    buildRope(_standingCalibration(), config: config);

ActionRunner _runner() => ActionRunner(
      _definition(),
      thresholds: _localTable(),
      calibration: _standingCalibration(),
    );

void _feed(ActionRunner runner, List<PoseFrame> frames) {
  for (final frame in frames) {
    runner.feed(frame);
  }
}

/// 取出某个状态的出边守卫，用来单独验证分段条件。
Guard _guardOf(ActionDefinition definition, String src, String dst) =>
    definition.transitions
        .firstWhere((t) => t.src == src && t.dst == dst)
        .guard;

/// 取出某条错误的组级统计，没有则返回 null。
FaultStat? _statOf(SetSummary summary, String code) {
  for (final stat in summary.faultStats) {
    if (stat.code == code) return stat;
  }
  return null;
}

/// 产品机位下读一帧的特征值。
///
/// **必须显式给这个机位**：两个脚尖特征都声明 `views: [sagittal, oblique45]`，
/// 用别的机位读出来的是 `view_mismatch` 而不是数值 —— 而那是静默的
/// （`get` 返回 null），测试会以一个看不懂的方式失败。
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄少一条边', () {
      // 这两条线全是可调的工程参数。调乱之后状态机不会报错，只会少一条边 ——
      // 表现是「计数偶尔不对」，离病因很远。两种调法各验一次。
      expect(
        () => _definition(
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            ropeTakeoffRatio: 0.05,
            ropeLandRatio: 0.08,
          ),
        ),
        throwsA(isA<ExerciseException>()),
        reason: '落地线高过起跳线：AIR 会一闪而过',
      );
      expect(
        () => _definition(
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            ropeLandRatio: 0.03,
            ropeSettleRatio: 0.04,
          ),
        ),
        throwsA(isA<ExerciseException>()),
        reason: '稳定线高过落地线：CUSHION 一进去就被封存，缓冲段又落到窗口外',
      );
    });

    test('脚尖高度基线缺席时当场抛，不取 0', () {
      // 取 0 的话三条线全部落在「贴着画面下缘」上，每一帧都被读成腾空。
      // 这里直接构造一个没有 `footHeight` 的标定结果 —— 也就是「这个动作没有
      // 采集它」的真实形态，而不是传一个 0 进去。
      final without = Calibration(
        kneeAngle: 175.0,
        trunkLean: 0,
        heelRiseRatio: 0.0,
        frames: 15,
      );
      expect(() => buildRope(without), throwsA(isA<ExerciseException>()));
    });

    test('防抖参数就是跳绳那一组，不是引擎默认', () {
      final config = _definition().config;
      expect(config.voteWindow, 2);
      expect(config.voteRequired, 2);
      expect(config.minDwellFrames, 1);
      expect(config.maxRepFrames, 60, reason: '一次真实跳跃约 8–15 帧，60 是它的四倍');
      expect(config.cameraView, CameraView.oblique45);
    });

    test('同一批帧换引擎默认参数就一次都数不出来 —— 这不是「稳一点」', () {
      // **这是本文件里最值钱的一条断言。** 引擎默认的 5/4/3 让每个状态都要
      // 攒满 5 帧票才可能转移，而一次跳绳的腾空段在 20 fps 下只有 4–6 帧：
      // 状态机永远走不出 `GROUND`，屏幕上什么都不报。
      // 把它钉在这里，是为了让「顺手把参数改回默认」这件事红在测试上。
      final frames = ropeRepFrames(startTimestampMs: 0);

      final tuned = _runner();
      _feed(tuned, frames);
      expect(tuned.repCount, 1, reason: '跳绳那一组参数下这一次必须数得上');

      final defaulted = ActionRunner(
        _definition(
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            maxRepFrames: 60,
          ),
        ),
        thresholds: _localTable(),
        calibration: _standingCalibration(),
      );
      _feed(defaulted, frames);
      expect(
        defaulted.repCount,
        0,
        reason: '引擎默认那一组下这次数不出来 —— 而这正是它必须被覆盖的理由',
      );
      // 而且机器**落在人的后面**：这批帧喂完时人早就站回地面了，机器却刚到
      // 「落地缓冲」这一步。它不是「谨慎」，是慢了一整个相位 —— 每一帧 HUD
      // 上都是一个与人当前姿势无关的词。
      expect(
        defaulted.currentState,
        isNot(RopeStates.ground),
        reason: '喂完整批帧机器还没回到起步状态，说明它落了一个相位',
      );
    });

    test('三条规则只挂一条基线偏移：躯干前倾那一条', () {
      final definition = _definition();
      expect(
        definition.thresholdOffsets.keys.toList(),
        ['rope.trunk_lean_max_delta'],
      );
      // 膝角是关节夹角、脚尖高差是已归一化的比值，两者挂基线只引入噪声；
      // 尤其 `foot_gap_ratio`：站稳的人它是 0，挂基线等于把阈值定在 0 附近，
      // 那条规则会变成「每一次都命中」。
      expect(
        definition.thresholdOffsets['rope.foot_gap_max_ratio'],
        isNull,
      );
    });

    test('相位映射刻意留空，三条规则全跑在整段上', () {
      // 落地缓冲那一段只有 2–5 帧；把它切成一个相位窗口会让「屈得最深的那一帧」
      // 有大概率落在窗口外，而 `RepWindow.select` 对缺失相位**退化为整段**
      // —— 那是一条静默的误判路径。空表 + `Phase.all` 是刻意的，不是漏了。
      final definition = _definition();
      expect(definition.stateToPhase, isEmpty);
      for (final rule in definition.rules) {
        expect(rule.phase, Phase.all, reason: rule.code);
      }
    });

    test('默认机位是 45°：三个判据在正视下读不出来', () {
      final definition = _definition();
      expect(definition.cameraView, CameraView.oblique45);

      final frame = ropePose(timestampMs: 0, kneeDeg: ropeFlexedDeg);
      const oblique = FeatureExtractor(cameraView: CameraView.oblique45);
      for (final code in [
        'knee_angle_L',
        'trunk_lean',
        'foot_height_ratio',
        'foot_gap_ratio',
      ]) {
        expect(oblique.extract(frame).get(code), isNotNull, reason: code);
      }
      // 而正视下两个脚尖特征都读不出来：脚尖的「高度」在正面就是镜头方向，
      // 左右脚尖的高度差同理。判据缺一个 = 少一条规则，而它不报错。
      const frontal = FeatureExtractor(cameraView: CameraView.frontal);
      for (final code in ['foot_height_ratio', 'foot_gap_ratio']) {
        expect(frontal.extract(frame).get(code), isNull, reason: code);
      }
    });
  });

  group('合成姿态的数值', () {
    test('站立时脚尖高度比恰好是 1.0，且与闭式解逐位相同', () {
      // 这条同时是合成帧几何的自检 —— 它错了，下面所有分段与规则的用例
      // 都是在测一个别的动作。
      final frame = ropePose(timestampMs: 0);
      expect(
        _feature(frame, 'foot_height_ratio'),
        closeTo(ropeFootHeightRatio(), 1e-9),
      );
      expect(ropeFootHeightRatio(), closeTo(1.0, 1e-9));
    });

    test('屈膝一个像素都不动脚尖 —— 这是整个合成器的构造不变量', () {
      // **真机上这两件事是独立的**（腿弯下去、脚还踩在地上），而跳绳的分段
      // 信号是脚尖的高度。要是屈膝也把脚尖抬高，一次落地缓冲会被读成一次起跳。
      // 所以 `kneeDeg` 只能改髋以上的高度。
      for (final deg in [178.0, 150.0, 120.0]) {
        final frame = ropePose(timestampMs: 0, kneeDeg: deg, lift: 0.03);
        expect(_feature(frame, 'knee_angle_L'), closeTo(deg, 1e-9));
        expect(_feature(frame, 'knee_angle_R'), closeTo(deg, 1e-9));
        expect(
          _feature(frame, 'foot_height_ratio'),
          closeTo(ropeFootHeightRatio(lift: 0.03), 1e-9),
          reason: '膝角 $deg° 时脚尖高度不许跟着变',
        );
      }
    });

    test('抬脚只改脚尖高度，不改任何关节角', () {
      final standing = ropePose(timestampMs: 0, trunkDeg: 5, kneeDeg: 160);
      final airborne =
          ropePose(timestampMs: 0, lift: ropeAirborne, trunkDeg: 5, kneeDeg: 160);
      for (final code in ['knee_angle_L', 'trunk_lean']) {
        expect(_feature(airborne, code), closeTo(_feature(standing, code)!, 1e-9),
            reason: code);
      }
      expect(
        _feature(airborne, 'foot_height_ratio')! -
            _feature(standing, 'foot_height_ratio')!,
        closeTo(ropeAirborne / 0.20, 1e-9),
        reason: '抬高一帧的增量恰好是 高度/躯干长',
      );
    });

    test('两脚尖高度差恰好等于它除以躯干长', () {
      for (final gap in [0.0, 0.02, 0.04]) {
        final frame = ropePose(timestampMs: 0, toeGap: gap);
        expect(
          _feature(frame, 'foot_gap_ratio'),
          closeTo(ropeFootGapRatio(toeGap: gap), 1e-9),
          reason: 'toeGap=$gap',
        );
      }
      expect(ropeFootGapRatio(toeGap: 0.04), closeTo(0.20, 1e-9));
    });

    test('躯干倾角逐位等于传入值 —— 两侧符号都验', () {
      // 符号只对「哪一侧」有意义（同深蹲那一条），所以规则那边取绝对值，
      // 而合成器必须能把两侧都造出来。
      for (final deg in [-20.0, -4.0, 0.0, 4.0, 20.0]) {
        expect(
          _feature(ropePose(timestampMs: 0, trunkDeg: deg), 'trunk_lean'),
          closeTo(deg, 1e-9),
          reason: 'trunkDeg=$deg',
        );
      }
    });

    test('缩放不改变任何角度与前两个比值，只改脚尖高度比', () {
      // **这个不对称是这个特征的定义，不是合成器的缺陷**：
      // `foot_height_ratio` 的分子是「画面下缘到脚尖」的像素距离，
      // 而画面下缘不跟着人缩放（缩放以画面中心为原点）。
      // 真机上它就是「离镜头远近」。三件事各验一次。
      const scale = 1.5;
      final near = ropePose(timestampMs: 0, scale: scale, kneeDeg: 160, toeGap: 0.02);
      final far = ropePose(timestampMs: 0, kneeDeg: 160, toeGap: 0.02);

      expect(_feature(near, 'knee_angle_L'), closeTo(_feature(far, 'knee_angle_L')!, 1e-9));
      expect(_feature(near, 'trunk_lean'), closeTo(_feature(far, 'trunk_lean')!, 1e-9));
      expect(
        _feature(near, 'foot_gap_ratio'),
        closeTo(_feature(far, 'foot_gap_ratio')!, 1e-9),
        reason: '高差是差值，缩放把分子分母一起约掉',
      );
      expect(
        _feature(near, 'foot_height_ratio'),
        closeTo(ropeFootHeightRatio(toeGap: 0.02, scale: scale), 1e-9),
        reason: '而离地高度是按定义跟着缩放走的',
      );
      expect(
        _feature(near, 'foot_height_ratio'),
        lessThan(_feature(far, 'foot_height_ratio')!),
        reason: '离得近 → 脚尖离画面下缘更近 → 读数更小',
      );
    });
  });

  group('分段', () {
    test('标准一次计 1，回到双脚着地', () {
      final runner = _runner();
      _feed(runner, ropeRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, RopeStates.ground);
    });

    test('封存窗口包含落地缓冲那一段 —— 这是 CUSHION 存在的全部理由', () {
      // 窗口从**离开 GROUND 的那一帧**开始（那一帧机器已经进了 AIR）、到
      // **重新进入 GROUND 的那一帧**结束：腾空 4 + 落地缓冲 4 + 落地 1 = 9 帧。
      // 起跳前那几帧站姿不在里面（等待期不保留历史，那是刻意的）。
      //
      // **两态环下这里会少掉整整一半**：封存发生在脚尖刚碰到地面的那一帧，
      // 窗口只剩腾空那几帧 —— 而 `ROPE_LOW_BUFFER` 量的正是被切掉的落地缓冲
      // 那一段，它会变成一条永远不命中的规则（见下面那条用例）。
      final runner = _runner();
      _feed(runner, ropeRepFrames(startTimestampMs: 0));

      expect(runner.windows, hasLength(1));
      final frames = runner.windows.single.frames;
      expect(frames, hasLength(9));
      expect(
        frames.last.get('knee_angle_L'),
        closeTo(ropeStandDeg, 1e-6),
        reason: '窗口最后一帧是「膝回到站立线」的那一帧',
      );

      // 窗口里膝角的**最小值**必须是落地缓冲那一帧的读数，不是腾空时的直腿。
      final knees = frames.map((f) => f.get('knee_angle_L')).whereType<double>();
      expect(knees.reduce((a, b) => a < b ? a : b), closeTo(ropeFlexedDeg, 1e-6));
    });

    test('两态环的对照：封存点提前到触地那一帧，落地缓冲就不在窗口里了', () {
      // 上面那条窗口帧数说的是「窗口够长」，这条说的是**为什么够长**：
      // 把 `restingState` 与 `bottomState` 换成一对两态环
      //（`GROUND ⇄ AIR`，落地直接判回 GROUND），同一批帧的窗口会短掉落地
      // 缓冲那一段。这正是 `CUSHION` 存在的理由，也是它必须**在计数点之前**
      // 的原因 —— 不是多绕一步，是把证据挪进窗口。
      //
      // 这里不重新构造一个两态定义（那要复制整份规则表，改动一旦漂移就失去
      // 意义），而是直接对着状态机的转移顺序断言：**从 AIR 出去的第一条边
      // 不能是「回到 GROUND」**。那一步一旦被谁简化掉，窗口长度会静默缩水。
      final definition = _definition();
      final fromAir = definition.transitions
          .where((t) => t.src == RopeStates.air)
          .map((t) => t.dst)
          .toList();
      expect(fromAir, [RopeStates.cushion]);
      expect(
        definition.transitions
            .where((t) => t.src == RopeStates.air && t.dst == RopeStates.ground),
        isEmpty,
        reason: 'AIR 直接落回 GROUND 的话，封存会发生在脚尖刚触地的那一帧',
      );
    });

    test('站着不动：不计也不弃', () {
      final runner = _runner();
      _feed(runner, ropeStandingFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '站着不该被记账成一次丢弃');
      expect(runner.currentState, RopeStates.ground);
    });

    test('原地提踵：脚尖抬不到起跳线，不计也不弃', () {
      // 脚尖抬到 0.015（比值 +0.075）—— 落在起跳线（+0.10）之下。
      // 这是「不够高」那一边的边界：`bottomState = AIR` 意味着没离地的那一次
      // **根本不算一次**，走 `discardedReps` 而不是计数。
      final runner = _runner();
      _feed(
        runner,
        [
          ...ropeStandingFrames(count: 4),
          ...ropeFromSegments([
            const RopeSegment(count: 6, lift: 0.015, kneeDeg: 176.0),
          ], startTimestampMs: 4 * 33),
          ...ropeStandingFrames(count: 6, startTimestampMs: 10 * 33),
        ],
      );

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '压根没进过 AIR，不该算一次丢弃');
      expect(runner.currentState, RopeStates.ground);
    });

    test('落地后一直蹲着不站直：卡在 CUSHION 直到超时被丢弃', () {
      // **这条专判「膝角回到站立线」那半句守卫。** 脚尖早在触地那一帧就贴回
      // 地面了，所以只靠脚尖的话这一次会在触地后两三帧内封存 —— 而这种人
      // （落地就不起来了）恰恰是缓冲不足规则最该说的那一类。
      final runner = _runner();
      _feed(
        runner,
        [
          ...ropeStandingFrames(count: 4),
          ...ropeFromSegments([
            const RopeSegment(count: 5, lift: ropeAirborne, kneeDeg: 176.0),
            // 脚尖已经贴回稳定线以下，但膝角一直停在 150°（远低于站立线 167°）。
            const RopeSegment(count: 70, lift: ropeSettledLift, kneeDeg: ropeFlexedDeg),
          ], startTimestampMs: 4 * 33),
        ],
      );

      expect(runner.repCount, 0, reason: '这一次没做完，不该计数');
      expect(runner.discardedReps, 1, reason: '超过 maxRepFrames 被丢弃');
    });

    test('缓冲没吃完又跳起来：仍然数得上', () {
      // `CUSHION → AIR` 那条回退边的用途。没有它的话，连跳的人第二次起跳时
      // 机器停在 CUSHION 上直到超时 —— 而 HUD 上一直显示「落地缓冲」。
      final runner = _runner();
      _feed(
        runner,
        [
          ...ropeStandingFrames(count: 4),
          ...ropeFromSegments([
            const RopeSegment(count: 5, lift: ropeAirborne, kneeDeg: 176.0),
            const RopeSegment(count: 3, lift: ropeCushionLift, kneeDeg: ropeFlexedDeg),
            // 缓冲还没吃完就蹬上去了
            const RopeSegment(count: 5, lift: ropeAirborne, kneeDeg: 176.0),
            const RopeSegment(count: 4, lift: ropeCushionLift, kneeDeg: ropeFlexedDeg),
            const RopeSegment(count: 4, lift: ropeSettledLift, kneeDeg: ropeStandDeg),
          ], startTimestampMs: 4 * 33),
        ],
      );

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, RopeStates.ground);
    });

    test('守卫的上下界：三条线各验两侧', () {
      // 上面那些分段测试一旦变绿，也可能是因为「压根没离开 GROUND」。
      // 这里直接对守卫求值，把三条线的两侧都钉住。
      final definition = _definition();
      final calibration = _standingCalibration();
      final base = calibration.footHeight!;

      bool air(double ratio, {double knee = 176.0}) => _guardOf(
            definition,
            RopeStates.ground,
            RopeStates.air,
          ).call({'foot_height_ratio': ratio, 'knee_angle_L': knee});

      bool landed(double ratio) => _guardOf(
            definition,
            RopeStates.air,
            RopeStates.cushion,
          ).call({'foot_height_ratio': ratio});

      bool recovered(double ratio, double knee) => _guardOf(
            definition,
            RopeStates.cushion,
            RopeStates.ground,
          ).call({'foot_height_ratio': ratio, 'knee_angle_L': knee});

      // 起跳线：高于它才成立，等于不成立
      expect(air(base + 0.10), isFalse);
      expect(air(base + 0.1001), isTrue);

      // 落地线：低于它才成立
      expect(landed(base + 0.05), isFalse);
      expect(landed(base + 0.0499), isTrue);

      // 封存：脚尖贴回稳定线以下 **且** 膝角回到站立线以上，缺一不可
      expect(recovered(base + 0.02, calibration.kneeAngle), isFalse);
      expect(recovered(base + 0.0199, calibration.kneeAngle - 8.0), isFalse,
          reason: '膝角恰好落在站立线上不算「回到」');
      expect(recovered(base + 0.0199, calibration.kneeAngle - 7.9), isTrue);

      // **CUSHION 的两条出边互斥**：一条要求高于起跳线、一条要求低于稳定线，
      // 相隔 (takeoff − settle)。同时成立的话状态机会按顺序取第一条，
      // 而那是「每一次落地都立刻又跳起来」。
      final middle = base + 0.03;
      expect(air(middle), isFalse);
      expect(recovered(middle, calibration.kneeAngle), isFalse);

      // 而「取不到这个量」时四条守卫全都不成立 —— 不能拿 0 顶替
      //（0 在量纲上正是「贴着画面下缘」，用它会凭空造出「已经落地」的结论）。
      for (final (src, dst) in [
        (RopeStates.ground, RopeStates.air),
        (RopeStates.air, RopeStates.cushion),
        (RopeStates.cushion, RopeStates.ground),
        (RopeStates.cushion, RopeStates.air),
      ]) {
        expect(
          _guardOf(definition, src, dst).call(const {}),
          isFalse,
          reason: '$src→$dst 在指标缺失时不该成立',
        );
      }
      // 膝角缺一帧也不许封存：那时 `_meanKnee` 两侧都取不到。
      expect(
        _guardOf(definition, RopeStates.cushion, RopeStates.ground)
            .call({'foot_height_ratio': base + 0.01}),
        isFalse,
        reason: '只看脚尖的话触地那一帧就会封存 —— 缓冲段又落到窗口之外',
      );
    });
  });

  group('三条规则', () {
    test('落地缓冲不足：只命中直腿砸下来的那一次，两个方向都断言', () {
      // 合规：屈到 140°（低于阈 150°）；违规：只屈到 170°（最低点都在阈值之上）。
      // 阈值必须**低于**「膝回到站立线」（175 − 8 = 167°），否则第二次封存就被
      // 卡住 —— 那种人会被整组丢弃（上面那条 CUSHION 卡死的用例）。
      final stiff = _runner();
      _feed(stiff, ropeRepFrames(startTimestampMs: 0, kneeDeg: 170.0));
      expect(stiff.repCount, 1, reason: '直腿落地照样算一次，只是要指出来');
      expect(_statOf(stiff.finishSet(), 'ROPE_LOW_BUFFER'), isNotNull);

      final soft = _runner();
      _feed(soft, ropeRepFrames(startTimestampMs: 0, kneeDeg: 140.0));
      expect(soft.repCount, 1);
      expect(
        _statOf(soft.finishSet(), 'ROPE_LOW_BUFFER'),
        isNull,
        reason: '屈到 140° 是合规的缓冲，不该被判不足 —— 否则这条规则是「永远命中」',
      );
    });

    test('躯干前倾：只命中趴下去的那一次，且相对本人站立基线', () {
      // 阈值 10° 挂在站立基线（0°）上 → 有效阈值 10°。
      final leaning = _runner();
      _feed(leaning, ropeRepFrames(startTimestampMs: 0, trunkDeg: 20.0));
      expect(leaning.repCount, 1);
      expect(_statOf(leaning.finishSet(), 'ROPE_TRUNK_LEAN'), isNotNull);

      final upright = _runner();
      _feed(upright, ropeRepFrames(startTimestampMs: 0, trunkDeg: 4.0));
      expect(
        _statOf(upright.finishSet(), 'ROPE_TRUNK_LEAN'),
        isNull,
        reason: '4° 是正常的前后摆动，不该命中',
      );

      // 符号不是体育含义（取决于人面朝画面哪一侧）：往另一侧趴同样要命中，
      // 所以规则用 `useAbs`。不取绝对值的话这条规则只惩罚一半的人。
      final leaningOther = _runner();
      _feed(leaningOther, ropeRepFrames(startTimestampMs: 0, trunkDeg: -20.0));
      expect(_statOf(leaningOther.finishSet(), 'ROPE_TRUNK_LEAN'), isNotNull);

      // 而「比本人站着时多前倾了多少」——站着本来就带前倾的人不该被判错。
      final sloucher = ActionRunner(
        _definition(),
        thresholds: _localTable(),
        calibration: Calibration(
          kneeAngle: 175.0,
          trunkLean: 7.0,
          heelRiseRatio: 0.0,
          frames: 15,
          footHeight: ropeFootHeightRatio(),
        ),
      );
      _feed(sloucher, ropeRepFrames(startTimestampMs: 0, trunkDeg: 12.0));
      expect(
        _statOf(sloucher.finishSet(), 'ROPE_TRUNK_LEAN'),
        isNull,
        reason: '12° 只比本人的 7° 多了 5°，在 10° 的增量之内',
      );
    });

    test('单脚落地：只命中两脚尖一高一低的那一次', () {
      // 阈值是**绝对**比值 0.10（不挂基线）：站稳的人两脚尖本来等高，
      // 挂基线只会得到「0 × 系数 ≈ 0」，那条规则会永远命中。
      //
      // 0.04 的高度差 = 比值 0.20，是阈值两倍。
      // 注意它同时把**站立基线**压低了 0.10（中点跟着走），但两条分段线记的是
      // 增量，所以这一次照样起跳、照样计数 —— 这正是「基线相对量」的好处。
      final oneLegged = _runner();
      _feed(oneLegged, ropeRepFrames(startTimestampMs: 0, toeGap: 0.04));
      expect(oneLegged.repCount, 1);
      expect(_statOf(oneLegged.finishSet(), 'ROPE_SINGLE_LEG'), isNotNull);

      final bothLegs = _runner();
      _feed(bothLegs, ropeRepFrames(startTimestampMs: 0));
      expect(
        _statOf(bothLegs.finishSet(), 'ROPE_SINGLE_LEG'),
        isNull,
        reason: '双脚同时起落不该被判单脚 —— 否则这条规则是「永远命中」',
      );
    });

    test('一次干净的跳绳三条都不命中', () {
      // 与上面三条合起来才构成「两个方向都断言」：这条是一次性检查
      // 「三条规则之间不会互相误触发」。
      final runner = _runner();
      _feed(runner, ropeRepFrames(startTimestampMs: 0));
      final summary = runner.finishSet();
      expect(runner.repCount, 1);
      expect(summary.faultStats, isEmpty);
    });
  });

  group('阈值表的三个键', () {
    test('规则引用的键与内联表对得上，且都是正的', () {
      final definition = _definition();
      final table = _localTable();
      for (final rule in definition.rules) {
        final value = table.get(rule.thresholdKey).value;
        expect(value.isFinite && value > 0, isTrue,
            reason: '${rule.code} 的阈值取到了 0、负数或非有限值');
      }
    });

    test('缓冲阈值必须低于「膝回到站立线」，否则合规的人被判错', () {
      // **本动作独有的一条阈值-分段关系**（阈值表里那条 `_note` 说的就是它）：
      // `CUSHION → GROUND` 的守卫保证每一次被计数的 rep 膝角都回到过
      // `站立膝角 − standingHysteresisDeg`；而 `ROPE_LOW_BUFFER` 取的是窗口内
      // 膝角的**最小值**。阈值高过那条线的话，**每一次**rep 的最小值都会超过它
      // —— 包括那些老老实实屈膝到 140° 的人。
      final definition = _definition();
      final calibration = _standingCalibration();
      final standLine =
          calibration.kneeAngle - definition.config.standingHysteresisDeg;
      final limit = _localTable().get('rope.buffer_max_knee_angle').value;

      expect(
        limit,
        lessThan(standLine),
        reason: '阈值 $limit 必须低于站立线 $standLine，否则这条规则永远命中',
      );
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表，键名与资产表一致、数值不必一致 —— 于是「资产表里
    // 少了一行」这件事它们一个都发现不了。而漏行的后果很重：`FaultPresenter` 与
    // `FormScorer` 都在**构造期**把键全部解析一遍、缺失即抛，构造点又恰好在
    // `_buildRunner` 里 —— 也就是用户做完一组、标定刚结束的那一刻。一组白做。
    late ThresholdTable table;

    setUpAll(() {
      final file = File('assets/thresholds/thr_2026-10_v1.json');
      if (!file.existsSync()) {
        fail(
          '找不到阈值表：${file.absolute.path}\n'
          '它由 scripts/sync_assets.py 从 shared/thresholds/ 同步而来，'
          '请先运行该脚本。',
        );
      }
      table = ThresholdTable.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    });

    test('跳绳引用的每一个阈值键都真实存在', () {
      for (final rule in _definition().rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = _definition();
      expect(
        () => FaultPresenter(definition: definition, thresholds: table),
        returnsNormally,
        reason: '阈值键缺一个就会在这里抛 —— 而线上那是在一组做完之后',
      );
      expect(
        () => FormScorer(definition: definition, thresholds: table),
        returnsNormally,
      );
    });

    test('三条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`rope.fault_weight.rope_low_buffer`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = _definition();
      final scorer = FormScorer(definition: definition, thresholds: table);
      final keyByCode = {for (final r in definition.rules) r.code: r.thresholdKey};

      final score = scorer.scoreRep([
        for (final rule in definition.rules)
          Fault(
            code: rule.code,
            nameZh: rule.nameZh,
            scorable: table.get(rule.thresholdKey).mayDriveScoring,
            confidence: 1.0,
            evidenceTimestamps: const [],
            deviation: Deviation(
              feature: 'x',
              measured: 1.0,
              threshold: 0.0,
              deltaSigned: 1.0,
              severity01: 0.5,
            ),
          ),
      ]);

      expect(score.terms, hasLength(definition.rules.length));
      for (final term in score.terms) {
        expect(
          term.weight,
          allOf(greaterThan(0), predicate<double>((w) => w.isFinite, '有限')),
          reason: '${term.code} 的权重取自 ${keyByCode[term.code]}',
        );
      }
      expect(scorer.weightSum, greaterThan(0));
    });

    test('评级切点正好 4 个且严格升序，构造期就数过', () {
      final breakpoints =
          table.get('rope.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表里缓冲阈值仍低于典型站立线', () {
      // 与上面那条用内联表的用例说的**是同一件事**，但它量的是随包发出的那个数：
      // 阈值表里这条改动本身没有测试会红。站立膝角取 175°（跳绳标定里最常见的
      // 读数，标定要求人站稳在地面上），站立线就是 175 − 8 = 167°。
      final calibration = _standingCalibration();
      final standLine =
          calibration.kneeAngle - _definition().config.standingHysteresisDeg;
      expect(
        table.get('rope.buffer_max_knee_angle').value,
        lessThan(standLine),
        reason: '随包的缓冲阈值必须低于 $standLine，否则每一次跳绳都必然命中 '
            '（FaultPresenter 会照常报出来，但那是在说假话）',
      );
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = _definition();
      final scorer = FormScorer(definition: definition, thresholds: table);
      expect(
        scorer.weightsVerified,
        isFalse,
        reason: '权重已核定的话，下面那条断言就该改成「随核定状态」',
      );

      final runner = ActionRunner(
        definition,
        thresholds: table,
        calibration: _standingCalibration(),
      );
      _feed(runner, ropeRepFrames(startTimestampMs: 0));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
