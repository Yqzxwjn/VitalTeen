///决策服务的 HTTP 客户端，全应用唯一的网络 I/O
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app/decision_request.dart';
import '../app/decision_response.dart';
import '../app/decision_submission.dart';

class DecideClient {
  DecideClient({
    this.connectTimeout = const Duration(seconds: 5),
    this.totalTimeout = const Duration(seconds: 15),
    HttpClient? httpClient,
  }) : _injected = httpClient;
  final Duration connectTimeout;
  final Duration totalTimeout;
  final HttpClient? _injected;
  HttpClient? _client;

  HttpClient get _http {
    final existing = _client ?? _injected;
    if (existing != null) return existing;
    final created = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = 'VitalTeen/0.1';
    _client = created;
    return created;
  }

  Future<DecisionOutcome> send(
    DecisionEndpoint endpoint,
    DecisionRequest request,
  ) async {
    final started = Stopwatch()..start();
    HttpClientRequest? inFlight;
    try {
      return await _send(endpoint, request, started, (r) => inFlight = r).timeout(
        totalTimeout,
        onTimeout: () {
          inFlight?.abort();
          throw TimeoutException('决策服务在 ${totalTimeout.inSeconds} 秒内没有回完');
        },
      );
    } on TimeoutException {
      return DecisionFailure(
        kind: DecisionFailureKind.timeout,
        elapsed: started.elapsed,
      );
    } on IOException catch (error) {
      return DecisionFailure(
        kind: DecisionFailureKind.unreachable,
        detail: '$error',
        elapsed: started.elapsed,
      );
    }
  }

  Future<DecisionOutcome> _send(
    DecisionEndpoint endpoint,
    DecisionRequest request,
    Stopwatch started,
    void Function(HttpClientRequest) onCreated,
  ) async {
    final httpRequest = await _http.postUrl(endpoint.decideUri);
    onCreated(httpRequest);
    for (final entry in endpoint.headers.entries) {
      httpRequest.headers.set(entry.key, entry.value);
    }
    httpRequest.add(utf8.encode(jsonEncode(request.toJson())));
    final httpResponse = await httpRequest.close();
    final body = await utf8.decoder.bind(httpResponse).join();
    final elapsed = started.elapsed;
    if (httpResponse.statusCode != 200) {
      return DecisionFailure(
        kind: _kindFor(httpResponse.statusCode),
        statusCode: httpResponse.statusCode,
        detail: extractServerDetail(body),
        elapsed: elapsed,
      );
    }
    final DecisionResponse response;
    try {
      response = DecisionResponse.decode(body);
    } on DecisionResponseException catch (error) {
      return DecisionFailure(
        kind: DecisionFailureKind.unreadable,
        statusCode: 200,
        detail: error.message,
        elapsed: elapsed,
      );
    }
    return DecisionSuccess(response: response, rawJson: body, elapsed: elapsed);
  }

  static DecisionFailureKind _kindFor(int status) => switch (status) {
        400 => DecisionFailureKind.rejected,
        401 || 403 => DecisionFailureKind.unauthorized,
        404 || 405 => DecisionFailureKind.wrongEndpoint,
        >= 500 => DecisionFailureKind.serverError,
        _ => DecisionFailureKind.unexpected,
      };

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
