/// **本机判定与 Python 服务端逐字段一致。**
///
/// 这是「断网也能出报告」这件事成立的核心证明，`decision_response_conformance_test.dart`
/// 是它的单向兄弟：那边证明端侧**读得懂**服务端，这边证明端侧**算得出同一份**。
///
/// ## 怎么锁
///
/// fixture 里每个场景都带一份**真请求**，以及服务端在同一份请求上产出的
/// `expected_response`（由 `build_response_fixture.py` 走 `DecisionService(laya=None)`
/// 生成）。这里把那份请求喂给 `decideLocally`，把结果 `toJson()` 一遍，
/// 与期望值**深比较**。
///
/// 比的是序列化后的 JSON 而不是 Dart 对象，因为「最终一致」的定义就在这里：
/// 报告渲染读的是这些字段，字段对上就是行为对上。
///
/// ## 唯一允许的差异：`meta.latency_ms`
///
/// 服务端那条路测的是真实耗时（fixture 里已归零），本机路径没有网络往返可测，
/// 恒为 0。除此之外**任何一个字段不同都算不一致** —— 包括文案字符串、
/// 模板 ID 的拼法、`gates` 的值、列表的顺序。
///
/// ## 这份测试红了怎么办
///
/// 说明两份实现漂移了。**先看 `service.py` 的 `_rule_only` / `_provisional_scores` /
/// `_rule_primary` / `_build_message`**，别直接改这里的期望值 ——
/// 期望值是服务端跑出来的，改它等于把锁拆了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/local_decision.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';
import 'package:vitalteen_app/app/rule_settings.dart';
import 'package:vitalteen_app/app/thresholds_loader.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';

import '../support/fixture_request.dart';

const String _fixtureRelativePath =
    '../shared/fixtures/decision_response_conformance.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> fixture;
  late Map<String, Map<String, dynamic>> scenarios;
  late FaultPresenter presenter;

  setUpAll(() async {
    final file = File(_fixtureRelativePath);
    if (!file.existsSync()) {
      fail(
        'fixture 缺失：${file.absolute.path}\n'
        '它由 `cd server && python -m tools.build_response_fixture` 生成。',
      );
    }
    fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    scenarios = {
      for (final item in fixture['scenarios'] as List<dynamic>)
        (item as Map<String, dynamic>)['name'] as String: item,
    };
    // 名字表来自本地动作定义 —— 与生产同源。**不能在这儿塞一个假的**：
    // 服务端是从 `taxonomy.FAULT_NAMES` 取名字的，两边对不上时报告里
    // 就会出现两种叫法，而那是本机判定最容易悄悄偏掉的一格。
    presenter = FaultPresenter(
      definition: buildSquat(
        const Calibration(
          kneeAngle: 178,
          trunkLean: 3,
          heelRiseRatio: 0.02,
          frames: 45,
        ),
        cameraView: CameraView.oblique45,
      ),
      thresholds: await loadThresholds(),
    );
  });

  /// 用随包发布的资产与真实的动作定义跑本机判定 —— 与生产同款依赖，不另造一套。
  Future<String> decideOnDevice(String name) async {
    final scenario = scenarios[name]!;
    final response = decideLocally(
      request: requestFromJson(scenario['request'] as Map<String, dynamic>),
      planCatalog: await loadPlanCatalog(),
      settings: await loadRuleSettings(),
      faultName: presenter.faultName,
      availableEquipment: [
        for (final item in scenario['available_equipment'] as List<dynamic>? ?? const [])
          item as String,
      ],
    );
    // 耗时归零：服务端那份由 fixture 生成时已归零，比的是其余全部字段。
    final json = response.toJson();
    (json['meta']! as Map<String, dynamic>)['latency_ms'] = 0;
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  group('本机判定 = 服务端判定', () {
    test('每个场景逐字段一致', () async {
      final failed = <String>[];
      for (final name in scenarios.keys) {
        final actual = await decideOnDevice(name);
        final expected = const JsonEncoder.withIndent('  ')
            .convert(scenarios[name]!['expected_response']);
        if (actual != expected) {
          failed.add('--- $name ---\n期望：\n$expected\n实际：\n$actual');
        }
      }
      expect(
        failed,
        isEmpty,
        reason: '本机判定与服务端不一致：\n${failed.join('\n\n')}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('这把锁本身不能空转', () {
    test('场景数不是零', () {
      // fixture 没有 scenarios 或名字对不上时，上面的用例会一个都不跑，
      // 然后「全部通过」。这条把它挡掉。
      expect(scenarios, isNotEmpty);
    });

    test('每个场景都具备三样东西', () {
      for (final entry in scenarios.entries) {
        expect(entry.value['request'], isA<Map<String, dynamic>>(),
            reason: '${entry.key} 缺 request');
        expect(entry.value['expected_response'], isA<Map<String, dynamic>>(),
            reason: '${entry.key} 缺 expected_response');
        expect(entry.value['note'], isNotEmpty, reason: '${entry.key} 缺 note');
      }
    });

    test('每个场景都能被端侧解析', () {
      // 解析失败会以异常形式炸在上面的用例里，但那句话读起来像是本机判定的错。
      // 这条把「读不懂」与「算不对」分开。
      for (final entry in scenarios.entries) {
        expect(
          () => requestFromJson(entry.value['request'] as Map<String, dynamic>),
          returnsNormally,
          reason: '${entry.key} 的请求端侧读不了',
        );
      }
    });
  });
}
