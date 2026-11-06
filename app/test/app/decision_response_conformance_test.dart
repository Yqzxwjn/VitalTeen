/// 跨语言一致性 —— 端侧必须读得懂 Python 服务端产出的真实响应。
///
/// fixture 由 `server/tools/build_response_fixture.py` 走**真实规则路径**
/// （`DecisionService(laya=None)`）产出，不是手写的。这条锁是**单向**的：
/// 服务端是唯一的产出者，端侧只需要能读。
///
/// **这里比的不只是「解析得动」**，还有三件事，它们各自对应一种「不会报错」的失败：
///
/// 1. **模板 ID 在包里查得到。** 服务端给了一个端侧没有的 ID 时，报告里那一句
///    会静默落进兜底文案 —— 少了一句话，没有任何异常。
/// 2. **方案 ID 在包里查得到。** 导出时忘了带 `status=draft` 的方案，报告里
///    就会显示「这条建议不在本应用的方案库中」，而方案库明明导出了。
/// 3. **证据能 join 回请求。** `evidence.reps` 是 1-based 的下标，要按它回
///    本地请求里取那一次的数字。差一位就是「报告说第 3 次有问题，视频里
///    第 3 次好好的」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_response.dart';
import 'package:vitalteen_app/app/message_catalog.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';

/// fixture 在仓库的 `shared/` 下。`flutter test` 的工作目录是包根（`app/`），
/// 因此要往上一级找。
const String _fixtureRelativePath =
    '../shared/fixtures/decision_response_conformance.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtureFile = File(_fixtureRelativePath);
  if (!fixtureFile.existsSync()) {
    fail(
      'fixture 缺失：${fixtureFile.absolute.path}\n'
      '它由 `cd server && python -m tools.build_response_fixture` 生成。',
    );
  }
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;

  final scenarios = {
    for (final item in fixture['scenarios'] as List<dynamic>)
      (item as Map<String, dynamic>)['name'] as String: item,
  };

  Map<String, dynamic> expected(String name) =>
      scenarios[name]!['expected_response'] as Map<String, dynamic>;
  Map<String, dynamic> request(String name) =>
      scenarios[name]!['request'] as Map<String, dynamic>;

  DecisionResponse parse(String name) =>
      DecisionResponse.fromJson(expected(name));

  /// 端侧**逐条点过名**的场景，与 `build_response_fixture.py` 的 `SCENARIO_NOTES`
  /// 一一对应。
  ///
  /// 写成显式名单而不是「只要有就行」，是因为下面那条断言要求两端**集合相等**：
  /// 服务端新加一个场景时这里会红，逼端侧来看一眼「这个新场景说的是报告里哪种
  /// 情形、我渲染得对吗」。只断言「原来那三个还在」的话，服务端加多少场景
  /// 都是假绿 —— 而假绿比红危险，它会让人相信覆盖了其实没覆盖的东西。
  const coveredScenarios = {
    'ok', // 有候选错误的规则兜底路径
    'clean', // 没触发任何候选错误 —— 这是一条结论，不是缺数据
    'abstain', // 质量门第一条：可见性不足
    'abstain_low_coverage', // 质量门第二条：有效帧占比不足
    'abstain_no_reps', // 质量门第三条，兼证明门在 clean 短路之前
    'primary_by_count', // 主问题取命中次数最多者
    'primary_tie_first_stat', // 并列时取 fault_stats 首个极大元素
    'severity_unknown_vs_zero', // 未知与零不是一回事
    'severity_rounding', // 半偶舍入（Python round / round(x, 4)）
    'stats_disjoint', // 统计与候选集不相交 → 退回候选集首项
    'no_reps_thin', // 无逐次明细时退回出现率
    'plans_equipment', // 器材过滤 + 覆盖数优先
    'plans_age_filter', // 年龄筛掉全部方案：choice 为 null 但错误照报
  };

  group('fixture 本身', () {
    test('场景名单两端一致', () {
      expect(
        scenarios.keys.toSet(),
        coveredScenarios,
        reason: '服务端 fixture 与端侧点过名的场景对不上。'
            '新增场景请先看清它在锁哪条分支、报告里怎么渲染，再把它加进 coveredScenarios。',
      );
    });

    test('全部由规则路径产出', () {
      // 模型路径刻意不进 fixture（需要假模型），由服务端单测覆盖。
      // 这条钉住的是「端侧声称覆盖了模型路径」这种事不会悄悄发生。
      expect(fixture['decided_with'], 'rule-only');
      for (final name in scenarios.keys) {
        expect(
          parse(name).meta.decisionModelVersion,
          'rule-only',
          reason: '$name 场景应当是规则兜底产出的',
        );
        expect(parse(name).meta.isRuleOnly, isTrue, reason: name);
      }
    });
  });

  /// 逐场景的**连通性**检查：响应里引用的每一个名字，端侧都得有对应的东西。
  ///
  /// 这些是「不会报错」的失败 —— 模板查不到就落兜底文案、方案查不到就显示
  /// 「不在本应用的方案库中」、主问题不在 faults 里就指向一条不存在的错误。
  /// 单看 `ok` 是覆盖不到新场景的，所以这里一律遍历全部场景。
  group('全部场景都连得上端侧资产', () {
    test('每条文案的模板 ID 都在包里', () async {
      final catalog = await loadMessageCatalog();
      for (final name in scenarios.keys) {
        final message = parse(name).message;
        // 弃权刻意不带模板（报告要说的是「数据不够」，不是动作结论）。
        if (message == null) continue;
        expect(
          catalog.templateIds,
          contains(message.templateId),
          reason: '$name：模板 ${message.templateId} 不在包里 —— '
              '报告里那一句会静默落进兜底文案',
        );
      }
    });

    test('填得满就渲染得出，填不满则必须落进兜底而不是留白', () async {
      final catalog = await loadMessageCatalog();
      final unrenderable = <String>[];

      for (final name in scenarios.keys) {
        final message = parse(name).message;
        if (message == null) continue;
        if (catalog.render(message.templateId, message.params) == null) {
          // 端侧的规矩是**不硬填**：缺失的 primary_count 有明确含义 ——
          // 组级统计里没有这个码。填 0 就是在编一个「一次都没出现」的事实。
          // 整句作废是本文件 `message_catalog.dart` 顶上的设计决定，
          // 但它有个前提：兜底模板必须填得满。
          expect(
            catalog.renderFallback(message.params),
            isNotNull,
            reason: '$name：主模板填不满，兜底模板也填不满 —— 报告那一格会留白',
          );
          unrenderable.add(name);
        }
      }

      // **已知只有 stats_disjoint 会走到这里**：主问题退回候选集首项，而组级
      // 统计里没有这个码，服务端因此给不出 primary_count。名单一旦变长，
      // 就说明又多了一种「服务端只能给出半句话」的情形 —— 那该有人看一眼，
      // 而不是让它悄悄混进来。
      expect(unrenderable, ['stats_disjoint']);
    });

    test('被选中的方案都在方案库里', () async {
      final catalog = await loadPlanCatalog();
      for (final name in scenarios.keys) {
        for (final id in parse(name).choice?.selectedPlanIds ?? const <String>[]) {
          expect(
            catalog.byId(id),
            isNotNull,
            reason: '$name：$id 在决策响应里被选中了，但导出的方案库里没有它 —— '
                '多半是 export_plans 漏掉了 status=draft 的方案',
          );
        }
      }
    });

    test('primary_fault 一定出现在 faults 里', () {
      // 契约要求。违反了报告会出现「主要问题：X」而下面那张错误清单里
      // 根本没有 X。`stats_disjoint` 正是把实现逼到这条边界上的场景。
      for (final name in scenarios.keys) {
        final response = parse(name);
        final primary = response.primaryFault;
        if (primary == null) continue;
        expect(
          response.faults.map((fault) => fault.code),
          contains(primary.code),
          reason: '$name：主问题 ${primary.code} 不在 faults 里',
        );
      }
    });
  });

  group('ok 场景', () {
    test('主问题、分数、门控都读得出来', () {
      final response = parse('ok');

      expect(response.status, DecisionStatus.ok);
      expect(response.primaryFault!.code, 'INSUFFICIENT_DEPTH');
      expect(response.faults, hasLength(1));
      expect(response.faults.single.code, 'INSUFFICIENT_DEPTH');
      expect(response.faults.single.severityLevel, 2);
      expect(response.faults.single.severityScore, 49);
      expect(response.faults.single.evidence.reps, [2]);
      expect(response.gates, {'INSUFFICIENT_DEPTH_ok': false});
      expect(response.scores!.formScore, 51);
      expect(response.scores!.rating, '需改进');
      expect(response.scores!.provisional, isTrue);
      expect(response.choice!.selectedPlanIds, hasLength(3));
      expect(response.choice!.doseNote, isNotEmpty);
    });

    test('message 能在包里查出正文', () async {
      final catalog = await loadMessageCatalog();
      final message = parse('ok').message!;

      final text = catalog.render(message.templateId, message.params);
      expect(
        text,
        isNotNull,
        reason: '服务端给的模板 ${message.templateId} 在包里查不到，或占位符填不满 —— '
            '两种情况都会让报告里那句话静默落进兜底文案',
      );
      // 参数要真的落进句子，而不是「填上了但填的是空的」。
      expect(text, contains('2'));
      expect(text, contains('下蹲深度不足'));
    });

    test('证据能 join 回请求里那一次的数字', () {
      // **这是本文件里唯一一条跨三方的断言**：响应的 evidence.reps
      //（1-based）→ 请求的 reps[].index → 那一次的 deviations。
      // decision_report.dart 就是按这条路取「左膝角 119.6°（参考值 100°）」的。
      final response = parse('ok');
      final reps = (request('ok')['reps'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      for (final fault in response.faults) {
        expect(fault.evidence.reps, isNotEmpty, reason: '${fault.code} 没有可 join 的次数');
        for (final index in fault.evidence.reps) {
          final rep = reps.singleWhere((r) => r['index'] == index);
          final matches = (rep['faults'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .where((f) => f['code'] == fault.code);
          expect(
            matches,
            isNotEmpty,
            reason: '响应说第 $index 次有 ${fault.code}，但请求里第 $index 次没有这条 —— '
                '序号基准错位',
          );
          expect(
            (matches.single['deviations'] as List<dynamic>),
            isNotEmpty,
            reason: '第 $index 次的 ${fault.code} 没有 deviations，报告里那行数字补不上',
          );
        }
      }
    });

    test('evidence.metric 是 null —— 数字必须回本地取', () {
      // 服务端不知道用户看到的那一行是什么。这条钉住的是「端侧不许把
      // metric 当成有值来用」：它恒为 null，渲染侧必须走上面那条 join。
      expect(parse('ok').faults.single.evidence.metric, isNull);
      expect(parse('ok').faults.single.evidence.meanDeviation, isNull);
    });
  });

  group('clean 场景', () {
    test('是一条有效结论，不是数据缺失', () {
      final response = parse('clean');
      expect(response.status, DecisionStatus.ok);
      expect(response.faults, isEmpty);
      expect(response.primaryFault, isNull);
      expect(response.gates, isEmpty);
      expect(response.scores!.formScore, 100);
      expect(response.scores!.rating, '优');
      // 满分也仍是临时算法 —— 口径声明照发。
      expect(response.scores!.provisional, isTrue);
    });

    test('没有建议方案时不编一条出来', () {
      expect(parse('clean').choice, isNull);
    });

    test('message 用的是 clean 模板，且与服务端另一条路径同 ID', () {
      // `_clean_response` 早先自己拼 `msg_squat_clean_v1`，而通用拼法给的是
      // `_teen_v1` —— 同一种情形两个 ID，端侧至多命中一个。这条锁住统一后的结果。
      expect(parse('clean').message!.templateId, 'msg_squat_clean_teen_v1');
    });

    test('clean 的一句话在包里能渲染出来', () async {
      final catalog = await loadMessageCatalog();
      final message = parse('clean').message!;
      expect(catalog.render(message.templateId, message.params), isNotNull);
    });
  });

  group('abstain 场景', () {
    test('弃权有原因，且不给分', () {
      final response = parse('abstain');
      expect(response.status, DecisionStatus.abstain);
      expect(response.abstainReason, isNotEmpty);
      expect(response.scores, isNull);
      expect(response.faults, isEmpty);
      expect(response.primaryFault, isNull);
    });

    test('弃权时不带文案模板 —— 报告要说的是「数据不够」，不是动作结论', () {
      expect(parse('abstain').message, isNull);
    });
  });

  group('主问题怎么挑', () {
    test('按命中次数最多，而不是取候选集第一项', () {
      // 候选序 [深度不足, 膝内扣]，命中次数 1 : 2。取 candidates[0] 的实现
      // 会报「深度不足」，而服务端报「膝内扣」。
      final response = parse('primary_by_count');
      expect(response.primaryFault!.code, 'KNEE_VALGUS');
      expect(
        response.faults.singleWhere((f) => f.code == 'KNEE_VALGUS').evidence.reps,
        [1, 2],
      );
    });

    test('并列时取 fault_stats 的首个极大元素', () {
      // 两个码都命中 2 次，而 fault_stats 的顺序与候选序**故意相反**。
      // 用 `>=` 推进的实现会取到最后一个极大元素（深度不足）—— 它不崩，
      // 只是让断网与联网两端的报告偶尔对不上。
      expect(parse('primary_tie_first_stat').primaryFault!.code, 'KNEE_VALGUS');
    });

    test('统计与候选集不相交时退回候选集首项，且不编造证据', () {
      final response = parse('stats_disjoint');
      expect(response.primaryFault!.code, 'INSUFFICIENT_DEPTH');
      for (final fault in response.faults) {
        expect(
          fault.evidence.reps,
          isEmpty,
          reason: '${fault.code} 在组级统计里一次都没出现，不该有逐次证据',
        );
      }
      // 没有次数可数时，文案参数里就没有 primary_count ——
      // 报告用的是同一个模板，缺这个参数不能整句落空（上面那条已覆盖渲染）。
      expect(
        parse('stats_disjoint').message!.params.containsKey('primary_count'),
        isFalse,
      );
    });
  });

  group('严重度', () {
    test('未知与零不是一回事', () {
      final response = parse('severity_unknown_vs_zero');
      final depth = response.faults.singleWhere((f) => f.code == 'INSUFFICIENT_DEPTH');
      final heel = response.faults.singleWhere((f) => f.code == 'HEEL_RISE');

      // 深度不足带一条 severity_0_1 == 0.0 的偏离：真零 → 0 分、1 档。
      expect(depth.severityScore, 0);
      expect(depth.severityLevel, 1);
      // 脚跟离地没有任何偏离明细：未知 → 退回出现率 1/2 → 50 分、2 档。
      // 把未知填成零的实现会给出两份几乎一样的报告，而这份本该是
      // 「2 次里犯了 1 次」。
      expect(heel.severityScore, 50);
      expect(heel.severityLevel, 2);
    });

    test('半偶舍入：0.125 → 12，0.375 → 38', () {
      // 这两个值在二进制里是精确的，×100 后恰好落在 12.5 与 37.5 上 ——
      // 真并列。Python 的 round 进位到偶数，Dart 原生的 round 远离零（13）。
      final response = parse('severity_rounding');
      expect(
        response.faults.singleWhere((f) => f.code == 'INSUFFICIENT_DEPTH').severityScore,
        12,
      );
      expect(
        response.faults.singleWhere((f) => f.code == 'KNEE_VALGUS').severityScore,
        38,
      );
      // 可见性同时钉住 round(x, 4)：0.90625 → 0.9062，不是 0.9063。
      for (final fault in response.faults) {
        expect(fault.confidence, 0.9062, reason: fault.code);
      }
    });

    test('没有逐次明细时退回出现率，而不是当成零', () {
      // reps 为空但组级统计在 —— 端侧只上报聚合结果时就是这样。
      // 退回出现率是一处**可接受的近似**：它用的仍是真实上报的数据。
      final response = parse('no_reps_thin');
      expect(response.faults.single.evidence.reps, [1, 2]);
      expect(response.faults.single.severityScore, 100);
      expect(response.faults.single.severityLevel, 3);
    });
  });

  group('方案的筛选', () {
    test('器材过滤 + 覆盖数优先', () {
      // 用户手上有弹力带，候选 [膝内扣, 左右不对称]。覆盖 2 个码的
      // 弹力带侧向行走排第一，尽管它难度 2 —— 而这要求器材真的传下去了：
      // 不传的话它会被器材过滤直接排除，第一名就不是它。
      expect(parse('plans_equipment').choice!.selectedPlanIds.first,
          'COR_LATERAL_BAND_WALK');
    });

    test('年龄筛掉全部方案：choice 为 null，但错误照报', () {
      // 「有错误但没有建议」是一个真实存在的组合，报告不能因此留白或崩掉。
      final response = parse('plans_age_filter');
      expect(response.choice, isNull);
      expect(response.faults, isNotEmpty);
      expect(response.primaryFault, isNotNull);
      expect(response.message, isNotNull);
      expect(response.scores, isNotNull);
    });
  });

  group('与端侧本地阈值版本无关', () {
    test('响应里的 thresholds_version 原样带出来，不拿去比对本地表', () {
      // 服务端用的是它自己那份阈值表。端侧的本地表只用于逐次提示，
      // 两者版本不同是常态（本地表随包发布、服务端随时可换）。
      // 报告要做的只是**把服务端用的那一版照实标出来**。
      for (final name in scenarios.keys) {
        expect(parse(name).meta.thresholdsVersion, 'conformance-1', reason: name);
      }
    });
  });
}
