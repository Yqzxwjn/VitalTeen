/// 报告 view-model 的测试。
///
/// **这个文件守的是「报告里说了什么」，不是排版。** 三处最容易静默出错的：
///
/// 1. **降调漏了一处。** 服务端给「膝内扣」，报告里必须写「膝内扣倾向」——
///    包括填进模板占位符的那个 `primary`，它是个字符串，不换就绕过降调了。
/// 2. **数字没 join 上却显示了一个数。** 响应里的 `metric` 恒为 `null`，
///    数字只能回本地请求里按错误码取。取不到就只显示次数，**不编**。
/// 3. **该披露的口径没披露。** 两个参考分同屏、规则兜底、阈值未核定 ——
///    少一条都不会报错，只会让人把结论读重。
///
/// ok / clean / abstain 三个场景用的是 `shared/fixtures/` 里那份**真响应**，
/// 加上**真资产**（随包的文案表与方案库），所以它同时是一条端到端的接缝测试。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_report.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/decision_response.dart';
import 'package:vitalteen_app/app/decision_submission.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/message_catalog.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

const String _fixturePath = '../shared/fixtures/decision_response_conformance.json';

/// 本地那一份阈值表。数值只为本测试服务，**不是**体育判定依据。
ThresholdTable _table({int pendingReview = 0}) => ThresholdTable(
      [
        for (final (index, (key, value)) in const [
          ('squat.min_depth_knee_angle', 100.0),
          ('squat.knee_valgus_angle_notice', 10.0),
          ('squat.trunk_lean_max_delta', 30.0),
          ('squat.heel_rise_ratio_max_delta', 0.15),
          ('squat.asymmetry_index_max', 0.10),
        ].indexed)
          Threshold(
            key: key,
            actionCode: squatActionCode,
            featureCode: '',
            value: value,
            unit: 'deg',
            // 前 N 条标成未核定，用来验「阈值未核定」那条声明。
            sourceType: index < pendingReview
                ? SourceType.pendingReview
                : SourceType.literature,
            version: 'local-test',
          ),
      ],
      version: 'local-test',
    );

/// 真实的 [FaultPresenter]。它假装成本地那一侧 —— 报告 join 数字证据时
/// 走的就是它。
FaultPresenter _presenter({int pendingReview = 0}) => FaultPresenter(
      definition: buildSquat(
        const Calibration(
          kneeAngle: 178,
          trunkLean: 3,
          heelRiseRatio: 0.02,
          frames: 45,
        ),
        cameraView: CameraView.oblique45,
      ),
      thresholds: _table(pendingReview: pendingReview),
    );

/// 一条本地的 rep 记录。默认是一条深度不足、带一条偏离的。
RepIn _rep({
  int index = 2,
  String code = 'INSUFFICIENT_DEPTH',
  String feature = 'knee_angle_L',
  double measured = 119.5923,
  double threshold = 100.0,
  double? severity01 = 0.4898,
}) =>
    RepIn(
      index: index,
      durationMs: 800,
      phasesMs: const {'descent': 200, 'bottom': 400, 'ascent': 200},
      metrics: const {},
      faults: [
        FaultIn(
          code: code,
          confidence: 1.0,
          evidenceFrames: const [100, 200],
          deviations: [
            DeviationIn(
              feature: feature,
              measured: measured,
              threshold: threshold,
              deltaSigned: measured - threshold,
              severity01: severity01,
            ),
          ],
        ),
      ],
      confidence: null,
    );

DecisionRequest _request({List<RepIn>? reps, String thresholdsVersion = 'local-test'}) =>
    DecisionRequest(
      requestId: 'conformance-1',
      context: const DecisionContext(
        sex: Sex.female,
        age: 16,
        grade: '高一',
        standardGroup: '高中女子',
        actionCode: squatActionCode,
        cameraView: 'oblique45',
      ),
      poseQuality: const PoseQuality(
        meanVisibility: 0.94,
        coverageOkRatio: 0.98,
        fpsMean: 29.7,
        gapMaxMs: 66,
        viewConfidence: 0.91,
      ),
      set: SetIn(
        repCount: 2,
        validRepCount: 2,
        tempoMeanMs: 825,
        romMeanDeg: null,
        symmetryIndexMean: null,
        faultStats: const [],
      ),
      reps: reps ?? [_rep()],
      candidates: const [],
      thresholdsVersion: thresholdsVersion,
    );

/// 一段响应文本，用来造各种边角情形。
DecisionResponse _response(String json) => DecisionResponse.decode(json);

/// 一份最小的 ok 响应，各用例在它上面改一处。
String _okJson({String message = '{"template_id":"msg_squat_insufficient_depth_teen_v1",'
    '"params":{"total":2,"valid":2,"primary":"下蹲深度不足","primary_count":1}}'}) =>
    '''
{
  "request_id": "r-1", "status": "ok",
  "primary_fault": {"code": "INSUFFICIENT_DEPTH", "name": "下蹲深度不足"},
  "faults": [{"code": "INSUFFICIENT_DEPTH", "name": "下蹲深度不足",
    "severity_level": 2, "severity_score": 49, "confidence": 0.94,
    "evidence": {"reps": [2], "metric": null, "mean_deviation": null}}],
  "gates": {"INSUFFICIENT_DEPTH_ok": false},
  "scores": {"form_score": 51, "rating": "需改进", "provisional": true},
  "message": $message,
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "server-1",
    "latency_ms": 12, "shuffled": false}
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final scenarios = {
    for (final item in fixture['scenarios'] as List<dynamic>)
      (item as Map<String, dynamic>)['name'] as String: item,
  };
  DecisionResponse expectedResponse(String name) => DecisionResponse.fromJson(
      scenarios[name]!['expected_response'] as Map<String, dynamic>);

  late MessageCatalog messages;
  late PlanCatalog plans;
  setUpAll(() async {
    messages = await loadMessageCatalog();
    plans = await loadPlanCatalog();
  });

  DecisionReport build(
    DecisionResponse response, {
    DecisionRequest? request,
    MessageCatalog? catalog,
    PlanCatalog? planCatalog,
    int pendingReview = 0,
    bool withLocal = true,
    ReportOrigin origin = ReportOrigin.server,
    DeviceFallbackCause? fallbackCause,
  }) =>
      buildDecisionReport(
        response: response,
        request: request ?? _request(),
        messages: catalog ?? messages,
        planCatalog: planCatalog ?? plans,
        thresholds: _table(pendingReview: pendingReview),
        origin: origin,
        fallbackCause: fallbackCause,
        local: withLocal ? _presenter(pendingReview: pendingReview) : null,
      );

  group('ok 场景（真 fixture + 真资产）', () {
    test('三种结论的判法', () {
      expect(build(expectedResponse('ok')).kind, ReportKind.scored);
      expect(build(expectedResponse('clean')).kind, ReportKind.clean);
      expect(build(expectedResponse('abstain')).kind, ReportKind.abstain);
    });

    test('总述用的是服务端指定的模板，且参数落进了句子', () {
      final report = build(expectedResponse('ok'));
      expect(report.headlineSource, HeadlineSource.serverTemplate);
      expect(report.headline, '这一组 2 次里有 2 次算数。最需要先改的是下蹲深度不足，'
          '它在 1 次里出现过。');
    });

    test('种子稿标着未评审，报告要说明文案是草稿', () {
      // 文案目前全是种子稿（见 shared/messages/teen_v1.json）。
      // 评审过之后这条会红 —— 那时应当更新 JSON 里的 reviewed，
      // 而不是把断言删掉。
      expect(build(expectedResponse('ok')).headlineIsDraft, isTrue);
    });

    test('主问题、严重度、次数都读得出来', () {
      final primary = build(expectedResponse('ok')).primary!;
      expect(primary.code, 'INSUFFICIENT_DEPTH');
      expect(primary.title, '下蹲深度不足');
      expect(primary.severityLabel, '中度');
      expect(primary.repsLabel, '第 2 次');
    });

    test('数字证据是回本地 join 出来的', () {
      // 响应里 `evidence.metric` 是 null —— 这一行只能从本地那份请求里取。
      //
      // 三位数不留小数（119.5923 → 120°），与逐次卡片上的写法一致：
      // 两处说同一个数却一个写 119.6 一个写 120，读的人会以为是两次测量。
      final fault = build(expectedResponse('ok')).faults.single;
      expect(fault.evidenceLine, '第 2 次 · 左膝角 120°（参考值 100°）');
    });

    test('服务端参考分带上口径', () {
      final score = build(expectedResponse('ok')).serviceScore!;
      expect(score.formScore, 51);
      expect(score.rating, '需改进');
      expect(score.provisional, isTrue);
    });

    test('三条建议练习都查得到正文', () {
      final report = build(expectedResponse('ok'));
      expect(report.plans, hasLength(3));
      expect(
        report.plans.map((p) => p.plan.nameZh),
        contains('箱式蹲（椅式蹲）'),
      );
      expect(report.disclosures.map((d) => d.kind),
          isNot(contains(DisclosureKind.planSnapshotStale)));
    });

    test('剂量说明里的 Markdown 星号被剥掉了', () {
      // 服务端文案里有一处 `**动作要领**`，原样渲染用户会看到星号。
      expect(build(expectedResponse('ok')).doseNote, isNot(contains('**')));
    });

    test('四条关键口径声明都在', () {
      final kinds = build(expectedResponse('ok')).disclosures.map((d) => d.kind).toSet();
      expect(kinds, containsAll([
        DisclosureKind.notNationalStandard,
        DisclosureKind.ruleOnly,
        DisclosureKind.provisionalScore,
        DisclosureKind.twoReferenceScores,
        DisclosureKind.dosageUnratified,
      ]));
    });

    test('阈值有未核定的就照实说几条', () {
      final report = build(expectedResponse('ok'), pendingReview: 3);
      final disclosure = report.disclosures
          .singleWhere((d) => d.kind == DisclosureKind.thresholdsPending);
      expect(disclosure.count, 3);
    });

    test('两边阈值版本不同时说清楚，不假装一致', () {
      final report = build(expectedResponse('ok'));
      expect(
        report.disclosures.map((d) => d.kind),
        contains(DisclosureKind.thresholdsVersionMismatch),
      );
    });

    test('技术信息原样带出来', () {
      final tech = build(expectedResponse('ok')).tech;
      expect(tech.requestId, 'conformance-1');
      expect(tech.modelVersion, 'rule-only');
      expect(tech.thresholdsVersion, 'conformance-1');
      expect(tech.localThresholdsVersion, 'local-test');
    });
  });

  group('措辞降调', () {
    test('主问题的名字过一遍降调', () {
      final report = build(_response('''
{
  "request_id": "r", "status": "ok",
  "primary_fault": {"code": "KNEE_VALGUS", "name": "膝内扣"},
  "faults": [{"code": "KNEE_VALGUS", "name": "膝内扣", "severity_level": 1,
    "severity_score": 20, "confidence": 0.6, "evidence": {"reps": [1]}}],
  "gates": {}, "scores": null, "message": null,
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": false}
}
'''));
      expect(report.primary!.title, '膝内扣倾向');
      expect(report.faults.single.title, '膝内扣倾向');
    });

    test('**填进模板占位符的那个 primary 也要降调**', () {
      // `params['primary']` 只是个字符串，而决定措辞强弱的错误码在
      // `primary_fault` 上。不换的话，这一句会绕过 faultTitle() 把
      // 「膝内扣」原样印进句子里 —— 而它恰恰是最需要弱化措辞的那一条。
      final report = build(_response('''
{
  "request_id": "r", "status": "ok",
  "primary_fault": {"code": "KNEE_VALGUS", "name": "膝内扣"},
  "faults": [{"code": "KNEE_VALGUS", "name": "膝内扣", "severity_level": 1,
    "severity_score": 20, "confidence": 0.6, "evidence": {"reps": [1]}}],
  "gates": {}, "scores": null,
  "message": {"template_id": "msg_squat_knee_valgus_teen_v1",
    "params": {"total": 10, "valid": 9, "primary": "膝内扣", "primary_count": 2}},
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": false}
}
'''));
      expect(report.headline, contains('膝内扣倾向'));
      expect(report.headline, isNot(contains('最需要先改的是膝内扣，')));
    });
  });

  group('总述的三级兜底', () {
    test('模板查得到但占位符填不满 → 用兜底模板，不留空格', () {
      // 缺 primary_count。填 0 就是在编一个「一次都没出现」的事实；
      // 硬填会渲染成「它在 次里出现过」。两种都不行，所以整句作废。
      final report = build(_response(_okJson(
        message: '{"template_id":"msg_squat_insufficient_depth_teen_v1",'
            '"params":{"total":2,"valid":2,"primary":"下蹲深度不足"}}',
      )));
      expect(report.headlineSource, HeadlineSource.fallbackTemplate);
      expect(report.headline, '这一组 2 次里有 2 次算数，下面是要留意的地方。');
    });

    test('模板 ID 完全不认识 → 用兜底模板', () {
      final report = build(_response(_okJson(
        message: '{"template_id":"msg_服务端刚加的","params":{"total":2,"valid":2}}',
      )));
      expect(report.headlineSource, HeadlineSource.fallbackTemplate);
      expect(report.headline, isNotNull);
    });

    test('连兜底要的参数都没有 → 明说渲染不出来，不留白', () {
      // 到这一步说明响应本身不合契约（服务端必然产出 total/valid）。
      // 留白是最坏的处理：读的人会以为报告本来就这么短。
      final report = build(_response(_okJson(
        message: '{"template_id":"msg_服务端刚加的","params":{}}',
      )));
      expect(report.headline, isNull);
      expect(report.headlineSource, HeadlineSource.unavailable);
      expect(
        report.disclosures.map((d) => d.kind),
        contains(DisclosureKind.headlineUnavailable),
      );
    });
  });

  group('数字证据补不出来时', () {
    test('本地上下文缺失 → 只显示次数，不显示数字', () {
      final report = build(expectedResponse('ok'), withLocal: false);
      expect(report.faults.single.evidenceLine, isNull);
      expect(report.faults.single.repsLabel, '第 2 次');
      expect(
        report.disclosures.map((d) => d.kind),
        contains(DisclosureKind.evidenceUnavailable),
      );
    });

    test('次数照实说几条', () {
      final report = build(expectedResponse('ok'), withLocal: false);
      final disclosure = report.disclosures
          .singleWhere((d) => d.kind == DisclosureKind.evidenceUnavailable);
      expect(disclosure.count, 1);
    });

    test('本地请求里没有那一次 → 不编，但也不报错', () {
      // 请求与响应不同源（换了设备、重发过）时会发生。这不是崩溃，
      // 只是这一行少个数字。
      final report = build(
        expectedResponse('ok'),
        request: _request(reps: [_rep(index: 7)]),
      );
      expect(report.faults.single.evidenceLine, isNull);
      expect(report.faults.single.repsLabel, '第 2 次');
    });

    test('本地那条 deviation 的单位查不到 → 不显示一个没有单位的数', () {
      final report = build(
        expectedResponse('ok'),
        request: _request(reps: [_rep(code: '不是一个本地规则码')]),
      );
      expect(report.faults.single.evidenceLine, isNull);
    });

    test('同一次有多条偏离时取最严重的那条', () {
      final report = build(
        expectedResponse('ok'),
        request: _request(reps: [
          RepIn(
            index: 2,
            durationMs: 800,
            phasesMs: const {},
            metrics: const {},
            confidence: null,
            faults: [
              FaultIn(
                code: 'INSUFFICIENT_DEPTH',
                confidence: 1,
                evidenceFrames: const [],
                deviations: const [
                  DeviationIn(
                    feature: 'knee_angle_L',
                    measured: 110,
                    threshold: 100,
                    deltaSigned: 10,
                    severity01: 0.1,
                  ),
                  DeviationIn(
                    feature: 'knee_angle_R',
                    measured: 130,
                    threshold: 100,
                    deltaSigned: 30,
                    severity01: 0.9,
                  ),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(report.faults.single.evidenceLine, contains('右膝角'));
      expect(report.faults.single.evidenceLine, contains('130'));
    });

    test('次数超过五条时不逐个列', () {
      final report = build(_response('''
{
  "request_id": "r", "status": "ok", "primary_fault": null,
  "faults": [{"code": "INSUFFICIENT_DEPTH", "name": "下蹲深度不足",
    "severity_level": 1, "severity_score": 10, "confidence": 0.5,
    "evidence": {"reps": [1,2,3,4,5,6,7]}}],
  "gates": {}, "scores": null, "message": null,
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": false}
}
'''));
      expect(report.faults.single.repsLabel, '共 7 次');
    });
  });

  group('达标情况', () {
    test('未达标的排前面，名字从本地定义补', () {
      final report = build(_response('''
{
  "request_id": "r", "status": "ok", "primary_fault": null,
  "faults": [], "gates": {"KNEE_VALGUS_ok": true, "INSUFFICIENT_DEPTH_ok": false},
  "scores": {"form_score": 80, "rating": "良", "provisional": true},
  "message": null,
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": false}
}
'''));
      expect(report.gates.map((g) => g.code).toList(),
          ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS']);
      expect(report.gates.first.ok, isFalse);
      // 响应里没给这两个码起名字 —— 名字由本地动作定义补。
      expect(report.gates.first.title, '下蹲深度不足');
      // 这一条走了降调。
      expect(report.gates.last.title, '膝内扣倾向');
    });

    test('本地也查不到时把码本身显示出来', () {
      // 难看，但能被搜索到；「未知」什么都查不出来。
      final report = build(
        _response('''
{
  "request_id": "r", "status": "ok", "primary_fault": null, "faults": [],
  "gates": {"将来才有的码_ok": false}, "scores": null, "message": null,
  "meta": {"decision_model_version": "rule-only", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": false}
}
'''),
        withLocal: false,
      );
      expect(report.gates.single.title, '将来才有的码');
    });
  });

  group('建议练习的兜底', () {
    test('未知 plan_id 不静默丢弃，也不让报告消失', () {
      final report = build(_response(_okJson().replaceFirst(
        '"scores"',
        '"choice":{"selected_plan_ids":["COR_BOX_SQUAT","COR_服务端刚加的"],'
            '"selection_reason":"按覆盖面排序","dose_note":"剂量待核定。"},"scores"',
      )));
      expect(report.plans, hasLength(1));
      expect(report.plans.single.plan.planId, 'COR_BOX_SQUAT');

      final disclosure = report.disclosures
          .singleWhere((d) => d.kind == DisclosureKind.planSnapshotStale);
      expect(disclosure.count, 1);
      expect(disclosure.text, contains('COR_服务端刚加的'));
    });

    test('选案理由与剂量说明原样带出来', () {
      final report = build(_response(_okJson().replaceFirst(
        '"scores"',
        '"choice":{"selected_plan_ids":[],"selection_reason":"按覆盖面排序",'
            '"dose_note":"本建议由规则引擎产出；剂量待**核定**。"},"scores"',
      )));
      expect(report.selectionReason, '按覆盖面排序');
      expect(report.doseNote, '本建议由规则引擎产出；剂量待核定。');
    });
  });

  group('clean 场景', () {
    test('没有发现问题也是一条结论', () {
      final report = build(expectedResponse('clean'));
      expect(report.kind, ReportKind.clean);
      expect(report.faults, isEmpty);
      expect(report.primary, isNull);
      expect(report.headline, '这一组 2 次里有 2 次算数，没有发现需要留意的地方。');
    });

    test('满分也照样声明「临时算法」与「两个参考分口径不同」', () {
      // 分数好看的时候最容易被当成结论读，口径反而更不能省。
      final kinds = build(expectedResponse('clean')).disclosures.map((d) => d.kind);
      expect(kinds, contains(DisclosureKind.provisionalScore));
      expect(kinds, contains(DisclosureKind.twoReferenceScores));
    });

    test('没有建议方案时不编一条出来', () {
      expect(build(expectedResponse('clean')).plans, isEmpty);
    });
  });

  group('abstain 场景', () {
    test('弃权不是失败态：有结论、有原因、没有错误色可言的分', () {
      final report = build(expectedResponse('abstain'));
      expect(report.kind, ReportKind.abstain);
      expect(report.headline, abstainHeadline);
      expect(report.headlineSource, HeadlineSource.clientConstant);
      expect(report.abstainReason, isNotEmpty);
      expect(report.serviceScore, isNull);
    });

    test('弃权时不说「两个参考分口径不同」—— 根本没有分', () {
      final kinds = build(expectedResponse('abstain')).disclosures.map((d) => d.kind);
      expect(kinds, isNot(contains(DisclosureKind.twoReferenceScores)));
      expect(kinds, isNot(contains(DisclosureKind.provisionalScore)));
    });

    test('重做提示是端侧的固定文案', () {
      expect(abstainAdvice, isNotEmpty);
    });
  });

  group('口径声明本身', () {
    test('「不是国标成绩」永远出现，与场景无关', () {
      for (final name in ['ok', 'clean', 'abstain']) {
        expect(
          build(expectedResponse(name)).disclosures.map((d) => d.kind),
          contains(DisclosureKind.notNationalStandard),
          reason: name,
        );
      }
    });

    test('规则兜底那条跟着 meta 走，不是写死的', () {
      final report = build(_response('''
{
  "request_id": "r", "status": "clean_marker", "primary_fault": null, "faults": [],
  "gates": {}, "scores": null, "message": null,
  "meta": {"decision_model_version": "laya-multilingual", "thresholds_version": "v",
    "latency_ms": 0, "shuffled": true}
}
'''.replaceFirst('"clean_marker"', '"ok"')));
      expect(
        report.disclosures.map((d) => d.kind),
        isNot(contains(DisclosureKind.ruleOnly)),
      );
    });

    test('阈值全部核定时不出那条声明', () {
      expect(
        build(expectedResponse('ok'), pendingReview: 0)
            .disclosures
            .map((d) => d.kind),
        isNot(contains(DisclosureKind.thresholdsPending)),
      );
    });
  });

  group('报告来源（服务端算的 / 本机算的）', () {
    test('服务端来源时不出现「本机算的」那条声明', () {
      expect(
        build(expectedResponse('ok')).disclosures.map((d) => d.kind),
        isNot(contains(DisclosureKind.decidedOnDevice)),
      );
    });

    test('本机来源时那条声明出现，且说得出是「没答话」不是「答错了」', () {
      final report = build(
        expectedResponse('ok'),
        origin: ReportOrigin.device,
        fallbackCause: DeviceFallbackCause.unreachable,
      );
      final disclosure = report.disclosures
          .singleWhere((d) => d.kind == DisclosureKind.decidedOnDevice);

      // 读的人要能一眼看出**这结论不是服务端给的**。
      expect(disclosure.text, contains('本机'));
      // 而且要知道当时到底怎么了 —— 「连不上」与「没回完」下一步做的事不一样。
      expect(disclosure.text, contains(DeviceFallbackCause.unreachable.clause));
    });

    test('超时那条的措辞与连不上不同', () {
      String textOf(DeviceFallbackCause cause) => build(
            expectedResponse('ok'),
            origin: ReportOrigin.device,
            fallbackCause: cause,
          )
              .disclosures
              .singleWhere((d) => d.kind == DisclosureKind.decidedOnDevice)
              .text;

      expect(textOf(DeviceFallbackCause.timeout),
          isNot(textOf(DeviceFallbackCause.unreachable)));
    });

    test('来源与原因必须同时给出', () {
      // 说这份报告是本机算的却不说为什么，读的人就无从判断该不该信它。
      expect(
        () => build(expectedResponse('ok'), origin: ReportOrigin.device),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => build(expectedResponse('ok'),
            fallbackCause: DeviceFallbackCause.unreachable),
        throwsA(isA<AssertionError>()),
      );
    });

    test('每一句自称「服务端」的措辞都跟着来源换', () {
      final server = build(expectedResponse('ok'));
      final device = build(
        expectedResponse('ok'),
        origin: ReportOrigin.device,
        fallbackCause: DeviceFallbackCause.unreachable,
      );

      // 参考分那个标签**保留「服务端」三个字**：它与组末那个端侧即时参考分
      // 是对照关系，省掉这三个字，对照就没有了参照物。本机来源时换成
      // 「本机判定参考分」，那个对照反而更准。
      expect(server.scoreLabel, '服务端参考分');
      expect(device.scoreLabel, '本机判定参考分');

      expect(server.abstainAttribution, '服务端的判定：');
      expect(device.abstainAttribution, '本机判定：');

      expect(server.thresholdsLabel, '服务端阈值表');
      expect(device.thresholdsLabel, '判定所用阈值表');

      // 技术信息里的来源标记也要跟着走。
      expect(server.tech.origin, ReportOrigin.server);
      expect(device.tech.origin, ReportOrigin.device);
    });

    test('「两套参考分」那条声明里的称呼跟着标签走', () {
      // 不跟着换的话，这句话说的就是一个界面上根本不存在的标签。
      String textOf(ReportOrigin origin) => build(
            expectedResponse('ok'),
            origin: origin,
            fallbackCause:
                origin.isDevice ? DeviceFallbackCause.unreachable : null,
          )
              .disclosures
              .singleWhere((d) => d.kind == DisclosureKind.twoReferenceScores)
              .text;

      expect(textOf(ReportOrigin.server), contains('服务端参考分'));
      expect(textOf(ReportOrigin.device), contains('本机判定参考分'));
      expect(textOf(ReportOrigin.device), isNot(contains('服务端参考分')));
    });

    test('弃权场景下来源照样标出来', () {
      // 弃权时没有分数、没有文案模板 —— 但「这份是谁判的」必须还在。
      final report = build(
        expectedResponse('abstain'),
        origin: ReportOrigin.device,
        fallbackCause: DeviceFallbackCause.timeout,
      );
      expect(
        report.disclosures.map((d) => d.kind),
        contains(DisclosureKind.decidedOnDevice),
      );
      expect(report.abstainAttribution, '本机判定：');
    });

    test('顶部那行只有本机来源才有', () {
      expect(build(expectedResponse('ok')).originNotice, isNull);
      expect(
        build(
          expectedResponse('ok'),
          origin: ReportOrigin.device,
          fallbackCause: DeviceFallbackCause.unreachable,
        ).originNotice,
        isNotNull,
      );
    });

    test('顶部那行与声明区那条不是同一句，但说的是同一件事', () {
      // 同一件事写两遍**是有意的**：顶部那行在第一个字之前就得被看见，
      // 声明区那条负责把话说完。但两处的措辞不能互相矛盾 —— 一处说
      // 「本机判定」另一处说「服务端降级」，读的人只会更糊涂。
      final report = build(
        expectedResponse('ok'),
        origin: ReportOrigin.device,
        fallbackCause: DeviceFallbackCause.timeout,
      );
      final notice = report.originNotice!;
      final disclosure = report.disclosures
          .singleWhere((d) => d.kind == DisclosureKind.decidedOnDevice)
          .text;

      expect(notice, isNot(disclosure));
      expect(notice, contains('本机判定'));
      expect(disclosure, contains('本机判定'));
      // 两种来源都不许出现「失败」「出错」——本机判定用的是同一套规则，
      // 它不是一次失败，唯一的差别是算在哪儿、以及没有经过决策模型。
      for (final text in [notice, disclosure]) {
        expect(text, isNot(contains('失败')));
        expect(text, isNot(contains('出错')));
      }
    });
  });
}
