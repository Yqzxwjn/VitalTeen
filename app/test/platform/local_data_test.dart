/// 「清除本机数据」的行为测试。
///
/// 只有几条，但它们各自都对应一个**用户能看见的坏结果**：
///
/// - 三样都成功 → `true`，调用方才会清空内存、回到首次填写；
/// - 一条失败 → `false`，调用方**不许动内存**（否则用户会看到「清干净了」，
///   重启之后资料又回来了）；
/// - **失败也不许短路** —— 短路的表现是「资料清掉了、历史还在」，
///   而用户以为三样都没了。
///
/// ## 为什么这里要三条通道全装
///
/// 这个文件里的假通道与别处不同：它**只有**「清」这一件事要测，
/// 所以三条都得装上，否则没装的那条走到 `MissingPluginException` 上、
/// 退化成 `false`，把每一次「都成功」都熏成失败 —— 这正是
/// 「清全部返回 true」那一条最初挂掉的原因。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/platform/local_data.dart';

const MethodChannel _profile = MethodChannel('vitalteen/profile');
const MethodChannel _history = MethodChannel('vitalteen/history');
const MethodChannel _avatar = MethodChannel('vitalteen/avatar');

/// 给三条通道各装一个假的，返回**按调用次数计的计数器**，并在用例结束时卸掉。
///
/// 计数器用闭包外面那几个变量（而不是一个返回值快照）：假通道是在 `await`
/// 期间被调到的，断言必须读到**调用之后**的值。
({
  int Function() profileCalls,
  int Function() historyCalls,
  int Function() avatarCalls,
  void Function() restore,
}) _fakeChannels({
  bool profileClears = true,
  bool historyClears = true,
  bool avatarClears = true,
}) {
  var profileCalls = 0;
  var historyCalls = 0;
  var avatarCalls = 0;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install(MethodChannel channel, bool clears, void Function() count) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clear') count();
      return clears;
    });
  }

  install(_profile, profileClears, () => profileCalls++);
  install(_history, historyClears, () => historyCalls++);
  install(_avatar, avatarClears, () => avatarCalls++);

  return (
    profileCalls: () => profileCalls,
    historyCalls: () => historyCalls,
    avatarCalls: () => avatarCalls,
    restore: () {
      for (final channel in [_profile, _history, _avatar]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('三样都清掉了：返回 true', () async {
    // 主机上没有这三条通道，所以「都成功」这一条必须靠假通道造出来。
    final fake = _fakeChannels();
    addTearDown(fake.restore);

    expect(await clearAllLocalData(), isTrue);
    expect(fake.profileCalls(), 1);
    expect(fake.historyCalls(), 1);
    expect(fake.avatarCalls(), 1, reason: '头像也是「本机数据」，不能漏');
  });

  test('资料清失败：返回 false，而且后面两样照样被调到了', () async {
    // **这一条测的是不短路。** 写成
    // `await clearProfileRaw() && await clearHistoryRaw()` 时，第一次失败会让
    // 第二次根本不发生 —— 于是一个「资料清掉了、历史还在」的半清状态
    // 被报成一次失败，而用户以为三样都没了。
    final fake = _fakeChannels(profileClears: false);
    addTearDown(fake.restore);

    expect(await clearAllLocalData(), isFalse);
    expect(fake.historyCalls(), 1, reason: '前一条失败不该拦住后一条');
    expect(fake.avatarCalls(), 1, reason: '前一条失败不该拦住后一条');
  });

  test('历史清失败：同样返回 false，头像照样被调到', () async {
    final fake = _fakeChannels(historyClears: false);
    addTearDown(fake.restore);

    expect(await clearAllLocalData(), isFalse);
    expect(fake.profileCalls(), 1);
    expect(fake.avatarCalls(), 1);
  });

  test('头像清失败：返回 false', () async {
    // **头像这一条最容易被漏掉** —— 它不在那个 prefs 文件里，而是私有目录里的
    // 一个文件。漏掉它的表现是「清除之后重填档案，头像从上一份资料里冒出来」，
    // 而那看起来像是没清干净，不像是一个漏写的 `&&`。
    final fake = _fakeChannels(avatarClears: false);
    addTearDown(fake.restore);

    expect(await clearAllLocalData(), isFalse);
    expect(fake.profileCalls(), 1);
  });

  test('三条通道都没有（主机上就是这样）：返回 false，不抛', () async {
    // 与 `profile_store_test.dart` 第一条同源：这条锁的是**其余所有主机测试
    // 的前提** —— 任何碰到「清除」的用例都不必先装 mock。
    expect(await clearAllLocalData(), isFalse);
  });
}
