/// 决策请求的组装测试。
///
/// **这里断言的是「有没有编数」和「序号对不对」**，因为这两类错误都不会报错：
/// 一个填了 0 的 `rom_mean_deg` 看起来就像「这组动作幅度是 0」，而一个
/// 0-based 的 `index` 会在决策层和 `fault_stats.reps` 错开一位 ——
/// 报告上说第 3 次有问题，视频里第 3 次好好的。
///
/// 与 Python 参考实现的逐字段一致性**不在这里测**，在
/// `decision_request_conformance_test.dart`（那条测的是漂移，这条测的是本文件
/// 自己的逻辑）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_squat.dart';

/// 本地阈值表。数值只为本测试服务，**不是**体育判定依据。
ThresholdTable _table() => ThresholdTable(
      [
        for (final (key, value) in const [
          ('squat.min_depth_knee_angle', 100.0),
          ('squat.knee_valgus_angle_notice', 10.0),
          ('squat.trunk_lean_max_delta', 30.0),
          ('squat.heel_rise_ratio_max_delta', 0.15),
          ('squat.asymmetry_index_max', 0.10),
        ])
          Threshold(
            key: key,
            actionCode: squatActionCode,
            featureCode: '',
            value: value,
            unit: 'deg',
            sourceType: SourceType.literature,
            version: 'test',
          ),
      ],
      version: 'test',
    );

const String _thresholdsVersion = 'test';

Calibration _calibration() => const Calibration(
      kneeAngle: standDeg,
      trunkLean: 0,
      heelRiseRatio: 0,
      frames: 15,
    );

/// 跑完 [reps] 次深蹲的 runner。[bottomDeg] 决定蹲得多深 —— 高于深度线
/// （100°）就会判出 `INSUFFICIENT_DEPTH`。
ActionRunner _runner({int reps = 2, double bottomDeg = 80.0}) {
  final calibration = _calibration();
  final runner = ActionRunner(
    buildSquat(calibration, cameraView: productCameraView),
    thresholds: _table(),
    calibration: calibration,
  );
  // 时间戳从 1000 起 —— 0 被会话层当作「这帧没有时钟」。
  var ts = 1000;
  for (var i = 0; i < reps; i++) {
    for (final frame in squatRepFrames(bottomDeg: bottomDeg, startTimestampMs: ts)) {
      runner.feed(frame);
    }
    ts += 3000;
  }
  return runner;
}

const PoseQuality _quality = PoseQuality(
  meanVisibility: 0.94,
  coverageOkRatio: 0.98,
  fpsMean: 29.7,
  gapMaxMs: 66,
  viewConfidence: 0.91,
);

DecisionContext _context() => const DecisionContext(
      sex: Sex.female,
      age: 16,
      grade: '高一',
      standardGroup: '高中女子',
      actionCode: squatActionCode,
      cameraView: 'oblique45',
    );

DecisionRequest _request(ActionRunner runner, {PoseQuality? quality}) =>
    buildDecisionRequest(
      requestId: 'req-1',
      context: _context(),
      poseQuality: quality ?? _quality,
      summary: runner.finishSet(),
      thresholdsVersion: _thresholdsVersion,
      windows: runner.windows,
      engine: runner.engine,
    );

void main() {
  group('信封', () {
    test('带版本号 —— 没有它，历史判定无法复现', () {
      final json = _request(_runner()).toJson();
      expect(json['schema_version'], decisionSchemaVersion);
      expect(json['request_id'], 'req-1');
      expect(json['thresholds_version'], _thresholdsVersion);
    });

    test('整个请求能直接 jsonEncode', () {
      // 契约的用途就是「发出去」。一个装着不可序列化对象的字段
      // 只有到真正 POST 的那天才炸，而那天离写它的人已经很远了。
      final encoded = jsonEncode(_request(_runner()).toJson());
      expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    });
  });

  group('谁在练', () {
    test('机位、动作码、后端由会话填，不从界面层来', () {
      final context = _request(_runner()).context.toJson();
      expect(context['camera_view'], 'oblique45');
      expect(context['action_code'], 'SQUAT');
      expect(context['pose_backend'], 'mlkit');
      // ML Kit 只有图像坐标。填 true 会让决策层以为米制特征可用，
      // 而它据此判定的那些结论全都没有依据。
      expect(context['has_world_landmarks'], isFalse);
    });

    test('性别与年龄原样带过去', () {
      final context = _request(_runner()).context.toJson();
      expect(context['sex'], 'female');
      expect(context['age'], 16);
      expect(context['grade'], '高一');
      expect(context['standard_group'], '高中女子');
    });
  });

  group('没有来源的字段留空，不编', () {
    test('组级幅度与对称性留 null', () {
      final set = _request(_runner()).set;
      expect(set.romMeanDeg, isNull);
      expect(set.symmetryIndexMean, isNull,
          reason: 'SetSummary 里根本没有这两个数 —— 填 0 等于声称「这组左右完全对称」');
    });

    test('逐次指标是空表，不是一张填满 0 的表', () {
      final reps = _request(_runner()).reps;
      expect(reps, isNotEmpty);
      for (final rep in reps) {
        expect(rep.metrics, isEmpty);
      }
    });

    test('逐次置信度留 null', () {
      // null 是「未提供」，1.0 是「这次动作的数据完全可信」——
      // 端侧拿不到逐次置信度，编一个 1.0 是在替决策层下一个它没做的结论。
      for (final rep in _request(_runner()).reps) {
        expect(rep.confidence, isNull);
      }
    });

    test('一次都没有的组，平均用时也是 null 而不是 0', () {
      final runner = _runner(reps: 0);
      final request = _request(runner);
      expect(request.set.repCount, 0);
      expect(request.set.tempoMeanMs, isNull);
      expect(request.reps, isEmpty);
    });
  });

  group('序号', () {
    test('reps 的序号从 1 开始', () {
      final reps = _request(_runner(reps: 3)).reps;
      expect(reps.map((r) => r.index), [1, 2, 3]);
    });

    test('fault_stats 里的次数与 reps 的序号同一套', () {
      // 两次都蹲得不够深 → INSUFFICIENT_DEPTH 出现在第 1、2 次。
      // 若一边 0-based 一边 1-based，报告会指着不存在的那一次。
      final request = _request(_runner(reps: 3, bottomDeg: 120.0));
      final stat = request.set.faultStats
          .singleWhere((s) => s.code == 'INSUFFICIENT_DEPTH');
      expect(stat.reps, [1, 2, 3]);
      expect(stat.count, 3);

      final indices = request.reps.map((r) => r.index).toSet();
      for (final rep in stat.reps) {
        expect(indices, contains(rep));
      }
    });

    test('候选错误码与组级统计一一对应', () {
      final request = _request(_runner(reps: 3, bottomDeg: 120.0));
      expect(
        request.candidates.map((c) => c.code),
        request.set.faultStats.map((s) => s.code),
      );
      for (final candidate in request.candidates) {
        expect(candidate.triggeredByRule, 'rule_engine');
      }
    });
  });

  group('时长', () {
    test('单次用时是窗口首末帧的时间跨度', () {
      final runner = _runner(reps: 1);
      final window = runner.windows.single;
      final rep = _request(runner).reps.single;

      expect(
        rep.durationMs,
        window.frames.last.timestampMs - window.frames.first.timestampMs,
      );
      // **窗口不含开头那段站立。** 状态机在离开站立的那一刻才开窗，
      // 所以一次深蹲的时长比「整段合成序列」短 —— 差的正是开场那十几帧。
      // 用整段序列的帧数去断言会多算一截，而那个数看起来很合理。
      expect(window.frames.length, lessThan(squatSequence(bottomDeg: 80).length));
    });

    test('平均用时是各次用时的均值', () {
      final request = _request(_runner(reps: 3));
      final durations = request.reps.map((r) => r.durationMs).toList();
      final expected =
          durations.reduce((a, b) => a + b) / durations.length;
      expect(request.set.tempoMeanMs, closeTo(expected, 1e-9));
    });

    test('各相位时长加起来不超过总时长', () {
      final rep = _request(_runner(reps: 1)).reps.single;
      expect(rep.phasesMs, isNotEmpty);
      final sum = rep.phasesMs.values.reduce((a, b) => a + b);
      expect(sum, greaterThan(0));
      expect(sum, lessThanOrEqualTo(rep.durationMs));
    });

    test('相位名与 Phase 枚举同字面 —— 决策层按字符串读', () {
      final rep = _request(_runner(reps: 1)).reps.single;
      final names = Phase.values.map((p) => p.name).toSet();
      for (final key in rep.phasesMs.keys) {
        expect(names, contains(key));
      }
      // 这是与 Python `str(phase)` 对齐的那条性质：两边拼出来的键必须同字面，
      // 否则决策层读到的相位时长全是缺的，而缺的默认值是 0 —— 一份「下蹲 0 毫秒」
      // 的数据看起来只像是动作很快。
      //
      // **没有 `stand`**：窗口在离开站立的那一刻才开，站立相位不在窗口里。
      expect(rep.phasesMs.keys,
          containsAll(['descent', 'bottom', 'ascent']));
      expect(rep.phasesMs.keys, isNot(contains('stand')));
    });
  });

  group('错误判定', () {
    test('蹲够了就没有深度问题', () {
      final request = _request(_runner(reps: 2, bottomDeg: 80.0));
      expect(request.set.faultStats.map((s) => s.code),
          isNot(contains('INSUFFICIENT_DEPTH')));
      for (final rep in request.reps) {
        expect(rep.faults, isEmpty);
      }
    });

    test('蹲浅了每次都有，且带量化偏离', () {
      final request = _request(_runner(reps: 2, bottomDeg: 120.0));
      for (final rep in request.reps) {
        final fault = rep.faults.singleWhere((f) => f.code == 'INSUFFICIENT_DEPTH');
        expect(fault.deviations, hasLength(1));
        final deviation = fault.deviations.single;
        // 测量值在窗口内取最坏，阈值取自阈值表 —— deviation 是给决策层
        // 判断「差多少」用的，不是给人看的文案。
        expect(deviation.feature, 'knee_angle_L');
        expect(deviation.threshold, 100.0);
        expect(deviation.measured, greaterThan(deviation.threshold));
        expect(deviation.deltaSigned, greaterThan(0));
      }
    });

    test('证据帧是时间戳，不是帧下标', () {
      // 字段名叫 evidence_frames，很容易被读成下标 —— 决策层若拿它当帧号去
      // 对齐别的数据源，会指向完全无关的位置。
      final rep = _request(_runner(reps: 1, bottomDeg: 120.0)).reps.single;
      final fault = rep.faults.single;
      expect(fault.evidenceFrames, isNotEmpty);
      expect(fault.evidenceFrames.first, greaterThanOrEqualTo(1000));
    });

    test('未核定阈值的判定照样上报 —— 提示级不改变「判出来了」这个事实', () {
      // 阈值表的 source_type 决定的是能不能扣分，不是能不能上报。
      // 这里整张表都是 literature，scorable 与否由规则决定，两种都要进候选集。
      final request = _request(_runner(reps: 2, bottomDeg: 120.0));
      expect(request.candidates, isNotEmpty);
    });
  });

  group('借口检查', () {
    test('给了 windows 却没给 engine → 抛异常，不静默出空数组', () {
      final runner = _runner(reps: 2);
      expect(
        () => buildDecisionRequest(
          requestId: 'req-1',
          context: _context(),
          poseQuality: _quality,
          summary: runner.finishSet(),
          thresholdsVersion: _thresholdsVersion,
          windows: runner.windows,
        ),
        throwsArgumentError,
      );
    });

    test('两个都不给是合法的 —— 组级判定照样成立', () {
      final runner = _runner(reps: 2);
      final request = buildDecisionRequest(
        requestId: 'req-1',
        context: _context(),
        poseQuality: _quality,
        summary: runner.finishSet(),
        thresholdsVersion: _thresholdsVersion,
      );
      expect(request.set.repCount, 2);
      expect(request.reps, isEmpty);
      expect(request.set.tempoMeanMs, isNull);
    });
  });
}
