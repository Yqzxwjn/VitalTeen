/// 动作层测试：校准、rep 切分、深蹲定义、端到端流水线。
///
/// 这里钉住的是几条**不做就会静默出错**的结论：
/// 基线必须用中位数（否则一次晃动就毁掉整组校准）、
/// 假动作与回蹲必须被正确处理（否则 App 从此数不出任何动作）、
/// 以及深蹲引用的每一个阈值键都真的存在。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_squat.dart';

const double _standDeg = standDeg;

const Calibration _standingCalibration = Calibration(
  kneeAngle: _standDeg,
  trunkLean: 0,
  heelRiseRatio: 0,
  frames: 15,
);

final FeatureExtractor _sagittal = FeatureExtractor(
  cameraView: CameraView.sagittal,
);

Threshold _threshold(String key, double value, {SourceType? sourceType}) =>
    Threshold(
      key: key,
      actionCode: squatActionCode,
      featureCode: '',
      value: value,
      unit: 'deg',
      sourceType: sourceType ?? SourceType.literature,
      version: 'test',
    );

/// 本地阈值表。数值只为本测试服务，**不是**体育判定依据。
ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('squat.min_depth_knee_angle', 100.0),
        _threshold('squat.knee_valgus_angle_notice', 10.0),
        _threshold('squat.trunk_lean_max_delta', 30.0),
        _threshold('squat.heel_rise_ratio_max_delta', 0.15),
        _threshold('squat.asymmetry_index_max', 0.10),
      ],
      version: 'test',
    );

ActionRunner _runner(ThresholdTable table, {TrackingConfig? config}) =>
    ActionRunner(
      buildSquat(_standingCalibration, config: config),
      thresholds: table,
      calibration: _standingCalibration,
    );

void _feedAll(ActionRunner runner, List<double> angles) {
  for (var i = 0; i < angles.length; i++) {
    runner.feed(squatPose(angles[i], timestampMs: i * 33));
  }
}

/// 造一帧只带一个特征信号的 [FrameFeatures]。
///
/// 给不依赖姿态的手工状态机用 —— 测 rep 切分的记账规则时，合成姿态那一整套
/// 几何只是噪声。
FrameFeatures _features(int index, {required double go}) => FrameFeatures(
      timestampMs: index * 33,
      values: {
        'go': FeatureValue(
          code: 'go',
          value: go,
          unit: 'ratio',
          coordSpace: 'dimensionless',
        ),
      },
    );

void main() {
  group('校准', () {
    test('攒够 minFrames 之前不就绪，之后返回基线', () {
      final calibrator = Calibrator(minFrames: 15);
      for (var i = 0; i < 14; i++) {
        expect(calibrator.feed(_sagittal.extract(squatPose(175, timestampMs: i))), isNull);
      }
      expect(calibrator.isReady, isFalse);

      final result = calibrator.feed(_sagittal.extract(squatPose(175, timestampMs: 14)));
      expect(result, isNotNull);
      expect(calibrator.isReady, isTrue);
      expect(result!.frames, 15);
      expect(result.kneeAngle, closeTo(175.0, 0.01));
    });

    test('用中位数而非均值 —— 几帧晃动不该把基线拖偏', () {
      // 15 帧里 12 帧站直（175°）、3 帧是校准期晃了一下（100°）。
      // 均值 ≈ 160°，中位数仍是 175°。用一个被拖偏的基线去算滞回带，
      // 会让整组动作的分段线一起错位，而且完全没有报错。
      final calibrator = Calibrator(minFrames: 15);
      final angles = <double>[
        ...List.filled(12, 175.0),
        ...List.filled(3, 100.0),
      ];

      Calibration? result;
      for (var i = 0; i < angles.length; i++) {
        result = calibrator.feed(_sagittal.extract(squatPose(angles[i], timestampMs: i)));
      }

      expect(result, isNotNull);
      expect(result!.kneeAngle, closeTo(175.0, 0.01));
      expect(result.kneeAngle, isNot(closeTo(160.0, 1.0)));
    });

    test('不可用的帧被跳过，不当成 0 也不计入帧数', () {
      final calibrator = Calibrator(minFrames: 5);

      // 10 帧全身都看不见 —— 是「不知道膝角是多少」，不是「膝角为 0 的帧」。
      for (var i = 0; i < 10; i++) {
        final blind = poseFrameFromPoints(
          frameWidth: frameSide,
          frameHeight: frameSide,
          timestampMs: i,
          visibility: 0.0,
          points: const {},
        );
        expect(calibrator.feed(_sagittal.extract(blind)), isNull);
      }
      expect(calibrator.isReady, isFalse);

      Calibration? result;
      for (var i = 0; i < 5; i++) {
        result = calibrator.feed(_sagittal.extract(squatPose(175, timestampMs: 100 + i)));
      }
      expect(result, isNotNull);
      // 帧数只数有效的 5 帧。若把那 10 帧当成 0°，中位数会被彻底带偏。
      expect(result!.frames, 5);
      expect(result.kneeAngle, closeTo(175.0, 0.01));
    });

    test('reset 之后回到未就绪', () {
      final calibrator = Calibrator(minFrames: 3);
      for (var i = 0; i < 3; i++) {
        calibrator.feed(_sagittal.extract(squatPose(175, timestampMs: i)));
      }
      expect(calibrator.isReady, isTrue);

      calibrator.reset();
      expect(calibrator.isReady, isFalse);
      expect(calibrator.calibration, isNull);
    });
  });

  group('rep 切分', () {
    test('一次完整深蹲封存一个 rep，且带 BOTTOM 相位', () {
      final runner = _runner(_localTable());
      _feedAll(runner, squatSequence(bottomDeg: 120));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);

      final window = runner.windows.single;
      expect(window.index, 1, reason: 'rep 序号从 1 起算，供报告直接显示「第 N 次」');
      // 底部相位必须切出来 —— 没有它，所有只在 BOTTOM 求值的规则会退化成整段评估。
      expect(window.phaseBounds.keys, contains(Phase.bottom));
      expect(window.select(Phase.bottom), isNotEmpty);
    });

    test('假动作（弯一下又直起来）不计入，且不卡死', () {
      // 这正是回退边存在的理由：只有一路向前的链条时，用户在 DESCENT 里
      // 直起来就再也出不去了，表现为 App 从此数不出任何动作。
      final runner = _runner(_localTable());
      _feedAll(runner, [
        ...List.filled(16, _standDeg),
        ...List.filled(16, 150.0), // 弯了一点，但 150 > 130 从未到过底部
        ...List.filled(16, _standDeg),
      ]);

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, SquatStates.standing, reason: '必须回到站立态等下一段');
    });

    test('回蹲（起身到一半又蹲下去）不卡死，最终仍数出一次', () {
      final runner = _runner(_localTable());
      _feedAll(runner, [
        ...List.filled(16, _standDeg),
        ...List.filled(12, 140.0), // DESCENT
        ...List.filled(12, 90.0), // BOTTOM
        ...List.filled(12, 145.0), // ASCENT（145 > 138）
        ...List.filled(12, 100.0), // 又弯回去 → ASCENT→DESCENT
        ...List.filled(12, 90.0), // BOTTOM（第二段）
        ...List.filled(12, 145.0), // ASCENT
        ...List.filled(16, _standDeg), // STANDING → 封存
      ]);

      expect(runner.repCount, 1);
      expect(runner.currentState, SquatStates.standing);
    });

    test('超时未完成的段落被丢弃', () {
      // 用户走开、镜头被挡、状态机卡住 —— 不该无限期挂着半个 rep。
      final runner = _runner(_localTable(), config: const TrackingConfig(maxRepFrames: 20));
      _feedAll(runner, List.filled(40, 150.0));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
    });

    test('起点那一帧就进 bottomState 的段落照样计数', () {
      // **等待期分支管的是「缓冲区不保留历史」，不该顺手把「这一帧进过底部」
      // 也一起吞掉。** 跳绳是第一个 `restingState` 的下一步就是 `bottomState`
      // 的动作（`GROUND → AIR`），而那个转移恰好落在 rep 起点那一帧上：漏记的
      // 话每一次封存都走「没到过底部」的分支 —— **整组一次都不计数、全部计进
      // discardedReps**，而 HUD 上的状态词一路都是对的，屏幕上什么错都不报。
      //
      // 这里用一台手工状态机（A ⇄ B，B 是底部），与任何动作定义无关：
      // 记账规则属于引擎，它的守卫不该寄生在某个动作的测试里。
      final tracker = RepTracker(
        StateMachine(
          initialState: 'A',
          transitions: [
            Transition(src: 'A', dst: 'B', guard: (s) => (s['go'] ?? 0) > 0.5),
            Transition(src: 'B', dst: 'A', guard: (s) => (s['go'] ?? 0) <= 0.5),
          ],
          minDwellFrames: 1,
          voteWindow: 1,
          voteRequired: 1,
        ),
        restingState: 'A',
        bottomState: 'B',
        config: const TrackingConfig(maxRepFrames: 100),
        stateToPhase: const {},
      );
      // 前两帧静止（A），第三帧起「起跳」进 B，第七帧起落回 A。
      for (var i = 0; i < 7; i++) {
        tracker.feed(_features(i, go: i >= 2 ? 1.0 : 0.0));
      }
      for (var i = 7; i < 12; i++) {
        tracker.feed(_features(i, go: 0.0));
      }

      expect(tracker.discardedReps, 0, reason: '这一次真的到过 B');
      expect(tracker.completed, hasLength(1));
      expect(tracker.completed.single.frames, hasLength(6),
          reason: '窗口从进 B 的那一帧（1 起算的第 3 帧）到落回 A 的那一帧（第 8 帧）');
    });


    test('丢弃之后能重新同步，下一段照常数得出来', () {
      // 这里的上限取 60，而不是上一条那个 20。合成序列为了喂满投票窗口与最短
      // 停留，每段都保持十几帧，一次完整深蹲有三十多帧 —— 上限太小会在动作做到
      // 一半时被超时丢弃，于是「重新同步」测的就变成了别的东西。
      final runner = _runner(
        _localTable(),
        config: const TrackingConfig(maxRepFrames: 60),
      );
      _feedAll(runner, List.filled(100, 150.0));
      _feedAll(runner, squatSequence(bottomDeg: 120));

      expect(runner.repCount, 1);
    });
  });

  group('端到端：姿态 → 特征 → 状态机 → 规则', () {
    /// 取出某条错误的组级统计，没有则返回 null。
    FaultStat? statOf(SetSummary summary, String code) {
      for (final stat in summary.faultStats) {
        if (stat.code == code) return stat;
      }
      return null;
    }

    test('蹲得不到位 → 深度不足命中', () {
      final runner = _runner(_localTable());
      _feedAll(runner, squatSequence(bottomDeg: 120)); // 深度线在 100°

      final summary = runner.finishSet();
      final depth = statOf(summary, 'INSUFFICIENT_DEPTH');

      expect(depth, isNotNull, reason: '最低点 120° 高于深度线 100°，应判深度不足');
      expect(depth!.rate, 1.0);
      expect(depth.scorable, isTrue, reason: '本地阈值表标的是 literature');
    });

    test('同一段轨迹蹲得更低就该放行 —— 判据是实测最低点，不是越界帧计数', () {
      // 与上一条的唯一差别是底部膝角。若深度规则误用 ANY_FRAME 计数，
      // 这条会跟着一起命中，因为底部窗口里混着回升的过渡帧。
      final runner = _runner(_localTable());
      _feedAll(runner, squatSequence(bottomDeg: 80)); // 低于深度线 100°

      final summary = runner.finishSet();
      expect(statOf(summary, 'INSUFFICIENT_DEPTH'), isNull);
    });

    test('逐次明细与组级汇总来自同一个引擎实例', () {
      final runner = _runner(_localTable());
      _feedAll(runner, squatSequence(bottomDeg: 120));

      // 这两个必须一致。若换了引擎重新求值，两次结果对不上时不会有任何报错。
      expect(runner.engine.evaluateSet(runner.windows).repCount, runner.finishSet().repCount);
      expect(runner.windows, hasLength(1));
    });
  });

  group('真实阈值表', () {
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

    test('深蹲引用的每一个阈值键都真实存在', () {
      // 这条是防「静默失效」的：引擎只在规则拿到样本时才查阈值，
      // 所以一条拼错的键（或一条在侧视机位下永远拿不到样本的规则）
      // 会让该规则永远不出结果，而不会有任何报错。
      for (final rule in buildSquat(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('每条错误的 scorable 都等于其阈值当前的核定状态', () {
      // 断言的是**机制**而不是当前数值：未核定阈值只出提示、不参与扣分。
      // 体育专业成员核定之后，这条断言仍应成立（那时深度不足就该变成可扣分）。
      final definition = buildSquat(_standingCalibration);
      final keyByCode = {for (final r in definition.rules) r.code: r.thresholdKey};

      final runner = _runner(table);
      _feedAll(runner, squatSequence(bottomDeg: 120));
      final summary = runner.finishSet();

      for (final stat in summary.faultStats) {
        expect(
          stat.scorable,
          table.get(keyByCode[stat.code]!).mayDriveScoring,
          reason: '${stat.code} 的 scorable 与阈值来源不一致',
        );
      }
      expect(table.version, isNotEmpty);
    });
  });

  group('构造期校验', () {
    test('Calibrator 的 minFrames 必须 >= 1', () {
      expect(() => Calibrator(minFrames: 0), throwsA(isA<ExerciseException>()));
    });

    test('RepTracker 拒绝 bottomState 等于 restingState', () {
      // 那样「到过底部」的门槛恒真，任何轻微弯曲都会被计成一次完整动作。
      expect(
        () => RepTracker(
          StateMachine(
            initialState: 'A',
            transitions: [
              Transition(src: 'A', dst: 'B', guard: (_) => true, label: 'a->b'),
            ],
          ),
          restingState: 'A',
          bottomState: 'A',
          config: const TrackingConfig(),
          stateToPhase: const {},
        ),
        throwsA(isA<ExerciseException>()),
      );
    });
  });
}
