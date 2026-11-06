///头像的读、换、删
library;

import 'package:flutter/services.dart';

import 'channel_call.dart';

const MethodChannel _channel = MethodChannel('vitalteen/avatar');

enum AvatarPickOutcome { picked, cancelled, failed }

Future<String?> loadAvatarPath() async {
  final path = await callChannel<String>(_channel, 'path', what: '头像路径读取');
  return (path == null || path.isEmpty) ? null : path;
}

Future<AvatarPickOutcome> pickAvatar() async {
  final raw = await callChannel<String>(_channel, 'pick', what: '换头像');
  return switch (raw) {
    'picked' => AvatarPickOutcome.picked,
    'cancelled' => AvatarPickOutcome.cancelled,
    _ => AvatarPickOutcome.failed,
  };
}

Future<bool> clearAvatarRaw() async =>
    await callChannel<bool>(_channel, 'clear', what: '头像清除') ?? false;
