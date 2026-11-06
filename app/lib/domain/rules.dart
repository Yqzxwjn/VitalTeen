library;

import 'features.dart';
import 'stats.dart';
import 'thresholds.dart';

enum Phase {
  all,
  stand,
  descent,
  bottom,
  ascent,
  prep,
  takeoff,
  flight,
  landing,
  contact,
  apex,
}

enum Direction {
  above,
  below,
}

enum Reduce {
  anyFrame,
  min,
  max,
  median,
  reversals,
}

const double reversalDeadband = 2.0;

int countReversals(List<double> values, {double deadband = reversalDeadband}) {
  var reversals = 0;
  var lastSign = 0;
  for (var i = 1; i < values.length; i++) {
    final delta = values[i] - values[i - 1];
    if (delta.abs() <= deadband) continue;
    final sign = delta > 0 ? 1 : -1;
    if (lastSign != 0 && sign != lastSign) reversals++;
    lastSign = sign;
  }
  return reversals;
}

class RuleException implements Exception {
  const RuleException(this.message);
  final String message;
  @override
  String toString() => 'RuleException: $message';
}

double _round4(double value) => (value * 10000).round() / 10000;

typedef PhaseBounds = ({int start, int end});

class Deviation {
  const Deviation({
    required this.feature,
    required this.measured,
    required this.threshold,
    required this.deltaSigned,
    required this.severity01,
  });
  final String feature;
  final double measured;
  final double threshold;
  final double deltaSigned;
  final double? severity01;
}

class Fault {
  const Fault({
    required this.code,
    required this.nameZh,
    required this.scorable,
    required this.confidence,
    required this.evidenceTimestamps,
    required this.deviation,
  });
  final String code;
  final String nameZh;
  final bool scorable;
  final double confidence;
  final List<int> evidenceTimestamps;
  final Deviation deviation;
}

class Rule {
  Rule({
    required this.code,
    required this.nameZh,
    required this.metric,
    required this.thresholdKey,
    required this.badSide,
    this.phase = Phase.all,
    this.useAbs = false,
    this.reduce = Reduce.anyFrame,
    this.minViolatingFrames = 3,
    this.severitySpan,
  }) {
    if (minViolatingFrames < 1) {
      throw RuleException(
        '规则 $code 的 minViolatingFrames 必须 >= 1，实际为 $minViolatingFrames。'
        '取 0 会让「零越界帧」也越过帧数门槛，随后在对空序列取极值时无从判定。',
      );
    }
    if (severitySpan != null && severitySpan! <= 0) {
      throw RuleException(
        '规则 $code 的 severitySpan 必须为正数或 null，实际为 $severitySpan。'
        '非正值会让 severity01 落到 0–1 之外：负 span 产出负严重度，'
        '0 则被当成「不归一」而静默失效。',
      );
    }
  }
  final String code;
  final String nameZh;
  final String metric;
  final String thresholdKey;
  final Direction badSide;
  final Phase phase;
  final bool useAbs;
  final Reduce reduce;
  final int minViolatingFrames;
  final double? severitySpan;
}

class RepWindow {
  const RepWindow({
    required this.index,
    required this.frames,
    this.phaseBounds = const {},
  });
  final int index;
  final List<FrameFeatures> frames;
  final Map<Phase, PhaseBounds> phaseBounds;

  int get durationMs {
    if (frames.length < 2) return 0;
    final span = frames.last.timestampMs - frames.first.timestampMs;
    return span < 0 ? 0 : span;
  }

  List<FrameFeatures> select(Phase phase) {
    if (phase == Phase.all) return frames;
    final bounds = phaseBounds[phase];
    if (bounds == null) return frames;
    final start = bounds.start < 0 ? 0 : bounds.start;
    var end = bounds.end + 1;
    if (end > frames.length) end = frames.length;
    if (start >= end) return const [];
    return frames.sublist(start, end);
  }
}

class FaultStat {
  const FaultStat({
    required this.code,
    required this.nameZh,
    required this.scorable,
    required this.count,
    required this.rate,
    required this.repIndices,
    required this.worstDelta,
  });
  final String code;
  final String nameZh;
  final bool scorable;
  final int count;
  final double rate;
  final List<int> repIndices;
  final double worstDelta;
}

class SetSummary {
  const SetSummary({required this.repCount, required this.faultStats});
  final int repCount;
  final List<FaultStat> faultStats;
  List<FaultStat> get scorableFaults =>
      faultStats.where((s) => s.scorable).toList();
  List<FaultStat> get notices =>
      faultStats.where((s) => !s.scorable).toList();

  FaultStat? primaryFault() {
    if (faultStats.isEmpty) return null;
    var best = faultStats.first;
    for (final stat in faultStats.skip(1)) {
      if (stat.rate > best.rate ||
          (stat.rate == best.rate && stat.worstDelta > best.worstDelta)) {
        best = stat;
      }
    }
    return best;
  }
}

class RuleEngine {
  RuleEngine(this.rules, this.thresholds);
  final List<Rule> rules;
  final ThresholdSource thresholds;

  List<Fault> evaluateRep(RepWindow window) {
    final faults = <Fault>[];
    for (final rule in rules) {
      final fault = _evaluate(rule, window);
      if (fault != null) faults.add(fault);
    }
    return faults;
  }

  Fault? _evaluate(Rule rule, RepWindow window) {
    final frames = window.select(rule.phase);
    final timestamps = <int>[];
    final samples = <double>[];
    for (final frame in frames) {
      if (!frame.isValid(rule.metric)) continue;
      final value = frame.get(rule.metric);
      if (value == null) continue;
      timestamps.add(frame.timestampMs);
      samples.add(rule.useAbs ? value.abs() : value);
    }
    if (samples.isEmpty) return null;
    final threshold = thresholds.get(rule.thresholdKey);
    final limit = threshold.value;
    final violatingTimestamps = <int>[];
    final violatingValues = <double>[];
    for (var i = 0; i < samples.length; i++) {
      if (_isViolation(samples[i], limit, rule.badSide)) {
        violatingTimestamps.add(timestamps[i]);
        violatingValues.add(samples[i]);
      }
    }
    final double worst;
    if (rule.reduce == Reduce.anyFrame) {
      if (violatingValues.length < rule.minViolatingFrames) return null;
      worst = rule.badSide == Direction.above
          ? violatingValues.reduce((a, b) => a > b ? a : b)
          : violatingValues.reduce((a, b) => a < b ? a : b);
    } else {
      worst = _reduce(samples, rule.reduce);
      if (!_isViolation(worst, limit, rule.badSide)) return null;
    }
    final delta = worst - limit;
    final span = rule.severitySpan;
    final severity = span == null ? null : _min(delta.abs() / span, 1.0);
    final coverage = violatingValues.length / samples.length;
    final validity = frames.isEmpty ? 0.0 : samples.length / frames.length;
    return Fault(
      code: rule.code,
      nameZh: rule.nameZh,
      scorable: threshold.mayDriveScoring,
      confidence: _round4(coverage * validity),
      evidenceTimestamps: violatingTimestamps,
      deviation: Deviation(
        feature: rule.metric,
        measured: _round4(worst),
        threshold: limit,
        deltaSigned: _round4(delta),
        severity01: severity == null ? null : _round4(severity),
      ),
    );
  }

  SetSummary evaluateSet(List<RepWindow> windows) {
    final perRep = windows.map(evaluateRep).toList();
    final counts = <String, int>{};
    final reps = <String, List<int>>{};
    final worstDelta = <String, double>{};
    final scorable = <String, bool>{};
    final names = <String, String>{};
    for (var i = 0; i < windows.length; i++) {
      final window = windows[i];
      final seen = <String>{};
      for (final fault in perRep[i]) {
        final code = fault.code;
        names[code] = fault.nameZh;
        scorable[code] = fault.scorable;
        final delta = fault.deviation.deltaSigned.abs();
        final previous = worstDelta[code];
        if (previous == null || delta > previous) worstDelta[code] = delta;
        if (!seen.add(code)) continue;
        counts[code] = (counts[code] ?? 0) + 1;
        (reps[code] ??= <int>[]).add(window.index);
      }
    }
    final total = windows.length;
    final codes = counts.keys.toList()..sort();
    final stats = <FaultStat>[
      for (final code in codes)
        FaultStat(
          code: code,
          nameZh: names[code]!,
          scorable: scorable[code]!,
          count: counts[code]!,
          rate: total == 0 ? 0.0 : _round4(counts[code]! / total),
          repIndices: reps[code] ?? const [],
          worstDelta: _round4(worstDelta[code] ?? 0.0),
        ),
    ];
    return SetSummary(repCount: total, faultStats: stats);
  }
}

double _min(double a, double b) => a < b ? a : b;

double _reduce(List<double> values, Reduce how) {
  switch (how) {
    case Reduce.min:
      return values.reduce((a, b) => a < b ? a : b);
    case Reduce.max:
      return values.reduce((a, b) => a > b ? a : b);
    case Reduce.median:
      return medianOf(values);
    case Reduce.reversals:
      return countReversals(values).toDouble();
    case Reduce.anyFrame:
      throw const RuleException('_reduce 不支持 Reduce.anyFrame；它不走归约路径');
  }
}

bool _isViolation(double value, double threshold, Direction badSide) =>
    badSide == Direction.above ? value > threshold : value < threshold;
