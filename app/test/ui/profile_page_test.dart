/// 资料页的测试。
///
/// ## 最要紧的一条：边界必须与分析面板一致
///
/// 这两处表单校验的是同一件事（年龄 5–25），但它们**各写各的报错文案**。
/// 只要有一处放宽，用户就能存下一份分析面板自己拒收的档案 ——
/// 而那个 bug 不会在填资料的时候现身，只会在几天后他做完二十个深蹲、
/// 按下「分析这一组」的那一刻现身。所以这里按 `decisionAgeMin/Max`
/// 逐个试边界，而不是各写一个字面量。
///
/// ## 第二条：保存失败不能假装成功
///
/// `saveProfileRaw` 在没有通道时会返回 `false`（主机测试里就是这样，
/// 真机上则是 `SharedPreferences.commit()` 真的失败了）。那时必须
/// **既弹提示、又照常放行**：弹提示是因为用户有权知道下次要重填；
/// 放行是因为内存里那份是好的，为了一个存储问题把他挡在这里毫无意义。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart'
    show Sex, decisionAgeMax, decisionAgeMin;
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/ui/profile_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

Profile _profile({
  Sex sex = Sex.female,
  int age = 16,
  int heightCm = 165,
  double weightKg = 52.5,
}) =>
    Profile(
      sex: sex,
      age: age,
      grade: '高一',
      standardGroup: '高中女子',
      heightCm: heightCm,
      weightKg: weightKg,
      updatedAt: DateTime(2026, 10, 4),
    );

/// 把测试窗口调成一台正常手机的形状。默认窗口只有 800×600，
/// 六个输入框一路排下来会把它撑满，底下那几个落在屏幕外 `enterText` 够不到。
void _phoneSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 给通道那一头装上「存上了没有」的答案。
///
/// **两条路都要显式装。** 「不装 mock 就等于写失败」在主机上确实成立，
/// 但那是靠环境碰巧对，不是靠测试说清楚 —— 一旦谁在前面某条用例里漏了清理，
/// 这里就会拿到一个 `true`，而失败的方式是「提示没出现」，
/// 看起来像是产品没弹提示，实际上是测试自己把通道接通了。
void _saveSucceeds(WidgetTester tester, {required bool ok}) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('vitalteen/profile'),
    (call) async => call.method == 'save' ? ok : null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('vitalteen/profile'),
        null,
      ));
}

Future<List<Profile>> _mount(
  WidgetTester tester, {
  Profile? initial,
  VoidCallback? onCancel,
}) async {
  _phoneSized(tester);
  final saved = <Profile>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: ProfilePage(
      initial: initial,
      onSaved: saved.add,
      onCancel: onCancel,
    ),
  ));
  return saved;
}

/// 填满四个框。性别不动 —— 它默认「男」；
/// 国标组别没有输入框了，按年龄性别自动分。
Future<void> _fill(
  WidgetTester tester, {
  String age = '16',
  String height = '170',
  String weight = '55',
}) async {
  await tester.enterText(find.widgetWithText(TextFormField, '年龄'), age);
  await tester.enterText(find.widgetWithText(TextFormField, '年级'), '高一');
  await tester.enterText(find.widgetWithText(TextFormField, '身高（厘米）'), height);
  await tester.enterText(find.widgetWithText(TextFormField, '体重（公斤）'), weight);
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '保存'));
  // **不用 `pumpAndSettle`**：它会一路把时间推过 SnackBar 那 4 秒的停留期 ——
  // 「保存失败」那句提示会在断言之前自己消失，于是那条测试永远红，
  // 而修它的诱惑是去放宽断言（比如「找到或找不到都算过」），把要测的东西丢掉。
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('首次填写', () {
    testWidgets('没有取消这条路 —— 按钮与返回键都不给', (tester) async {
      // 「不填就是不想用」这条规矩有两个入口：页面上的取消按钮，
      // 以及标题栏上的返回箭头。只关掉一个等于没关。
      await _mount(tester, onCancel: null);

      expect(find.text('填写资料'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.byTooltip('放弃改动'), findsNothing);
    });

    testWidgets('说清楚为什么要填，以及身高体重不参与判定', (tester) async {
      // 第一屏就要人交出年龄与体重，不解释的话看起来像在收集用不着的东西。
      // 而「身高体重只做记录」这句是**照实说** —— 全仓库没有任何判定用它们。
      await _mount(tester, onCancel: null);

      expect(find.textContaining('和谁比'), findsOneWidget);
      expect(find.textContaining('只做记录'), findsOneWidget);
    });
  });

  group('编辑已有档案', () {
    testWidgets('六个值都预填，且整数体重不显示成 55.0', (tester) async {
      await _mount(
        tester,
        initial: _profile(age: 15, heightCm: 170, weightKg: 55),
        onCancel: () {},
      );

      // 回显必须能被 `double.parse` 原样读回来 —— 显示成「55.0」虽然只是难看，
      // 但同一个值在两处格式化，迟早会出现「首页显示 55、点进去变成 55.00」。
      expect(find.text('15'), findsOneWidget);
      expect(find.text('170'), findsOneWidget);
      expect(find.text('55'), findsOneWidget);
      // 组别没有输入框，但要把自动分出来的那一档显示给人看
      expect(find.textContaining('国标组别：初中女子'), findsOneWidget);

      final segments = tester.widget<SegmentedButton<Sex>>(
        find.byType(SegmentedButton<Sex>),
      );
      expect(segments.selected, {Sex.female});
    });

    testWidgets('有取消，且点它会回调', (tester) async {
      var cancels = 0;
      await _mount(tester, initial: _profile(), onCancel: () => cancels++);

      expect(find.byTooltip('放弃改动'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();

      expect(cancels, 1);
    });
  });

  group('校验', () {
    testWidgets('空提交：逐项列缺项，一个值都不回调', (tester) async {
      final saved = await _mount(tester, onCancel: null);
      await _tapSave(tester);

      expect(find.text('请填年龄'), findsOneWidget);
      expect(find.text('请填年级'), findsOneWidget);
      expect(find.text('请填身高'), findsOneWidget);
      expect(find.text('请填体重'), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('国标组别没有输入框：填了年龄性别就自己分出来', (tester) async {
      // 原来这一项是手填的，填错了没人拦得住 —— 而它决定「跟谁的标准比」。
      _saveSucceeds(tester, ok: true);
      final saved = await _mount(tester, onCancel: null);
      expect(find.widgetWithText(TextFormField, '国标组别'), findsNothing);
      expect(find.textContaining('填了年龄就会自动分出组别'), findsOneWidget);

      await _fill(tester, age: '16');
      expect(find.textContaining('国标组别：高中男子'), findsOneWidget);

      await tester.tap(find.text('女'));
      await tester.pump();
      expect(find.textContaining('国标组别：高中女子'), findsOneWidget);

      await _tapSave(tester);
      expect(saved.single.standardGroup, '高中女子');
    });

    testWidgets('年龄：上下限与契约常量对齐，边界两边都试', (tester) async {
      _saveSucceeds(tester, ok: true);
      // 逐个边界单独跑一遍 —— 只在「4 被拦、5 通过」这类相邻值上，
      // 差一位的 off-by-one 才会现身。
      for (final (age, ok) in [
        (decisionAgeMin - 1, false),
        (decisionAgeMin, true),
        (decisionAgeMax, true),
        (decisionAgeMax + 1, false),
      ]) {
        final saved = await _mount(tester, onCancel: null);
        await _fill(tester, age: '$age');
        await _tapSave(tester);

        expect(saved, ok ? hasLength(1) : isEmpty, reason: '年龄 $age');
        if (ok) {
          expect(saved.single.age, age);
        } else {
          // 报错里要带出区间本身，否则用户不知道该改到多少。
          expect(
            find.textContaining('$decisionAgeMin 到 $decisionAgeMax'),
            findsOneWidget,
            reason: '年龄 $age',
          );
        }
      }
    });

    testWidgets('身高：80 与 250 通过，79 与 251 拦下', (tester) async {
      // 这两个区间是**笔误护栏**，不是专业标准 —— 拦的是「165 打成 1650」。
      _saveSucceeds(tester, ok: true);
      for (final (cm, ok) in [(79, false), (80, true), (250, true), (251, false)]) {
        final saved = await _mount(tester, onCancel: null);
        await _fill(tester, height: '$cm');
        await _tapSave(tester);

        expect(saved, ok ? hasLength(1) : isEmpty, reason: '身高 $cm');
        if (ok) expect(saved.single.heightCm, cm);
      }
    });

    testWidgets('体重：15 与 200 通过，14 与 201 拦下', (tester) async {
      _saveSucceeds(tester, ok: true);
      for (final (kg, ok) in [(14, false), (15, true), (200, true), (201, false)]) {
        final saved = await _mount(tester, onCancel: null);
        await _fill(tester, weight: '$kg');
        await _tapSave(tester);

        expect(saved, ok ? hasLength(1) : isEmpty, reason: '体重 $kg');
        if (ok) expect(saved.single.weightKg, kg.toDouble());
      }
    });

    testWidgets('超长的年级被截在 20 个字，而不是提交时才报错', (tester) async {
      // 契约限定 1–20 字符。**在这里截断而不是校验**：超长只可能是误触，
      // 弹一条「不能超过 20 个字」让人回去删，不如根本不让他输进去。
      _saveSucceeds(tester, ok: true);
      final saved = await _mount(tester, onCancel: null);
      await _fill(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, '年级'),
        '初' * 40,
      );
      await _tapSave(tester);

      expect(saved.single.grade.length, 20);
    });
  });

  group('保存', () {
    testWidgets('几个值原样交给 onSaved，组别按年龄性别算出来', (tester) async {
      _saveSucceeds(tester, ok: true);
      final saved = await _mount(tester, onCancel: null);
      await _fill(tester, age: '15', height: '172', weight: '58.5');
      await _tapSave(tester);

      expect(saved, hasLength(1));
      final profile = saved.single;
      expect(profile.sex, Sex.male);
      expect(profile.age, 15);
      expect(profile.grade, '高一');
      // 15 岁男 → 初中男子（不是手填的那个值）
      expect(profile.standardGroup, '初中男子');
      expect(profile.heightCm, 172);
      expect(profile.weightKg, 58.5);
    });

    testWidgets('保存的时间是这一份自己的，不是档案里那个旧日期', (tester) async {
      // 从 `initial` 抄一个旧日期的话，首页那条「该复核了」会立刻又冒出来 ——
      // 而用户刚刚才填过。
      _saveSucceeds(tester, ok: true);
      final saved = await _mount(
        tester,
        initial: _profile().copyWith(
          updatedAt: DateTime.now().subtract(const Duration(days: 400)),
        ),
        onCancel: () {},
      );
      await _tapSave(tester);

      expect(needsProfileRefresh(saved.single, DateTime.now()), isFalse);
    });

    testWidgets('写不进去：既弹提示，也照常放行', (tester) async {
      // 真机上对应 `SharedPreferences.commit()` 返回 false。
      // **两件事都要发生**：弹提示是因为用户有权知道下次要重填；
      // 放行是因为内存里那份是好的，为了一个存储问题把他挡在这里毫无意义。
      _saveSucceeds(tester, ok: false);
      final saved = await _mount(tester, onCancel: null);
      await _fill(tester);
      await _tapSave(tester);

      expect(find.textContaining('没能存到这台设备上'), findsOneWidget);
      expect(saved, hasLength(1));
      expect(saved.single.age, 16);
    });

    testWidgets('写得进去就不弹那句', (tester) async {
      // 反过来的那一半：恒弹提示的话，上面那条测试照样绿，
      // 而用户会在每一次保存时都看到一句吓人的话。
      _saveSucceeds(tester, ok: true);
      final saved = await _mount(tester, onCancel: null);
      await _fill(tester);
      await _tapSave(tester);

      expect(find.textContaining('没能存到这台设备上'), findsNothing);
      expect(saved, hasLength(1));
    });
  });
}
