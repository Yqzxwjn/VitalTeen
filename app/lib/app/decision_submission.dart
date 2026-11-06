///把一组发出去这件事的形状：发到哪儿、成没成、没成怎么说
library;

import 'dart:convert';

import 'decision_response.dart';

class DecisionEndpoint {
  const DecisionEndpoint({required this.baseUrl, this.apiKey});
  final String baseUrl;
  final String? apiKey;
  static const String baseUrlDefine = 'VITALTEEN_API_BASE';
  static const String apiKeyDefine = 'VITALTEEN_API_KEY';
  static const String defaultBaseUrl = 'http://127.0.0.1:8080';
  static const String decidePath = '/v1/decide';
  static const String _envBase =
      String.fromEnvironment(baseUrlDefine, defaultValue: defaultBaseUrl);
  static const String _envKey = String.fromEnvironment(apiKeyDefine);
  static DecisionEndpoint fromEnvironment() => DecisionEndpoint(
        baseUrl: _envBase,
        apiKey: _envKey.isEmpty ? null : _envKey,
      );
  DecisionEndpoint withBaseUrl(String value) =>
      DecisionEndpoint(baseUrl: value, apiKey: apiKey);
  DecisionEndpoint withApiKey(String? value) =>
      DecisionEndpoint(baseUrl: baseUrl, apiKey: value);

  String get normalizedBaseUrl {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
  Uri get decideUri => Uri.parse('$normalizedBaseUrl$decidePath');

  Map<String, String> get headers => {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer ${apiKey!}',
      };

  static String? validationError(String input) {
    final value = input.trim();
    if (value.isEmpty) return '请填写服务地址';
    if (!value.contains('://')) return '地址要以 http:// 或 https:// 开头';
    final uri = Uri.tryParse(value);
    if (uri == null) return '这不是一个合法的地址';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '地址要以 http:// 或 https:// 开头';
    }
    if (uri.host.isEmpty) return '地址里缺少主机名或 IP';
    return null;
  }
  bool get isLoopback =>
      normalizedBaseUrl.contains('127.0.0.1') ||
      normalizedBaseUrl.contains('localhost');
  @override
  String toString() => 'DecisionEndpoint($normalizedBaseUrl)';
}

sealed class DecisionOutcome {
  const DecisionOutcome();
}

class DecisionSuccess extends DecisionOutcome {
  const DecisionSuccess({required this.response, required this.rawJson, required this.elapsed});
  final DecisionResponse response;
  final String rawJson;
  final Duration elapsed;
}

class DecisionFailure extends DecisionOutcome {
  const DecisionFailure({
    required this.kind,
    this.statusCode,
    this.detail,
    this.elapsed,
  });
  final DecisionFailureKind kind;
  final int? statusCode;
  final String? detail;
  final Duration? elapsed;
}

enum DecisionFailureKind {
  unreachable,
  timeout,
  unauthorized,
  rejected,
  wrongEndpoint,
  serverError,
  unreadable,
  unexpected;
  String get message => switch (this) {
        unreachable => '连不上决策服务',
        timeout => '决策服务没有在规定时间内回应',
        unauthorized => '服务端拒绝了这次请求（密钥不对）',
        rejected => '服务端认为这份请求不合契约',
        wrongEndpoint => '这个地址上没有决策接口',
        serverError => '决策服务内部出错了',
        unreadable => '服务端返回的内容读不懂',
        unexpected => '提交没有成功',
      };

  String get advice => switch (this) {
        unreachable => '检查电脑上是否跑着 `python -m app.api`；'
            '用 USB 的话，先在电脑上执行 `adb reverse tcp:8080 tcp:8080`。',
        timeout => '服务可能正忙或卡住了。稍等几秒再试；'
            '如果一直这样，看看电脑上那个终端有没有报错。',
        unauthorized => '把服务端的 VITALTEEN_API_KEY 和这里填的密钥对一下 —— '
            '两边必须一模一样。',
        rejected => '这是两端程序对不上的信号，不是操作问题。'
            '把技术信息里的请求编号报给开发者。',
        wrongEndpoint => '确认地址只写到端口，例如 http://127.0.0.1:8080 —— '
            '不要带 `/v1/decide`。',
        serverError => '看电脑上那个终端的输出，那里会有完整的报错。',
        unreadable => '服务端回了话但不是决策响应。'
            '确认地址指向的是决策服务，而不是别的网页。',
        unexpected => '把技术信息里的请求编号报给开发者。',
      };

  String get reassurance => '这一组的数据还在手机上，直接重试就行，不用再做一遍。';
}

enum DeviceFallbackCause {
  unreachable,
  timeout;
  static DeviceFallbackCause? from(DecisionFailureKind kind) => switch (kind) {
        DecisionFailureKind.unreachable => DeviceFallbackCause.unreachable,
        DecisionFailureKind.timeout => DeviceFallbackCause.timeout,
        _ => null,
      };

  String get clause => switch (this) {
        unreachable => '当时连不上决策服务',
        timeout => '当时决策服务没有在规定时间内回应',
      };
}

String? extractServerDetail(String body) {
  final trimmed = body.trim();
  if (!trimmed.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  return _readDetail(decoded['detail']) ?? _readDetail(decoded['error']);
}

String? _readDetail(Object? detail) {
  if (detail is String) return detail.isEmpty ? null : detail;
  if (detail is List) {
    final lines = <String>[];
    for (final item in detail) {
      if (item is Map) {
        final field = item['field'];
        final message = item['message'];
        lines.add(field == null ? '$message' : '$field：$message');
      } else {
        lines.add('$item');
      }
    }
    return lines.isEmpty ? null : lines.join('\n');
  }
  return null;
}
