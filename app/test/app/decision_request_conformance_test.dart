/// 跨语言一致性 —— 端侧产出的决策请求必须与 Python 参考实现逐字段一致。
///
/// `server/app/adapter.py` 的模块注释里写着「Dart 侧的请求组装逻辑应当与本模块
/// 逐字段对齐」。这份测试就是那句话的执行方式：Python 侧生成期望请求，
/// 这里用同一批原始姿态跑一遍端侧的完整链路，比对两者。
///
/// **为什么值得为它写一整套流水线**
///
/// 因为端侧拿不到「已经调好个体化偏移的引擎」—— `ActionRunner` 刻意不接
/// `config` / 偏移参数，它自己从标定算。所以两边都只能走
/// 「标定 → 建 runner → 喂帧 → finishSet」这条真实路径，顺带把**状态机、
/// 相位切分、特征计算**也纳入了跨语言比对。这不是副作用，是收益：
/// 那些环节里的任何一处漂移都会让逐次时长、相位时长、错误判定对不上。
///
/// **失败时怎么办**（与 `test/domain/fixtures_test.dart` 同一套处置）：
///
/// - 刚改过 Dart 侧组装逻辑 → 先判断是有意变更还是 bug
/// - 有意变更 → 必须同时改 `server/app/adapter.py` 并重新生成 fixture
/// - 意外漂移 → 是 bug，改回去
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

/// fixture 在仓库的 `shared/` 下。`flutter test` 的工作目录是包根（`app/`），
/// 因此要往上一级找。
const String _fixtureRelativePath =
    '../shared/fixtures/decision_request_conformance.json';

/// 浮点比对容差。两侧都保留了 6 位小数，这里再留一点余量 ——
/// 要抓的是「差了一个量级」「符号反了」「该是 null 却填了数」，不是末位 ulp。
const double _tolerance = 1e-4;

void main() {
  final fixtureFile = File(_fixtureRelativePath);
  if (!fixtureFile.existsSync()) {
    fail(
      'fixture 缺失：${fixtureFile.absolute.path}\n'
      '它由 `cd server && python -m tools.build_request_fixture` 生成。',
    );
  }
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;

  final context = fixture['context'] as Map<String, dynamic>;
  final thresholdsSpec = fixture['thresholds'] as Map<String, dynamic>;
  final cameraView = switch (fixture['camera_view'] as String) {
    'frontal' => CameraView.frontal,
    'sagittal' => CameraView.sagittal,
    'oblique45' => CameraView.oblique45,
    final other => throw ArgumentError('未知机位：$other'),
  };

  /// 按 fixture 重建一帧姿态。
  ///
  /// 基准姿态取自 fixture 自带的 `base_pose`（完整 33 点），因此这里不需要
  /// 复制生成器里的任何常量 —— 那份 base 一旦改动，两侧会一起变。
  PoseFrame buildFrame(Map<String, dynamic> frame) {
    final points = <L, (double, double)>{};

    void apply(Map<String, dynamic> source) {
      for (final entry in source.entries) {
        final landmark = landmarkFromName(entry.key);
        if (landmark == null) continue;
        final value = entry.value as List<dynamic>;
        points[landmark] = (
          (value[0] as num).toDouble(),
          (value[1] as num).toDouble(),
        );
      }
    }

    apply(fixture['base_pose'] as Map<String, dynamic>);
    apply(frame['overrides'] as Map<String, dynamic>);

    return poseFrameFromPoints(
      points: points,
      frameWidth: fixture['frame_width'] as int,
      frameHeight: fixture['frame_height'] as int,
      timestampMs: frame['timestamp_ms'] as int,
    );
  }

  final frames = [
    for (final frame in fixture['frames'] as List<dynamic>)
      buildFrame(frame as Map<String, dynamic>),
  ];

  ThresholdTable buildThresholds() => ThresholdTable(
        [
          for (final entry in (thresholdsSpec['values'] as Map<String, dynamic>).entries)
            Threshold(
              key: entry.key,
              actionCode: thresholdsSpec['action_code'] as String,
              featureCode: '',
              value: (entry.value as num).toDouble(),
              unit: 'deg',
              sourceType: SourceType.literature,
              version: thresholdsSpec['version'] as String,
            ),
        ],
        version: thresholdsSpec['version'] as String,
      );

  /// 跑完整条端侧链路，返回组装好的请求。
  DecisionRequest runPipeline() {
    final extractor = FeatureExtractor(cameraView: cameraView);
    final calibrator = Calibrator();
    final calibrationFrames = fixture['calibration_frames'] as int;

    var index = 0;
    while (!calibrator.isReady && index < calibrationFrames) {
      calibrator.feed(extractor.extract(frames[index]));
      index++;
    }
    final calibration = calibrator.calibration;
    expect(calibration, isNotNull,
        reason: '标定没有完成 —— fixture 开头的站立帧数或几何与端侧对不上');

    // **不传 config。** 两侧都取定义自带的工程默认值，这正是不给
    // `ActionRunner` 开 config 参数的目的：没有第二处可以填错。
    final runner = ActionRunner(
      buildSquat(calibration!, cameraView: cameraView),
      thresholds: buildThresholds(),
      calibration: calibration,
    );
    for (final frame in frames.skip(index)) {
      runner.feed(frame);
    }

    return buildDecisionRequest(
      requestId: 'conformance-1',
      context: DecisionContext(
        sex: context['sex'] == 'female' ? Sex.female : Sex.male,
        age: context['age'] as int,
        grade: context['grade'] as String,
        standardGroup: context['standard_group'] as String,
        actionCode: thresholdsSpec['action_code'] as String,
        cameraView: cameraView.name,
      ),
      poseQuality: PoseQuality(
        meanVisibility: (fixture['pose_quality'] as Map<String, dynamic>)['mean_visibility'] as double,
        coverageOkRatio: (fixture['pose_quality'] as Map<String, dynamic>)['coverage_ok_ratio'] as double,
        fpsMean: (fixture['pose_quality'] as Map<String, dynamic>)['fps_mean'] as double,
        gapMaxMs: (fixture['pose_quality'] as Map<String, dynamic>)['gap_max_ms'] as int,
        viewConfidence: (fixture['pose_quality'] as Map<String, dynamic>)['view_confidence'] as double,
      ),
      summary: runner.finishSet(),
      thresholdsVersion: thresholdsSpec['version'] as String,
      windows: runner.windows,
      engine: runner.engine,
    );
  }

  /// 递归比对，浮点用容差。
  ///
  /// 逐层比对而不是比字符串：两边的 JSON 序列化对同一个 double 可能给出不同
  /// 写法（`1e-05` / `1e-5`），比字符串会把格式差异报成数值差异，
  /// 而真正要看的是数值。
  void expectJsonClose(Object? actual, Object? expected, [String path = '']) {
    if (expected == null) {
      expect(actual, isNull, reason: '$path 该是 null');
      return;
    }
    if (expected is Map) {
      expect(actual, isA<Map<Object?, Object?>>(), reason: '$path 该是对象');
      final actualMap = actual! as Map<Object?, Object?>;
      expect(
        actualMap.keys.map((k) => '$k').toSet(),
        expected.keys.map((k) => '$k').toSet(),
        reason: '$path 的字段集不同',
      );
      for (final key in expected.keys) {
        expectJsonClose(actualMap[key], expected[key], '$path.$key');
      }
      return;
    }
    if (expected is List) {
      expect(actual, isA<List<Object?>>(), reason: '$path 该是数组');
      final actualList = actual! as List<Object?>;
      expect(actualList, hasLength(expected.length), reason: '$path 长度不同');
      for (var i = 0; i < expected.length; i++) {
        expectJsonClose(actualList[i], expected[i], '$path[$i]');
      }
      return;
    }
    if (expected is num) {
      expect(actual, isA<num>(), reason: '$path 该是数字');
      expect((actual! as num).toDouble(), closeTo(expected.toDouble(), _tolerance),
          reason: path);
      return;
    }
    expect(actual, expected, reason: path);
  }

  group('决策请求 · 跨语言一致性', () {
    test('fixture 的场景确实造出了「一次干净、一次深度不足」', () {
      // **先验场景，再验一致性。** 若场景因为几何或分段参数变化而塌成
      // 「两次都没计数」，后面的逐字段比对会以「空数组等于空数组」的形式
      // 全绿通过 —— 那是最糟的一种绿。
      final request = runPipeline();
      expect(request.set.repCount, 2);
      expect(
        request.set.faultStats.map((s) => s.code),
        contains('INSUFFICIENT_DEPTH'),
      );
      expect(
        request.set.faultStats.singleWhere((s) => s.code == 'INSUFFICIENT_DEPTH').reps,
        [2],
        reason: '只有第二次蹲浅了 —— 这条同时锁住序号基准（1-based）',
      );
    });

    test('端侧产出的请求与 Python 参考实现逐字段一致', () {
      final actual = runPipeline().toJson();
      expectJsonClose(actual, fixture['expected_request']);
    });
  });
}
