/// 资料通道**没装 mock** 时的行为。
///
/// 这一条锁住的不是产品行为，而是**其余所有主机测试的前提**：主机上没有
/// `vitalteen/profile` 这个通道，于是任何碰到它的页面（`AppEntry` 启动就要读一次）
/// 都会走到 `MissingPluginException`。如果这里改成往上抛，那每一个挂
/// `VitalTeenApp` 的用例都得先装一遍 mock —— 而那正是 `keep_screen_on.dart`
/// 早就拒绝过一次的做法。
///
/// 所以这里断言的是「静默降级，但不假装成功」：
/// 读不出来＝没有资料（问一次），写不进去＝`false`（要告诉用户）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/platform/profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没有通道时读回 null，不抛', () async {
    expect(await loadProfileRaw(), isNull);
  });

  test('没有通道时写回 false —— 不能假装存上了', () async {
    // 返回 `true` 的话，资料页就不会弹「没能存到这台设备上」那句提示，
    // 而用户会在下次打开时发现又要重填一遍 —— 那时他只会觉得这个应用记不住事。
    expect(await saveProfileRaw('{"v":1}'), isFalse);
  });

  test('没有通道时清回 false —— 也不能假装清掉了', () async {
    // 说「清掉了」而实际没清，后果比清不掉更糟：用户以为资料已经不在
    // 这台设备上了，下次打开时它自己回来了 —— 那看起来像见鬼。
    expect(await clearProfileRaw(), isFalse);
  });

  test('装上了通道就照原样搬字符串，不解析内容', () async {
    // 这一层只搬字符串：格式的合法性由 `Profile.decode` 判定。
    // 两边都解析的话，一份坏档案会在两个地方各报一次错，而说法不一样。
    // 只记「写」的那一次：`load` 不带参数，混在一起断言会把两种调用
    // 当成同一件事，而它们恰恰是这个模块的两半。
    final written = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('vitalteen/profile'),
      (call) async {
        if (call.method == 'save') written.add(call.arguments as String?);
        return call.method == 'load' ? '{"原文":"不动"}' : true;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vitalteen/profile'),
        null,
      );
    });

    expect(await loadProfileRaw(), '{"原文":"不动"}');
    expect(await saveProfileRaw('{"原文":"不动"}'), isTrue);
    expect(written, ['{"原文":"不动"}']);
  });

  test('清除走的是 clear 这个方法名，且不带参数', () async {
    // 方法名写错（比如写成 `delete`）的表现是原生侧 `notImplemented`，
    // 这里拿到 null → `false` → 用户看到「没能清干净」—— 而那与她做错了
    // 什么毫无关系。名字是这条通道两侧唯一的约定，所以在这里钉住。
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('vitalteen/profile'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('vitalteen/profile'),
        null,
      );
    });

    expect(await clearProfileRaw(), isTrue);
    expect(calls.single.method, 'clear');
    expect(calls.single.arguments, isNull,
        reason: '删的是哪个键由原生侧决定，Dart 侧不该知道');
  });
}
