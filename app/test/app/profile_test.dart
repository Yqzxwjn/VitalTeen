/// 资料档案的编解码测试。
///
/// **这里最要紧的一条是「读不出来时返回 null，而不是抛」。** 档案存在磁盘上，
/// 它会因为卸载重装、系统清理、上一次写到一半断电而变成任何形状。一个
/// `decode` 里没接住的类型转换，代价是**应用一打开就崩** —— 而用户唯一的
/// 自救手段是清数据。所以下面每一类损坏都单独列一条，而不是合并成一条
/// 「乱七八糟的输入」：合并之后，新加一种损坏形态时没人会发现少了一种。
///
/// 第二条是**边界**。年龄 5–25 是契约的硬区间，资料页收下一份 4 岁的档案，
/// 用户会在按下「分析这一组」时被面板拒收 —— 而那一刻离病因已经很远了。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/profile.dart';

Profile _profile({
  String nickname = '',
  Sex sex = Sex.female,
  int age = 16,
  String grade = '高一',
  String standardGroup = '高中女子',
  int heightCm = 165,
  double weightKg = 52.5,
  DateTime? updatedAt,
}) {
  return Profile(
    nickname: nickname,
    sex: sex,
    age: age,
    grade: grade,
    standardGroup: standardGroup,
    heightCm: heightCm,
    weightKg: weightKg,
    updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(1780598400000),
  );
}

/// 一份合法档案的 JSON，改动某几个键就是一类损坏。
Map<String, dynamic> _json({Map<String, dynamic>? override}) => {
      ..._profile().toJson(),
      ...?override,
    };

/// 一份 v1 时代的档案：**没有 `nickname` 这个键**。
///
/// 这里**手写一份字面量，而不是拿 `_json()` 删掉一个键**，理由是这份东西的
/// 全部意义就在于「它长得和当年那个版本写下去的一模一样」。从当前格式反推出来的
/// v1 会随着当前格式一起变 —— 哪天字段再改一次，这条测试会跟着改，于是它测的
/// 永远是「当前格式」而不是「迁移」。
Map<String, dynamic> _v1Json() => {
      'v': 1,
      'sex': 'female',
      'age': 16,
      'grade': '高一',
      'standard_group': '高中女子',
      'height_cm': 165,
      'weight_kg': 52.5,
      'updated_at_ms': 1780598400000,
    };

void main() {
  group('编解码往返', () {
    test('六个字段与填写时间都能原样回来', () {
      final original = _profile();
      final back = Profile.decode(original.encode());

      expect(back, isNotNull);
      expect(back!.sex, Sex.female);
      expect(back.age, 16);
      expect(back.grade, '高一');
      expect(back.standardGroup, '高中女子');
      // 少写一个字段在运行时是看不出来的：资料页只会显示一个空框，
      // 而那条记录明明是从这台手机里读出来的 —— 用户会以为自己填丢了。
      expect(back.heightCm, 165);
      expect(back.weightKg, 52.5);
      expect(back.updatedAt, original.updatedAt);
    });

    test('体重是整数时也读得回来', () {
      // jsonEncode(52.0) 出去是 `52.0`，但一份被人手改过或由别的版本写下的
      // 档案里可能是 `52`。dart:convert 读回来会是 int —— 于是 `is double`
      // 那一支漏掉它，档案被判为损坏，用户被要求重填一遍。
      final back = Profile.decode(jsonEncode(_json(override: {'weight_kg': 52})));
      expect(back?.weightKg, 52.0);
    });

    test('两端的空白被去掉', () {
      final back =
          Profile.decode(jsonEncode(_json(override: {'grade': '  高一  '})));
      expect(back?.grade, '高一');
    });

    test('昵称也原样回来', () {
      final original = _profile(nickname: '小陈');
      expect(Profile.decode(original.encode())?.nickname, '小陈');
    });
  });

  group('v1 档案的迁移', () {
    // 这一组是 v2 存在的**唯一理由**。加昵称本身是一行字段的事，
    // 但 `decode` 原先的规矩是「版本号不等于当前值就返回 null」——
    // 那条规矩撞上「加了一个字段」时，后果是**所有存量用户的资料在升级后
    // 静默消失**：应用会把他们当新用户再问一遍，而他们填完也不知道
    // 刚才发生了什么。所以这一组测的不是「能不能读 v1」，
    // 而是「读 v1 时不许丢任何已有的东西」。

    test('v1 读得进来，昵称是空的', () {
      final back = Profile.decode(jsonEncode(_v1Json()));

      expect(back, isNotNull, reason: 'v1 必须被认识，否则存量资料全部作废');
      expect(back!.nickname, '');
      // **逐字段断言，不用「不为 null」代替。** 迁移最容易出的错是
      // 「版本号认了、但某个字段忘了搬」—— 那只表现为用户打开应用发现
      // 身高空了，而测试全绿。
      expect(back.sex, Sex.female);
      expect(back.age, 16);
      expect(back.grade, '高一');
      expect(back.standardGroup, '高中女子');
      expect(back.heightCm, 165);
      expect(back.weightKg, 52.5);
      expect(back.updatedAt,
          DateTime.fromMillisecondsSinceEpoch(1780598400000));
    });

    test('v1 读出来之后按 v2 写回去，再读还是同一份', () {
      // 迁移的真实路径是「读 v1 → 用户什么都不改就保存 → 写 v2」。
      // 这一条走完整圈：如果 `toJson` 漏写 `nickname`，第二步会读不出来。
      final migrated = Profile.decode(jsonEncode(_v1Json()))!;
      final again = Profile.decode(migrated.encode());

      expect(again, isNotNull);
      expect(again!.nickname, '');
      expect(again.heightCm, 165);
      expect(again.weightKg, 52.5);
    });

    test('v2 写出来的档案，版本号真的是 2', () {
      // 锁住常量本身。写成 1 的话，下次启动会把它当 v1 读 ——
      // 而 v1 那条路径**不读 `nickname`**，用户刚填的昵称会安静地没掉。
      expect(jsonDecode(_profile(nickname: '小陈').encode())['v'], 2);
    });
  });

  group('昵称的边界', () {
    test('留空是合法的', () {
      // 空是「还没填」，不是损坏。把这两种情形混起来，用户清空昵称
      // 再保存，下次打开会发现自己被当成没填过资料的人。
      expect(Profile.decode(jsonEncode(_json(override: {'nickname': ''}))),
          isNotNull);
      // 全是空格的昵称读出来是空串，不是「空格」——资料页的输入框会把
      // `'   '` 原样交上来（`_submit` 里 trim 过，但存储可能来自别的路径）。
      expect(Profile.decode(jsonEncode(_json(override: {'nickname': '   '})))
          ?.nickname, '');
    });

    test('超过 12 个字被拒，正好 12 个字收下', () {
      // 上下限写在这里而不是从 `profileNicknameMaxLength` 取：这条测试的作用
      // 正是**锁住**那个常量，从常量取就成了自己证明自己。
      expect(
        Profile.decode(jsonEncode(_json(override: {'nickname': '陈' * 13}))),
        isNull,
      );
      expect(
        Profile.decode(jsonEncode(_json(override: {'nickname': '陈' * 12})))
            ?.nickname,
        '陈' * 12,
      );
      expect(profileNicknameMaxLength, 12);
    });

    test('昵称不是字符串被拒', () {
      for (final bad in <Object?>[42, true, <String>[]]) {
        expect(
          Profile.decode(jsonEncode(_json(override: {'nickname': bad}))),
          isNull,
          reason: '$bad',
        );
      }
    });

    test('没填昵称时称呼是「同学」，填了就用昵称', () {
      expect(profileDisplayName(_profile()), '同学');
      expect(profileDisplayName(_profile(nickname: '小陈')), '小陈');
    });
  });

  group('损坏的档案一律返回 null，而且不抛', () {
    // 每一类单独一条：合并成一条「乱七八糟的输入」之后，
    // 新加一种损坏形态时没人会发现少了一种。
    final cases = <String, String?>{
      '没存过': null,
      '空串': '',
      '不是 JSON': '{这不是 json',
      'JSON 但不是一个对象': '[1,2,3]',
      // v1 与 v2 都认识（见下面那一组迁移测试），所以「不认识」要拿 3 来试。
      '版本号不认识': jsonEncode(_json(override: {'v': 3})),
      '版本号是 0': jsonEncode(_json(override: {'v': 0})),
      '版本号缺失': jsonEncode(_json(override: {'v': null})),
      // v2 里 `nickname` 这个键**必须存在**：它缺失说明这份档案是被写坏了，
      // 而不是「用户没填」。用户没填写出来的是 `""`，两者必须分得开。
      'v2 但昵称这个键没了': jsonEncode(_json(override: {'nickname': null})),
      '性别不是枚举值': jsonEncode(_json(override: {'sex': 'other'})),
      '性别缺失': jsonEncode(_json(override: {'sex': null})),
      '年龄不是数字': jsonEncode(_json(override: {'age': '16'})),
      '年级是空的': jsonEncode(_json(override: {'grade': '   '})),
      '国标组别缺失': jsonEncode(_json(override: {'standard_group': null})),
      '身高是小数': jsonEncode(_json(override: {'height_cm': 165.5})),
      '填写时间缺失': jsonEncode(_json(override: {'updated_at_ms': null})),
    };
    cases.forEach((name, raw) {
      test('$name → null', () {
        expect(Profile.decode(raw), isNull);
      });
    });

    test('数值越界的一律拒绝', () {
      // 上下限写在这里而不是从常量取：这条测试的作用正是**锁住**那两个常量，
      // 从常量取就成了自己证明自己。
      final outOfRange = <String, Map<String, dynamic>>{
        '年龄小于 5': {'age': 4},
        '年龄大于 25': {'age': 26},
        '身高为 0': {'height_cm': 0},
        '身高 1650（多打一个 0）': {'height_cm': 1650},
        '体重为 0': {'weight_kg': 0},
        '体重 520': {'weight_kg': 520},
      };
      outOfRange.forEach((name, override) {
        expect(Profile.decode(jsonEncode(_json(override: override))), isNull,
            reason: name);
      });

      // NaN 与无穷**没法用 jsonEncode 造出来**（JSON 没有这两个字面量，
      // jsonEncode 自己就抛了）。但一个溢出到无穷的数可以 —— `1e400` 是合法
      // JSON，dart:convert 把它读成 Infinity。所以这一条走原始字符串，
      // 而不是拼一个 Map：拼接的那条路根本到不了 decode。
      final raw = jsonEncode(_json()).replaceFirst('52.5', '1e400');
      expect(raw, contains('1e400'));
      expect(Profile.decode(raw), isNull);
    });

    test('边界上的值收得下', () {
      // 上下限本身是合法的 —— 只测「4 被拒」不测「5 通过」的话，
      // 把判定写成 `<=` 也能绿。
      for (final (age, height, weight) in const [(5, 80, 15.0), (25, 250, 200.0)]) {
        final back = Profile.decode(jsonEncode(_json(override: {
          'age': age,
          'height_cm': height,
          'weight_kg': weight,
        })));
        expect(back, isNotNull, reason: '年龄 $age 应当收得下');
        expect(back!.age, age);
      }
    });

    test('年级超过 20 个字被拒', () {
      // 契约对这两个字段的约束是 1–20 字符（DecisionContext）。资料页收下
      // 一个 30 字的年级，生成的请求会被服务端 400 —— 病因离这里很远。
      expect(
        Profile.decode(jsonEncode(_json(override: {'grade': '高' * 21}))),
        isNull,
      );
      expect(
        Profile.decode(jsonEncode(_json(override: {'grade': '高' * 20}))),
        isNotNull,
      );
    });

    test('坏档案不会让应用打不开 —— 逐类调用都不抛', () {
      // 上面每一条都断言了「返回 null」，这一条断言的是**没有异常逃出来**：
      // 两者的区别是「测试绿」与「用户的手机绿」。
      for (final raw in <String?>[
        null,
        '',
        '{',
        'null',
        '{"v":1}',
        jsonEncode(_json(override: {'weight_kg': 'abc'})),
      ]) {
        expect(() => Profile.decode(raw), returnsNormally, reason: '$raw');
      }
    });
  });

  group('资料该不该复核', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1780000000000);

    test('填了不到一年：不提示', () {
      for (final days in const [0, 30, 364]) {
        final p = _profile(updatedAt: now.subtract(Duration(days: days)));
        expect(needsProfileRefresh(p, now), isFalse, reason: '$days 天');
      }
    });

    test('满一年：提示', () {
      // 判据是「满一年则年龄必然至少长了一岁」—— 这是唯一一条能从存储本身
      // 推出来的陈旧结论。364 与 365 各测一次，免得把边界写成 `>` 也没人发现。
      for (final days in const [365, 400, 1000]) {
        final p = _profile(updatedAt: now.subtract(Duration(days: days)));
        expect(needsProfileRefresh(p, now), isTrue, reason: '$days 天');
      }
    });
  });

  group('年龄区间只有一份', () {
    test('资料用的就是契约那一对常量', () {
      // 资料页、面板、decode 三处都引 decisionAgeMin/Max。谁要是把手写一遍，
      // 就会出现「资料收得下、面板拒收」的档案 —— 那条断言在这里。
      expect(decisionAgeMin, 5);
      expect(decisionAgeMax, 25);
      expect(Profile.decode(jsonEncode(_json(override: {'age': decisionAgeMin - 1}))),
          isNull);
      expect(Profile.decode(jsonEncode(_json(override: {'age': decisionAgeMax + 1}))),
          isNull);
    });
  });

  group('国标组别按年龄性别自动分', () {
    test('学段按年龄分档，性别接在后面', () {
      expect(standardGroupFor(sex: Sex.male, age: 7), '小学一二年级男子');
      expect(standardGroupFor(sex: Sex.female, age: 9), '小学三四年级女子');
      expect(standardGroupFor(sex: Sex.male, age: 12), '小学五六年级男子');
      expect(standardGroupFor(sex: Sex.female, age: 13), '初中女子');
      expect(standardGroupFor(sex: Sex.male, age: 15), '初中男子');
      expect(standardGroupFor(sex: Sex.female, age: 16), '高中女子');
      expect(standardGroupFor(sex: Sex.male, age: 18), '高中男子');
      expect(standardGroupFor(sex: Sex.female, age: 19), '大学女子');
      expect(standardGroupFor(sex: Sex.male, age: decisionAgeMax), '大学男子');
    });

    test('每个年龄都能分出一档，不会漏到空字符串', () {
      // 分档写漏一个区间的话，值会是「男子」这种没有学段的东西 ——
      // 而它照样能存进档案、照样发给决策服务，没人会拦。
      for (var age = decisionAgeMin; age <= decisionAgeMax; age++) {
        for (final sex in Sex.values) {
          final group = standardGroupFor(sex: sex, age: age);
          expect(
            group,
            anyOf(
              startsWith('小'),
              startsWith('初'),
              startsWith('高'),
              startsWith('大'),
            ),
            reason: '$age 岁 $sex 分成了「$group」',
          );
          expect(group, endsWith(sex == Sex.male ? '男子' : '女子'));
          expect(group.length, lessThanOrEqualTo(20),
              reason: '服务端 standard_group 上限是 20 个字');
        }
      }
    });
  });
}
