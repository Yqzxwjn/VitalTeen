///通道调用
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

///调一次原生通道。插件不在（主机测试、桌面调试）或者平台那边报了错，
///都当成「没拿到」返回 null，平台异常记一行日志。what 是日志前缀，
///比如传「资料读取」就打出「资料读取失败：…」
Future<T?> callChannel<T>(
  MethodChannel channel,
  String method, {
  Object? arguments,
  String? what,
}) async {
  try {
    return await channel.invokeMethod<T>(method, arguments);
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error) {
    final prefix = what;
    if (prefix != null) debugPrint('$prefix失败：${error.message}');
    return null;
  }
}

///只要调一下、不关心返回值的通道
Future<void> callChannelVoid(
  MethodChannel channel,
  String method, {
  Object? arguments,
  String? what,
}) =>
    callChannel<Object?>(channel, method, arguments: arguments, what: what);
