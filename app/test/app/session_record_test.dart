/// 练习记录的编解码测试。
///
/// 与 `profile_test.dart` 同一条主线：**读不出来时返回 `null` / 丢那一条，
/// 而不是抛**。区别在于历史是**一列**，所以这里多一整组测「一条坏的不许
/// 连累旁边那条好的」—— 整列丢的后果是「一次写坏 = 用户所有历史清零」，
/// 而那是这类功能里最难挽回的一种损失。
///
/// 第二条是**顺序**。`decodeHistory` 刻意不排序（理由写在它的注释里），
/// 于是「最新的在最前」这条不变式全靠 `appendToHistory` 维持 ——
/// 下面那两条测试就是它唯一的守卫。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/session_record.dart';

SessionRecord _record({
  String actionCode = 'SQUAT',
  String actionNameZh = '深蹲',
  DateTime? finishedAt,
  int repCount = 12,
  bool isTimed = false,
  int? score = 85,
  bool provisional = false,
  Map<String, int>? faultCounts,
}) {
  return SessionRecord(
    actionCode: actionCode,
    actionNameZh: actionNameZh,
    finishedAt:
        finishedAt ?? DateTime.fromMillisecondsSinceEpoch(1780598400000),
    repCount: repCount,
    isTimed: isTimed,
    score: score,
    provisional: provisional,
    faultCounts: faultCounts,
  );
}

/// 一条合法记录的 JSON，改动某几个键就是一类损坏。
Map<String, dynamic> _json({Map<String, dynamic>? override}) => {
      ..._record().toJson(),
      ...?override,
    };

/// 一列记录的磁盘格式。
String _listJson(List<Map<String, dynamic>> entries) => jsonEncode(entries);

void main() {
  group('编解码往返', () {
    test('七个字段一个不少地回来', () {
      final original = _record();
      final back = SessionRecord.decode(original.encode());

      expect(back, isNotNull);
      // 逐字段断言而不是「不为 null」：漏搬一个字段的表现是历史里那一栏空白，
      // 而测试全绿。
      expect(back!.actionCode, 'SQUAT');
      expect(back.actionNameZh, '深蹲');
      expect(back.finishedAt, original.finishedAt);
      expect(back.repCount, 12);
      expect(back.isTimed, isFalse);
      expect(back.score, 85);
      expect(back.provisional, isFalse);
    });

    test('没有分数的那一条也原样回来', () {
      // `score == null` 是**合法值**（一次都没打上分），不是损坏。
      // 这一条与下面「score 缺键也收下」是一对：两处都必须是收下。
      final back = SessionRecord.decode(_record(score: null).encode());
      expect(back, isNotNull);
      expect(back!.score, isNull);
      expect(back.provisional, isFalse);
    });

    test('暂定分与计时制动作都记得住', () {
      final back = SessionRecord.decode(_record(
        actionCode: 'PLANK',
        actionNameZh: '平板支撑',
        repCount: 4,
        isTimed: true,
        score: 72,
        provisional: true,
      ).encode());

      expect(back!.isTimed, isTrue, reason: '丢了它，界面会把「4 段」说成「4 个」');
      expect(back.provisional, isTrue,
          reason: '丢了它，一个暂定分会被显示成正式结论');
      expect(back.repCount, 4);
    });

    test('版本号是常量本身', () {
      // 锁住常量。写成别的值时，下一次启动会把它当未知版本丢掉。
      expect(jsonDecode(_record().encode())['v'], sessionRecordSchemaVersion);
      expect(sessionRecordSchemaVersion, 2);
    });
  });

  group('损坏的一条一律返回 null，而且不抛', () {
    // 每一类单独一条，理由与 `profile_test.dart` 那份一样：合并成一条
    // 「乱七八糟的输入」之后，新加一种损坏形态时没人会发现少了一种。
    final cases = <String, Map<String, dynamic>>{
      '版本号不认识': {'v': 3},
      '版本号是 0': {'v': 0},
      '版本号缺失': {'v': null},
      '动作码缺失': {'action_code': null},
      '动作码是空的': {'action_code': '   '},
      '动作码是数字': {'action_code': 42},
      '动作码长得不像动作码': {'action_code': 'S' * 41},
      '动作名缺失': {'action_name': null},
      '动作名是空的': {'action_name': ''},
      '结束时间缺失': {'finished_at_ms': null},
      // 0 是「这个键没被写进去」留下的默认值 —— 1970 年 1 月 1 日不是一次真实的练习。
      '结束时间是 0': {'finished_at_ms': 0},
      '结束时间是负数': {'finished_at_ms': -1},
      '结束时间是字符串': {'finished_at_ms': '1780598400000'},
      '次数是 0': {'reps': 0},
      '次数是负数': {'reps': -3},
      '次数是小数': {'reps': 12.0},
      '次数超护栏': {'reps': sessionRecordMaxReps + 1},
      '次数缺失': {'reps': null},
      '计时标志不是 bool': {'timed': 'false'},
      '计时标志缺失': {'timed': null},
      // 分数的定义域是 0–100。
      '分数是 101': {'score': 101},
      '分数是负数': {'score': -1},
      '分数是小数': {'score': 85.5},
      '分数是字符串': {'score': '85'},
      '暂定标志不是 bool': {'provisional': 0},
      '暂定标志缺失': {'provisional': null},
      // 故障表：**键在、值非 null 但读不出来**才是损坏（缺键 / null 是合法的，
      // 见下面那一组）。一份写坏的表说明这份数据不是我们写的 —— 丢整条。
      '故障表是数组': {'fault_counts': <Object?>[]},
      '故障表是字符串': {'fault_counts': 'EXCESSIVE_TRUNK_LEAN'},
      '故障计数是 0': {'fault_counts': {'EXCESSIVE_TRUNK_LEAN': 0}},
      '故障计数是负数': {'fault_counts': {'EXCESSIVE_TRUNK_LEAN': -1}},
      '故障计数是小数': {'fault_counts': {'EXCESSIVE_TRUNK_LEAN': 2.0}},
      '故障计数是字符串': {'fault_counts': {'EXCESSIVE_TRUNK_LEAN': '3'}},
      // 某个码命中的 rep 数不可能超过这一组数到的个数（默认 12）。
      '故障计数超过本组次数': {'fault_counts': {'EXCESSIVE_TRUNK_LEAN': 13}},
      '故障码是空的': {'fault_counts': {'   ': 2}},
      '故障码超长': {'fault_counts': {'S' * 41: 2}},
    };
    cases.forEach((name, override) {
      test('$name → null', () {
        expect(SessionRecord.decode(jsonEncode(_json(override: override))),
            isNull);
      });
    });

    test('分数这个键整个没了，也收下', () {
      // **这一条与 `profile.dart` 的昵称刻意不同。** 那边「键缺失」说明这份
      // 档案是被 v2 之前的版本写的，是一个可分辨的异常；这边 `null` 本身
      // 就是一个合法的领域值（这一组一次都没打上分），所以「缺键」与
      // 「值为 null」对任何消费方都是同一件事 —— 两个都收。
      final without = _json()..remove('score');
      expect(without.containsKey('score'), isFalse);
      final back = SessionRecord.decode(jsonEncode(without));
      expect(back, isNotNull);
      expect(back!.score, isNull);
    });

    test('护栏边界上的值收得下', () {
      // 只测「超一个被拒」不测「正好等于通过」的话，把判定写成 `<` 也能绿。
      for (final reps in const [1, sessionRecordMaxReps]) {
        expect(
          SessionRecord.decode(jsonEncode(_json(override: {'reps': reps}))),
          isNotNull,
          reason: '$reps 个',
        );
      }
      for (final score in const [0, sessionRecordMaxScore]) {
        final back = SessionRecord.decode(
            jsonEncode(_json(override: {'score': score})));
        expect(back, isNotNull, reason: '$score 分');
        expect(back!.score, score);
      }
    });

    test('坏记录不会让应用打不开 —— 逐类调用都不抛', () {
      // 上面每条断言的是「返回 null」，这一条断言的是**没有异常逃出来**：
      // 两者的区别是「测试绿」与「用户的手机绿」。
      for (final raw in <String?>[
        null,
        '',
        '{',
        'null',
        '[]',
        '{"v":1}',
        jsonEncode(_json(override: {'reps': <String>[]})),
      ]) {
        expect(() => SessionRecord.decode(raw), returnsNormally, reason: '$raw');
      }
    });
  });

  group('故障计数（v2）与 v1 迁移', () {
    /// 一条 **v1 记录在磁盘上真正的样子**：手写，不经过 `toJson()` ——
    /// 后者现在写的是 v2，用它造的「v1」会把被测的东西一起换掉。
    ///
    /// 注意它**根本没有 `fault_counts` 这个键**（不是值为 null）：
    /// 这才是老版本写在盘上的字节。
    String v1Raw({int score = 85}) => jsonEncode({
          'v': 1,
          'action_code': 'SQUAT',
          'action_name': '深蹲',
          'finished_at_ms': 1780598400000,
          'reps': 12,
          'timed': false,
          'score': score,
          'provisional': false,
        });

    test('v1 的记录还读得出来，七个字段一个不少', () {
      final back = SessionRecord.decode(v1Raw());
      expect(back, isNotNull, reason: '认不出 v1 就是存量历史当场清零');
      expect(back!.actionCode, 'SQUAT');
      expect(back.actionNameZh, '深蹲');
      expect(back.repCount, 12);
      expect(back.isTimed, isFalse);
      expect(back.score, 85);
      expect(back.provisional, isFalse);
      // **没采集过 = null**，不是空表。这条与下面「干净组是空表」是一对。
      expect(back.faultCounts, isNull);
    });

    test('v1 记录被重新编码之后再读，还是原样 —— 这是全案最要紧的一条', () {
      // 为什么它单独存在：`history_store.appendSessionRecord` 每次落盘都是
      // 「整列解码 → 整列重编码写回」。于是**下一次练完一组**就会把盘上所有
      // v1 记录读出来、当作 v2 写回去。
      //
      // 如果解码端拒收 `"fault_counts": null`（一个看起来更「严格」的写法），
      // 那一次回写就把全部存量历史变成读不回来的字节 —— 用户练完一组，
      // 历史里一条都不剩，而且不会自己变回来。
      final once = SessionRecord.decode(v1Raw());
      final twice = SessionRecord.decode(once!.encode());

      expect(twice, isNotNull, reason: '回写一次就把老记录写死了');
      expect(twice!.actionCode, once.actionCode);
      expect(twice.repCount, once.repCount);
      expect(twice.score, once.score);
      expect(twice.faultCounts, isNull);
    });

    test('v2 的表原样回来，顺序按次数降序、码升序', () {
      final back = SessionRecord.decode(_record(faultCounts: {
        'ASYMMETRY': 2,
        'EXCESSIVE_TRUNK_LEAN': 7,
        'HEEL_RISE': 7,
      }).encode());

      expect(back!.faultCounts, {
        // 同为 7：码升序（EXCESSIVE… 在 HEEL_RISE 之前）。
        'EXCESSIVE_TRUNK_LEAN': 7,
        'HEEL_RISE': 7,
        'ASYMMETRY': 2,
      });
      expect(back.faultCounts!.keys.toList(),
          ['EXCESSIVE_TRUNK_LEAN', 'HEEL_RISE', 'ASYMMETRY']);
    });

    test('编码出的字节是稳定的 —— 同一份内容两次写出同一个串', () {
      // 落盘是整列重写，字节不稳的话「盘上有没有变」这件事就没法判断。
      const faults = {'ASYMMETRY': 2, 'EXCESSIVE_TRUNK_LEAN': 7};
      final a = _record(faultCounts: faults).encode();
      final b = _record(faultCounts: faults).encode();
      expect(a, b);
    });

    test('空表与 null 分得开', () {
      // 这一对是整个功能的分母：空表 = 采集到了、这组很干净（进分母），
      // null = 没采集过、不知道（不进分母）。折平它们，体态页会把一批
      // 「不知道」当成「很干净」，于是出现率被系统性压低。
      final clean = SessionRecord.decode(_record(faultCounts: const {}).encode());
      final unknown = SessionRecord.decode(_record(faultCounts: null).encode());

      expect(clean!.faultCounts, isEmpty);
      expect(unknown!.faultCounts, isNull);
      expect(clean.faultCounts, isNot(unknown.faultCounts));
    });

    test('v2 记录缺这个键、或值为 null，都收下', () {
      for (final override in <Map<String, dynamic>>[
        <String, dynamic>{}, // 键整个不在
        {'fault_counts': null},
      ]) {
        final json = _json()..remove('fault_counts');
        json.addAll(override);
        final back = SessionRecord.decode(jsonEncode(json));
        expect(back, isNotNull, reason: '$override');
        expect(back!.faultCounts, isNull, reason: '$override');
      }
    });

    test('超过护栏只截断，整条记录还在', () {
      // 为几个多余的码抹掉用户一次真实的练习，代价远大于收益。
      final lots = <String, int>{
        for (var i = 0; i < sessionRecordMaxFaultCodes + 3; i++)
          'CODE_$i': i + 1,
      };
      final back = SessionRecord.decode(
          _record(repCount: 20, faultCounts: lots).encode());

      expect(back, isNotNull, reason: '表太长不该把整条记录丢掉');
      expect(back!.faultCounts!.length, sessionRecordMaxFaultCodes);
      // 留的是次数最高的那几个：CODE_14 的 count 是 15，往下排。
      expect(back.faultCounts!['CODE_14'], 15);
      expect(back.faultCounts!.containsKey('CODE_0'), isFalse);
    });

    test('护栏边界：正好等于上限时一个都不截', () {
      final exact = <String, int>{
        for (var i = 0; i < sessionRecordMaxFaultCodes; i++) 'CODE_$i': i + 1,
      };
      final back = SessionRecord.decode(
          _record(repCount: 20, faultCounts: exact).encode());
      expect(back!.faultCounts!.length, sessionRecordMaxFaultCodes);
    });
  });

  group('整列解码：只丢坏的那条', () {
    test('空 / 不是 JSON / 不是一个数组 → 空表', () {
      for (final raw in <String?>[null, '', '  ', '{这不是 json', '{}', '"SQUAT"']) {
        expect(decodeHistory(raw), isEmpty, reason: '$raw');
      }
    });

    test('一列好的全都读得出来，顺序原样保留', () {
      // **顺序是原样保留的**（`decodeHistory` 刻意不排序）。这条测试钉住它，
      // 是为了让「最新的在最前由写入方维持」这句话有一个具体的位置 ——
      // 哪天有人往这里加一句 `sort`，这条会红，而他会读到这里。
      final raw = _listJson([
        _json(override: {'finished_at_ms': 3000}),
        _json(override: {'finished_at_ms': 2000}),
        _json(override: {'finished_at_ms': 1000}),
      ]);

      final records = decodeHistory(raw);
      expect(records.length, 3);
      expect(records.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [3000, 2000, 1000]);
    });

    test('夹在中间的一条坏了，两边的还都在', () {
      final raw = _listJson([
        _json(override: {'finished_at_ms': 3000}),
        _json(override: {'reps': 0}),
        _json(override: {'finished_at_ms': 1000}),
      ]);

      final records = decodeHistory(raw);
      expect(records.length, 2, reason: '整列丢会让一次写坏等于历史清零');
      expect(records.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [3000, 1000]);
    });

    test('数组里混着不是对象的东西，跳过它', () {
      final raw = jsonEncode([_json(), 'SQUAT', 42, null, _json()]);
      expect(decodeHistory(raw).length, 2);
    });

    test('全坏 → 空表，不抛', () {
      final raw = _listJson([_json(override: {'reps': 0}), _json(override: {'v': 9})]);
      expect(decodeHistory(raw), isEmpty);
    });

    test('坏输入不会让应用打不开 —— 逐类调用都不抛', () {
      for (final raw in <String?>[
        null,
        '',
        '[',
        '[{}]',
        '[[1,2]]',
        '[{"v":1,"reps":"十二"}]',
      ]) {
        expect(() => decodeHistory(raw), returnsNormally, reason: '$raw');
      }
    });
  });

  group('往一列前面加一条', () {
    SessionRecord at(int ms) => _record(
          finishedAt: DateTime.fromMillisecondsSinceEpoch(ms),
        );

    test('新的排在最前', () {
      // 这一条是 `decodeHistory` 不排序的前提：顺序由这里维持。
      final next = appendToHistory([at(2000), at(1000)], at(3000));
      expect(next.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [3000, 2000, 1000]);
    });

    test('传进来的顺序是乱的，出去也是排好的', () {
      // **不信任传进来的顺序。** 契约没被违反时这一步白做；被违反时不做它的
      // 那个版本会把**用户最新练的那一组**当成最旧的裁掉（见上面那条 cap 测试），
      // 而违反契约根本不需要谁做错事：换一个写入顺序、一次写到一半的落盘、
      // 一个手工改过的文件都会造成它。
      final next = appendToHistory([at(1000), at(3000), at(2000)], at(2500));
      expect(next.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [3000, 2500, 2000, 1000]);
    });

    test('没超上限时一条都不丢', () {
      final next = appendToHistory([at(2000)], at(3000));
      expect(next.length, 2);
    });

    test('超上限时丢的是最旧的那些，不是最新那条', () {
      // cap=3 而不是默认的 200：这条测的是**裁哪一头**，
      // 用 200 会需要造 201 条记录，而它们读起来全都一样。
      final existing = [at(3000), at(2000), at(1000)];
      final next = appendToHistory(existing, at(4000), cap: 3);

      expect(next.length, 3);
      expect(next.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [4000, 3000, 2000], reason: '裁错一头会把用户刚练的那次丢掉');
    });

    test('不改传进来的那个列表', () {
      // 纯函数。它要是就地改了，`history_store.dart` 那条「读失败时退化成
      // 只有新条」的路径会把调用方手里那份也一起改掉。
      //
      // 传一个**乱的**列表：排序是后来才加进来的（见上面那条），
      // 而「先 `existing.sort()` 再拼」是这里最容易写出的实现 ——
      // 那样排序就落到了调用方那份上。这一条拦的正是它。
      final existing = [at(1000), at(3000)];
      appendToHistory(existing, at(2000));
      expect(existing.map((r) => r.finishedAt.millisecondsSinceEpoch).toList(),
          [1000, 3000], reason: '传进来那份的顺序与长度都不许变');
    });

    test('默认上限就是常量本身', () {
      final many = [for (var i = 0; i < historyRecordCap; i++) at(i + 1)];
      final next = appendToHistory(many, at(999999));
      expect(next.length, historyRecordCap);
      expect(next.first.finishedAt.millisecondsSinceEpoch, 999999);
      expect(historyRecordCap, 200);
    });
  });
}
