/// 方案库装载的测试。
///
/// **两条不变量在这里被钉死，因为它们的失效都不会报错：**
///
/// 1. **未知 `plan_id` 返回 `null` 而不是抛异常** —— 包里的快照落后于服务端
///    时，用户该看到「这条建议不在本应用的方案库中」，而不是整份报告消失。
/// 2. **`isRatified` 只认 `active`** —— 服务端将来新增一个状态时，端侧要往
///    「未核定」这一侧错。反过来（把不认识的当成已核定）会让一份没人核定过的
///    训练剂量看起来像有依据的。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';

const String _path = 'assets/plans/plan_library.json';
const String _sharedPath = '../shared/plans/plan_library.json';

/// 两条方案 + 一条状态认不出来的，够把查表与核定的行为说清楚。
const String _raw = '''
{
  "plans": [
    {
      "plan_id": "COR_A", "name_zh": "甲", "goal": "目的甲",
      "instructions": ["第一步"], "key_cues": ["提示"],
      "equipment": [], "contraindications": ["疼就停"],
      "status": "active", "dosage_text": "3 组 × 12 次", "dosage_ratified": true,
      "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
      "age_min": 12, "age_max": 18
    },
    {
      "plan_id": "COR_B", "name_zh": "乙", "goal": "目的乙",
      "instructions": ["第一步", "第二步"], "key_cues": [],
      "equipment": ["弹力带"], "contraindications": ["腰部不适时不做"],
      "status": "draft", "dosage_text": "剂量待体育专业成员核定",
      "dosage_ratified": false,
      "target_fault_codes": ["KNEE_VALGUS", "ASYMMETRY"], "difficulty": 2,
      "age_min": 12, "age_max": 18
    },
    {
      "plan_id": "COR_C", "name_zh": "丙", "goal": "目的丙",
      "instructions": ["第一步"], "key_cues": [],
      "equipment": [], "contraindications": ["疼就停"],
      "status": "将来才有的状态", "dosage_text": "剂量待体育专业成员核定",
      "dosage_ratified": false,
      "target_fault_codes": ["HEEL_RISE"], "difficulty": 1,
      "age_min": 12, "age_max": 18
    }
  ]
}
''';

PlanCatalog _catalog([String raw = _raw]) => parsePlanAsset(path: _path, raw: raw);

/// 一条字段齐全的方案，供改单个字段的用例打底。
String _onePlan({String id = 'COR_X', String extra = ''}) => '''
{
  "plans": [
    {
      "plan_id": "$id", "name_zh": "甲", "goal": "目的",
      "instructions": [], "key_cues": [], "equipment": [],
      "contraindications": [], "status": "draft",
      "dosage_text": "待核定", "dosage_ratified": false,
      "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
      "age_min": 12, "age_max": 18
      $extra
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('挑文件', () {
    test('目录里只有一份时选它', () {
      expect(selectPlanAsset([_path]), _path);
    });

    test('目录为空时抛，且异常类型是方案库自己的', () {
      expect(
        () => selectPlanAsset(['AssetManifest.bin']),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(contains('assets/plans/'), contains('pubspec.yaml')),
          ),
        ),
      );
    });

    test('找到两份时抛，并把两份都列出来', () {
      expect(
        () => selectPlanAsset([
          'assets/plans/plan_library.json',
          'assets/plans/plan_library_old.json',
        ]),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(contains('2 份'), contains('plan_library.json')),
          ),
        ),
      );
    });
  });

  group('查表', () {
    test('按 ID 取到全部字段', () {
      final plan = _catalog().byId('COR_B')!;
      expect(plan.nameZh, '乙');
      expect(plan.goal, '目的乙');
      expect(plan.instructions, ['第一步', '第二步']);
      expect(plan.keyCues, isEmpty);
      expect(plan.equipment, ['弹力带']);
      expect(plan.contraindications, ['腰部不适时不做']);
      expect(plan.dosageText, '剂量待体育专业成员核定');
      expect(plan.dosageRatified, isFalse);
    });

    test('未知 ID 返回 null，不抛', () {
      // 包内快照落后于服务端时，这是**一个可显示的状态**。
      // 改成抛异常会让整份报告消失，而用户本来还能看到其余部分。
      expect(_catalog().byId('COR_服务端刚加的'), isNull);
    });

    test('plan_id 重复时抛', () {
      // 历史记录里存的是 ID。两条方案共用一个 ID 时，
      // 「当时推荐的是哪一套」就再也追溯不回来了。
      expect(
        () => _catalog('''
{"plans": [
  {"plan_id": "COR_A", "name_zh": "甲", "goal": "g", "instructions": [],
   "key_cues": [], "equipment": [], "contraindications": [],
   "status": "draft", "dosage_text": "d", "dosage_ratified": false,
   "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
   "age_min": 12, "age_max": 18},
  {"plan_id": "COR_A", "name_zh": "甲的同名兄弟", "goal": "g", "instructions": [],
   "key_cues": [], "equipment": [], "contraindications": [],
   "status": "draft", "dosage_text": "d", "dosage_ratified": false,
   "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
   "age_min": 12, "age_max": 18}
]}
'''),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            contains('COR_A'),
          ),
        ),
      );
    });
  });

  group('核定状态', () {
    test('只有 active 算已核定', () {
      final catalog = _catalog();
      expect(catalog.byId('COR_A')!.isRatified, isTrue);
      expect(catalog.byId('COR_B')!.isRatified, isFalse);
    });

    test('认不出来的状态按未核定算', () {
      // 朝着保守的方向失败：把 `deprecated` 或将来某个新状态当成已核定，
      // 会让一份没人核定过的处方看起来像有依据的。
      final catalog = _catalog();
      expect(catalog.byId('COR_C')!.isRatified, isFalse);
    });

    test('未核定时剂量文案照实保留', () {
      // 界面不能因为「剂量待核定」是句套话就把这一行省掉 ——
      // 省掉会让人以为这个动作没有剂量要求。
      expect(_catalog().byId('COR_B')!.dosageText, isNotEmpty);
    });
  });

  group('解析', () {
    test('坏 JSON 的报错带文件名', () {
      expect(
        () => _catalog('{ 这不是 json'),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });

    test('缺 plans 数组时报错并带文件名', () {
      expect(
        () => _catalog('{"_comment": "只有注释"}'),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith(_path), contains('plans')),
          ),
        ),
      );
    });

    test('缺字段的条目报错，而不是当成空串塞进去', () {
      // 空串会一路渲染到界面上：一张没有「动作要领」也没有「禁忌」的卡片，
      // 看起来像这份方案本来就没写，而不是数据坏了。
      expect(
        () => _catalog('{"plans": [{"plan_id": "COR_X", "name_zh": "甲"}]}'),
        throwsA(isA<PlanCatalogException>()),
      );
    });

    test('instructions 不是数组时报错', () {
      expect(
        () => _catalog(_onePlan(extra: '').replaceFirst('"instructions": []', '"instructions": "第一步"')),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            contains('数组'),
          ),
        ),
      );
    });

    test('字段类型不对的报错带文件名', () {
      expect(
        () => _catalog(_onePlan().replaceFirst('"dosage_ratified": false', '"dosage_ratified": "false"')),
        throwsA(
          isA<PlanCatalogException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });
  });

  group('真读随包发布的那份', () {
    test('能从资源里读出来，且与 shared/ 下那份同源', () async {
      final loaded = await loadPlanCatalog();
      final onDisk = parsePlanAsset(
        path: _sharedPath,
        raw: File(_sharedPath).readAsStringSync(),
      );

      expect(loaded.length, onDisk.length);
      for (final plan in ['COR_BOX_SQUAT', 'COR_KNEE_TO_WALL', 'COR_TEMPO_SQUAT']) {
        expect(loaded.byId(plan), isNotNull, reason: '$plan 应该在导出的方案库里');
      }
    });

    test('每条都至少有一条禁忌', () async {
      // 这是青少年使用场景，禁忌是必显项。一条没有禁忌的方案在界面上
      // 会渲染成一块空白，而空白看起来像「这个动作没有要注意的」。
      final catalog = await loadPlanCatalog();
      final raw = File(_sharedPath).readAsStringSync();
      // **仍然从原始文本里数一遍 ID，虽然 `PlanCatalog.all` 已经能遍历。**
      // 用 `all` 的话，这条测试就变成了「解析器读出来的那些条目都有禁忌」——
      // 而解析器悄悄漏掉一条时，它照样绿。从文本里数，才有「文件里的每一条都在」
      // 这个更强的断言（下面 `ids.length == catalog.length` 就是那个等号）。
      final ids = RegExp(r'"plan_id":\s*"([A-Z_0-9]+)"')
          .allMatches(raw)
          .map((match) => match.group(1)!)
          .toList();

      expect(ids.length, catalog.length);
      for (final id in ids) {
        expect(
          catalog.byId(id)!.contraindications,
          isNotEmpty,
          reason: '$id 没有禁忌',
        );
      }
    });

    test('剂量文案一条都不为空', () async {
      // 未核定时它是句套话，但**必须显示**：省略会让人以为这个动作没有剂量要求。
      final catalog = await loadPlanCatalog();
      final ids = RegExp(r'"plan_id":\s*"([A-Z_0-9]+)"')
          .allMatches(File(_sharedPath).readAsStringSync())
          .map((match) => match.group(1)!);

      for (final id in ids) {
        expect(catalog.byId(id)!.dosageText, isNotEmpty, reason: '$id 没有剂量文案');
      }
    });
  });

  group('断网时的方案筛选', () {
    // 六条方案，把筛选与排序的每一维都摆开。库顺序刻意与期望顺序**不同** ——
    // 排序键是三级全序（plan_id 不重复），结果不该取决于谁先谁后。
    //
    // **只有 COR_M_ACTIVE 是已核定，而它针对的是 HEEL_RISE** —— 这一点是刻意的。
    // 让它覆盖 KNEE_VALGUS 的话，下面大多数用例会在「已核定那一遍」就短路返回，
    // 真正要测的回退那一遍根本跑不起来，测试会全绿地什么都没测到。
    //
    // 三级键各埋了一处反例，少比一级就会排错：
    //   覆盖数 —— COR_Z 难度 3，靠覆盖 2 个码排在最前；
    //   难度   —— COR_Y 与 COR_B 覆盖数相同，Y 难度 1 压过 B 的 2，
    //             而 B 的 plan_id 反而更靠前；
    //   字典序 —— COR_A 与 COR_Y 同为覆盖 1、难度 1，全靠 plan_id 决胜。
    final catalog = _catalog('''
{
  "plans": [
    {"plan_id": "COR_Z_OVERLAP2_HARD", "name_zh": "广覆盖但难", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
     "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
     "target_fault_codes": ["KNEE_VALGUS", "ASYMMETRY"], "difficulty": 3,
     "age_min": 12, "age_max": 18},
    {"plan_id": "COR_A_OVERLAP1", "name_zh": "单覆盖、字典序靠前", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
     "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
     "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
     "age_min": 12, "age_max": 18},
    {"plan_id": "COR_B_OVERLAP1", "name_zh": "单覆盖、难度 2", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
     "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
     "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 2,
     "age_min": 12, "age_max": 18},
    {"plan_id": "COR_M_ACTIVE", "name_zh": "唯一的已核定", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
     "status": "active", "dosage_text": "3 组", "dosage_ratified": true,
     "target_fault_codes": ["HEEL_RISE"], "difficulty": 1,
     "age_min": 12, "age_max": 18},
    {"plan_id": "COR_X_DEPRECATED", "name_zh": "已作废", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": [], "contraindications": ["停"],
     "status": "deprecated", "dosage_text": "待核定", "dosage_ratified": false,
     "target_fault_codes": ["KNEE_VALGUS"], "difficulty": 1,
     "age_min": 12, "age_max": 18},
    {"plan_id": "COR_Y_EQUIPMENT", "name_zh": "要弹力带", "goal": "g",
     "instructions": [], "key_cues": [], "equipment": ["弹力带"], "contraindications": ["停"],
     "status": "draft", "dosage_text": "待核定", "dosage_ratified": false,
     "target_fault_codes": ["ASYMMETRY"], "difficulty": 1,
     "age_min": 16, "age_max": 18}
  ]
}
''');

    /// 全部方案的 ID，按当前顺序。
    List<String> idsOf(PlanSelection selection) =>
        [for (final plan in selection.plans) plan.planId];

    test('已核定的有货时，一条未核定的都不给', () {
      final picked = catalog.selectForFaults(['HEEL_RISE'], age: 16, limit: 10);
      expect(idsOf(picked), ['COR_M_ACTIVE']);
      expect(picked.includesUnreviewed, isFalse);
    });

    test('已核定的没货时才退回未核定，并把标志带上', () {
      // 要的是「已核定那一遍查不到、回退那一遍才查得到」的组合。
      // 这个标志一路传到响应里（PlanChoice.dose_note）。半路丢掉，未核定的方案
      // 就会被渲染成有依据的处方。
      final picked = catalog.selectForFaults(
        ['KNEE_VALGUS', 'ASYMMETRY'],
        age: 17,
        limit: 10,
      );
      expect(picked.includesUnreviewed, isTrue);
      expect(picked.plans, isNotEmpty);
    });

    test('排序是三级键：覆盖数 → 难度 → plan_id', () {
      final picked = catalog.selectForFaults(
        ['KNEE_VALGUS', 'ASYMMETRY'],
        age: 17,
        availableEquipment: ['弹力带'],
        limit: 10,
      );

      // **四条的顺序逐级都有反例**，只按其中一级排都会错：
      //   Z 覆盖 2 个，难度 3 也照样第一；
      //   A 与 Y 同为覆盖 1、难度 1，靠 plan_id 决出 A 在前；
      //   Y 难度 1 压过 B 的 2 —— 而 B 的 plan_id 比 Y 靠前，
      //     所以只看 plan_id 或只看难度的实现都会在这里红。
      expect(idsOf(picked), [
        'COR_Z_OVERLAP2_HARD',
        'COR_A_OVERLAP1',
        'COR_Y_EQUIPMENT',
        'COR_B_OVERLAP1',
      ]);
    });

    test('作废的方案两遍都不选', () {
      // deprecated 不是「还没人核定」，是「已经否决」—— 回退那一遍也不能把它捞回来。
      // 两条路径各查一次：一条会走已核定那一遍，一条会走回退那一遍。
      for (final codes in [
        ['HEEL_RISE'],
        ['KNEE_VALGUS', 'ASYMMETRY'],
      ]) {
        final picked = catalog.selectForFaults(codes, age: 17, limit: 50);
        expect(idsOf(picked), isNot(contains('COR_X_DEPRECATED')), reason: '$codes');
      }
    });

    test('器材不在手时那条被挡掉', () {
      final without = catalog.selectForFaults(
        ['KNEE_VALGUS', 'ASYMMETRY'],
        age: 17,
        limit: 50,
      );
      expect(idsOf(without), isNot(contains('COR_Y_EQUIPMENT')));

      final with_ = catalog.selectForFaults(
        ['KNEE_VALGUS', 'ASYMMETRY'],
        age: 17,
        availableEquipment: ['弹力带'],
        limit: 50,
      );
      expect(idsOf(with_), contains('COR_Y_EQUIPMENT'));
    });

    test('年龄区间外的那条不出现', () {
      // COR_Y_EQUIPMENT 的区间是 16–18。15 岁看不到 —— 就算手里有弹力带。
      final picked = catalog.selectForFaults(
        ['KNEE_VALGUS', 'ASYMMETRY'],
        age: 15,
        availableEquipment: ['弹力带'],
        limit: 50,
      );
      expect(idsOf(picked), isNot(contains('COR_Y_EQUIPMENT')));
    });

    test('limit 是硬截断', () {
      const codes = ['KNEE_VALGUS', 'ASYMMETRY'];
      expect(catalog.selectForFaults(codes, age: 17, limit: 2).plans, hasLength(2));
      expect(catalog.selectForFaults(codes, age: 17, limit: 0).plans, isEmpty);
    });

    test('候选集与方案覆盖的码不相交时，一条都不给', () {
      // 不是「勉强给一条」，是空的 —— 与服务端一致。
      final picked = catalog.selectForFaults(['EXCESSIVE_TRUNK_LEAN'], age: 16, limit: 10);
      expect(picked.plans, isEmpty);
      expect(picked.includesUnreviewed, isFalse, reason: '一条都没选中时不算「含未核定」');
    });
  });
}
