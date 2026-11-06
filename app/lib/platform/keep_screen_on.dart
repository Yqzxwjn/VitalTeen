///屏幕常亮
library;

import 'package:flutter/services.dart';

import 'channel_call.dart';

const MethodChannel _channel = MethodChannel('vitalteen/display');

Future<void> setKeepScreenOn(bool on) => callChannelVoid(
      _channel,
      'keepScreenOn',
      arguments: on,
      what: '屏幕常亮设置',
    );
