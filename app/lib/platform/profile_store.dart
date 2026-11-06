///资料的本机存取
library;

import 'package:flutter/services.dart';

import 'channel_call.dart';

const MethodChannel _channel = MethodChannel('vitalteen/profile');

Future<String?> loadProfileRaw() =>
    callChannel<String>(_channel, 'load', what: '资料读取');

Future<bool> saveProfileRaw(String raw) async =>
    await callChannel<bool>(_channel, 'save', arguments: raw, what: '资料保存') ??
    false;

Future<bool> clearProfileRaw() async =>
    await callChannel<bool>(_channel, 'clear', what: '资料清除') ?? false;
