///练完一组后记录
library;

import 'action_spec.dart';
import 'session_record.dart';
import 'squat_session.dart' show SessionPhase, SessionView;

typedef RecordSink = void Function(SessionRecord record);

class SetRecorder {
  SetRecorder({
    required this.spec,
    required this.onRecord,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final ActionSpec spec;
  final RecordSink onRecord;
  final DateTime Function() _now;
  SessionPhase? _phase;

  void onView(SessionView view) {
    final previous = _phase;
    _phase = view.phase;
    if (view.phase != SessionPhase.finished) return;
    if (previous == SessionPhase.finished) return;
    final summary = view.summary;
    if (summary == null || summary.repCount <= 0) return;
    onRecord(SessionRecord(
      actionCode: spec.code,
      actionNameZh: spec.nameZh,
      finishedAt: _now(),
      repCount: summary.repCount,
      isTimed: spec.isTimed,
      score: view.setScore?.score,
      provisional: view.setScore?.provisional ?? false,
      faultCounts: {
        for (final stat in summary.faultStats) stat.code: stat.count,
      },
    ));
  }
}
