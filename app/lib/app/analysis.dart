///一次「分析这一组」的三种结局
library;

import 'decision_report.dart';
import 'decision_submission.dart';

sealed class AnalysisResult {
  const AnalysisResult();
}

class AnalysisReported extends AnalysisResult {
  const AnalysisReported({
    required this.report,
    required this.rawJson,
    required this.elapsed,
    required this.origin,
    this.fallbackCause,
  });
  final DecisionReport report;
  final String rawJson;
  final Duration elapsed;
  final ReportOrigin origin;
  final DeviceFallbackCause? fallbackCause;
  bool get isFromDevice => origin.isDevice;
}

class AnalysisFailed extends AnalysisResult {
  const AnalysisFailed(this.failure);
  final DecisionFailure failure;
}

class AnalysisBlocked extends AnalysisResult {
  const AnalysisBlocked({required this.message, required this.advice});
  final String message;
  final String advice;
}
