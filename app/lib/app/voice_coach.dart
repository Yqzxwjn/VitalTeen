///语音模块
library;

import 'package:flutter/foundation.dart';

import 'action_spec.dart';
import 'camera_position_check.dart' show PositionIssueCode;
import 'fault_presentation.dart' show faultTitle;
import 'squat_session.dart' show SessionPhase, SessionView;

typedef SpeakSink = void Function(String text);

const Map<PositionIssueCode, String?> _gatePhrases = {
  PositionIssueCode.missingTorso: '请站到画面里，让整个人进镜头',
  PositionIssueCode.missingLegs: '请后退一点，让双腿进画面',
  PositionIssueCode.missingLeftFoot: '左脚没进画面，请后退一点，或者稍微侧身',
  PositionIssueCode.missingFeet: '看不到脚尖，数不出数，请后退一点，让两只脚进画面',
  PositionIssueCode.tooFar: '离得有点远，请走近一些',
  PositionIssueCode.tooClose: '离得太近，请后退一些',
  PositionIssueCode.cropped: '有一部分身体出画了，请后退一点，站到画面中间',
  PositionIssueCode.facingFront: '请侧身四十五度，正对镜头数不出数',
  PositionIssueCode.notFacingFront: '请正对镜头站好，侧着身子数不出数',
  PositionIssueCode.headNotVisible: null,
  PositionIssueCode.facingSide: null,
  PositionIssueCode.viewUnstable: null,
};

String? gatePhrase(PositionIssueCode code) => _gatePhrases[code];

@visibleForTesting
bool hasGatePhrase(PositionIssueCode code) => _gatePhrases.containsKey(code);

class VoiceCoach {
  VoiceCoach({
    required this.speak,
    this.framingHint,
    this.discardedReason = squatDiscardedReason,
    this.isTimed = false,
  });
  final SpeakSink speak;
  final String? framingHint;
  final String discardedReason;
  final bool isTimed;
  String get _unit => repUnitText(isTimed);
  String get _discardUnit => isTimed ? '段' : '次';
  SessionPhase? _phase;
  int _reportedReps = 0;
  PositionIssueCode? _lastGateCode;

  void onView(SessionView view) {
    if (view.phase != _phase) {
      _onPhaseChange(view.phase, view);
      _phase = view.phase;
    }
    switch (view.phase) {
      case SessionPhase.counting:
        if (view.repCount > _reportedReps) speak(_number(view.repCount));
      case SessionPhase.position:
      case SessionPhase.calibrating:
        _speakGate(view);
      case SessionPhase.finished:
        break;
    }
    _reportedReps = view.repCount;
  }

  void onCountdown(int secondsLeft) {
    if (secondsLeft > 0) speak(_number(secondsLeft));
  }

  void _onPhaseChange(SessionPhase phase, SessionView view) {
    switch (phase) {
      case SessionPhase.calibrating:
        speak('站直，别动');
      case SessionPhase.counting:
        speak(framingHint == null ? '开始' : '开始。$framingHint');
        _lastGateCode = null;
      case SessionPhase.finished:
        _speakSummary(view);
      case SessionPhase.position:
        _lastGateCode = null;
    }
  }

  void _speakGate(SessionView view) {
    final issue = view.position.primaryIssue;
    final code = (issue != null && issue.blocking) ? issue.code : null;
    if (code == _lastGateCode) return;
    _lastGateCode = code;
    if (code == null) return;
    final phrase = gatePhrase(code);
    if (phrase != null) speak(phrase);
  }

  void _speakSummary(SessionView view) {
    final summary = view.summary;
    if (summary == null) return;
    final parts = <String>['本组结束，一共${_quantity(summary.repCount)}$_unit'];
    if (view.repDurationsMs.isNotEmpty) {
      final totalSeconds = (view.totalRepDurationMs / 1000).round();
      parts.add('合计${_quantity(totalSeconds)}秒');
    }
    final primary = summary.primaryFault();
    if (primary != null) {
      parts.add(
        '${_quantity(primary.count)}次${faultTitle(primary.code, primary.nameZh)}',
      );
    } else {
      parts.add('没有发现需要留意的地方');
    }
    if (view.discardedReps > 0) {
      parts.add('有${_quantity(view.discardedReps)}$_discardUnit$discardedReason，没计入');
    }
    if (view.interrupted) {
      parts.add('中途离开过画面，计数可能不准');
    }
    speak('${parts.join('，')}。');
  }
}

String _number(int n) {
  const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
  if (n < 0) return '$n';
  if (n < 10) return digits[n];
  if (n < 20) return n == 10 ? '十' : '十${digits[n % 10]}';
  if (n < 100) {
    final ones = n % 10;
    return '${digits[n ~/ 10]}十${ones == 0 ? '' : digits[ones]}';
  }
  return '$n';
}

String _quantity(int n) => n == 2 ? '两' : _number(n);

@visibleForTesting
String chineseNumber(int n) => _number(n);

@visibleForTesting
String chineseQuantity(int n) => _quantity(n);
