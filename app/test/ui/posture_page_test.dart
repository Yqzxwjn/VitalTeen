/// 体态页的测试。
///
/// 这一页最容易做错的地方不是排版，是**四种情形各说什么话** —— 它们看起来
/// 都是「一屏文字」，混起来不会报错，只会让用户把一句没依据的话当成结论：
///
/// - 一条可用记录都没有 → 空状态；
/// - 有记录但不够几组 → 「再练 N 组」；
/// - 够多了但没有特征反复出现 → 「没有反复出现的」；
/// - 有结论 → 倾向卡（带依据行与「阈值待核定」角标）。
///
/// 另有两处是**跨文件的约定**，必须在这里钉住：
///
/// 1. **AppBar 标题与底栏标签不同字**（「体态倾向」vs「体态」）——
///    相同的话 `find.text` 会一次找到两个，而那条断言红在别的文件里。
/// 2. **方案库读不出来不影响倾向结论** —— 与练习页「读不出方案库就整份报告
///    不出」刻意不同。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart' show Sex;
import 'package:vitalteen_app/app/plan_catalog.dart';
import 'package:vitalteen_app/app/posture_analysis.dart';
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/ui/app_icons.dart';
import 'package:vitalteen_app/ui/design.dart';
import 'package:vitalteen_app/ui/posture_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 钉死的「现在」。三态全由时间窗决定，不钉死就没法在主机上把三态走一遍。
final DateTime _now = DateTime(2026, 10, 5, 14, 30);

Profile _profile() => Profile(
      sex: Sex.female,
      age: 15,
      grade: '初三',
      standardGroup: '初中女子',
      heightCm: 163,
      weightKg: 52,
      updatedAt: DateTime(2026, 1, 1),
    );

/// 一条记录。[daysAgo] 相对 [_now]。
SessionRecord _record({
  String actionCode = 'SQUAT',
  int daysAgo = 1,
  int repCount = 12,
  Map<String, int>? faultCounts = const {},
}) =>
    SessionRecord(
      actionCode: actionCode,
      actionNameZh: actionCode == 'SQUAT' ? '深蹲' : '平板支撑',
      finishedAt: DateTime(_now.year, _now.month, _now.day - daysAgo, 10),
      repCount: repCount,
      isTimed: false,
      score: 80,
      provisional: false,
      faultCounts: faultCounts,
    );

/// [n] 组深蹲，其中前 [withFault] 组命中 `EXCESSIVE_TRUNK_LEAN`，
/// 前 [asymmetry] 组命中 `ASYMMETRY`。
List<SessionRecord> _sets(int n, {int withFault = 0, int asymmetry = 0}) => [
      for (var i = 0; i < n; i++)
        _record(faultCounts: {
          if (i < withFault) 'EXCESSIVE_TRUNK_LEAN': 3,
          if (i < asymmetry) 'ASYMMETRY': 2,
        }),
    ];

/// 一条最简方案。字段全给满 —— [CorrectionPlan.fromJson] 之外的构造点
/// 没有默认值。
CorrectionPlan _plan({
  required String id,
  required String nameZh,
  required List<String> targetFaultCodes,
}) =>
    CorrectionPlan(
      planId: id,
      nameZh: nameZh,
      goal: '$nameZh 的目标',
      instructions: const ['第一步'],
      keyCues: const ['慢一点'],
      equipment: const [],
      contraindications: const ['出现疼痛时立即停止'],
      status: 'draft',
      dosageText: '剂量待体育专业成员核定',
      dosageRatified: false,
      targetFaultCodes: targetFaultCodes,
      difficulty: 2,
      ageMin: 12,
      ageMax: 18,
    );

/// 一份能查出方案的假方案库：深蹲前倾 → 箱式蹲，左右不均 → 鸟狗式。
PlanCatalog _catalog({List<CorrectionPlan>? plans}) => PlanCatalog(plans ??
    [
      _plan(
        id: 'COR_BOX_SQUAT',
        nameZh: '箱式蹲',
        targetFaultCodes: const ['EXCESSIVE_TRUNK_LEAN'],
      ),
      _plan(
        id: 'COR_BIRD_DOG',
        nameZh: '鸟狗式',
        targetFaultCodes: const ['ASYMMETRY'],
      ),
    ]);

Future<void> _mount(
  WidgetTester tester,
  List<SessionRecord> records, {
  Future<PlanCatalog> Function()? loadPlans,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: PosturePage(
      records: records,
      profile: _profile(),
      now: () => _now,
      loadPlans: loadPlans,
    ),
  ));
  // 方案库是异步读的。**不 `pumpAndSettle`** —— 这一页没有循环动画，
  // 但那次读在主机上会抛（没有随包资源），交给 `_loadPlans` 自己吞掉。
  await tester.pump();
}

void main() {
  group('四种情形各说各的话', () {
    testWidgets('一条可用记录都没有：空状态，并说明这些量从这一版才开始记',
        (tester) async {
      await _mount(tester, const []);

      expect(find.text('还没有可以看的记录'), findsOneWidget);
      // **老记录补不回来这件事必须写在空状态里。** 不写的话，练了半年的
      // 用户会以为这一页坏了 —— 而它不是坏了，是那些记录里根本没有这个量。
      expect(find.textContaining('更早的练习不在里面'), findsOneWidget);
      // 空状态不该长得像一张成绩单。
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('全是 v1 的老记录：与一条都没有同一种说法', (tester) async {
      // `faultCounts == null` 是「没采集过」，不是「很干净」。把它算成
      // 「有 8 组可以看」会让这个页面拿一批「不知道」去推倾向。
      await _mount(tester, [
        for (var i = 1; i <= 8; i++) _record(daysAgo: i, faultCounts: null),
      ]);

      expect(find.text('还没有可以看的记录'), findsOneWidget);
      expect(find.textContaining('再练'), findsNothing);
    });

    testWidgets('采到了但不够几组：说「再练 N 组」，且报出已有几组',
        (tester) async {
      await _mount(tester, _sets(postureMinEligibleSets - 2, withFault: 1));

      expect(find.text('再练 2 组'), findsOneWidget);
      expect(
        find.textContaining('已经有 ${postureMinEligibleSets - 2} 组可以看了'),
        findsOneWidget,
      );
      // **不能在这里给结论。** 门槛以下出结论就等于拿两三组编一个倾向。
      expect(find.text('上身前倾倾向'), findsNothing);
    });

    testWidgets('够多了但没有特征反复出现：不塞一张 0% 的卡', (tester) async {
      await _mount(tester, _sets(10, withFault: 0));

      expect(
        find.text('近 $postureWindowDays 天没有反复出现的特征'),
        findsOneWidget,
      );
      // 一条 0% 的卡片会被读成「这条也查过、你有」—— 它是一句不同的话。
      expect(find.byType(Card), findsOneWidget, reason: '只有那一张说明卡');
    });

    testWidgets('有结论：倾向卡带标题、依据行和分档词', (tester) async {
      await _mount(tester, _sets(10, withFault: 6, asymmetry: 3));

      expect(find.text('上身前倾倾向'), findsOneWidget);
      // **依据行是这张卡片的全部依据。** 没有它，上面那句话就只是一个形容词。
      expect(find.text('近 30 天里，10 组中有 6 组出现'), findsOneWidget);
      // 6/10 = 0.6 → 持续（切点是包含的）。
      expect(find.text('持续'), findsOneWidget);

      expect(find.text('左右用力不均倾向'), findsOneWidget);
      expect(find.text('近 30 天里，10 组中有 3 组出现'), findsOneWidget);
      // 3/10 = 0.3 → 反复。
      expect(find.text('反复'), findsOneWidget);
    });

    testWidgets('点病名的通俗说法，紧接着就是它的边界', (tester) async {
      // 顺序反了（先说边界再点病名）就成了先撇清、再暗示。两句都在，
      // 且俗话那句在前 —— 这里断的是两句都在，位置由版式保证。
      await _mount(tester, _sets(8, withFault: 5));

      expect(find.textContaining('「圆背」「驼背」'), findsOneWidget);
      expect(find.textContaining('不是对脊柱形状的判断'), findsOneWidget);
    });
  });

  group('跨文件的约定', () {
    testWidgets('标题是「体态倾向」，不是底栏那个「体态」', (tester) async {
      await _mount(tester, const []);

      expect(find.text('体态倾向'), findsOneWidget);
      // **这一条守的是标题与底栏标签不同字。** 标题若写成「体态」，
      // 首页底栏那个标签会与它撞成 `findsNWidgets(2)`，
      // 而那条断言红在 `app_shell_test.dart` 里 —— 离改动很远的地方。
      expect(find.text('体态'), findsNothing);
    });

    testWidgets('空状态里不重复出现「体态倾向」这个串', (tester) async {
      await _mount(tester, const []);

      // 整个屏幕上只有 AppBar 那一处。
      expect(find.text('体态倾向'), findsOneWidget);
    });

    testWidgets('范围声明固定显示，四种情形都在', (tester) async {
      for (final records in [
        const <SessionRecord>[],
        _sets(2, withFault: 1),
        _sets(10, withFault: 0),
        _sets(10, withFault: 6),
      ]) {
        await _mount(tester, records);

        expect(find.text('看这一页前请知道'), findsOneWidget,
            reason: '声明块不能折起来，也不能只在有结论时才出现');
        expect(find.textContaining('这一页说的是你练过的动作里反复出现的特征'),
            findsOneWidget);
        // **「判不了脊柱侧弯」必须写在页面上。** 不写的话，用户会拿
        // 「这里没提」当成「这里没查出来问题」—— 那是把测不出读成了正常。
        expect(find.textContaining('判不了「脊柱侧弯」'), findsOneWidget);
        expect(find.textContaining('请停下来'), findsOneWidget);
      }
    });
  });

  group('建议练习', () {
    testWidgets('按故障码查出方案，禁忌用警示色显示', (tester) async {
      await _mount(
        tester,
        _sets(10, withFault: 6, asymmetry: 5),
        loadPlans: () async => _catalog(),
      );

      expect(find.text('可以这样练'), findsNWidgets(2), reason: '两张卡各一段');
      expect(find.text('箱式蹲'), findsOneWidget);
      expect(find.text('鸟狗式'), findsOneWidget);

      // **禁忌必须显示，而且是最扎眼的东西。** 漏读它的代价不是「分数不准」。
      // 断的是应用自己的那套线性图标：重设计之后警示标记不再借 Material 的字形。
      final warnings = tester
          .widgetList<AppIcon>(
            find.byWidgetPredicate(
              (widget) => widget is AppIcon && widget.glyph == AppGlyph.warning,
            ),
          )
          .toList();
      expect(warnings, hasLength(2));
      expect(
        warnings.every((icon) => icon.color == AppColors.danger),
        isTrue,
        reason: '禁忌用的是警示色',
      );
      expect(find.text('出现疼痛时立即停止'), findsNWidgets(2));
    });

    testWidgets('未核定的方案要标出来，不能冒充已核定', (tester) async {
      await _mount(
        tester,
        _sets(10, withFault: 6),
        loadPlans: () async => _catalog(),
      );

      // `selectForFaults` 走的是「一条已核定的都没有 → 退回未核定」那条路，
      // 那个位丢了就等于把草稿当成核定过的处方。
      expect(find.text('这几个动作还没有经过体育专业成员核定，先照着做，别自己加量。'),
          findsOneWidget);
      expect(find.text('剂量待核定'), findsOneWidget);
    });

    testWidgets('查不到方案：照实说，不摆一个空壳', (tester) async {
      await _mount(
        tester,
        _sets(10, withFault: 6),
        // 方案库是好的，只是里面没有针对这个码的方案。
        loadPlans: () async => _catalog(plans: const []),
      );

      expect(find.text('上身前倾倾向'), findsOneWidget);
      expect(find.textContaining('暂时没有适合的练习推荐'), findsOneWidget);
      expect(find.text('可以这样练'), findsNothing);
    });

    testWidgets('方案库读不出来：倾向结论照样在，只降级建议那一段', (tester) async {
      await _mount(
        tester,
        _sets(10, withFault: 6),
        loadPlans: () async => throw const PlanCatalogException('资源坏了'),
      );

      // **这一条是这一页与练习页最大的不同。** 那边读不出方案库整份报告不出，
      // 这边倾向才是主体，建议只是附加 —— 不能因为建议没了就什么都不说。
      expect(find.text('上身前倾倾向'), findsOneWidget);
      expect(find.text('近 30 天里，10 组中有 6 组出现'), findsOneWidget);
      expect(find.textContaining('建议练习的清单这次没读出来'), findsOneWidget);
      expect(find.text('可以这样练'), findsNothing);
    });

    testWidgets('方案库还在读的时候，那一段什么都不画', (tester) async {
      // 一个永远不完成的 Future —— 停在「还在读」那一态。
      await _mount(
        tester,
        _sets(10, withFault: 6),
        loadPlans: () => Completer<PlanCatalog>().future,
      );

      expect(find.text('上身前倾倾向'), findsOneWidget);
      expect(find.text('可以这样练'), findsNothing);
      expect(find.textContaining('没读出来'), findsNothing);
    });
  });
}
