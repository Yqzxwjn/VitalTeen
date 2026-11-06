/// 文案模板装载与渲染的测试。
///
/// **这个文件的重点是 [MessageCatalog.render] 返回 `null` 的那两条路径**
/// （模板 ID 不认识、占位符填不上半个）。它们决定了「报告里会不会出现一个
/// 缺词的句子」，而缺词的句子不会报错、不会有异常、只会安静地错。
///
/// **「深蹲的每个错误码都有模板」不在这里测**，由 `server/tests/test_messages.py`
/// 负责：那边能拿到规则定义、能跑真实服务，端侧要做同一件事就得把
/// `msg_{code}_teen_v1` 这个命名约定再抄一遍 —— 抄一份就有两份会漂移。
/// 这里只认它拿到的那份文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/message_catalog.dart';

const String _path = 'assets/messages/teen_v1.json';
const String _sharedPath = '../shared/messages/teen_v1.json';

/// 一份够用的模板表：两条正常模板 + 一条只在部分 params 下填得满的 + 兜底。
const String _raw = '''
{
  "fallback_template_id": "msg_generic_teen_v1",
  "templates": {
    "msg_clean": {"text": "这一组 {total} 次里有 {valid} 次算数。", "reviewed": false},
    "msg_primary": {
      "text": "最需要先改的是{primary}，它在 {primary_count} 次里出现过。",
      "reviewed": true
    },
    "msg_generic_teen_v1": {"text": "共 {total} 次，{valid} 次算数。", "reviewed": false}
  }
}
''';

MessageCatalog _catalog([String raw = _raw]) =>
    parseMessageAsset(path: _path, raw: raw);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('挑文件', () {
    test('目录里只有一份时选它', () {
      expect(selectMessageAsset([_path]), _path);
    });

    test('目录为空时抛，且异常类型是文案层自己的', () {
      // 报错类型必须能被调用方按「是哪份资产」分辨。三个装载器都把
      // AssetCatalogException 换成自己的类型，正是为了这个。
      expect(
        () => selectMessageAsset(['AssetManifest.bin']),
        throwsA(
          isA<MessageCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(contains('assets/messages/'), contains('pubspec.yaml')),
          ),
        ),
      );
    });

    test('找到两份时抛，并把两份都列出来', () {
      expect(
        () => selectMessageAsset([
          'assets/messages/teen_v1.json',
          'assets/messages/teen_v2.json',
        ]),
        throwsA(
          isA<MessageCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(contains('2 份'), contains('teen_v1.json'), contains('teen_v2.json')),
          ),
        ),
      );
    });
  });

  group('装载时的不变量', () {
    test('兜底模板本身不在表里就直接抛', () {
      // 这是**装载期**的失败，不是渲染期的：兜底模板找不到 = 没有兜底，
      // 而那种错误的表现是「某个用户做完一组后界面上少一整段话」，
      // 中间没有任何东西会报错。等不到那时候，在这里炸。
      expect(
        () => _catalog('''
{
  "fallback_template_id": "msg_not_there",
  "templates": {"msg_clean": {"text": "{total}", "reviewed": false}}
}
'''),
        throwsA(
          isA<MessageCatalogException>().having(
            (e) => e.message,
            'message',
            contains('msg_not_there'),
          ),
        ),
      );
    });

    test('缺少 templates 或 fallback_template_id 都抛', () {
      expect(() => _catalog('{"templates": {}}'), throwsA(isA<MessageCatalogException>()));
      expect(
        () => _catalog('{"fallback_template_id": "x"}'),
        throwsA(isA<MessageCatalogException>()),
      );
    });

    test('模板条目缺 text 时抛，并指出是哪一个', () {
      expect(
        () => _catalog('{"fallback_template_id": "a", "templates": {"a": {"reviewed": true}}}'),
        throwsA(
          isA<MessageCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(contains('a'), contains('text')),
          ),
        ),
      );
    });

    test('缺 reviewed 按未评审算', () {
      // 保守方向：多一句「文案为草稿」比少一句好。
      final catalog = _catalog('''
{"fallback_template_id": "a", "templates": {"a": {"text": "{total}"}}}
''');
      expect(catalog.isReviewed('a'), isFalse);
    });

    test('未知 ID 视为未评审', () {
      expect(_catalog().isReviewed('msg_从没见过的'), isFalse);
    });

    test('坏 JSON 的报错带文件名', () {
      expect(
        () => _catalog('{ 这不是 json'),
        throwsA(
          isA<MessageCatalogException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });
  });

  group('填占位符', () {
    test('填得满就填', () {
      expect(
        _catalog().render('msg_clean', {'total': 10, 'valid': 8}),
        '这一组 10 次里有 8 次算数。',
      );
    });

    test('模板 ID 不认识时返回 null', () {
      expect(_catalog().render('msg_没有这个', {'total': 10, 'valid': 8}), isNull);
    });

    test('有一个占位符填不上就整句作废，不留下空格', () {
      // **这是本文件最要紧的一条。** 少一个 primary_count 的含义是
      // 「组级统计里没有这个码」，填 0 就是在编一个「一次都没出现」的事实；
      // 而不作废就会渲染成「它在 次里出现过」—— 一句没有任何异常、
      // 只是读起来别扭的错话。
      final rendered = _catalog().render('msg_primary', {
        'primary': '下蹲深度不足',
        // 故意不给 primary_count
      });
      expect(rendered, isNull);
    });

    test('多给的 params 不影响结果', () {
      expect(
        _catalog().render('msg_clean', {'total': 10, 'valid': 8, 'note': '没人用这个'}),
        '这一组 10 次里有 8 次算数。',
      );
    });

    test('整数形态的小数不留小数点', () {
      // params 走 JSON，服务端一个 int 到了 Dart 侧可能是 10.0。
      // 渲染成「这一组 10.0 次」读起来像机器写的。
      expect(
        _catalog().render('msg_clean', {'total': 10.0, 'valid': 8.0}),
        '这一组 10 次里有 8 次算数。',
      );
    });

    test('真的带小数时保留小数', () {
      expect(
        _catalog().render('msg_clean', {'total': 10.5, 'valid': 8}),
        '这一组 10.5 次里有 8 次算数。',
      );
    });
  });

  group('兜底', () {
    test('只有 total 与 valid 时兜底模板也填得满', () {
      // 兜底模板能用的占位符只有服务端无条件产出的那两个 —— 这是它能当
      // 兜底的前提，由 server/tests/test_messages.py 钉着。
      expect(
        _catalog().renderFallback({'total': 12, 'valid': 12}),
        '共 12 次，12 次算数。',
      );
    });

    test('连兜底要的参数都没有时返回 null，不抛', () {
      // 到这一步说明响应本身不合契约（服务端必然产出 total/valid），
      // 该由调用方决定显示什么，而不是让渲染炸掉一整屏。
      expect(_catalog().renderFallback(const {}), isNull);
    });
  });

  group('真读随包发布的那份', () {
    test('能从资源里读出来，且与 shared/ 下那份同源', () async {
      final loaded = await loadMessageCatalog();
      final onDisk = parseMessageAsset(
        path: _sharedPath,
        raw: File(_sharedPath).readAsStringSync(),
      );

      expect(
        loaded.templateIds.toSet(),
        onDisk.templateIds.toSet(),
        reason: '包里的文案表和 shared/messages/ 下的真源对不上，'
            '多半是改了真源没跑 scripts/sync_assets.py',
      );
      expect(loaded.fallbackTemplateId, onDisk.fallbackTemplateId);
    });

    test('兜底模板在真表里填得满，且用的是草稿措辞', () async {
      final catalog = await loadMessageCatalog();

      // 服务端必然产出这两个键，所以兜底永远渲染得出来 —— 若这条挂了，
      // 说明有人往兜底模板里塞了新的占位符。
      expect(
        catalog.renderFallback({'total': 10, 'valid': 9}),
        '这一组 10 次里有 9 次算数，下面是要留意的地方。',
      );
    });

    test('种子稿全部标着未评审', () async {
      // 文案尚未经传播学评审，报告页据此披露。等哪天真评了，
      // 这一条会红 —— 那时应当把 true 连同评审记录一起写进 JSON，
      // 而不是把断言删掉。
      final catalog = await loadMessageCatalog();
      for (final id in catalog.templateIds) {
        expect(catalog.isReviewed(id), isFalse, reason: '$id 标成了已评审');
      }
    });

    test('包里的正文与 shared/ 下那份逐字一致', () async {
      // 上面比的是 ID 集合，这里比正文：改一个字而没同步，上面那条不会红。
      final loaded = await loadMessageCatalog();
      final raw = jsonDecode(File(_sharedPath).readAsStringSync());
      final templates = (raw as Map<String, dynamic>)['templates'] as Map<String, dynamic>;

      for (final entry in templates.entries) {
        final text = (entry.value as Map<String, dynamic>)['text'] as String;
        // 用一条必然填得满的 params 把正文取出来比对。
        expect(
          loaded.render(
            entry.key,
            {
              for (final key in _placeholdersIn(text)) key: 'X',
            },
          ),
          text.replaceAllMapped(RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}'), (_) => 'X'),
          reason: '${entry.key} 的正文在包里和 shared/ 下不一致',
        );
      }
    });
  });
}

/// 取出模板里的占位符名。测试自己解析，不依赖被测实现的那份正则。
Iterable<String> _placeholdersIn(String text) => RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}')
    .allMatches(text)
    .map((match) => match.group(1)!);
