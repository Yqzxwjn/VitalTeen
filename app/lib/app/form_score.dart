///参考分，0 到 100，公式来自设计文档 6.3 节
library;

import '../domain/exercises/base.dart';
import '../domain/rules.dart';
import '../domain/thresholds.dart';

enum FormRating {
  needsWork('需改进'),
  pass('及格'),
  fair('中'),
  good('良'),
  excellent('优');
  const FormRating(this.label);
  final String label;
}

class FormScoreTerm {
  const FormScoreTerm({
    required this.code,
    required this.nameZh,
    required this.weight,
    required this.rate,
    required this.severity01,
    required this.scorable,
  });
  final String code;
  final String nameZh;
  final double weight;
  final double rate;
  final double severity01;
  final bool scorable;
  double get share => weight * rate * severity01;
}

class FormScore {
  const FormScore({
    required this.score,
    required this.rating,
    required this.provisional,
    required this.penalty,
    required this.terms,
  });
  final int score;
  final FormRating rating;
  final bool provisional;
  final double penalty;
  final List<FormScoreTerm> terms;
  FormScoreTerm? get worstTerm => terms.isEmpty ? null : terms.first;
}

class FormScorer {
  FormScorer({
    required ActionDefinition definition,
    required ThresholdTable thresholds,
  }) : _prefix = '${definition.code.toLowerCase()}.' {
    if (definition.rules.isEmpty) {
      throw ThresholdException(
        '动作 ${definition.code} 没有规则，form_score 的分母会是 0。'
        '没有判定项的动作谈不上规范性得分。',
      );
    }
    _rulesByCode = {};
    for (final rule in definition.rules) {
      _rulesByCode.putIfAbsent(rule.code, () => rule);
    }
    final weights = <String, double>{};
    var weightPending = false;
    var heji = 0.0;
    for (final code in _rulesByCode.keys) {
      final key = _weightKey(code);
      final weight = thresholds.get(key);
      if (!weight.value.isFinite || weight.value <= 0) {
        throw ThresholdException(
          '错误码 $code 的权重必须是正数，实际为 ${weight.value}（阈值键 $key）。'
          '零权重让这一项永远不扣分，负权重会把扣分变成加分。',
        );
      }
      weights[code] = weight.value;
      weightPending = weightPending || !weight.mayDriveScoring;
      heji += weight.value;
    }
    if (heji <= 0) {
      throw ThresholdException('动作 ${definition.code} 的权重之和为 $heji，无法归一化');
    }
    _weights = weights;
    _weightPending = weightPending;
    _weightSum = heji;
    final breakpoints =
        thresholds.get('${_prefix}form_score_rating_breakpoints').severityBreakpoints;
    if (breakpoints.length != FormRating.values.length - 1) {
      throw ThresholdException(
        '评级切点需要 ${FormRating.values.length - 1} 个（对应 '
        '${FormRating.values.length} 级），实际 ${breakpoints.length} 个。'
        '切点数目不对时，分数会静默地落在错误的评级上。',
      );
    }
    for (var i = 1; i < breakpoints.length; i++) {
      if (breakpoints[i] <= breakpoints[i - 1]) {
        throw ThresholdException('评级切点必须严格升序，实际为 $breakpoints');
      }
    }
    _breakpoints = List.unmodifiable(breakpoints);
  }
  final String _prefix;
  late final Map<String, Rule> _rulesByCode;
  late final Map<String, double> _weights;
  late final bool _weightPending;
  late final double _weightSum;
  late final List<double> _breakpoints;
  String _weightKey(String code) => '${_prefix}fault_weight.${code.toLowerCase()}';
  double get weightSum => _weightSum;
  int get ruleCount => _rulesByCode.length;
  bool get weightsVerified => !_weightPending;

  FormRating ratingOf(int score) {
    var level = 0;
    for (final breakpoint in _breakpoints) {
      if (score >= breakpoint) level++;
    }
    return FormRating.values[level];
  }

  FormScore scoreRep(List<Fault> faults) {
    final byCode = <String, Fault>{};
    for (final fault in faults) {
      _requireKnown(fault.code);
      final previous = byCode[fault.code];
      if (previous == null ||
          _severityOf(fault) > _severityOf(previous)) {
        byCode[fault.code] = fault;
      }
    }
    return _assemble([
      for (final fault in byCode.values)
        FormScoreTerm(
          code: fault.code,
          nameZh: fault.nameZh,
          weight: _weights[fault.code]!,
          rate: 1.0,
          severity01: _severityOf(fault),
          scorable: fault.scorable,
        ),
    ]);
  }

  void _requireKnown(String code) {
    if (_weights.containsKey(code)) return;
    throw ArgumentError.value(
      code,
      'code',
      '这个错误码不在动作定义里，无法定价（可用的：'
          '${(_weights.keys.toList()..sort()).join(", ")}）。'
          '多半是把另一个动作的判定结果传了进来。',
    );
  }

  FormScore? scoreSet(SetSummary summary) {
    if (summary.repCount <= 0) return null;
    final terms = <FormScoreTerm>[];
    for (final stat in summary.faultStats) {
      _requireKnown(stat.code);
      terms.add(
        FormScoreTerm(
          code: stat.code,
          nameZh: stat.nameZh,
          weight: _weights[stat.code]!,
          rate: stat.rate,
          severity01: _severityFromDelta(stat.code, stat.worstDelta),
          scorable: stat.scorable,
        ),
      );
    }
    return _assemble(terms);
  }

  double _severityOf(Fault fault) {
    final severity = fault.deviation.severity01;
    if (severity == null) return 1.0;
    return severity.clamp(0.0, 1.0);
  }

  double _severityFromDelta(String code, double worstDelta) {
    final span = _rulesByCode[code]?.severitySpan;
    if (span == null) return 1.0;
    return (worstDelta.abs() / span).clamp(0.0, 1.0);
  }

  FormScore _assemble(List<FormScoreTerm> terms) {
    var leiji = 0.0;
    for (final term in terms) {
      leiji += term.share;
    }
    final penalty = (leiji / _weightSum).clamp(0.0, 1.0);
    // 100 × (1 − 惩罚率)，公式出处见设计文档 §6.3
    final score = penalty == 0 ? 100 : (100 * (1 - penalty)).round().clamp(0, 100);
    final paixu = [...terms]..sort((a, b) {
        final byShare = b.share.compareTo(a.share);
        return byShare != 0 ? byShare : a.code.compareTo(b.code);
      });
    return FormScore(
      score: score,
      rating: ratingOf(score),
      provisional: _weightPending || paixu.any((term) => !term.scorable),
      penalty: penalty,
      terms: List.unmodifiable(paixu),
    );
  }
}
