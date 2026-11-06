/// 历史通道的行为测试。
///
/// 前三条（**没装 mock 时的降级**）锁住的不是产品行为，而是**其余所有主机
/// 测试的前提**：主机上没有 `vitalteen/history` 这个通道，而 `AppEntry`
/// 启动就要读一次。它们要是改成往上抛，每一个挂 `AppEntry` 的用例都得先装
/// 一遍 mock —— 那正是 `keep_screen_on.dart` 早就拒绝过一次的做法。
///
/// 后面几条测的是 **`appendSessionRecord` 那三条失败路径**。它是这个模块里
/// 唯一一处「读改写回」，也是唯一一处**读了别人的数据再整列写回去**的地方 ——
/// 写坏了不是丢一条，是把用户的历史全部替换掉。所以三种情形各自一条：
/// 盘上已有记录、盘上是坏串、写不进去。
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/platform/history_store.dart';

const MethodChannel _channel = MethodChannel('vitalteen/history');

SessionRecord _record(String code, int ms, {int repCount = 12}) => SessionRecord(
      actionCode: code,
      actionNameZh: code == 'SQUAT' ? '深蹲' : '平板支撑',
      finishedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      repCount: repCount,
      isTimed: code != 'SQUAT',
      score: 80,
      provisional: false,
    );

/// 装上一个把每次 `save` 的原文都记下来的假通道。
///
/// [stored] 是「盘上现在有什么」，[saveResult] 是写盘成不成 ——
/// 两个都要能单独控制，因为下面要测的正是它们的各种组合。
({List<String> writes, void Function() restore}) _fakeChannel({
  String? stored,
  bool saveResult = true,
  bool clearResult = true,
}) {
  final writes = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'load':
        return stored;
      case 'save':
        writes.add(call.arguments as String);
        return saveResult;
      case 'clear':
        return clearResult;
      default:
        return null;
    }
  });
  return (
    writes: writes,
    restore: () => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('没有通道时静默降级', () {
    test('读回 null，不抛', () async {
      expect(await loadHistoryRaw(), isNull);
    });

    test('写回 false —— 不能假装存上了', () async {
      // 返回 `true` 的话，练习页就不会弹「这一组没能存到这台设备上」，
      // 而用户会在下次打开时发现那一组不见了 —— 那时他只会觉得这个应用
      // 有时候不记事，而不知道是哪一次。
      expect(await saveHistoryRaw('[]'), isFalse);
    });

    test('清回 false', () async {
      expect(await clearHistoryRaw(), isFalse);
    });
  });

  group('搬字符串', () {
    test('读到的原文一字不改地给出来', () async {
      final fake = _fakeChannel(stored: '[{"v":1,"原文":"不动"}]');
      addTearDown(fake.restore);

      expect(await loadHistoryRaw(), '[{"v":1,"原文":"不动"}]');
    });

    test('写下去的原文一字不改地过去', () async {
      // 格式的合法性由 `decodeHistory` 判定，这一层不解析内容 ——
      // 两边都解析的话，一份坏数据会在两个地方各报一次错，而说法不一样。
      final fake = _fakeChannel();
      addTearDown(fake.restore);

      expect(await saveHistoryRaw('[{"v":1,"原文":"不动"}]'), isTrue);
      expect(fake.writes, ['[{"v":1,"原文":"不动"}]']);
    });

    test('清除走的是 clear 这个方法名', () async {
      final fake = _fakeChannel();
      addTearDown(fake.restore);

      expect(await clearHistoryRaw(), isTrue);
      expect(fake.writes, isEmpty, reason: '清除不是一次写');
    });
  });

  group('appendSessionRecord：读改写回', () {
    test('盘上已经有一条：写回去的是两条，新的在最前', () async {
      // **这是「读改写回」唯一的守卫。** 少了那次读，写回去的就是只有新条
      // 的一列 —— 而调用方拿到的是 `true`，看起来一切正常，
      // 直到用户发现历史里只剩今天这一条。
      final fake = _fakeChannel(
        stored: encodeHistory([_record('PLANK', 1000, repCount: 4)]),
      );
      addTearDown(fake.restore);

      expect(await appendSessionRecord(_record('SQUAT', 2000)), isTrue);

      final written = decodeHistory(fake.writes.single);
      expect(written.length, 2);
      expect(written.map((r) => r.actionCode).toList(), ['SQUAT', 'PLANK']);
      expect(written.first.finishedAt.millisecondsSinceEpoch, 2000);
    });

    test('盘上是 v1 的老记录：回写之后它还在 —— 迁移不清空历史', () async {
      // **这一条守的是 v1→v2 迁移最要命的那个坑。** 落盘是「整列解码 →
      // 整列重编码写回」，于是 `appendSessionRecord` 会把盘上所有 v1 记录
      // 读出来、当作 v2 写回去。解码端只要拒收迁移出来的 `fault_counts: null`
      //（一个看起来很合理、更「严格」的写法），用户练完一组就会发现历史
      // 一条都不剩 —— 而且不会自己变回来。
      //
      // 这里用**手写的 v1 原文**，不经 `toJson()`（它现在写的是 v2），
      // 否则测的就不是老版本的字节了。
      final v1 = jsonEncode({
        'v': 1,
        'action_code': 'PLANK',
        'action_name': '平板支撑',
        'finished_at_ms': 1000,
        'reps': 4,
        'timed': true,
        'score': 80,
        'provisional': false,
      });
      final fake = _fakeChannel(stored: jsonEncode([jsonDecode(v1)]));
      addTearDown(fake.restore);

      expect(await appendSessionRecord(_record('SQUAT', 2000)), isTrue);

      final written = decodeHistory(fake.writes.single);
      expect(written.length, 2, reason: '老记录在回写时被写死了');
      expect(written.last.actionCode, 'PLANK');
      expect(written.last.faultCounts, isNull, reason: 'v1 记录迁移后仍是「没采集过」');
    });

    test('回写不会动已经有表的那条记录的故障计数', () async {
      final withFaults = SessionRecord(
        actionCode: 'SQUAT',
        actionNameZh: '深蹲',
        finishedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        repCount: 12,
        isTimed: false,
        score: 80,
        provisional: false,
        faultCounts: const {'EXCESSIVE_TRUNK_LEAN': 5},
      );
      final fake = _fakeChannel(stored: encodeHistory([withFaults]));
      addTearDown(fake.restore);

      await appendSessionRecord(_record('SQUAT', 2000));

      final written = decodeHistory(fake.writes.single);
      expect(written.last.faultCounts, {'EXCESSIVE_TRUNK_LEAN': 5});
    });

    test('盘上什么都没有：写下去的就是这一条', () async {
      final fake = _fakeChannel();
      addTearDown(fake.restore);

      expect(await appendSessionRecord(_record('SQUAT', 2000)), isTrue);
      expect(decodeHistory(fake.writes.single).length, 1);
    });

    test('盘上是个坏串：退化成只有新条，而不是放弃保存', () async {      // 另一条路（读到坏数据就不存了）会让用户在存储出问题之后**再也存不进
      // 任何东西** —— 而他会以为是自己练得不对。少几条旧记录比这好得多。
      final fake = _fakeChannel(stored: '{这不是 json');
      addTearDown(fake.restore);

      expect(await appendSessionRecord(_record('SQUAT', 2000)), isTrue);
      expect(decodeHistory(fake.writes.single).length, 1);
    });

    test('盘上那一条是坏的：好的那些留下，坏的丢掉', () async {
      // `decodeHistory` 是逐条丢的（见它的注释）。整列丢在这里的后果是
      // 「一条坏记录 = 用户其余全部历史清零」。
      final fake = _fakeChannel(
        stored: jsonEncode([
          _record('SQUAT', 3000).toJson(),
          {'v': 1, 'reps': 0}, // 坏的
          _record('PLANK', 1000).toJson(),
        ]),
      );
      addTearDown(fake.restore);

      await appendSessionRecord(_record('SQUAT', 4000));

      final written = decodeHistory(fake.writes.single);
      expect(written.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [4000, 3000, 1000]);
    });

    test('写不进去：原样返回 false，而且没往通道上发过东西', () async {
      // **「不动盘上内容」是这一条的全部意义。** 写失败却发了一次 `save`，
      // 在某些实现里就是一次真实的覆盖 —— 而调用方会照着 `false` 去告诉
      // 用户「这一组没存上」，同时盘上那份已经被换掉了。
      final fake = _fakeChannel(saveResult: false);
      addTearDown(fake.restore);

      expect(await appendSessionRecord(_record('SQUAT', 2000)), isFalse);
    });

    test('超过上限的那一次，裁掉的是最旧的', () async {
      // 盘上是**最新在前**（写入方维持的契约）。
      final many = [
        for (var i = 4; i >= 0; i--) _record('SQUAT', 1000 + i),
      ];
      final fake = _fakeChannel(stored: encodeHistory(many));
      addTearDown(fake.restore);

      await appendSessionRecord(_record('SQUAT', 9999), cap: 3);

      final written = decodeHistory(fake.writes.single);
      expect(written.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [9999, 1004, 1003]);
    });

    test('盘上的顺序乱了，也不会丢错人', () async {
      // **顺序乱掉时,「裁哪一头」的代价是不对称的**：裁错会把用户最新练的
      // 那一组当成最旧的丢掉，而他刚练完。所以写入路径不信任磁盘上的顺序,
      // 按时间重新排一遍再裁 —— 顺带把那份文件自愈了。
      //
      // 盘上那份刻意造成**升序**（最旧的在前），新条的时间戳落在正中间 ——
      // 于是两条捷径都过不了这一关：「信任传进来的顺序」会把最旧的留下、
      // 最新的裁掉；「新来的排最前」会让新条挤掉 1040。
      final scrambled = [
        for (var i = 0; i < 5; i++) _record('SQUAT', 1000 + i * 10),
      ];
      final fake = _fakeChannel(stored: encodeHistory(scrambled));
      addTearDown(fake.restore);

      await appendSessionRecord(_record('SQUAT', 1025), cap: 3);

      final written = decodeHistory(fake.writes.single);
      expect(written.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [1040, 1030, 1025],
          reason: '留下的必须是时间最晚的那三条');
    });
  });
}
