/// 本机判定器的单元测试。
///
/// **这里测的是「分支走对了」，不是「与服务端一模一样」** —— 后者由
/// `local_decision_conformance_test.dart` 拿真 fixture 逐字段锁。
/// 两者不重复：这个文件用最小、可读的请求把每条分支单独照亮，
/// conformance 那份则拿真实流水线产出的请求压整体。
///
/// 参数取的是 `shared/decision/rule_settings.json` 里的真值，
/// 但**写成字面量而不是读文件** —— 这些用例断言的是算法，读文件会让
/// 「改了参数」和「改坏了算法」这两种失败长得一样。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/decision_response.dart';
import 'package:vitalteen_app/app/local_decision.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';
import 'package:vitalteen_app/app/rule_settings.dart';

/// 与服务端当前配置一致的参数。
final RuleSettings _settings = RuleSettings.fromJson(const {
  'min_mean_visibility': 0.5,
  'min_coverage_ratio': 0.6,
  'max_plans': 3,
  'severity_level_breakpoints': [0.34, 0.67],
  'score_worst_weight': 0.6,
  'score_mean_weight': 0.4,
  'rating_cutoffs': [90, 80, 70, 60],
  'rating_labels': ['优', '良', '中', '及格', '需改进'],
  'fallback_model_version': 'rule-only',
});

/// 两条方案：一条覆盖 INSUFFICIENT_DEPTH，一条覆盖 KNEE_VALGUS。
PlanCatalog _catalog() => parsePlanAsset(
      path: 'test',
      raw: '''
{"plans": [
  {"plan_id": "COR_DEPTH", "name_zh": "触凳", "goal": "给深度一个明确目标",
   "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
   "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
   "target_fault_codes": ["INSUFFICIENT_DEPTH"], "difficulty": 1,
   "age_min": 12, "age_max": 18},
  {"plan_id": "COR_VALGUS", "name_zh": "髋周激活", "goal": "改善髋外展控制",
   "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
   "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
   "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
   "age_min": 12, "age_max": 18}
]}
''',
    );

/// 本机判定器的默认入参。多数用例只改其中一两项。
DecisionResponse _decide({
  double meanVisibility = 0.94,
  double coverageOkRatio = 0.98,
  int repCount = 2,
  List<String> candidates = const ['INSUFFICIENT_DEPTH'],
  List<FaultStatIn> faultStats = const [],
  List<RepIn> reps = const [],
  List<String> equipment = const [],
  PlanCatalog? catalog,
  RuleSettings? settings,
}) =>
    decideLocally(
      request: DecisionRequest(
        requestId: 'local-1',
        context: const DecisionContext(
          sex: Sex.female,
          age: 16,
          grade: '高一',
          standardGroup: '高中女子',
          actionCode: 'SQUAT',
          actionVariant: 'standard',
          cameraView: 'oblique45',
          poseBackend: 'mlkit',
          hasWorldLandmarks: false,
        ),
        poseQuality: PoseQuality(
          meanVisibility: meanVisibility,
          coverageOkRatio: coverageOkRatio,
          fpsMean: 29.7,
          gapMaxMs: 66,
          viewConfidence: 0.91,
        ),
        set: SetIn(
          repCount: repCount,
          validRepCount: repCount,
          tempoMeanMs: 825.0,
          romMeanDeg: null,
          symmetryIndexMean: null,
          faultStats: faultStats,
        ),
        reps: reps,
        candidates: [
          for (final code in candidates)
            CandidateIn(code: code, triggeredByRule: 'rule_engine'),
        ],
        thresholdsVersion: 'thr_2026-10_v1',
      ),
      planCatalog: catalog ?? _catalog(),
      settings: settings ?? _settings,
      faultName: _faultName,
      availableEquipment: equipment,
    );

/// 与服务端 `taxonomy.fault_name` 同样只覆盖深蹲这五条（其余原样返回代码）。
String? _faultName(String code) => const {
      'KNEE_VALGUS': '膝内扣',
      'INSUFFICIENT_DEPTH': '下蹲深度不足',
      'EXCESSIVE_TRUNK_LEAN': '躯干过度前倾',
      'HEEL_RISE': '脚跟离地',
      'ASYMMETRY': '左右不对称',
    }[code];

/// 一次带偏离明细的 rep。
RepIn _rep(String code, double? severity, {int index = 1}) => RepIn(
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
              feature: 'knee_angle_L',
              measured: 119.5923,
              threshold: 100.0,
              deltaSigned: 19.5923,
              severity01: severity,
            ),
          ],
        ),
      ],
      confidence: null,
    );

void main() {
  group('质量门', () {
    test('可见性过低 → 弃权，理由里的数字按 Python 保留两位', () {
      final response = _decide(meanVisibility: 0.125);
      expect(response.status, DecisionStatus.abstain);
      // 0.125 → Python 的 f"{:.2f}" 给 0.12（进位到偶数），Dart 原生给 0.13。
      expect(response.abstainReason, '关键点可见性过低（0.12），画面质量不足以判断动作');
      expect(response.scores, isNull, reason: '没有判定就没有分，不填 0');
    });

    test('有效帧占比过低 → 弃权', () {
      final response = _decide(coverageOkRatio: 0.59);
      expect(response.status, DecisionStatus.abstain);
      expect(response.abstainReason, contains('有效帧占比过低（0.59）'));
    });

    test('一次完整动作都没记录到 → 弃权', () {
      final response = _decide(repCount: 0);
      expect(response.status, DecisionStatus.abstain);
      expect(response.abstainReason, '本组未记录到任何完整动作');
    });

    test('门在 clean 短路之前', () {
      // 这一条**只**在顺序写反时才红：没有候选（本该走 clean）同时没有 rep
      // （本该弃权）。先判 clean 的实现会说「动作没问题，100 分」——
      // 那是把「没测到」说成了「测得好」。
      final response = _decide(candidates: const [], repCount: 0);
      expect(response.status, DecisionStatus.abstain);
      expect(response.abstainReason, '本组未记录到任何完整动作');
    });

    test('门槛是闭区间：恰好等于下限不算弃权', () {
      // 服务端写的是 `<`，不是 `<=`。差一个等号会让「刚好达标」的人拿到弃权，
      // 而弃权看起来像数据坏了。
      expect(_decide(meanVisibility: 0.5).status, DecisionStatus.ok);
      expect(_decide(coverageOkRatio: 0.6).status, DecisionStatus.ok);
    });
  });

  group('clean 短路', () {
    test('没有候选 → 直接满分，不挑方案', () {
      final response = _decide(candidates: const [], repCount: 2);
      expect(response.status, DecisionStatus.ok);
      expect(response.faults, isEmpty);
      expect(response.gates, isEmpty);
      expect(response.scores!.formScore, 100);
      expect(response.scores!.rating, '优');
      expect(response.choice, isNull, reason: '没发现问题就不该推荐任何方案');
    });

    test('模板 ID 是 clean 那条，且带 _teen_v1 后缀', () {
      // 早先这里拼出过 `msg_squat_clean_v1`，与 `_build_message` 给的
      // `msg_squat_clean_teen_v1` 是同一种情形的两个 ID，
      // 端侧的模板表至多命中其中一个，另一个静默落进兜底文案。
      final response = _decide(candidates: const [], repCount: 2);
      expect(response.message!.templateId, 'msg_squat_clean_teen_v1');
      expect(response.message!.params, {'total': 2, 'valid': 2});
    });

    test('clean 也必须署名规则兜底', () {
      // 这条路径在构造 state 之前就返回了，从未调用过决策模型 ——
      // 记成模型版本会让一份纯规则的结论被下游当成模型判断，
      // 而端侧正是靠这个字段决定要不要披露「未经模型判断」。
      final response = _decide(candidates: const [], repCount: 2);
      expect(response.meta.decisionModelVersion, 'rule-only');
      expect(response.meta.isRuleOnly, isTrue);
    });
  });

  group('主问题的挑选', () {
    test('取候选集内出现次数最多的，而不是候选集第一项', () {
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
          FaultStatIn(code: 'KNEE_VALGUS', reps: [1, 2, 3], count: 3),
        ],
      );
      expect(response.primaryFault!.code, 'KNEE_VALGUS');
      expect(response.primaryFault!.name, '膝内扣');
    });

    test('faults 的顺序跟着候选集，不跟着统计', () {
      // 服务端是按 `request.candidates` 遍历构造 faults 的。
      // 跟着 fault_stats 排会让同一组数据在两端给出顺序不同的列表，
      // 而报告里「其余问题」那一段直接反映了这个顺序。
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'KNEE_VALGUS', reps: [1, 2, 3], count: 3),
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect([for (final f in response.faults) f.code],
          ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS']);
    });

    test('并列时取 fault_stats 里的首个极大元素', () {
      // Python 的 `max` 返回第一个极大元素。用 `>=` 推进的实现会取到最后一个 ——
      // 结果依然「是个并列项」，所以不会崩，只会让两端的报告偶尔对不上。
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'KNEE_VALGUS', reps: [1, 2], count: 2),
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1, 2], count: 2),
        ],
      );
      // fault_stats 里 KNEE_VALGUS 在前，于是它胜出 —— 尽管候选集里
      // INSUFFICIENT_DEPTH 在前。
      expect(response.primaryFault!.code, 'KNEE_VALGUS');
    });

    test('统计与候选集完全不相交时退回候选集首项', () {
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'HEEL_RISE', reps: [1], count: 5),
        ],
      );
      expect(response.primaryFault!.code, 'INSUFFICIENT_DEPTH');
      // 证据按码 join，不相交就查不到 —— 空列表，不是编一个。
      expect(response.faults.first.evidence.reps, isEmpty);
    });

    test('候选集外的码不会成为主问题', () {
      // 候选集是封闭的：主问题必须出现在 faults 里，而 faults 按候选集构造。
      // 让 HEEL_RISE 胜出会直接违反响应契约。
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH'],
        faultStats: const [
          FaultStatIn(code: 'HEEL_RISE', reps: [1, 2, 3], count: 9),
        ],
      );
      expect(response.primaryFault!.code, 'INSUFFICIENT_DEPTH');
      expect([for (final f in response.faults) f.code], ['INSUFFICIENT_DEPTH']);
    });
  });

  group('严重度：未知与零不是一回事', () {
    test('没有逐次明细时退回出现率，不是当作零', () {
      // 2 次里犯了 2 次 → 出现率 1.0 → 扣满。
      final response = _decide(
        repCount: 2,
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1, 2], count: 2),
        ],
      );
      expect(response.faults.single.severityScore, 100);
      expect(response.faults.single.severityLevel, 3);
      expect(response.scores!.formScore, 0);
      expect(response.scores!.rating, '需改进');
    });

    test('有逐次明细且幅度为零时，就是零', () {
      // 和上一条同一个错误码、同一个出现次数，只有「有没有偏离明细」不同。
      // 把未知填成 0 的实现会让上一条也变成满分 —— 这正是设计文档
      // 铁律二禁止的降级填充。
      final response = _decide(
        repCount: 2,
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1, 2], count: 2),
        ],
        reps: [_rep('INSUFFICIENT_DEPTH', 0.0)],
      );
      expect(response.faults.single.severityScore, 0);
      expect(response.faults.single.severityLevel, 1);
      expect(response.scores!.formScore, 100);
      expect(response.scores!.rating, '优');
    });

    test('取整组最大值，不取平均', () {
      // 一次严重的膝内扣不该被九次轻微动作平摊掉。
      final response = _decide(
        candidates: const ['KNEE_VALGUS'],
        reps: [
          _rep('KNEE_VALGUS', 0.2, index: 1),
          _rep('KNEE_VALGUS', 0.9, index: 2),
          _rep('KNEE_VALGUS', 0.1, index: 3),
        ],
      );
      expect(response.faults.single.severityScore, 90);
      expect(response.faults.single.severityLevel, 3);
    });

    test('severity_0_1 为 null 的那些偏离被跳过，不当成零参与取最大', () {
      // 一条 0.9 与一条未知：未知被跳过，结果是 0.9 而不是 (0.9+0)/2。
      final response = _decide(
        candidates: const ['KNEE_VALGUS'],
        reps: [_rep('KNEE_VALGUS', 0.9), _rep('KNEE_VALGUS', null, index: 2)],
      );
      expect(response.faults.single.severityScore, 90);
    });

    test('severity_score 用 Python 的舍入：0.125 → 12 而不是 13', () {
      // round(0.125 * 100) = round(12.5) → 12（进位到偶数）。
      // 差这 1 分不会报错，只会让断网与联网两端的报告对不上。
      final response = _decide(
        candidates: const ['KNEE_VALGUS'],
        reps: [_rep('KNEE_VALGUS', 0.125)],
      );
      expect(response.faults.single.severityScore, 12);
    });

    test('档位切点是闭下界', () {
      for (final (severity, level) in [
        (0.0, 1),
        (0.339, 1),
        (0.34, 2),
        (0.669, 2),
        (0.67, 3),
      ]) {
        final response = _decide(
          candidates: const ['KNEE_VALGUS'],
          reps: [_rep('KNEE_VALGUS', severity)],
        );
        expect(response.faults.single.severityLevel, level, reason: '$severity');
      }
    });
  });

  group('评分与评级', () {
    test('置信度取可见性与覆盖占比的较小者，保留四位', () {
      final response = _decide(
        meanVisibility: 0.90625,
        coverageOkRatio: 0.98,
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      // round(0.90625, 4) → 0.9062（进位到偶数），Dart 原生会给 0.9063。
      expect(response.faults.single.confidence, 0.9062);
    });

    test('多条错误按「最重为主、其余平均为辅」加权', () {
      // worst=0.9, mean=(0.9+0.3)/2=0.6 → 扣分 = 0.6*0.9 + 0.4*0.6 = 0.78
      // → 100 * (1-0.78) = 22。
      final response = _decide(
        candidates: const ['KNEE_VALGUS', 'INSUFFICIENT_DEPTH'],
        reps: [
          _rep('KNEE_VALGUS', 0.9),
          _rep('INSUFFICIENT_DEPTH', 0.3, index: 2),
        ],
      );
      expect(response.scores!.formScore, 22);
      expect(response.scores!.rating, '需改进');
    });

    test('评级阶梯的边界是闭下界', () {
      expect(_settings.ratingOf(90), '优');
      expect(_settings.ratingOf(89), '良');
      expect(_settings.ratingOf(60), '及格');
      expect(_settings.ratingOf(59), '需改进');
    });

    test('评分永远标 provisional', () {
      // 正式评分要等体育专业成员给出扣分曲线。标 false 会让一份临时算法
      // 的结果看起来像已核定的成绩。
      final response = _decide(
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect(response.scores!.provisional, isTrue);
    });
  });

  group('方案与文案', () {
    test('按候选错误码挑方案，并带上「未核定」的说明', () {
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect(response.choice!.selectedPlanIds, ['COR_DEPTH', 'COR_VALGUS']);
      // 库里两条都是 draft，已核定那一遍查不到 → 回退，并如实标注。
      expect(response.choice!.selectionReason, startsWith('（方案未核定，仅供参考）'));
      expect(response.choice!.doseNote, contains('规则引擎'));
    });

    test('候选码没有对应方案时不给建议，而不是勉强给一条', () {
      final response = _decide(
        candidates: const ['EXCESSIVE_TRUNK_LEAN', 'HEEL_RISE'],
        faultStats: const [
          FaultStatIn(code: 'HEEL_RISE', reps: [1], count: 1),
        ],
      );
      expect(response.choice, isNull);
      expect(response.primaryFault!.code, 'HEEL_RISE');
    });

    test('器材过滤：手上有弹力带才选得出要器材的那条', () {
      // 单独造一份库，避免动上面那两条共用方案。
      final catalog = parsePlanAsset(
        path: 'test',
        raw: '''
{"plans": [
  {"plan_id": "COR_BAND", "name_zh": "弹力带侧向行走", "goal": "练臀中肌",
   "instructions": [], "key_cues": [], "equipment": ["弹力带"], "contraindications": ["停"],
   "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
   "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 2,
   "age_min": 12, "age_max": 18},
  {"plan_id": "COR_FREE", "name_zh": "徒手蚌式", "goal": "练臀中肌",
   "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
   "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
   "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
   "age_min": 12, "age_max": 18}
]}
''',
      );

      List<String> chosenWith(List<String> equipment) => _decide(
            candidates: const ['KNEE_VALGUS'],
            faultStats: const [
              FaultStatIn(code: 'KNEE_VALGUS', reps: [1], count: 1),
            ],
            catalog: catalog,
            equipment: equipment,
          ).choice!.selectedPlanIds;

      // 徒手时那条要器材的**被排除**，不是排到最后 ——
      // 推荐一条做不了的方案，比少推荐一条更糟。
      expect(chosenWith(const []), ['COR_FREE']);
      // 有弹力带时两条都在；徒手那条难度更低，所以仍排在前面。
      expect(chosenWith(const ['弹力带']), ['COR_FREE', 'COR_BAND']);
    });

    test('方案数被 max_plans 硬截断', () {
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
        settings: RuleSettings.fromJson(const {
          'min_mean_visibility': 0.5,
          'min_coverage_ratio': 0.6,
          'max_plans': 1,
          'severity_level_breakpoints': [0.34, 0.67],
          'score_worst_weight': 0.6,
          'score_mean_weight': 0.4,
          'rating_cutoffs': [90, 80, 70, 60],
          'rating_labels': ['优', '良', '中', '及格', '需改进'],
          'fallback_model_version': 'rule-only',
        }),
      );
      expect(response.choice!.selectedPlanIds, hasLength(1));
    });

    test('模板 ID 按动作码与主问题码拼，全小写', () {
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'KNEE_VALGUS', reps: [1], count: 3),
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect(response.message!.templateId, 'msg_squat_knee_valgus_teen_v1');
      expect(response.message!.params['primary'], '膝内扣');
      expect(response.message!.params['primary_count'], 3);
      expect(response.message!.params['total'], 2);
    });
  });

  group('契约形状', () {
    test('规则路径的每一项门控都记 false', () {
      // gates 的含义是「这一项由决策模型判过并通过了吗」。规则路径根本没判过，
      // 记 true 会变成冒充模型结论。
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect(response.gates, {
        'INSUFFICIENT_DEPTH_ok': false,
        'KNEE_VALGUS_ok': false,
      });
    });

    test('元信息署规则兜底、不打乱、耗时记 0', () {
      final response = _decide(
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
      );
      expect(response.meta.decisionModelVersion, 'rule-only');
      expect(response.meta.shuffled, isFalse);
      expect(response.meta.shuffleSeed, isNull);
      expect(response.meta.latencyMs, 0);
      expect(response.meta.thresholdsVersion, 'thr_2026-10_v1');
    });

    test('未知的错误码原样用代码当名字，不编一个', () {
      // 与服务端 `taxonomy.fault_name` 一致。返回空串会让界面出现一个
      // 没有标题的告警，比看到英文码更糟。
      final response = _decide(
        candidates: const ['SOME_FUTURE_CODE'],
        faultStats: const [
          FaultStatIn(code: 'SOME_FUTURE_CODE', reps: [1], count: 1),
        ],
      );
      expect(response.primaryFault!.name, 'SOME_FUTURE_CODE');
    });

    test('序列化回去还能解析出同一份', () {
      // 深比较的前提是 toJson 与 fromJson 是一对互逆的。
      final response = _decide(
        candidates: const ['INSUFFICIENT_DEPTH', 'KNEE_VALGUS'],
        faultStats: const [
          FaultStatIn(code: 'INSUFFICIENT_DEPTH', reps: [1], count: 1),
        ],
        reps: [_rep('INSUFFICIENT_DEPTH', 0.4898)],
      );
      final round = DecisionResponse.fromJson(response.toJson());
      expect(round.toJson(), response.toJson());
    });
  });
}
