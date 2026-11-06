/// HTTP 客户端的测试。**这里起真的 `HttpServer`。**
///
/// 不 mock `HttpClient`：这一层要验的正是「换到真实 socket 上还成不成立」的
/// 那几件事 —— 状态码怎么分类、超时是不是真的会到点、中文是不是真的没变成
/// 乱码、连接被拒绝是不是真的能认出来。用 `MockClient` 测这些，
/// 测的是我自己对 HTTP 的想象。
///
/// 超时那两条用的是**很短的自定义超时**（几百毫秒），否则一套测试要跑十几秒。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/decision_response.dart';
import 'package:vitalteen_app/app/decision_submission.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/platform/decide_client.dart';

/// 一份最小的合法请求。**故意带中文**（年级）—— 编码那条测试全靠它。
DecisionRequest _request({String grade = '高一'}) => DecisionRequest(
      requestId: 'r-1',
      context: DecisionContext(
        sex: Sex.female,
        age: 16,
        grade: grade,
        standardGroup: '高中女子',
        actionCode: squatActionCode,
        cameraView: 'oblique45',
      ),
      poseQuality: const PoseQuality(
        meanVisibility: 0.94,
        coverageOkRatio: 0.98,
        fpsMean: 29.7,
        gapMaxMs: 66,
        viewConfidence: 0.91,
      ),
      set: const SetIn(
        repCount: 2,
        validRepCount: 2,
        tempoMeanMs: 825,
        romMeanDeg: null,
        symmetryIndexMean: null,
        faultStats: [],
      ),
      reps: const [],
      candidates: const [],
      thresholdsVersion: 'local-test',
    );

/// 一段合法的响应正文，带中文。
String _okBody() => jsonEncode({
      'request_id': 'r-1',
      'status': 'ok',
      'faults': <dynamic>[],
      'gates': <String, dynamic>{},
      'scores': {'form_score': 100, 'rating': '优', 'provisional': true},
      'message': {
        'template_id': 'msg_squat_clean_teen_v1',
        'params': {'total': 2, 'valid': 2},
      },
      'meta': {
        'decision_model_version': 'rule-only',
        'thresholds_version': 'v1',
        'latency_ms': 3,
        'shuffled': false,
      },
    });

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late DecideClient client;

  /// 每个用例自己决定怎么回应。
  ///
  /// **body 由监听器读一次再传进来。** `HttpRequest` 是一支只能听一次的流，
  /// 让监听器和 handler 各读一遍会抛「Stream has already been listened to」——
  /// 那是测试自己的 bug，会伪装成客户端的问题。
  late FutureOr<void> Function(HttpRequest request, String body) handler;

  /// 服务端收到的最后一份请求。
  late Map<String, dynamic> received;
  late String receivedBody;

  /// 回一份 200 + 合法正文。绝大多数用例只关心自己那一点差别。
  Future<void> replyOk(HttpRequest request, {String? body}) async {
    request.response
      ..statusCode = 200
      ..write(body ?? _okBody());
    await request.response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    receivedBody = '';
    received = <String, dynamic>{};
    handler = (request, body) => replyOk(request);
    subscription = server.listen((request) async {
      receivedBody = await utf8.decoder.bind(request).join();
      received = jsonDecode(receivedBody) as Map<String, dynamic>;
      await handler(request, receivedBody);
    });
    client = DecideClient();
  });

  tearDown(() async {
    client.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  DecisionEndpoint endpointFor(HttpServer server, {String? apiKey}) =>
      DecisionEndpoint(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: apiKey,
      );

  group('成功', () {
    test('200 且正文读得懂时给出成功结果', () async {
      final outcome = await client.send(endpointFor(server), _request());

      expect(outcome, isA<DecisionSuccess>());
      final success = outcome as DecisionSuccess;
      expect(success.response.status, DecisionStatus.ok);
      expect(success.response.scores!.rating, '优');
      // 原始正文要留着 —— Phase 1 的验收物（结构化 JSON 可复制）不能丢。
      expect(success.rawJson, contains('msg_squat_clean_teen_v1'));
    });

    test('往返耗时是端侧实测的，不是响应里的 latency_ms', () async {
      // 现场的「是服务慢还是网慢」只能靠这个数 —— 响应里的那个只算服务端内部。
      handler = (request, body) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await replyOk(request);
      };

      final outcome = await client.send(endpointFor(server), _request()) as DecisionSuccess;
      expect(outcome.elapsed.inMilliseconds, greaterThanOrEqualTo(100));
      expect(outcome.response.meta.latencyMs, 3);
    });

    test('中文请求发出去是中文，响应里的中文读回来也是中文', () async {
      // Content-Type 不带 charset 时 Dart 按 latin1 编解码，两边都会变乱码 ——
      // 服务端收乱码会回 400，而报错完全指不出病因。
      handler = (request, body) async {
        await replyOk(request);
      };

      final outcome = await client.send(endpointFor(server), _request(grade: '高一（3）班'));
      expect(received['context']['grade'], '高一（3）班');
      expect(
        (outcome as DecisionSuccess).response.message!.params['valid'],
        2,
      );
    });

    test('带密钥时 Authorization 头到得了服务端', () async {
      String? seen;
      handler = (request, body) async {
        seen = request.headers.value('Authorization');
        await replyOk(request);
      };

      await client.send(endpointFor(server, apiKey: 'k-1'), _request());
      expect(seen, 'Bearer k-1');
    });

    test('不发密钥时服务端看不到 Authorization', () async {
      String? seen = 'not-yet';
      handler = (request, body) async {
        seen = request.headers.value('Authorization');
        await replyOk(request);
      };

      await client.send(endpointFor(server), _request());
      expect(seen, isNull);
    });

    test('发到的是 /v1/decide', () async {
      String? path;
      handler = (request, body) async {
        path = request.uri.path;
        await replyOk(request);
      };

      await client.send(endpointFor(server), _request());
      expect(path, '/v1/decide');
    });
  });

  group('失败分类', () {
    Future<DecisionFailure> failWith(
      int status, {
      String raw = '{"error":"boom"}',
    }) async {
      // 第二个参数是**收进来的**正文，写成 `_` 免得遮住 `raw`。
      handler = (request, _) async {
        request.response
          ..statusCode = status
          ..write(raw);
        await request.response.close();
      };
      final outcome = await client.send(endpointFor(server), _request());
      expect(outcome, isA<DecisionFailure>());
      return outcome as DecisionFailure;
    }

    test('401 → 密钥不对', () async {
      final failure = await failWith(401, raw: '{"error":"unauthorized"}');
      expect(failure.kind, DecisionFailureKind.unauthorized);
      expect(failure.statusCode, 401);
    });

    test('403 也归到密钥不对', () async {
      expect((await failWith(403)).kind, DecisionFailureKind.unauthorized);
    });

    test('400 → 两端契约对不上，并把逐字段说明带出来', () async {
      final failure = await failWith(
        400,
        raw: '{"error":"invalid_request","detail":['
            '{"field":"context.age","message":"should be greater than 5"}]}',
      );
      expect(failure.kind, DecisionFailureKind.rejected);
      expect(failure.detail, 'context.age：should be greater than 5');
    });

    test('404 → 地址上没有接口，与 400 分开', () async {
      // 两者对用户的意义完全不同：404 是「地址写错了」，现场出现得多得多，
      // 也更容易自己修好。
      final failure = await failWith(404, raw: '{"error":"not_found"}');
      expect(failure.kind, DecisionFailureKind.wrongEndpoint);
    });

    test('405 也归到地址不对', () async {
      expect((await failWith(405)).kind, DecisionFailureKind.wrongEndpoint);
    });

    test('500 → 服务端内部出错', () async {
      final failure = await failWith(500, raw: '{"error":"internal_error"}');
      expect(failure.kind, DecisionFailureKind.serverError);
      expect(failure.statusCode, 500);
    });

    test('502 之类的也算服务端出错', () async {
      expect((await failWith(502, raw: '')).kind, DecisionFailureKind.serverError);
    });

    test('没归类的状态码不假装知道', () async {
      expect((await failWith(418, raw: '')).kind, DecisionFailureKind.unexpected);
    });
  });

  group('正文读不懂', () {
    Future<DecisionFailure> sendBody(String raw) async {
      // 第二个参数是**收进来的**正文，这里不用它 —— 所以写成 `_`，
      // 免得它悄悄遮住外面那个 `raw`。
      handler = (request, _) => replyOk(request, body: raw);
      final outcome = await client.send(endpointFor(server), _request());
      expect(outcome, isA<DecisionFailure>());
      return outcome as DecisionFailure;
    }

    test('200 但正文不是 JSON', () async {
      final failure = await sendBody('<html>我是一个网页</html>');
      expect(failure.kind, DecisionFailureKind.unreadable);
      expect(failure.statusCode, 200);
    });

    test('200、是 JSON，但不符合契约', () async {
      // **这一条最危险**：读得进 JSON，字段却对不上。当成成功会让报告里
      // 出现半份结论，而没有任何东西报错。
      final failure = await sendBody('{"hello":"world"}');
      expect(failure.kind, DecisionFailureKind.unreadable);
      // 详情要指到**哪个字段**，只说「不符合契约」等于没说。
      expect(failure.detail, contains('response.'));
    });

    test('status 认不出来时不按 ok 猜着读', () async {
      final broken = jsonDecode(_okBody()) as Map<String, dynamic>;
      broken['status'] = 'degraded';
      final failure = await sendBody(jsonEncode(broken));
      expect(failure.kind, DecisionFailureKind.unreadable);
    });
  });

  group('连不上与超时', () {
    test('端口上没人监听 → 连不上', () async {
      // 127.0.0.1:1 上几乎不可能有服务在听。
      final outcome = await client.send(
        const DecisionEndpoint(baseUrl: 'http://127.0.0.1:1'),
        _request(),
      );
      expect(outcome, isA<DecisionFailure>());
      final failure = outcome as DecisionFailure;
      expect(failure.kind, DecisionFailureKind.unreachable);
      expect(failure.statusCode, isNull);
      // OS 那句 Connection refused 要留着 —— 它是唯一的线索。
      expect(failure.detail, isNotNull);
    });

    test('服务端收下请求却一直不回 → 到点放弃', () async {
      // 这是最有实际意义的一种超时：服务连上了，但它在等那个 1GB 的模型进程。
      client.close();
      client = DecideClient(totalTimeout: const Duration(milliseconds: 300));

      final blocked = Completer<void>();
      handler = (request, body) async {
        // 收下请求，什么都不回，一直挂着。
        await blocked.future;
      };
      addTearDown(() => blocked.complete());

      final outcome = await client.send(endpointFor(server), _request());
      expect(outcome, isA<DecisionFailure>());
      expect((outcome as DecisionFailure).kind, DecisionFailureKind.timeout);
    });

    test('超时后不会留着那条请求继续跑', () async {
      // 不 abort 的话，用户点重试就会有两条请求在飞，
      // 而先回来的那条会覆盖后发的结论。
      client.close();
      client = DecideClient(
        totalTimeout: const Duration(milliseconds: 200),
        connectTimeout: const Duration(milliseconds: 200),
      );

      final closed = Completer<void>();
      handler = (request, _) async {
        // 把 socket 从 response 上摘下来，直接听它的关闭。`response.done`
        // 要等到真的写过东西才动，而这里我们什么都不写。
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () => _completeOnce(closed),
          onError: (Object _) => _completeOnce(closed),
          cancelOnError: true,
        );
        // 永不回应。
      };

      final outcome = await client.send(endpointFor(server), _request());
      expect((outcome as DecisionFailure).kind, DecisionFailureKind.timeout);

      // abort 之后这条连接应当被对端看到关闭 —— 给一点时间让它传过来。
      await closed.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('超时后请求没有被 abort，对端一直没看到连接关闭'),
      );
    });
  });

  group('资源', () {
    test('close 之后还能再发（会新建一个连接池）', () async {
      await client.send(endpointFor(server), _request());
      client.close();
      final outcome = await client.send(endpointFor(server), _request());
      expect(outcome, isA<DecisionSuccess>());
    });
  });
}

void _completeOnce(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}
