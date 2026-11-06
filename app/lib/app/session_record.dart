///一条练习记录，存进本机的就是它编码出来的那串 JSON
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

const int sessionRecordSchemaVersion = 2;

const int historyRecordCap = 200;

const int sessionRecordMaxReps = 999;

const int sessionRecordMaxScore = 100;

const int sessionRecordMaxTextLength = 40;

const int sessionRecordMaxFaultCodes = 12;

@immutable
class SessionRecord {
  const SessionRecord({
    required this.actionCode,
    required this.actionNameZh,
    required this.finishedAt,
    required this.repCount,
    required this.isTimed,
    required this.score,
    required this.provisional,
    this.faultCounts,
  });
  final String actionCode;
  final String actionNameZh;
  final DateTime finishedAt;
  final int repCount;
  final bool isTimed;
  final int? score;
  final bool provisional;
  final Map<String, int>? faultCounts;

  Map<String, dynamic> toJson() => {
        'v': sessionRecordSchemaVersion,
        'action_code': actionCode,
        'action_name': actionNameZh,
        'finished_at_ms': finishedAt.millisecondsSinceEpoch,
        'reps': repCount,
        'timed': isTimed,
        'score': score,
        'provisional': provisional,
        'fault_counts': faultCounts,
      };
  String encode() => jsonEncode(toJson());

  static SessionRecord? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;
    return _fromMap(parsed);
  }

  static SessionRecord? _fromMap(Map<Object?, Object?> parsed) {
    final version = parsed['v'];
    if (version != 1 && version != 2) return null;
    final code = _text(parsed['action_code']);
    if (code == null) return null;
    final name = _text(parsed['action_name']);
    if (name == null) return null;
    final ms = parsed['finished_at_ms'];
    if (ms is! int || ms <= 0) return null;
    final reps = parsed['reps'];
    if (reps is! int || reps <= 0 || reps > sessionRecordMaxReps) return null;
    final timed = parsed['timed'];
    if (timed is! bool) return null;
    final score = parsed['score'];
    if (score != null &&
        (score is! int || score < 0 || score > sessionRecordMaxScore)) {
      return null;
    }
    final provisional = parsed['provisional'];
    if (provisional is! bool) return null;
    Map<String, int>? faultCounts;
    if (version == 2 && parsed['fault_counts'] != null) {
      faultCounts = _faultCounts(parsed['fault_counts'], reps);
      if (faultCounts == null) return null;
    }
    return SessionRecord(
      actionCode: code,
      actionNameZh: name,
      finishedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      repCount: reps,
      isTimed: timed,
      score: score as int?,
      provisional: provisional,
      faultCounts: faultCounts,
    );
  }

  static Map<String, int>? _faultCounts(Object? value, int maxReps) {
    if (value is! Map) return null;
    final entries = <MapEntry<String, int>>[];
    for (final entry in value.entries) {
      final rawKey = entry.key;
      if (rawKey is! String) return null;
      final code = rawKey.trim();
      if (code.isEmpty || code.length > sessionRecordMaxTextLength) return null;
      final rawCount = entry.value;
      if (rawCount is! int || rawCount < 1 || rawCount > maxReps) return null;
      entries.add(MapEntry(code, rawCount));
    }
    entries.sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
    final kept = entries.length > sessionRecordMaxFaultCodes
        ? entries.sublist(0, sessionRecordMaxFaultCodes)
        : entries;
    return Map.unmodifiable(<String, int>{for (final e in kept) e.key: e.value});
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > sessionRecordMaxTextLength) {
      return null;
    }
    return trimmed;
  }
}

List<SessionRecord> decodeHistory(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (parsed is! List) return const [];
  final records = <SessionRecord>[];
  for (final entry in parsed) {
    if (entry is! Map) continue;
    final record = SessionRecord._fromMap(entry);
    if (record != null) records.add(record);
  }
  return records;
}

String encodeHistory(List<SessionRecord> records) =>
    jsonEncode([for (final record in records) record.toJson()]);

List<SessionRecord> appendToHistory(
  List<SessionRecord> existing,
  SessionRecord record, {
  int cap = historyRecordCap,
}) {
  final next = <SessionRecord>[record, ...existing]
    ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
  if (next.length <= cap) return next;
  return next.sublist(0, cap);
}
