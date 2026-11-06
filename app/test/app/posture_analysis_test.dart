/// 姿态倾向分析的测试。**全是纯函数，所以每一处判断都能穷尽。**
///
/// 这一层最要紧的三件事，各有一组：
///
/// 1. **分母是谁。** 旧记录（`faultCounts == null`）不进分母、别的动作不进分母 ——
///    两处错都会让出现率被系统性压低，而页面看上去一切正常。
/// 2. **什么时候不说话。** 样本不够、一组都没命中，都不产出结论。
///    这一页的价值全在「宁可不说，不可瞎说」上。
/// 3. **定义表与规则集对不对得上。** 手写的表必然漂移，所以反过来用
///    `kActionSpecs` 的真实规则集查它。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/posture_analysis.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';

/// 一份形状正常的基线 —— 这里测的是汇总，基线取什么都不影响规则码的集合。
///
/// **六个量都要给**：开合跳要 `legSpread`、跳绳要 `footHeight`，缺了它们
/// `build(...)` 会当场抛（那是有意的，见 `jj.dart` 里「缺席即抛，不取 0」）。
/// 这一组断的是规则**码的集合**，与数值无关，所以给一个正常范围里的数就行。
const Calibration _calibration = Calibration(
  kneeAngle: 178.0,
  trunkLean: 3.0,
  heelRiseRatio: 0.02,
  frames: 45,
  legSpread: 0.30,
  footHeight: 0.06,
);

/// 「现在」。窗口边界那几条都围着它算。
final DateTime _now = DateTime(2026, 10, 5, 14, 30);

/// 一条记录。[daysAgo] 是相对 [_now] 的日历天数。
SessionRecord _record({
  String actionCode = 'SQUAT',
  int daysAgo = 1,
  int repCount = 12,
  Map<String, int>? faultCounts = const {},
}) {
  final day = DateTime(_now.year, _now.month, _now.day - daysAgo, 10);
  return SessionRecord(
    actionCode: actionCode,
    actionNameZh: actionCode == 'SQUAT' ? '深蹲' : '平板支撑',
    finishedAt: day,
    repCount: repCount,
    isTimed: false,
    score: 80,
    provisional: false,
    faultCounts: faultCounts,
  );
}

/// 造 n 条深蹲，其中前 [withFault] 条命中 [code]。
List<SessionRecord> _sets(
  int n, {
  int withFault = 0,
  String code = 'EXCESSIVE_TRUNK_LEAN',
  int daysAgo = 1,
}) =>
    [
      for (var i = 0; i < n; i++)
        _record(
          daysAgo: daysAgo,
          faultCounts: i < withFault ? {code: 3} : const {},
        ),
    ];

PostureFinding? _findingOf(PostureAnalysis analysis, String id) {
  for (final finding in analysis.findings) {
    if (finding.definition.id == id) return finding;
  }
  return null;
}

void main() {
  group('一条记录都没有 / 一条都不够资格', () {
    test('空表：什么都没采到，也不够说话', () {
      final analysis = analyzePostures(const [], _now);

      expect(analysis.findings, isEmpty);
      expect(analysis.eligibleSets, 0);
      expect(analysis.hasAnyRecordedData, isFalse);
      expect(analysis.hasEnoughData, isFalse);
      expect(analysis.setsNeeded, postureMinEligibleSets);
    });

    test('全是 v1 的老记录（faultCounts 为 null）：等于没采到', () {
      // **这一条是「不知道不是干净」的守卫。** 老记录没有故障计数，
      // 把它们算进分母，等于宣布「这些组都没问题」—— 而我们根本不知道。
      final analysis = analyzePostures(
        [for (var i = 1; i <= 8; i++) _record(daysAgo: i, faultCounts: null)],
        _now,
      );

      expect(analysis.eligibleSets, 0, reason: '老记录不该进分母');
      expect(analysis.hasAnyRecordedData, isFalse);
    });

    test('动作不对：平板支撑练了一堆也不进深蹲的分母', () {
      // 平板支撑产不出 `EXCESSIVE_TRUNK_LEAN`。把它算进分母，深蹲的
      // 出现率会被凭空摊薄 —— 而用户看到的只是「好像没那么严重」。
      final analysis = analyzePostures(
        [for (var i = 0; i < 10; i++) _record(actionCode: 'PLANK')],
        _now,
      );

      expect(analysis.eligibleSets, 0);
    });
  });

  group('时间窗', () {
    test('第 30 天还算，第 31 天不算', () {
      // 边界写成 `>=` 还是 `>` 只差一组，但它决定「刚好一个月前那次算不算」。
      final onTheLine = analyzePostures(
        _sets(postureMinEligibleSets, withFault: 6, daysAgo: postureWindowDays),
        _now,
      );
      final justOutside = analyzePostures(
        _sets(postureMinEligibleSets, withFault: 6, daysAgo: postureWindowDays + 1),
        _now,
      );

      expect(onTheLine.eligibleSets, postureMinEligibleSets,
          reason: '正好第 30 天的那一组该算进来');
      expect(justOutside.eligibleSets, 0, reason: '第 31 天的不该算');
    });
  });

  group('什么时候不说话', () {
    test('样本不够：一条结论都不给', () {
      final analysis = analyzePostures(
        _sets(postureMinEligibleSets - 1, withFault: postureMinEligibleSets - 1),
        _now,
      );

      expect(analysis.findings, isEmpty);
      expect(analysis.hasEnoughData, isFalse);
      expect(analysis.setsNeeded, 1);
      // 采到的组数照报 —— 界面要用它说「再练一组」。
      expect(analysis.eligibleSets, postureMinEligibleSets - 1);
      expect(analysis.hasAnyRecordedData, isTrue);
    });

    test('够多了，但一组都没命中：也不给结论', () {
      // 「没有倾向」是一句不同的话，由页面在 findings 为空时单独说。
      // 塞一条 0% 的卡片进列表，会被读成「这条也查过、你有」。
      final analysis = analyzePostures(_sets(10, withFault: 0), _now);

      expect(analysis.hasEnoughData, isTrue);
      expect(analysis.findings, isEmpty);
    });

    test('刚好够门槛就说话', () {
      final analysis = analyzePostures(
        _sets(postureMinEligibleSets, withFault: 3),
        _now,
      );

      expect(analysis.hasEnoughData, isTrue);
      expect(_findingOf(analysis, 'trunk_lean'), isNotNull);
    });
  });

  group('出现率与分档', () {
    test('分子分母各自读得对', () {
      final analysis = analyzePostures(_sets(10, withFault: 4), _now);
      final finding = _findingOf(analysis, 'trunk_lean')!;

      expect(finding.setsWithFault, 4);
      expect(finding.eligibleSets, 10);
      expect(finding.rate, 0.4);
    });

    test('分档的三个切点', () {
      // 0.3 与 0.6 是**包含**的（`>=`）。写成 `>` 会让正好 30% 的那一组
      // 掉到「偶有」，而它明明是反复。
      for (final (withFault, expected) in const [
        (2, PostureBand.occasional), // 0.2
        (3, PostureBand.recurring), // 0.3 —— 边界
        (5, PostureBand.recurring), // 0.5
        (6, PostureBand.persistent), // 0.6 —— 边界
        (9, PostureBand.persistent), // 0.9
      ]) {
        final analysis = analyzePostures(_sets(10, withFault: withFault), _now);
        final finding = _findingOf(analysis, 'trunk_lean')!;
        expect(finding.band, expected, reason: '$withFault / 10');
      }
    });

    test('分档的中文名集中在一处', () {
      expect(bandLabelZh(PostureBand.occasional), '偶有');
      expect(bandLabelZh(PostureBand.recurring), '反复');
      expect(bandLabelZh(PostureBand.persistent), '持续');
    });
  });

  group('两条倾向各算各的', () {
    test('两条都命中：都在，按出现率排', () {
      final records = [
        for (var i = 0; i < 10; i++)
          _record(faultCounts: {
            if (i < 8) 'EXCESSIVE_TRUNK_LEAN': 3,
            if (i < 4) 'ASYMMETRY': 2,
          }),
      ];
      final analysis = analyzePostures(records, _now);

      expect(analysis.findings.map((f) => f.definition.id).toList(),
          ['trunk_lean', 'asymmetry']);
      expect(analysis.eligibleSets, 10);
    });

    test('一条动作产出的码不影响另一条的分子', () {
      // 十条里前三条有躯干前倾，全都带左右不对称 —— 两条的分子必须各自独立。
      final records = [
        for (var i = 0; i < 10; i++)
          _record(faultCounts: {
            if (i < 3) 'EXCESSIVE_TRUNK_LEAN': 3,
            'ASYMMETRY': 2,
          }),
      ];
      final analysis = analyzePostures(records, _now);

      expect(_findingOf(analysis, 'trunk_lean')!.setsWithFault, 3);
      expect(_findingOf(analysis, 'asymmetry')!.setsWithFault, 10);
    });

    test('并列时按 id 排 —— 同一份数据两次打开位置一样', () {
      final records = [
        for (var i = 0; i < 10; i++)
          _record(faultCounts: {
            if (i < 5) 'EXCESSIVE_TRUNK_LEAN': 3,
            if (i < 5) 'ASYMMETRY': 3,
          }),
      ];
      final analysis = analyzePostures(records, _now);

      expect(analysis.findings.map((f) => f.definition.id).toList(),
          ['asymmetry', 'trunk_lean'], // 同为 0.5，`asymmetry` < `trunk_lean`
          reason: '并列时不按 id 就是不确定的顺序');
    });
  });

  group('定义表与真实规则集对得上', () {
    /// 全部动作的真实规则集：故障码 → 产出它的动作码。
    Map<String, Set<String>> produced() {
      final map = <String, Set<String>>{};
      for (final spec in kActionSpecs) {
        for (final rule in spec.build(_calibration).rules) {
          (map[rule.code] ??= <String>{}).add(spec.code);
        }
      }
      return map;
    }

    test('每条倾向依据的故障码，都真的有动作产出它', () {
      // 手写的表必然漂移。谁删了规则、改了码名而没回来改
      // `kPostureDefinitions`，这一条会红 —— 否则那一页会拿一个
      // 永远算不出来的码做分析，结论永远是空的，而且不报错。
      final exist = produced();
      for (final definition in kPostureDefinitions) {
        expect(exist[definition.faultCode], isNotNull,
            reason: '${definition.id} 依据的 ${definition.faultCode} 没有任何规则产出');
      }
    });

    test('合格动作表与规则集逐字一致 —— 多一个少一个都红', () {
      // 这张表决定分母。写多了会把产不出该码的动作算进分母（摊薄出现率），
      // 写少了会把该算的漏掉。两个方向都由这一条守住。
      final exist = produced();
      for (final entry in kPostureEligibleActions.entries) {
        expect(entry.value, exist[entry.key] ?? const <String>{},
            reason: '${entry.key} 的合格动作表与规则集不一致');
      }
    });

    test('表里每一个码都被某条倾向用上了 —— 没有写了不用的行', () {
      final used = {for (final d in kPostureDefinitions) d.faultCode};
      expect(kPostureEligibleActions.keys.toSet(), used);
    });
  });
}
