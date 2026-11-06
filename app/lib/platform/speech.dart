///语音播报
library;

import 'package:flutter/services.dart';

import 'channel_call.dart';

const MethodChannel _channel = MethodChannel('vitalteen/speech');

///说一句话。返回引擎有没有接下这一句 —— 文本为空时当作「不用说了」
Future<bool> speak(String text) async {
  if (text.isEmpty) return true;
  return await callChannel<bool>(_channel, 'speak',
          arguments: {'text': text}, what: '语音播报') ??
      false;
}

Future<void> stopSpeaking() =>
    callChannelVoid(_channel, 'stop', what: '停止语音播报');
