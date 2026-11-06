/// 阈值表装载的测试。
///
/// **这个文件的重点是「找不到」和「找到两份」这两条报错路径。**
/// 它们平时一行都不会执行，只在阈值表升版的那天跑一次 —— 而那正是最需要
/// 它说清楚问题的时候。所以它们不靠「假装测过」，靠 [selectThresholdAsset]
/// 是纯函数来穷尽覆盖。
///
/// 另一头是**真读一次随包发布的那份 asset**：装载器的接缝（AssetManifest →
/// 文件 → 解析）任何一处错位，都只有真读才会暴露。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/thresholds_loader.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

const String _path = 'assets/thresholds/thr_2026-10_v1.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('挑文件', () {
    test('目录里只有一份时选它', () {
      expect(
        selectThresholdAsset([_path]),
        _path,
      );
    });

    test('忽略别的资源，只认阈值目录下的 .json', () {
      expect(
        selectThresholdAsset([
          'AssetManifest.bin',
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
          'assets/thresholds/thr_2026-10_v1.json',
          // 同目录但不是 json —— 比如留给人的说明文档，不该被当成阈值表。
          'assets/thresholds/README.md',
          // 别的目录下的 json 也不认。
          'assets/fixtures/squat.json',
        ]),
        _path,
      );
    });

    test('目录为空时抛，并说清去哪看', () {
      expect(
        () => selectThresholdAsset(['AssetManifest.bin']),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            allOf(contains('assets/thresholds/'), contains('pubspec.yaml')),
          ),
        ),
      );
    });

    test('找到两份时抛，并把两份都列出来', () {
      // 不选「较新的那个」是刻意的：名字里的版本号怎么排、v10 与 v2 谁新，
      // 都是约定；程序猜错的表现是判定悄悄用上旧阈值，且不报错。
      expect(
        () => selectThresholdAsset([
          'assets/thresholds/thr_2026-10_v1.json',
          'assets/thresholds/thr_2027-01_v2.json',
        ]),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('2 份'),
              contains('thr_2026-10_v1.json'),
              contains('thr_2027-01_v2.json'),
            ),
          ),
        ),
      );
    });
  });

  group('解析', () {
    test('坏 JSON 的报错带文件名', () {
      expect(
        () => parseThresholdAsset(path: _path, raw: '{ 这不是 json'),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });

    test('顶层不是对象也报错，并说明实际是什么', () {
      expect(
        () => parseThresholdAsset(path: _path, raw: '[1, 2, 3]'),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith(_path), contains('List')),
          ),
        ),
      );
    });

    test('缺字段的报错也带文件名', () {
      // 调试的人手上可能有十几份 json，只说「缺少 version 字段」等于没说。
      expect(
        () => parseThresholdAsset(path: _path, raw: '{"thresholds": []}'),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith(_path), contains('version')),
          ),
        ),
      );
    });
  });

  group('真读随包发布的那份', () {
    test('能从资源里读出来，且与磁盘上那份一致', () async {
      final loaded = await loadThresholds();
      final onDisk = ThresholdTable.fromJson(
        jsonDecode(File(_path).readAsStringSync()) as Map<String, dynamic>,
      );

      expect(loaded.version, onDisk.version);
      expect(loaded.length, onDisk.length);
      expect(loaded.pendingReview().length, onDisk.pendingReview().length);
    });

    test('深蹲的每条规则都能在里面查到阈值', () async {
      final table = await loadThresholds();
      final definition = buildSquat(
        const Calibration(
          kneeAngle: 178,
          trunkLean: 3,
          heelRiseRatio: 0.02,
          frames: 45,
        ),
        cameraView: CameraView.oblique45,
      );

      for (final rule in definition.rules) {
        expect(
          table.contains(rule.thresholdKey),
          isTrue,
          reason: '规则 ${rule.code} 的阈值键 ${rule.thresholdKey} 不在表里，'
              '判定会在运行时抛异常',
        );
      }
    });
  });
}
