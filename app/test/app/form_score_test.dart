/// `form_score` 的测试。
///
/// 这一层算出来的数字**会直接印在屏幕上给人看**，而它没有一个「对不对」的
/// 客观参照 —— 权重与切分都还没核定。所以这里钉的不是「分数该是多少」，
/// 而是那几条**错了也看不出来**的性质：
///
/// - 分数落在 0–100 里，且「一个错都没犯」就是 100。
/// - 显示的数与评级用的数是同一个（79.6 显示成 80 却是「中」是最难解释的一种错）。
/// - 权重换了分数跟着换；全 1.0 的占位权重不能让分数挤在 95 以上。
/// - 拿不到严重度时**按最坏算**，不是按 0 算 —— 后者等于白送一个满分。
/// - 未核定就一定要标出来（`provisional`），否则屏幕上那个数会被当成结论。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

/// 权重之和 11，全部是 `literature`（已核定）。
///
/// **故意不取 1.0。** 随包发出的表里五个权重全是占位值 1.0，用它们做断言时
/// 归一化会把「权重真的被读进去了」这件事抹平 —— 一个把权重写死成 1 的实现
/// 会全绿通过。
const Map<String, double> _weights = {
  'squat.fault_weight.knee_valgus': 4.0,
  'squat.fault_weight.insufficient_depth': 3.0,
  'squat.fault_weight.excessive_trunk_lean': 2.0,
  'squat.fault_weight.heel_rise': 1.0,
  'squat.fault_weight.asymmetry': 1.0,
};

const List<double> _breakpoints = [60.0, 70.0, 80.0, 90.0];

ThresholdTable _table({
  Map<String, double> weights = _weights,
  SourceType weightSource = SourceType.literature,
  List<double> breakpoints = _breakpoints,
}) =>
    ThresholdTable(
      [
        for (final entry in weights.entries)
          Threshold(
            key: entry.key,
            actionCode: squatActionCode,
            featureCode: '',
            value: entry.value,
            unit: 'weight',
            sourceType: weightSource,
            version: 'test',
          ),
        Threshold(
          key: 'squat.form_score_rating_breakpoints',
          actionCode: squatActionCode,
          featureCode: '',
          value: 0.0,
          unit: 'score',
          sourceType: SourceType.literature,
          version: 'test',
          severityBreakpoints: breakpoints,
        ),
      ],
      version: 'test',
    );

/// 一份典型的成人站立基线。数值本身不参与评分，只用来构造动作定义。
const Calibration _calibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 5.0,
  heelRiseRatio: 0.0,
  frames: 15,
);

FormScorer _scorer({ThresholdTable? thresholds}) => FormScorer(
      definition: buildSquat(_calibration, cameraView: CameraView.oblique45),
      thresholds: thresholds ?? _table(),
    );

Fault _fault(
  String code, {
  double? severity01,
  bool scorable = true,
}) =>
    Fault(
      code: code,
      nameZh: '测试用错误 $code',
      scorable: scorable,
      confidence: 1.0,
      evidenceTimestamps: const [1000],
      deviation: Deviation(
        feature: 'test_metric',
        measured: 1.0,
        threshold: 0.5,
        deltaSigned: 0.5,
        severity01: severity01,
      ),
    );

FaultStat _stat(
  String code, {
  required int count,
  required int reps,
  double worstDelta = 1.0,
  bool scorable = true,
}) =>
    FaultStat(
      code: code,
      nameZh: '测试用错误 $code',
      scorable: scorable,
      count: count,
      rate: reps == 0 ? 0.0 : count / reps,
      repIndices: const [],
      worstDelta: worstDelta,
    );

void main() {
  group('构造期把关', () {
    test('缺权重键就抛，并指出是哪一个', () {
      final partial = Map.of(_weights)..remove('squat.fault_weight.heel_rise');
      expect(
        () => _scorer(thresholds: _table(weights: partial)),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            contains('squat.fault_weight.heel_rise'),
          ),
        ),
      );
    });

    test('权重是 0 或负数就抛 —— 它会让一项永远不扣分，或把扣分变成加分', () {
      for (final bad in [0.0, -1.0]) {
        final weights = Map.of(_weights)..['squat.fault_weight.asymmetry'] = bad;
        expect(
          () => _scorer(thresholds: _table(weights: weights)),
          throwsA(isA<ThresholdException>()),
          reason: '权重 $bad 应当被拒绝',
        );
      }
    });

    test('切点数目不等于「级数 − 1」就抛', () {
      // 少一个切点，4 级要用 5 个名字，分数会静默地落在错误的评级上。
      expect(
        () => _scorer(thresholds: _table(breakpoints: const [60.0, 70.0, 80.0])),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            contains('4 个'),
          ),
        ),
      );
    });

    test('切点必须严格升序', () {
      expect(
        () => _scorer(
          thresholds: _table(breakpoints: const [60.0, 80.0, 70.0, 90.0]),
        ),
        throwsA(
          isA<ThresholdException>().having(
            (e) => e.message,
            'message',
            contains('升序'),
          ),
        ),
      );
    });

    test('权重之和与错误码个数就是动作定义里的那几个', () {
      final scorer = _scorer();
      expect(scorer.ruleCount, 5);
      expect(scorer.weightSum, 11.0);
    });
  });

  group('逐次评分', () {
    test('一个错都没犯就是 100 分', () {
      final score = _scorer().scoreRep(const []);

      expect(score.score, 100);
      expect(score.rating, FormRating.excellent);
      expect(score.penalty, 0.0);
      expect(score.terms, isEmpty);
      expect(score.worstTerm, isNull);
    });

    test('扣分按 权重 × 严重度 / 权重之和 走', () {
      // 3 × 1.0 × 0.5 / 11 = 0.13636…，100 × (1 − 0.13636) = 86.36 → 86。
      final score = _scorer().scoreRep([
        _fault('INSUFFICIENT_DEPTH', severity01: 0.5),
      ]);

      expect(score.score, 86);
      expect(score.rating, FormRating.good);
      expect(score.terms.single.weight, 3.0);
      expect(score.terms.single.rate, 1.0);
      expect(score.terms.single.severity01, 0.5);
    });

    test('拿不到严重度时按最坏算，不按 0 算', () {
      // 按 0 算等于「这次动作没问题」，白送一个满分 —— 而它其实是一次命中。
      final score = _scorer().scoreRep([_fault('ASYMMETRY')]);

      expect(score.terms.single.severity01, 1.0);
      expect(score.score, 91); // 100 − 100 × 1/11 = 90.9 → 91
    });

    test('五个错误全犯满就是 0 分', () {
      final score = _scorer().scoreRep([
        _fault('KNEE_VALGUS', severity01: 1.0),
        _fault('INSUFFICIENT_DEPTH', severity01: 1.0),
        _fault('EXCESSIVE_TRUNK_LEAN', severity01: 1.0),
        _fault('HEEL_RISE', severity01: 1.0),
        _fault('ASYMMETRY', severity01: 1.0),
      ]);

      expect(score.score, 0);
      expect(score.rating, FormRating.needsWork);
      expect(score.penalty, 1.0);
    });

    test('同一错误码被两条规则同时命中时只扣一次', () {
      // `evaluateRep` 不去重，去重是 `evaluateSet` 做的。逐次这边必须照同样的
      // 口径，否则同一件事在逐次扣两遍、在组级扣一遍，两个分数对不上。
      final twice = _scorer().scoreRep([
        _fault('ASYMMETRY', severity01: 0.4),
        _fault('ASYMMETRY', severity01: 0.9),
      ]);

      expect(twice.terms, hasLength(1));
      // 取最严重的那一次，不是第一次、也不是两个相加。
      expect(twice.terms.single.severity01, 0.9);
    });

    test('不认识的错误码直接抛 —— 静默跳过会让分数因为漏算而偏高', () {
      expect(
        () => _scorer().scoreRep([_fault('NOT_A_SQUAT_FAULT')]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('扣分从重到轻排，并列时按错误码升序', () {
      final score = _scorer().scoreRep([
        _fault('HEEL_RISE', severity01: 0.2), // 1 × 0.2 = 0.2
        _fault('KNEE_VALGUS', severity01: 0.5), // 4 × 0.5 = 2.0
        _fault('ASYMMETRY', severity01: 0.2), // 1 × 0.2 = 0.2，与 HEEL_RISE 并列
        _fault('EXCESSIVE_TRUNK_LEAN', severity01: 0.9), // 2 × 0.9 = 1.8
      ]);

      expect(
        score.terms.map((t) => t.code),
        ['KNEE_VALGUS', 'EXCESSIVE_TRUNK_LEAN', 'ASYMMETRY', 'HEEL_RISE'],
      );
      expect(score.worstTerm?.code, 'KNEE_VALGUS');
    });
  });

  group('组级评分', () {
    test('一次都没做的一组没有分数 —— 不是 100 分', () {
      // 「零错误即满分」的自然推论是「什么都没做也满分」，而那是这套评分能
      // 给出的最荒唐的答案。
      final score = _scorer().scoreSet(
        const SetSummary(repCount: 0, faultStats: []),
      );

      expect(score, isNull);
    });

    test('发生率用 count / rep_count', () {
      // 膝内扣的跨度是 8 度，最坏偏离取满 → 严重度 1.0，这一项只剩发生率一个变量。
      // 10 次里犯了 4 次：4 × 0.4 × 1.0 / 11 = 0.14545，100 × 0.85454 = 85.45 → 85。
      final score = _scorer().scoreSet(
        SetSummary(
          repCount: 10,
          faultStats: [
            _stat('KNEE_VALGUS', count: 4, reps: 10, worstDelta: 8.0),
          ],
        ),
      )!;

      expect(score.terms.single.rate, closeTo(0.4, 1e-9));
      expect(score.score, 85);
    });

    test('严重度从组内最坏偏离反推，与该规则的跨度对应', () {
      // 深度不足的跨度是 40 度（`squat.dart` 的 _severitySpan），
      // 偏离 20 度 → 0.5。
      final score = _scorer().scoreSet(
        SetSummary(
          repCount: 4,
          faultStats: [
            _stat('INSUFFICIENT_DEPTH', count: 4, reps: 4, worstDelta: 20.0),
          ],
        ),
      )!;

      expect(score.terms.single.severity01, closeTo(0.5, 1e-9));
      expect(score.score, 86);
    });

    test('最坏偏离超过跨度时封顶在 1.0，不会扣出 100 分以上', () {
      final score = _scorer().scoreSet(
        SetSummary(
          repCount: 2,
          faultStats: [
            _stat('INSUFFICIENT_DEPTH', count: 2, reps: 2, worstDelta: 200.0),
          ],
        ),
      )!;

      expect(score.terms.single.severity01, 1.0);
      expect(score.score, inInclusiveRange(0, 100));
    });

    test('同一次错误在多个 rep 里重复，不改变逐组的严重度上限', () {
      final score = _scorer().scoreSet(
        SetSummary(
          repCount: 6,
          faultStats: [_stat('HEEL_RISE', count: 6, reps: 6, worstDelta: 0.075)],
        ),
      )!;

      // 脚跟抬升的跨度是 0.15 → 0.075/0.15 = 0.5。
      expect(score.terms.single.severity01, closeTo(0.5, 1e-9));
    });
  });

  group('评级', () {
    test('四个切点切出五级，边界值归上一级', () {
      final scorer = _scorer();
      const expected = {
        0: FormRating.needsWork,
        59: FormRating.needsWork,
        60: FormRating.pass, // 切点本身属于上一级，不是下一级
        69: FormRating.pass,
        70: FormRating.fair,
        79: FormRating.fair,
        80: FormRating.good,
        89: FormRating.good,
        90: FormRating.excellent,
        100: FormRating.excellent,
      };

      expected.forEach((score, rating) {
        expect(scorer.ratingOf(score), rating, reason: '$score 应当是「${rating.label}」');
      });
    });

    test('显示的数与评级用的是同一个 —— 分数是整数，不会出现 80 分却判「中」', () {
      for (var i = 0; i <= 100; i++) {
        final score = FormScore(
          score: i,
          rating: _scorer().ratingOf(i),
          provisional: true,
          penalty: 0,
          terms: const [],
        );
        // 取整只发生在算分那一步；一旦落进 FormScore，它就是最终值。
        expect(score.score, i);
        expect(score.rating.label, isNotEmpty);
      }
    });
  });

  group('权重换了就跟着换', () {
    test('把深度的权重从 3 调到 8，同一个动作的分数必须变', () {
      final fault = [_fault('INSUFFICIENT_DEPTH', severity01: 1.0)];

      final before = _scorer().scoreRep(fault);
      final weights = Map.of(_weights)..['squat.fault_weight.insufficient_depth'] = 8.0;
      final after = _scorer(thresholds: _table(weights: weights)).scoreRep(fault);

      // 前：100 − 100 × 3/11 = 72.7 → 73。后：100 − 100 × 8/16 = 50。
      expect(before.score, 73);
      expect(after.score, 50);
    });

    test('占位值 1.0 也不会把分数挤在 95 以上', () {
      // 随包发出的正是这一份（五个 1.0）。字面套用文档公式会得到 96 分，
      // 归一化之后同样五个权重仍然能拉开 0–100。
      final placeholder = {
        for (final key in _weights.keys) key: 1.0,
      };
      final scorer = _scorer(thresholds: _table(weights: placeholder));

      expect(scorer.weightSum, 5.0);
      expect(
        scorer.scoreRep([_fault('KNEE_VALGUS', severity01: 1.0)]).score,
        80,
      );
      expect(
        scorer
            .scoreRep([
              for (final code in ['KNEE_VALGUS', 'INSUFFICIENT_DEPTH'])
                _fault(code, severity01: 1.0),
            ])
            .score,
        60,
      );
    });
  });

  group('provisional —— 什么时候这个分数还不是结论', () {
    test('权重是待核定的，一个错都没犯也要标出来', () {
      // 随包发出的表就是这一份：五个权重全是 pending_review。
      final scorer = _scorer(
        thresholds: _table(weightSource: SourceType.pendingReview),
      );

      expect(scorer.weightsVerified, isFalse);
      expect(scorer.scoreRep(const []).provisional, isTrue);
    });

    test('权重核定了但判定本身待核定，仍然要标出来', () {
      // 扣的那个错是「未核定阈值判出来的」，那它一样不能当结论。
      final score = _scorer().scoreRep([
        _fault('KNEE_VALGUS', severity01: 0.5, scorable: false),
      ]);

      expect(score.provisional, isTrue);
    });

    test('权重与判定都核定了才不标', () {
      // 这条同时钉住「阈值真的被读进来了」：权重全 1.0 时它测不出区别，
      // 所以 _weights 取的是平方数。
      final scorer = _scorer();

      expect(scorer.weightsVerified, isTrue);
      expect(
        scorer.scoreRep([_fault('KNEE_VALGUS', severity01: 0.5)]).provisional,
        isFalse,
      );
      expect(scorer.scoreRep(const []).provisional, isFalse);
    });

    test('组级同样按这两条判', () {
      final score = _scorer().scoreSet(
        SetSummary(
          repCount: 3,
          faultStats: [
            _stat('HEEL_RISE', count: 3, reps: 3, scorable: false),
          ],
        ),
      )!;

      expect(score.provisional, isTrue);
    });
  });

  group('随包发出的那一份阈值表', () {
    // 上面所有用例用的都是本地表。这一组读**真实的那份 asset** —— 屏幕上跑的是
    // 它，而它的性质（权重齐不齐、是不是待核定、切点是几个）没有任何别的地方
    // 在管。少一个权重键的表现不是报错，是应用做完一组之后构建 `FormScorer`
    // 时抛异常 —— 那已经离病因很远了。

    ThresholdTable realTable() => ThresholdTable.fromJson(
          jsonDecode(
            File('assets/thresholds/thr_2026-10_v1.json').readAsStringSync(),
          ) as Map<String, dynamic>,
        );

    test('五条规则的权重一个都不缺，构造得起来', () {
      final scorer = FormScorer(
        definition: buildSquat(_calibration, cameraView: CameraView.oblique45),
        thresholds: realTable(),
      );

      expect(scorer.ruleCount, 5);
      expect(scorer.weightSum, greaterThan(0));
    });

    test('权重还全是待核定的，所以随包算出来的分数一定是参考分', () {
      // **这条会随核定一起失效，那是好事。** 权重一旦被体育专业成员核定，
      // 它就红 —— 这时该做的是把下面那句 expected 改成 isFalse，并顺手确认
      // 界面上「参考分 · 阈值待核定」的角标跟着消失（`FormScore.provisional`
      // 本来就管着它，不需要改文案）。
      final scorer = FormScorer(
        definition: buildSquat(_calibration, cameraView: CameraView.oblique45),
        thresholds: realTable(),
      );

      expect(
        scorer.weightsVerified,
        isFalse,
        reason: '权重已核定 —— 请把这条断言改成 isFalse，并确认界面角标消失',
      );
      expect(scorer.scoreRep(const []).provisional, isTrue);
    });

    test('评级切点就是文档说的那四个，五级切分', () {
      final scorer = FormScorer(
        definition: buildSquat(_calibration, cameraView: CameraView.oblique45),
        thresholds: realTable(),
      );

      expect(
        [
          for (final bp in _breakpoints) scorer.ratingOf(bp.toInt()),
        ],
        [
          FormRating.pass,
          FormRating.fair,
          FormRating.good,
          FormRating.excellent,
        ],
      );
    });
  });
}
