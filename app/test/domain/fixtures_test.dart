/// 跨语言一致性测试 —— Dart 实现必须复现 golden fixtures。
///
/// **这是整个端侧移植的分水岭。** 特征在 Python（生成训练数据）和 Dart（端上推理）
/// 中各实现一次；两者算出的数值若有细微差异，模型会在训练时学到一套分布、
/// 推理时见到另一套，准确率静默崩塌且不会报任何错。
///
/// 通过这份测试之前，后面的摄像头、UI、状态机都不该写 —— 那是在没有地基的地上盖楼。
///
/// 若本文件失败：
///
/// - 若你刚改过 Dart 特征实现 → 先判断是有意的行为变更还是 bug
/// - 有意变更 → 必须同时改 Python 侧并重新生成 fixtures（两侧不能各自漂移）
/// - 意外漂移 → 是 bug，改回去
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// fixture 在仓库的 `shared/` 下。`flutter test` 的工作目录是包根（`app/`），
/// 因此要往上一级找。
const String _fixtureRelativePath = '../shared/fixtures/feature_conformance.json';

/// 浮点比对容差。fixture 保留 6 位小数，跨语言重实现很难做到逐位相同，
/// 因此用绝对容差；关键是要抓住「差了一个量级」「符号反了」「该是 null 却填了数」。
const double _tolerance = 1e-4;

CameraView _viewFromName(String name) => switch (name) {
      'frontal' => CameraView.frontal,
      'sagittal' => CameraView.sagittal,
      'oblique45' => CameraView.oblique45,
      _ => throw ArgumentError('未知机位：$name'),
    };

void main() {
  // **必须在声明期加载，不能放进 setUpAll。**
  //
  // 下面的 `for (final scenario in scenarios())` 在**定义测试**时就会执行，
  // 而 setUpAll 要等到测试开始才跑 —— 那时 fixture 还是个未初始化的 late 变量，
  // 整个文件会以「加载失败」的形式挂掉（报错指向 group 那一行，看不出真正原因）。
  final fixtureFile = File(_fixtureRelativePath);
  if (!fixtureFile.existsSync()) {
    fail(
      'fixture 缺失：${fixtureFile.absolute.path}\n'
      '它由 `cd domain && PYTHONPATH=src python -m tools.build_fixtures` 生成。',
    );
  }
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;

  /// 按场景描述重建姿态帧。
  ///
  /// 基准姿态来自 fixture 自带的 `base_pose`（完整 33 点），因此这里不需要
  /// 复制 Python 生成器里的任何常量 —— 那份 base 一旦改动，两侧会一起变。
  PoseFrame buildPose(Map<String, dynamic> scenario) {
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
    apply((scenario['overrides'] as Map<String, dynamic>?) ?? const {});

    if (scenario['mirrored'] == true) {
      for (final landmark in points.keys.toList()) {
        final p = points[landmark]!;
        points[landmark] = (1.0 - p.$1, p.$2);
      }
    }

    // 遮挡只作用于左膝，与生成器一致（见 build_fixtures.py 的 _build_pose）
    final occluded = (scenario['occluded_landmark_visibility'] as num?)?.toDouble();
    return poseFrameFromPoints(
      points: points,
      frameWidth: fixture['frame_width'] as int,
      frameHeight: fixture['frame_height'] as int,
      visibilityOverrides: occluded == null ? null : {L.leftKnee: occluded},
    );
  }

  List<Map<String, dynamic>> scenarios() =>
      (fixture['scenarios'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('fixture 自身', () {
    test('覆盖全部已注册特征', () {
      final declared = (fixture['feature_codes'] as List<dynamic>).cast<String>().toSet();
      final registered = featureSpecs.map((s) => s.code).toSet();
      expect(
        declared,
        equals(registered),
        reason: 'fixture 与 Dart 特征注册表不一致：'
            '缺少 ${registered.difference(declared)}，'
            '多出 ${declared.difference(registered)}',
      );
    });

    test('每个场景的期望值都完整', () {
      final registered = featureSpecs.map((s) => s.code).toSet();
      for (final scenario in scenarios()) {
        final expected = (scenario['expected'] as Map<String, dynamic>).keys.toSet();
        expect(expected, equals(registered), reason: '场景 ${scenario['id']} 的期望值不完整');
      }
    });

    test('含完整的 33 点基准姿态', () {
      expect((fixture['base_pose'] as Map<String, dynamic>).length, equals(nLandmarks));
    });

    test('每个场景声明了适用的机位', () {
      for (final scenario in scenarios()) {
        expect(
          () => _viewFromName(scenario['camera_view'] as String),
          returnsNormally,
          reason: '场景 ${scenario['id']} 的机位名认不出',
        );
      }
    });
  });

  group('Dart 实现复现 fixture', () {
    for (final scenario in scenarios()) {
      final id = scenario['id'] as String;

      test(id, () {
        final frame = buildPose(scenario);
        final extractor = FeatureExtractor(
          cameraView: _viewFromName(scenario['camera_view'] as String),
        );
        final features = extractor.extract(frame);
        final expected = scenario['expected'] as Map<String, dynamic>;

        final mismatches = <String>[];
        for (final entry in expected.entries) {
          final code = entry.key;
          final want = (entry.value as num?)?.toDouble();
          final got = features.get(code);

          if (want == null) {
            // null 也是契约：不可用的特征两边都必须为 null
            if (got != null) {
              mismatches.add('$code: 期望不可用(null)，实际 $got');
            }
          } else if (got == null) {
            final reason = features.values[code]?.invalidReason;
            mismatches.add('$code: 期望 $want，实际不可用($reason)');
          } else if ((got - want).abs() > _tolerance) {
            mismatches.add('$code: 期望 $want，实际 $got（差 ${got - want}）');
          }
        }

        expect(
          mismatches,
          isEmpty,
          reason: '场景 $id 与 fixture 不符：\n  ${mismatches.join('\n  ')}',
        );
      });
    }
  });

  group('null 是契约的一部分', () {
    test('fixture 里确实存在 null 期望值（可用性契约被覆盖到了）', () {
      final nulls = <String>{};
      for (final scenario in scenarios()) {
        final expected = scenario['expected'] as Map<String, dynamic>;
        for (final entry in expected.entries) {
          if (entry.value == null) nulls.add(entry.key);
        }
      }
      expect(nulls, isNotEmpty, reason: 'fixture 中没有任何 null 期望值');
      expect(nulls, contains('knee_angle_L'), reason: '遮挡场景应当让 knee_angle_L 不可用');
      expect(
        nulls,
        contains('frontal_knee_angle_L'),
        reason: '机位不匹配应当让额状面特征不可用',
      );
    });
  });

  group('关键点名称映射', () {
    test('33 个关键点都能从 UPPER_SNAKE 名称取回', () {
      for (final landmark in L.values) {
        // 反推：先按规则转成 UPPER_SNAKE，再解析回来，应当得到同一个枚举
        final upper = landmark.name
            .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}')
            .toUpperCase();
        expect(
          landmarkFromName(upper),
          equals(landmark),
          reason: '$upper 没能解析回 ${landmark.name}',
        );
      }
    });

    test('fixture 的 base_pose 里每个名称都能解析', () {
      final basePose = fixture['base_pose'] as Map<String, dynamic>;
      final unresolved =
          basePose.keys.where((name) => landmarkFromName(name) == null).toList();
      expect(unresolved, isEmpty, reason: '这些名称解析不出关键点：$unresolved');
    });

    test('认不出的名称返回 null，不猜', () {
      expect(landmarkFromName('NOT_A_LANDMARK'), isNull);
      expect(landmarkFromName(''), isNull);
    });
  });
}
