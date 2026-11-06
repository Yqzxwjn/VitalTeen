/// 平板支撑动作定义测试。
///
/// 与 `domain/tests/test_plank.py` 的断言**逐条对应**：合成几何相同、阈值相同、
/// 结论相同。语言之间出现分歧时 `check_all.py` 不会报警 —— 唯一的发现方式就是
/// 两侧各有一份说同一件事的测试。
///
/// 这里钉住六类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **支撑位是三条判据的合取，而且每一条都在起作用。** 站着的人体线也直、
///    趴着的人体线也直也水平 —— 三条里少掉哪一条，都会有一整类不属于支撑的姿势
///    被安静地计成一整组好成绩。下面三条断言各挡住一条：站着但肘角在支撑带上
///    （只差「身体放平」那条）、趴着但手臂伸直（只差「肘角带」那条）、
///    以及身体倾斜但体线弯着（只差体线那条）。
/// 2. **一次 rep 的时长就是那一段支撑。** 这个动作的产品承诺是「累计撑了多久」，
///    而时长不是任何一条规则算出来的 —— 它来自 rep 窗口的首末帧时间戳。
///    谁把窗口的开合位置改了（或者谁让状态机在中途断一下），累计时长就跟着错，
///    而屏幕上只会显示一个看起来还挺合理的数字。
/// 3. **撑住的过程中被挡住一会儿，不该把一次支撑切成两段。** `leftHold` 在
///    「读不到特征」时维持撑住，与 `enteredHold` 的取舍正好相反。谁把它改成
///    「读不到就结束」，一次遮挡就会变成两次计数 —— 而两次计数**看起来**是对的。
/// 4. **四条规则的灵敏度与方向。** 每一条都给「合规」与「违规」两组：
///    只断言「违规时命中」的话，一条永远命中的规则也是绿的。
/// 5. **`PLANK_ELBOW` 的两条规则共用一个错误码，组级只算一次。** 引擎
///    `evaluateSet` 里有一段按码去重的注释专门交代过这件事，而「共用码」这件事
///    一旦被改成两个码，出现率会立刻虚高一倍 —— 不报错。
/// 6. **三条判定都不挂本人基线。** 体线偏移已用躯干长归一、肘角是关节夹角，
///    再乘一个基线只会引入噪声；挂错的表现是阈值整体挪位、判错率变，不报错。
///
/// 阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
/// 与真实资产的对照在「真实阈值表」那组里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/plank.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_plank.dart';

/// 站立基线。**平板支撑三条判定一条都不用它**（体线偏移已用躯干长归一、
/// 肘角是关节夹角），但它仍然要采 —— 那是 `Calibrator` 的门槛，
/// 也是「开始之前先站好」那一步的产物，与其余动作共用同一套流程。
const Calibration _standingCalibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 0,
  heelRiseRatio: 0.0,
  frames: 15,
);

/// 内联阈值表。四条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的取值远一点：
///
/// | 量 | 合规 | 违规 | 阈值 |
/// |---|---|---|---|
/// | 塌腰 / 撅臀（体线偏移） | 0 | ±0.287 | ±0.20 |
/// | 肘角 | 90° | 60° / 120° | 70° / 110° |
///
/// **肘角那一对必须严格落在支撑带里面**（50..130），否则「越界」蕴含「离开支撑位」，
/// 那一段会被封存成 rep、越界帧数永远攒不够，**规则永远不触发也不报错**。
/// 下面有一条断言把这件事钉在真实资产表上。
///
/// **注意 `plank.hip_pike_ratio_min` 是一个负数** —— 撅臀的判据是「髋比连线高」，
/// 在这个带符号的特征上是负值。所以本文件里不能断言「阈值一律为正」，
/// 只能断言「非零、有限」。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: plankActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('plank.hip_sag_ratio_max', 0.20, 'body_line_offset_ratio'),
        _threshold('plank.hip_pike_ratio_min', -0.20, 'body_line_offset_ratio'),
        _threshold('plank.elbow_angle_max', 110.0, 'elbow_angle_L',
            unit: 'deg'),
        _threshold('plank.elbow_angle_min', 70.0, 'elbow_angle_L', unit: 'deg'),
      ],
      version: 'test',
    );

/// 与产品一致：平板支撑走 45° 主链路（`productCameraView`）。
TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.oblique45, maxRepFrames: 3600);

ActionRunner _runner({ThresholdTable? thresholds, ActionDefinition? definition}) =>
    ActionRunner(
      definition ?? buildPlank(_standingCalibration, config: _config()),
      thresholds: thresholds ?? _localTable(),
      calibration: _standingCalibration,
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

/// 取出某个错误的组级统计，没有则返回 null。
FaultStat? _statOf(SetSummary summary, String code) {
  for (final stat in summary.faultStats) {
    if (stat.code == code) return stat;
  }
  return null;
}

/// 一次支撑的时长：rep 窗口首末帧的时间戳之差。
///
/// **这就是产品上那个「累计撑了多久」** —— 决策契约里的 `duration_ms` 与它同源
/// （`decision_request.dart` 读的是同一对时间戳）。所以这条断言同时也是
/// 「计时制的数据从哪儿来」的说明。
int _durationMs(RepWindow window) =>
    window.frames.last.timestampMs - window.frames.first.timestampMs;

/// 产品机位下读一帧的特征值。
///
/// 分段用的三个量（`trunk_lean` / `body_line_offset_ratio` / `elbow_angle_*`）
/// 在 45° 下都**可用**（前两个里体线偏移声明了 `[sagittal, oblique45]`），
/// 所以这个读取器与 runner 内部用的那个一致。
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

void main() {
  group('合成帧的读数', () {
    // 上面那些用例全都建立在「合成帧读出来的就是它声称的那个数」之上：
    // 撑住那一段的体线偏移必须接近 0、塌腰那一段必须越过阈值但仍在支撑位内。
    // 断言值而不是「大致对」——这些常数是照着 `synthetic_plank.dart` 的几何
    // 推出来的，推错的时候（比如换了归一化用的分母）**每一条规则测试都会
    // 安静地改变含义**，而它们自己不会红。
    test('标准支撑：身体放平、体线笔直、肘角在支撑带上', () {
      final frame = plankPose(timestampMs: 0);
      expect(_feature(frame, 'trunk_lean')!.abs(), greaterThanOrEqualTo(60.0));
      expect(_feature(frame, 'body_line_offset_ratio')!.abs(), lessThan(0.05));
      expect(_feature(frame, 'elbow_angle_L'), closeTo(90.0, 1e-6));
      expect(_feature(frame, 'elbow_angle_R'), closeTo(90.0, 1e-6));
    });

    test('塌腰那一段：越过质量阈值（0.20），但仍在进入线（0.45）之内', () {
      final offset = _feature(
        plankPose(timestampMs: 0, hipOffset: plankSagOffset),
        'body_line_offset_ratio',
      )!;
      expect(offset, greaterThan(0.20));
      expect(offset, lessThan(0.45));
    });

    test('站立：体线也是直的 —— 所以站姿必须靠「身体放平」那条判据挡', () {
      final frame = plankPose(
        timestampMs: 0,
        bodyAngleDeg: plankStandingAngleDeg,
      );
      expect(_feature(frame, 'trunk_lean')!.abs(), lessThan(60.0));
      expect(_feature(frame, 'body_line_offset_ratio')!.abs(), lessThan(0.05));
    });

    test('手臂伸直那一段：身体与体线都对，只有肘角出了支撑带', () {
      final frame = plankPose(
        timestampMs: 0,
        elbowDeg: plankStraightArmDeg,
      );
      expect(_feature(frame, 'trunk_lean')!.abs(), greaterThanOrEqualTo(60.0));
      expect(_feature(frame, 'elbow_angle_L')!, greaterThan(130.0));
    });
  });

  group('构造期校验', () {
    test('体线容差的进入线不小于退出线时当场炸', () {
      // 两者之间是滞回带。写反或写等之后状态机不会报错，只会让髋在边界上抖一帧
      // 就把一次支撑切成两段 —— 表现是「明明撑了 30 秒，却显示 2 次」。
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(
            plankLineEnterRatio: 0.60,
            plankLineExitRatio: 0.45,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(
            plankLineEnterRatio: 0.45,
            plankLineExitRatio: 0.45,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('身体放平线退到滞回带附近时当场炸', () {
      // 退出线是「放平线 − 滞回」。放平线不大于滞回时它会落到 0 附近，
      // 站着的人（躯干倾角只有几度）也会满足「身体放平了」—— 于是标定那 15 帧
      // 站立就是一次长支撑。
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(plankLieDeg: 5.0),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('支撑带的上下沿写反时当场炸', () {
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(
            plankElbowMinDeg: 130.0,
            plankElbowMaxDeg: 50.0,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('支撑带上沿够到「手臂伸直」时当场炸', () {
      // 这是三条判据里唯一一条能分开「撑着」与「站着」的（站着的人体线也直、
      // 也大致水平？不 —— 站着的人体线是竖直的，靠的是第一条判据；但**肘角**
      // 这一条要挡住的是趴着放松的人）。上沿加上滞回够到 180° 之后，
      // 手臂伸直也会落进支撑带，第三条判据就形同虚设。
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(plankElbowMaxDeg: 175.0),
        ),
        throwsA(isA<ExerciseException>()),
      );
      // 边界值：刚好等于 180° 减滞回，仍然会炸（要求严格小于）。
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(plankElbowMaxDeg: 172.0),
        ),
        throwsA(isA<ExerciseException>()),
      );
      // 差一点点就过关的：171.9 通过。
      expect(
        () => buildPlank(
          _standingCalibration,
          config: const TrackingConfig(plankElbowMaxDeg: 171.0),
        ),
        returnsNormally,
      );
    });
  });

  group('分段：三条判据各挡一类姿势', () {
    test('一次标准支撑计 1 次，时长约等于撑住的那一段', () {
      const holdCount = 90;
      const interval = 33;
      final runner = _runner();
      _feed(
        runner,
        plankOneHoldFrames(
          holdCount: holdCount,
          startTimestampMs: 0,
          frameIntervalMs: interval,
        ),
      );

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);

      // 容差 ±8 帧：状态机换相要经过驻留与投票（`minDwellFrames` = 3、
      // 投票窗口 5 取 4），所以「离开 HOLD_BREAK」与「回到 HOLD_BREAK」都
      // 比人真正动的那一帧晚几帧。**这个滞后是计时的固有代价**，
      // 它让时长有一两百毫秒的偏差 —— 反过来，任何要求「逐帧精确」的计时
      // 都不可能由状态机做出来。
      final duration = _durationMs(runner.windows.single);
      expect(duration, greaterThanOrEqualTo((holdCount - 8) * interval));
      expect(duration, lessThanOrEqualTo((holdCount + 8) * interval));
    });

    test('两段分开的支撑是两次计数，累计时长是两段之和', () {
      const interval = 33;
      final runner = _runner();
      _feed(
        runner,
        plankFromSegments([
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          const PlankSegment(count: 60),
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          const PlankSegment(count: 60),
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
        ], frameIntervalMs: interval),
      );

      expect(runner.repCount, 2);
      expect(runner.discardedReps, 0);
      final total = runner.windows.map(_durationMs).reduce((a, b) => a + b);
      expect(total, greaterThanOrEqualTo(96 * interval));
      expect(total, lessThanOrEqualTo(136 * interval));
    });

    test('自始至终站着：一次都不计', () {
      final runner = _runner();
      _feed(
        runner,
        plankStandingFrames(count: 120),
      );
      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0);
    });

    test('身体放平、体线也直，但手臂是伸直的：一次都不计（第三条判据）', () {
      // 这是**趴着放松**的姿势。它满足前两条（身体放平、体线成一条线），
      // 唯一不满足的是肘角 —— 少了那条判据，趴在地上休息会被安静地计成
      // 一整段支撑，而这正是计时的动作最容易被钻的漏洞。
      final runner = _runner();
      _feed(
        runner,
        plankHoldFrames(
          count: 120,
          elbowDeg: plankStraightArmDeg,
        ),
      );
      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0);
    });

    test('站着但肘角在支撑带上：一次都不计（第一条判据）', () {
      // 反过来的那一半：肘角 90°、体线也直，只有「身体放平」这一条不满足。
      final runner = _runner();
      _feed(
        runner,
        plankFromSegments([
          const PlankSegment(
            count: 120,
            bodyAngleDeg: plankStandingAngleDeg,
            elbowDeg: 90.0,
          ),
        ]),
      );
      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0);
    });

    test('身体放平、肘角也对，但体线弯着（塌腰越过了退出线）：一次都不计', () {
      // 第三条判据的反面。位移 0.12 → 体线偏移约 0.51，超过退出线 0.60？不 ——
      // 0.51 < 0.60，仍在支撑位上。所以这里用 0.20 的位移（约 0.71），
      // 明确越过退出线：蹲下来休息、或者撑不住了塌在地上。
      final runner = _runner();
      _feed(
        runner,
        plankHoldFrames(count: 120, hipOffset: 0.20),
      );
      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0);
    });

    test('守卫函数本身：三条都满足才进支撑位，缺一条维持原状', () {
      final definition = buildPlank(_standingCalibration, config: _config());
      final entered = _guardOf(definition, PlankStates.holdBreak, PlankStates.holdOk);
      final held = _guardOf(definition, PlankStates.holdOk, PlankStates.holdBreak);

      const extractor = FeatureExtractor(cameraView: CameraView.oblique45);
      Map<String, double?> signalsOf(PoseFrame frame) => extractor.extract(frame).asSignals();

      expect(entered(signalsOf(plankPose(timestampMs: 0))), isTrue);
      expect(
        entered(signalsOf(plankPose(
          timestampMs: 0,
          bodyAngleDeg: plankStandingAngleDeg,
        ))),
        isFalse,
        reason: '第一条判据：身体没放平',
      );
      expect(
        entered(signalsOf(plankPose(
          timestampMs: 0,
          elbowDeg: plankStraightArmDeg,
        ))),
        isFalse,
        reason: '第三条判据：手臂伸直',
      );
      expect(
        entered(signalsOf(plankPose(timestampMs: 0, hipOffset: 0.20))),
        isFalse,
        reason: '第二条判据：体线弯过了进入线',
      );

      // 读不到特征：进入侧说「没进」，维持侧说「还撑着」—— 两者相反是刻意的。
      final blind = signalsOf(plankPose(
        timestampMs: 0,
        visibilityOverrides: const {L.leftShoulder: 0.0, L.rightShoulder: 0.0},
      ));
      expect(entered(blind), isFalse);
      expect(held(blind), isFalse, reason: '读不到就维持撑住，不该断开这一段的计数');
    });
  });

  group('时长：撑住的过程中被挡住一会儿，不该切成两段', () {
    test('中间有 20 帧肩点看不见，仍然是一次支撑', () {
      const interval = 33;
      final runner = _runner();
      _feed(
        runner,
        plankFromSegments([
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          const PlankSegment(count: 40),
          const PlankSegment(
            count: 20,
            hidden: {L.leftShoulder, L.rightShoulder},
          ),
          const PlankSegment(count: 40),
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
        ], frameIntervalMs: interval),
      );

      expect(
        runner.repCount,
        1,
        reason: '一次遮挡变成两次计数的话，累计时长会凭空缩短，而屏幕上只有数字',
      );
      expect(runner.discardedReps, 0);
      // 时长仍然覆盖整段，包括看不见的那 20 帧 —— 人确实撑着，只是没被拍到。
      final duration = _durationMs(runner.windows.single);
      expect(duration, greaterThanOrEqualTo(88 * interval));
    });
  });

  group('四条规则的灵敏度与方向', () {
    /// 一次「撑住 [holdCount] 帧」的支撑，中间的自变量由调用方给。
    SetSummary holdWith({
      double hipOffset = 0.0,
      double elbowDeg = plankHoldElbowDeg,
      int holdCount = 60,
    }) {
      final runner = _runner();
      _feed(
        runner,
        plankOneHoldFrames(
          holdCount: holdCount,
          hipOffset: hipOffset,
          elbowDeg: elbowDeg,
        ),
      );
      expect(runner.repCount, 1, reason: '这一组的前提是它得被算成一次');
      return runner.finishSet();
    }

    test('合规的一次支撑：四条规则一条都不命中', () {
      final summary = holdWith();
      expect(summary.repCount, 1);
      expect(
        summary.faultStats,
        isEmpty,
        reason: '合规组必须什么都不报，否则「违规组会报」什么也证明不了',
      );
    });

    test('塌腰只命中 PLANK_HIP_SAG，不连坐撅臀', () {
      final summary = holdWith(hipOffset: plankSagOffset);
      expect(_statOf(summary, 'PLANK_HIP_SAG'), isNotNull);
      expect(
        _statOf(summary, 'PLANK_HIP_PIKE'),
        isNull,
        reason: '两者共用同一个指标、方向相反；方向判错时它们会互相顶替',
      );
      expect(_statOf(summary, 'PLANK_ELBOW'), isNull);
    });

    test('撅臀只命中 PLANK_HIP_PIKE，不连坐塌腰', () {
      final summary = holdWith(hipOffset: -plankSagOffset);
      expect(_statOf(summary, 'PLANK_HIP_PIKE'), isNotNull);
      expect(_statOf(summary, 'PLANK_HIP_SAG'), isNull);
      expect(_statOf(summary, 'PLANK_ELBOW'), isNull);
    });

    test('肘角撑得太塌（60°）与撑得太直（120°）都命中 PLANK_ELBOW', () {
      for (final elbow in [60.0, 120.0]) {
        final summary = holdWith(elbowDeg: elbow);
        expect(
          _statOf(summary, 'PLANK_ELBOW'),
          isNotNull,
          reason: '肘角 $elbow° 落在支撑带内、但越过了质量阈值，必须被判错',
        );
        expect(
          _statOf(summary, 'PLANK_HIP_SAG'),
          isNull,
          reason: '体线是直的，不该被连坐',
        );
      }
    });

    test('两条规则共用一个错误码，组级只算一次', () {
      // 肘角在**同一次支撑里**先撑得太直、再撑得太塌，两条规则都会命中；
      // 引擎按码去重，所以组级只能有一条统计。改成两个错误码的话，
      // 那两段会各报一次，出现率直接翻倍 —— 而两个码名字一样、用户看不出差别。
      final runner = _runner();
      _feed(
        runner,
        plankFromSegments([
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          const PlankSegment(count: 30, elbowDeg: 120.0),
          const PlankSegment(count: 30, elbowDeg: 90.0),
          const PlankSegment(count: 30, elbowDeg: 60.0),
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
        ]),
      );
      expect(runner.repCount, 1);
      final summary = runner.finishSet();
      expect(summary.faultStats.where((s) => s.code == 'PLANK_ELBOW'), hasLength(1));
    });

    test('短暂塌一下（不足门槛帧数）不判错，持续塌下去才判', () {
      // 这是 `minViolatingFrames = 8` 那条工程参数唯一的用处，也是这个动作
      // 与其余动作（门槛取 2）最不一样的地方。合成帧是逐帧精确的，
      // 所以这里的差别**只**来自门槛帧数。
      SetSummary holdWithSagFrames(int sagFrames) {
        final runner = _runner();
        _feed(
          runner,
          plankFromSegments([
            const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
            const PlankSegment(count: 40),
            PlankSegment(count: sagFrames, hipOffset: plankSagOffset),
            const PlankSegment(count: 40),
            const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          ]),
        );
        expect(runner.repCount, 1);
        return runner.finishSet();
      }

      expect(
        _statOf(holdWithSagFrames(4), 'PLANK_HIP_SAG'),
        isNull,
        reason: '抖一下不该在几十秒的支撑里变成一次犯规',
      );
      expect(
        _statOf(holdWithSagFrames(40), 'PLANK_HIP_SAG'),
        isNotNull,
        reason: '门槛把真塌也放过了的话，8 这个数就是大的方向调过头了',
      );
    });

    test('正常收势（起身）不误报', () {
      // 状态机换相滞后几帧，所以 rep 窗口的**尾巴上有几帧已经是起身了**。
      // 门槛取 2 帧的时候，正是这几帧会把每一次正常收势判成塌腰
      // —— 这也是 8 这个数的由来。
      final runner = _runner();
      _feed(
        runner,
        plankFromSegments([
          const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
          const PlankSegment(count: 60),
          const PlankSegment(count: 20, bodyAngleDeg: plankStandingAngleDeg),
        ]),
      );
      expect(runner.repCount, 1);
      expect(runner.finishSet().faultStats, isEmpty);
    });
  });

  group('三条判定都不挂本人基线', () {
    test('阈值偏移表是空的', () {
      final definition = buildPlank(_standingCalibration);
      expect(definition.thresholdOffsets, isEmpty);
      for (final rule in definition.rules) {
        // 规则上也不带基线标记：三条的量本身就已经与体型无关。
        expect(rule.metric, isNot(contains('baseline')));
      }
    });

    test('换一套标定值，同一次支撑的判定结果一模一样', () {
      SetSummary judge(Calibration calibration) {
        final runner = ActionRunner(
          buildPlank(calibration, config: _config()),
          thresholds: _localTable(),
          calibration: calibration,
        );
        _feed(
          runner,
          plankOneHoldFrames(holdCount: 60, hipOffset: plankSagOffset),
        );
        return runner.finishSet();
      }

      const another = Calibration(
        kneeAngle: 150.0,
        trunkLean: 12.0,
        heelRiseRatio: 0.30,
        frames: 15,
      );
      final a = judge(_standingCalibration);
      final b = judge(another);
      expect(a.repCount, b.repCount);
      expect(
        [for (final s in a.faultStats) s.code],
        [for (final s in b.faultStats) s.code],
      );
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表：键名与资产表一致、数值不必一致 —— 于是「资产表里
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

    test('平板支撑引用的每一个阈值键都真实存在', () {
      for (final rule in buildPlank(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('两条肘角阈值严格落在支撑带里面', () {
      // 否则「肘角越界」蕴含「离开支撑位」，那一段会被封存成 rep、
      // 越界帧数永远攒不够，**规则永远不触发也不报错**。
      final config = buildPlank(_standingCalibration).config;
      expect(
        table.get('plank.elbow_angle_min').value,
        greaterThan(config.plankElbowMinDeg),
        reason: '低于支撑带下沿的话，这一段根本不会被算成一次支撑',
      );
      expect(
        table.get('plank.elbow_angle_max').value,
        lessThan(config.plankElbowMaxDeg),
      );
    });

    test('两条体线阈值严格落在进入线里面（同一条自查）', () {
      final config = buildPlank(_standingCalibration).config;
      expect(
        table.get('plank.hip_sag_ratio_max').value,
        lessThan(config.plankLineEnterRatio),
      );
      // 撅臀那条是负数：越负越坏，所以它必须**大于**进入线的相反数。
      expect(
        table.get('plank.hip_pike_ratio_min').value,
        greaterThan(-config.plankLineEnterRatio),
      );
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildPlank(_standingCalibration);
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
      // 真的取到了值 —— 键名双前缀（`plank.fault_weight.plank_hip_sag`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      //
      // **`PLANK_ELBOW` 有两条规则共用它** —— 于是这里顺带验到第二处去重：
      // `FormScorer.scoreRep` 按错误码取最严重的一次（与 `evaluateSet` 的口径
      // 一致），所以四条判定进来、三项出去。不去重的话，同一件事会在逐次评分里
      // 扣两遍，而组级只扣一遍，两个分数对不上。
      final definition = buildPlank(_standingCalibration);
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

      expect(definition.rules, hasLength(4), reason: '四条规则、三个码');
      expect(
        score.terms.map((t) => t.code).toSet(),
        {for (final rule in definition.rules) rule.code},
        reason: '输出按错误码去重，但三个码一个都不能少',
      );
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
          table.get('plank.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildPlank(_standingCalibration);
      final scorer = FormScorer(definition: definition, thresholds: table);
      expect(
        scorer.weightsVerified,
        isFalse,
        reason: '权重已核定的话，下面那条断言就该改成「随核定状态」',
      );

      final runner = ActionRunner(
        definition,
        thresholds: table,
        calibration: _standingCalibration,
      );
      _feed(runner, plankOneHoldFrames(holdCount: 60));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
