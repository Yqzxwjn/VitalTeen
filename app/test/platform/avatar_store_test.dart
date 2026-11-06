/// 头像通道的契约：三个方法名、三种选图结果、以及**取消不是失败**。
///
/// 这一层与 `profile_store_test.dart` 同源：主机上没有 `vitalteen/avatar`
/// 这个通道，所以「没通道时静默降级且不假装成功」是其余主机测试的前提。
///
/// 而这个文件里真正值钱的是**取消那一条**。把「用户按了返回键」映射成
/// `failed`，界面上就会在每一次正常取消后弹一句「没能换头像」——
/// 而那种 bug 冒烟测试看不出来（不崩、不报错，只是每取消一次骂用户一句）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/platform/avatar_store.dart';

/// 给 `vitalteen/avatar` 装一个假盘，返回收到了哪些调用。
List<MethodCall> _fakeChannel(Object? Function(MethodCall call) reply) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vitalteen/avatar'),
    (call) async {
      calls.add(call);
      return reply(call);
    },
  );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vitalteen/avatar'), null);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('没有通道时（主机、桌面）', () {
    test('读路径给 null，不抛', () async {
      expect(await loadAvatarPath(), isNull);
    });

    test('换头像回 failed —— 不能假装换上了', () async {
      // 回 `picked` 的话，调用方会去重新读路径、读到 null，然后**什么都不说**：
      // 用户点了一次头像，界面闪都不闪一下。
      expect(await pickAvatar(), AvatarPickOutcome.failed);
    });

    test('清头像回 false —— 也不能假装清掉了', () async {
      expect(await clearAvatarRaw(), isFalse);
    });
  });

  group('选图结果的三态', () {
    test('picked 原样映射过来', () async {
      _fakeChannel((_) => 'picked');
      expect(await pickAvatar(), AvatarPickOutcome.picked);
    });

    test('cancelled 是 cancelled —— 这**不是**失败', () async {
      _fakeChannel((_) => 'cancelled');
      expect(
        await pickAvatar(),
        AvatarPickOutcome.cancelled,
        reason: '用户按了返回键，应用不该为此弹一句报错',
      );
    });

    test('failed 映射成 failed', () async {
      _fakeChannel((_) => 'failed');
      expect(await pickAvatar(), AvatarPickOutcome.failed);
    });

    test('原生给了个没见过的字符串 → failed，**不当成成功**', () async {
      // 协议两头对不上时，正确的结果是「换不了，并且说一声」，
      // 而不是静默地什么都不发生。
      _fakeChannel((_) => 'success');
      expect(await pickAvatar(), AvatarPickOutcome.failed);
    });

    test('原生返回 null → failed（比如它忘了 return）', () async {
      _fakeChannel((_) => null);
      expect(await pickAvatar(), AvatarPickOutcome.failed);
    });

    test('起选择器时原生抛异常 → failed，不把异常漏出去', () async {
      _fakeChannel((_) => throw PlatformException(code: 'boom'));
      expect(await pickAvatar(), AvatarPickOutcome.failed);
    });
  });

  group('路径', () {
    test('照原样搬字符串，不解析、不拼接', () async {
      // 路径怎么算出来是原生的事（应用私有目录在哪只有它知道）。
      // Dart 侧一旦开始拼路径，同一个位置就有了两个算法。
      _fakeChannel((_) => '/data/user/0/cn.vitalteen.vitalteen_app/files/a.jpg');
      expect(
        await loadAvatarPath(),
        '/data/user/0/cn.vitalteen.vitalteen_app/files/a.jpg',
      );
    });

    test('空串归一成 null —— 空路径拿去 Image.file 会抛', () async {
      _fakeChannel((_) => '');
      expect(await loadAvatarPath(), isNull);
    });

    test('走的是 path 这个方法名，且不带参数', () async {
      final calls = _fakeChannel((_) => null);
      await loadAvatarPath();
      expect(calls.single.method, 'path');
      expect(calls.single.arguments, isNull, reason: '只有一份头像，不需要点名');
    });
  });

  test('清除走的是 clear 这个方法名，且不带参数', () async {
    // 与 `profile_store_test.dart` 里那条同一个理由：名字是通道两侧唯一的约定，
    // 写错了表现是「用户看到没能清干净」，而与她做错了什么毫无关系。
    final calls = _fakeChannel((_) => true);
    expect(await clearAvatarRaw(), isTrue);
    expect(calls.single.method, 'clear');
    expect(calls.single.arguments, isNull);
  });

  test('清失败时回 false', () async {
    _fakeChannel((_) => false);
    expect(await clearAvatarRaw(), isFalse);
  });
}
