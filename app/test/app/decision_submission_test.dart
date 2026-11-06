/// 提交层的测试：地址怎么定、失败怎么分类、失败时对用户说什么。
///
/// **这里最要紧的是「每种失败都说得出下一步做什么」。** 演示现场最常见的
/// 两种失败是「服务没起」和「地址填错」，而它们最不该显示成「请求失败」——
/// 那句话对站在体育馆里的人等于没说。
///
/// 真正的网络 I/O 不在这里测，在 `test/platform/decide_client_test.dart`
///（那里起真的 `HttpServer`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_submission.dart';

void main() {
  group('地址', () {
    test('默认指向手机自己的回环', () {
      // 演示走 USB + `adb reverse tcp:8080 tcp:8080`：手机上的
      // 127.0.0.1:8080 直通笔记本的回环。地址与 WiFi 无关。
      expect(DecisionEndpoint.defaultBaseUrl, 'http://127.0.0.1:8080');
      expect(DecisionEndpoint.fromEnvironment().baseUrl, DecisionEndpoint.defaultBaseUrl);
    });

    test('末尾的斜杠会被容忍', () {
      const endpoint = DecisionEndpoint(baseUrl: 'http://10.0.0.5:8080///');
      expect(endpoint.normalizedBaseUrl, 'http://10.0.0.5:8080');
      expect(endpoint.decideUri.toString(), 'http://10.0.0.5:8080/v1/decide');
    });

    test('前后的空格会被去掉', () {
      const endpoint = DecisionEndpoint(baseUrl: '  http://127.0.0.1:8080  ');
      expect(endpoint.decideUri.toString(), 'http://127.0.0.1:8080/v1/decide');
    });

    test('认得出回环地址 —— 只有它需要提示 adb reverse', () {
      expect(const DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080').isLoopback, isTrue);
      expect(const DecisionEndpoint(baseUrl: 'http://localhost:8080').isLoopback, isTrue);
      expect(const DecisionEndpoint(baseUrl: 'http://192.168.1.7:8080').isLoopback, isFalse);
    });

    group('校验', () {
      test('空地址', () {
        expect(DecisionEndpoint.validationError(''), isNotNull);
        expect(DecisionEndpoint.validationError('   '), isNotNull);
      });

      test('没有协议头', () {
        // 「192.168.1.7:8080」`Uri.tryParse` 直接返回 `null`（冒号前那段不是
        // 合法 scheme，也不像相对路径），所以拦住它的是**「先看有没有 `://`」
        // 那一条**，而不是「解不开」那一条。两句话对用户的用处差很远：
        // 一个是「差六个字符」，另一个是「你这串东西不算地址」。
        //
        // 这是现场最常见的一种写法 —— 从浏览器地址栏抄来的那一串本来就不带协议头。
        expect(
          DecisionEndpoint.validationError('192.168.1.7:8080'),
          '地址要以 http:// 或 https:// 开头',
        );
        expect(DecisionEndpoint.validationError('localhost:8080'),
            '地址要以 http:// 或 https:// 开头');
      });

      test('有协议头但整体解不开', () {
        // 走到「解不开」那一条。得挑一个 `Uri.tryParse` 真会返回 null 的输入：
        // 它对空格、`%`、`:` 都相当宽容（「http://a b:8080」会被收成
        // `host=a%20b`），只有没闭合的方括号这种结构错误才拦得住它。
        expect(DecisionEndpoint.validationError('http://[::1'),
            '这不是一个合法的地址');
      });

      test('协议头不是 http/https', () {
        expect(DecisionEndpoint.validationError('ftp://127.0.0.1:8080'), isNotNull);
      });

      test('只有协议头，没有主机', () {
        expect(DecisionEndpoint.validationError('http://'), isNotNull);
      });

      test('能用的地址一律放行', () {
        for (final value in [
          'http://127.0.0.1:8080',
          'http://192.168.1.7:8000',
          'https://vitalteen.example.com',
          'http://127.0.0.1:8080/',
        ]) {
          expect(DecisionEndpoint.validationError(value), isNull, reason: value);
        }
      });
    });
  });

  group('请求头', () {
    test('没配密钥时不带 Authorization', () {
      const endpoint = DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080');
      expect(endpoint.headers.containsKey('Authorization'), isFalse);
    });

    test('空串密钥也算没配', () {
      const endpoint = DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080', apiKey: '');
      expect(endpoint.headers.containsKey('Authorization'), isFalse);
    });

    test('配了密钥就带 Bearer', () {
      const endpoint =
          DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080', apiKey: 'k-1');
      expect(endpoint.headers['Authorization'], 'Bearer k-1');
    });

    test('Content-Type 显式声明 utf-8', () {
      // 请求里有中文（年级）。不声明 charset 时 Dart 按 latin1 编码，
      // 服务端收到乱码回 400，而报错完全指不出病因。
      const endpoint = DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080');
      expect(endpoint.headers['Content-Type'], contains('utf-8'));
    });

    test('换地址时保留密钥', () {
      const endpoint =
          DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080', apiKey: 'k-1');
      expect(endpoint.withBaseUrl('http://10.0.0.5:9000').apiKey, 'k-1');
    });
  });

  group('失败种类', () {
    test('每一种都说得出「发生了什么」和「下一步做什么」', () {
      for (final kind in DecisionFailureKind.values) {
        expect(kind.message, isNotEmpty, reason: '$kind 没有 message');
        expect(kind.advice, isNotEmpty, reason: '$kind 没有 advice');
        expect(kind.reassurance, isNotEmpty, reason: '$kind 没有 reassurance');
      }
    });

    test('「连不上」的提示里必须有那两条手工步骤', () {
      // 这是唯一一处**不做就一定连不上**的手工操作，而它的报错
      // （连接被拒绝）完全指不出病因。
      expect(DecisionFailureKind.unreachable.advice, contains('app.api'));
      expect(DecisionFailureKind.unreachable.advice, contains('adb reverse'));
    });

    test('「地址上没有接口」提示不要带上路径', () {
      expect(DecisionFailureKind.wrongEndpoint.advice, contains('http://127.0.0.1:8080'));
    });

    test('每种失败的说明互不相同', () {
      // 两条失败说同一句话，等于分类没做。
      final messages = DecisionFailureKind.values.map((k) => k.message).toSet();
      expect(messages, hasLength(DecisionFailureKind.values.length));
    });

    test('失败时明说「数据还在，直接重试」', () {
      // 失败之后用户的第一反应是「我是不是得再做一组」。服务端是无状态的，
      // 重发同一份请求是安全的 —— 这句话必须说出来。
      expect(DecisionFailureKind.unreachable.reassurance, contains('重试'));
      expect(DecisionFailureKind.serverError.reassurance, contains('不用再做'));
    });
  });

  group('本机兜底的准入线', () {
    test('只有「没拿到答复」才允许本机兜底', () {
      // **这是整个断网兜底功能的准入线。** 判据是「有没有拿到答复」，
      // 不是「失败得严不严重」：服务端答复了（哪怕答的是 500），
      // 本机就不该顶上去 —— 否则「密钥配错」「两端契约不一致」
      // 「地址填错」这三类问题会永远查不出来，现场表现为「一直有报告」，
      // 而报告不是服务端给的。
      const mayFallBack = {
        DecisionFailureKind.unreachable,
        DecisionFailureKind.timeout,
      };

      for (final kind in DecisionFailureKind.values) {
        final cause = DeviceFallbackCause.from(kind);
        if (mayFallBack.contains(kind)) {
          expect(cause, isNotNull, reason: '$kind 该允许本机兜底');
        } else {
          expect(
            cause,
            isNull,
            reason: '$kind 是「服务端答复了」，必须照旧失败而不是转本机',
          );
        }
      }
    });

    test('八种失败一种都没漏', () {
      // 上面那条是按集合判断的，将来加了新的失败种类而没人想过它算不算
      // 「拿到了答复」时，这条会红。
      expect(DecisionFailureKind.values, hasLength(8));
    });

    test('两种原因的措辞互不相同，且说得出是哪一种', () {
      final clauses = DeviceFallbackCause.values.map((c) => c.clause).toSet();
      expect(clauses, hasLength(DeviceFallbackCause.values.length));
      // 「连不上」与「没回完」对读的人来说是两件不同的事 ——
      // 一个该去查服务起没起，另一个该等一等再试。
      expect(DeviceFallbackCause.unreachable.clause, contains('连不上'));
      expect(DeviceFallbackCause.timeout.clause, contains('没有在规定时间内'));
    });
  });

  group('从正文里抠服务端的说明', () {
    test('字符串 detail 直接用', () {
      expect(
        extractServerDetail('{"error":"invalid_request","detail":"字段不对"}'),
        '字段不对',
      );
    });

    test('没有 detail 时退回 error', () {
      expect(extractServerDetail('{"error":"unauthorized"}'), 'unauthorized');
    });

    test('400 那串逐字段说明排成人话', () {
      // api.py 逐字段回报，好让端侧直接定位。让 Dart 的 List.toString()
      // 把大括号印到用户面前就白搭了。
      expect(
        extractServerDetail(
          '{"error":"invalid_request","detail":['
          '{"field":"context.age","message":"should be greater than 5"},'
          '{"field":"set.rep_count","message":"should be >= 1"}]}',
        ),
        'context.age：should be greater than 5\nset.rep_count：should be >= 1',
      );
    });

    test('HTML 错误页不塞进详情', () {
      // 一个 nginx 的 502 页面塞进「详情」里，比空着更让人困惑。
      expect(extractServerDetail('<html><body>502 Bad Gateway</body></html>'), isNull);
    });

    test('空正文与半截 JSON 都返回 null', () {
      expect(extractServerDetail(''), isNull);
      expect(extractServerDetail('   '), isNull);
      expect(extractServerDetail('{"error":'), isNull);
      expect(extractServerDetail('{}'), isNull);
    });

    test('detail 是空串时退回 error', () {
      expect(extractServerDetail('{"error":"boom","detail":""}'), 'boom');
    });
  });
}
