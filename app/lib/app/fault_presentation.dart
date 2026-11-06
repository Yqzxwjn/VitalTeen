///把判定结果翻译成界面上的一句话
library;

import '../domain/exercises/base.dart';
import '../domain/rules.dart';
import '../domain/thresholds.dart';

const Map<String, String> _featureLabels = {
  'knee_angle_L': '左膝角',
  'knee_angle_R': '右膝角',
  'hip_angle_L': '左髋角',
  'heel_rise_ratio_L': '左脚跟抬起幅度',
  'heel_rise_ratio_R': '右脚跟抬起幅度',
  'trunk_lean': '躯干前倾角',
  'knee_symmetry': '左右膝角差',
  'frontal_knee_angle_max': '额状面膝角',
  'pelvis_offset_ratio': '骨盆偏移',
};

const Map<String, String> _softenedTitles = {
  'KNEE_VALGUS': '膝内扣倾向',
};

String faultTitle(String code, String nameZh) =>
    _softenedTitles[code] ?? nameZh;

String featureLabel(String feature) => _featureLabels[feature] ?? feature;

String? measureLabel(Rule rule) =>
    rule.reduce == Reduce.reversals ? '掉头次数' : null;

String deviationLine({
  required String feature,
  required double measured,
  required double threshold,
  required String unit,
  String? measure,
}) =>
    '${measure ?? featureLabel(feature)} ${formatMeasurement(measured, unit)}'
    '（参考值 ${formatMeasurement(threshold, unit)}）';

String formatMeasurement(double value, String unit) {
  final text = value.abs() >= 100 || value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return unit == 'deg' ? '$text°' : text;
}

abstract interface class LocalFaultContext {
  String? faultName(String code);
  String? evidenceLine({
    required String code,
    required String feature,
    required double measured,
    required double threshold,
  });
}

class FaultView {
  const FaultView({
    required this.code,
    required this.title,
    required this.detail,
    required this.severityLabel,
    required this.scorable,
    required this.notice,
    this.severity01,
  });
  final String code;
  final String title;
  final String detail;
  final String severityLabel;
  final bool scorable;
  final String? notice;
  final double? severity01;
}

class RepFeedbackView {
  const RepFeedbackView({
    required this.repIndex,
    required this.headline,
    required this.faults,
    required this.clean,
  });
  final int repIndex;
  final String headline;
  final List<FaultView> faults;
  final bool clean;
}

class FaultPresenter implements LocalFaultContext {
  FaultPresenter({
    required ActionDefinition definition,
    required ThresholdTable thresholds,
  })  : _rules = {
          for (final rule in definition.rules)
            rule.code: _RuleFacts(
              rule: rule,
              threshold: thresholds.get(rule.thresholdKey),
            ),
        };
  final Map<String, _RuleFacts> _rules;
  @override
  String? faultName(String code) => _rules[code]?.rule.nameZh;

  @override
  String? evidenceLine({
    required String code,
    required String feature,
    required double measured,
    required double threshold,
  }) {
    final facts = _rules[code];
    if (facts == null) return null;
    return deviationLine(
      feature: feature,
      measure: measureLabel(facts.rule),
      measured: measured,
      threshold: threshold,
      unit: facts.threshold.unit,
    );
  }

  RepFeedbackView present(int repIndex, List<Fault> faults) {
    final ordered = List<Fault>.of(faults)
      ..sort((a, b) {
        final sa = a.deviation.severity01;
        final sb = b.deviation.severity01;
        if (sa != sb) {
          if (sa == null) return 1;
          if (sb == null) return -1;
          return sb.compareTo(sa);
        }
        if (a.confidence != b.confidence) {
          return b.confidence.compareTo(a.confidence);
        }
        return a.code.compareTo(b.code);
      });
    final views = ordered.map(_present).toList();
    return RepFeedbackView(
      repIndex: repIndex,
      headline: _headline(repIndex, views),
      faults: views,
      clean: views.isEmpty,
    );
  }

  FaultView _present(Fault fault) {
    final facts = _rules[fault.code];
    assert(
      facts != null,
      '故障码 ${fault.code} 不在动作定义的规则里。'
      '引擎与本界面用的不是同一份定义，判定和措辞会对不上。',
    );
    final unit = facts?.threshold.unit ?? '';
    return FaultView(
      code: fault.code,
      title: faultTitle(fault.code, fault.nameZh),
      detail: deviationLine(
        feature: fault.deviation.feature,
        measure: facts == null ? null : measureLabel(facts.rule),
        measured: fault.deviation.measured,
        threshold: fault.deviation.threshold,
        unit: unit,
      ),
      severityLabel: _severityLabel(fault, facts),
      scorable: fault.scorable,
      notice: fault.scorable ? null : '待核定 · 仅提示',
      severity01: fault.deviation.severity01,
    );
  }

  String _severityLabel(Fault fault, _RuleFacts? facts) {
    final breakpoints = facts?.threshold.severityBreakpoints ?? const [];
    if (facts != null && breakpoints.isNotEmpty) {
      final side = facts.rule.badSide;
      final value = facts.threshold.value;
      final crossing =
          breakpoints.where((b) => _isBeyond(b, value, side)).toList();
      if (crossing.isNotEmpty) {
        final measured = fault.deviation.measured;
        final crossed = crossing.where((b) => _isBeyond(measured, b, side)).length;
        final levels = ['需关注', '明显'];
        return levels[crossed.clamp(0, levels.length - 1)];
      }
    }
    final severity = fault.deviation.severity01;
    if (severity == null) return '已记录';
    if (severity < 0.34) return '轻微';
    if (severity < 0.67) return '中等';
    return '明显';
  }
  bool _isBeyond(double value, double line, Direction side) =>
      side == Direction.above ? value > line : value < line;

  String _headline(int repIndex, List<FaultView> views) {
    if (views.isEmpty) return '第 $repIndex 个 · 完成得不错';
    if (views.length == 1) {
      return '第 $repIndex 个 · ${views.first.title}（${views.first.severityLabel}）';
    }
    return '第 $repIndex 个 · ${views.length} 处需要留意';
  }
}

class _RuleFacts {
  const _RuleFacts({required this.rule, required this.threshold});
  final Rule rule;
  final Threshold threshold;
}
