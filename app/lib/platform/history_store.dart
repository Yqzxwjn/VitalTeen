///练习记录的本机存取
library;

import 'package:flutter/services.dart';

import '../app/session_record.dart';
import 'channel_call.dart';

const MethodChannel _channel = MethodChannel('vitalteen/history');

Future<String?> loadHistoryRaw() =>
    callChannel<String>(_channel, 'load', what: '历史读取');

Future<bool> saveHistoryRaw(String raw) async =>
    await callChannel<bool>(_channel, 'save', arguments: raw, what: '历史保存') ??
    false;

Future<bool> clearHistoryRaw() async =>
    await callChannel<bool>(_channel, 'clear', what: '历史清除') ?? false;

Future<bool> appendSessionRecord(
  SessionRecord record, {
  int cap = historyRecordCap,
}) async {
  final existing = decodeHistory(await loadHistoryRaw());
  return saveHistoryRaw(
      encodeHistory(appendToHistory(existing, record, cap: cap)));
}
