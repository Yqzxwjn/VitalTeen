/// 界面冒烟测试。
///
/// ## 为什么不测「点一下会怎样」
///
/// 这一层的输入全是**已经算好的视图对象**（`SessionView` / `RepFeedbackView` /
/// `PositionReport`），真正的交互逻辑在会话层，那里有 `squat_session_test.dart`
/// 的 23 个用例按帧驱动。在这里再模拟一遍点击，测的是同一件事的第二遍，
/// 而且第二遍的假输入更容易失真。
///
/// 所以这里只回答一个问题：**给定这些数据，界面画得出来吗、画的是不是那些字。**
/// 它挡住的是「改字段名忘了改界面」这类断裂 —— 那种错误编译期不报，
/// 而真机上表现为一块空白，离病因很远。
///
/// ## 为什么启动测试不用 `pumpAndSettle`
///
/// 深蹲页在等相机起来时一直转着进度圈，而 `pumpAndSettle` 会一直等到
/// 「没有待处理的动画帧」—— 转圈动画永远不会满足这个条件，于是它只能超时失败。
/// 所以启动测试用固定次数的 `pump`。
///
/// 挂单控件时用**这些控件真实所处的那个主题**（`buildCameraTheme`）
/// 而不是裸 `MaterialApp`：「未核定的判定不用错误色」那条断言比的是一个具体的
/// `colorScheme.error`，拿别的主题去比，比的是另一个应用 —— 某个控件真的用了
/// 错误色，它照样绿。
///
/// **这个主题换过一次，跟着改是对的。** 全应用从深色改成浅色之后，
/// 练习页那一屏被单独套进 `buildCameraTheme()`（`theme.dart` 文件头），
/// 而这里挂的每一个控件（计数抬头显示、站位清单、单次反馈卡、整组报告）
/// 都只出现在那一屏里。还用 `buildVitalTeenTheme()` 的话，测试比的就是
/// 一个**真机上不存在**的浅色练习页 —— 正是这条注释一开始要防的那种错。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/decision_request.dart' show Sex;
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/features.dart' show CameraView;
import 'package:vitalteen_app/domain/landmarks.dart' show L;
import 'package:vitalteen_app/domain/rules.dart' show SetSummary;
import 'package:vitalteen_app/main.dart';
import 'package:vitalteen_app/ui/counting_hud.dart';
import 'package:vitalteen_app/ui/home_page.dart';
import 'package:vitalteen_app/ui/position_checklist.dart';
import 'package:vitalteen_app/ui/preview_page.dart';
import 'package:vitalteen_app/ui/profile_page.dart';
import 'package:vitalteen_app/ui/rep_feedback_card.dart';
import 'package:vitalteen_app/ui/score_badge.dart';
import 'package:vitalteen_app/ui/splash_page.dart';
import 'package:vitalteen_app/ui/squat_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

/// 把控件挂到应用真正用的主题上。
Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: buildCameraTheme(),
        home: Scaffold(body: child),
      ),
    );

/// 一份分数。默认是「满分但未核定」—— 随包发出的权重现在是占位值，
/// 所以 `provisional: true` 才是真实的状态。
FormScore _score({
  int score = 86,
  FormRating rating = FormRating.good,
  bool provisional = true,
}) =>
    FormScore(
      score: score,
      rating: rating,
      provisional: provisional,
      penalty: (100 - score) / 100,
      terms: const [],
    );

/// 造一个会话快照。**只给关心的字段，其余取中性值** ——
/// 每次都用完整构造会让每个用例多出十几个与断言无关的参数。
SessionView _view({
  SessionPhase phase = SessionPhase.counting,
  PositionReport position = const PositionReport.empty(),
  int repCount = 0,
  int discardedReps = 0,
  String machineState = '',
  double? kneeAngle,
  int holdMs = 0,
  List<int> repDurationsMs = const [],
  RepFeedbackView? lastRep,
  FormScore? lastRepScore,
  SetSummary? summary,
  FormScore? setScore,
  bool interrupted = false,
  bool sawFrame = true,
}) =>
    SessionView(
      phase: phase,
      position: position,
      calibrationFrames: 0,
      calibrationTarget: 15,
      repCount: repCount,
      discardedReps: discardedReps,
      machineState: machineState,
      kneeAngle: kneeAngle,
      holdMs: holdMs,
      repDurationsMs: repDurationsMs,
      lastRep: lastRep,
      lastRepScore: lastRepScore,
      summary: summary,
      setScore: setScore,
      interrupted: interrupted,
      sawFrame: sawFrame,
    );

/// 这台设备上「已经装好的」一份档案。`daysAgo` 是相对今天算的，
/// 所以它**不是陈旧档案** —— 陈旧那一条只在首页测试里测。
final _storedProfile = Profile(
  sex: Sex.male,
  age: 15,
  grade: '初三',
  standardGroup: '初中男子',
  heightCm: 170,
  weightKg: 55,
  updatedAt: DateTime(2026, 9, 1),
);

/// 装一个假的资料通道，返回那块「盘」。
///
/// **走通道而不是给 `AppEntry` 开一个注入口**：真机上走的就是这条通道，
/// 把它换掉测的才是同一条路。多开一个注入口的代价是两者会漂移 ——
/// 测试覆盖的会是一条真机上不存在的路径。
_ProfileSlot _fakeProfileChannel(WidgetTester tester, {String? stored}) {
  final slot = _ProfileSlot(stored);
  final messenger = tester.binding.defaultBinaryMessenger;
  const channel = MethodChannel('vitalteen/profile');
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'load':
        return slot.stored;
      case 'save':
        slot.stored = call.arguments as String?;
        return true;
      default:
        return null;
    }
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return slot;
}

class _ProfileSlot {
  _ProfileSlot(this.stored);
  String? stored;
}

/// 把测试窗口调成一台正常手机的形状。
///
/// **不这么做的话**：默认窗口只有 800×600，而资料页六个输入框一路排下来
/// 会把它撑满，底下那几个（身高、体重）落在屏幕外 —— `enterText` 够不到。
/// 这不是产品的问题，是测试窗口太矮。
void _phoneSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 等一次页面切换走完。**不用 `pumpAndSettle`** —— 深蹲页在等相机起来时
/// 一直转着进度圈，永远不会静止（见本文件顶部）。
Future<void> _settleStage(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 按一次系统返回键（手势/按键），走的是 `flutter/navigation` 那条平台消息。
///
/// **不能用 `tester.pageBack()`** —— 那个是点标题栏上那个箭头，
/// 而这里要验的恰恰是「没有箭头的时候返回键去哪」。
Future<void> _pressSystemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await tester.pump();
}

/// 开屏那张品牌图。
///
/// 按**资源路径**找它，不是按 `Image` 的类型 —— 欢迎页上也有图
///（标志与主视觉），按类型找会在切屏之后照样命中，那样这条守卫就白写了。
final Finder _splashArtwork = find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is AssetImage &&
      (widget.image as AssetImage).assetName == SplashPage.artworkPath,
  description: '开屏品牌图 ${SplashPage.artworkPath}',
);

/// 把资料页那四个文本框填满。性别不用动 —— 它默认「男」，
/// 国标组别按性别年龄自动分，没有输入框。
Future<void> _fillProfile(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextFormField, '年龄'), '16');
  await tester.enterText(find.widgetWithText(TextFormField, '年级'), '高一');
  await tester.enterText(find.widgetWithText(TextFormField, '身高（厘米）'), '172');
  await tester.enterText(find.widgetWithText(TextFormField, '体重（公斤）'), '58.5');
  await tester.pump();
}

void main() {
  group('启动', () {
    testWidgets('开屏 → 填资料 → 首页 → 预览页 → 深蹲页，一路不炸', (tester) async {
      _phoneSized(tester);
      final slot = _fakeProfileChannel(tester);
      await tester.pumpWidget(const VitalTeenApp());

      // 开屏期间：**品牌图在**。
      //
      // 这里原来断言的是那句英文小字（「VITALTEEN · 青少年体态与体能」），
      // 而那句话连同整层文字一起删掉了 —— 品牌图自己带着标志与中文名，
      // 再叠一层字是把同一件事说两遍（`splash_page.dart` 文件头）。
      // 所以守卫换成「这一屏放的是那张图」：它比哪句文案都稳，
      // 换文案不会惊动它，而换成别的图或图加载不出来时它会红。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SplashPage), findsOneWidget);
      expect(_splashArtwork, findsOneWidget);
      expect(find.text('开始'), findsNothing);

      // 放完 → 直接进资料页（欢迎页已经删掉，开屏之后不再有一屏「开始」）。
      //
      // **这里必须真的把时间推过去**：开屏现在等的是一个 `Timer`，
      // 而等它的时候没有任何帧要画 —— `pumpAndSettle` 那种「等到没有待画的帧」
      // 的等法会立刻返回，把这一屏原地留在那儿。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // 这台设备上没有档案 → 先填资料。**没填完进不去首页。**
      // 这是「第一次下载时要求填写」那条要求的落点，所以要断言的是
      // 「首页不在」，而不只是「资料页在」。
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      // 隐私边界在第一屏就得说清楚，不能只写在隐私政策里。
      // 原来这句话在欢迎页上，欢迎页删掉之后挪到了资料页。
      expect(find.textContaining('画面不出手机'), findsOneWidget);

      await _fillProfile(tester);
      await tester.tap(find.text('保存'));
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      // 存下去的内容必须是刚填的那一份 —— 页面 → 编码 → 通道这一整条，
      // 少了任何一段，用户都会在下次打开时发现又要重填。
      final saved = Profile.decode(slot.stored);
      expect(saved?.age, 16);
      expect(saved?.grade, '高一');
      expect(saved?.weightKg, 58.5);

      await tester.tap(find.text('深蹲'));
      await _settleStage(tester);

      // **先到预览页，不是直接进相机页。** 相机一起来就要占位、要标定，
      // 而在那之前得让人看清这个动作长什么样 —— 这是「点进去先看一遍」
      // 那条要求的落点，所以要在这里断言，不然哪天有人把这一屏接掉，
      // 首页测试照样绿。
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.byType(SquatPage), findsNothing);

      await tester.tap(find.text('开始'));
      await _settleStage(tester);

      // 标题按类型找，不按文字：首页那张卡片和预览页的标题栏上
      // 都有「深蹲」两个字。
      // 测试环境里没有相机插件，管线会走到它的失败分支 —— 那正是这里要确认的：
      // **失败要表现为界面上的一句说明，而不是一个没人接的异常。**
      expect(find.byType(SquatPage), findsOneWidget);
      expect(tester.takeException(), isNull);

      // **底栏整个不在树上。** 不是「被藏起来了」——练习页是独立的一屏，
      // 壳在那时候根本没被构建（`main.dart` 文件头「预览页与练习页不进那个壳」）。
      // 这条守的是相机：让练习页进 `IndexedStack` 的话，任何一次父级重建
      // 都会把它 dispose 再 initState，表现是画面黑一下再回来。
      expect(find.byType(NavigationBar), findsNothing,
          reason: '练习页那一屏不该有底栏 —— 有的话说明它被塞进壳里了');

      // **这一屏必须是深色的。** 全应用是浅色主题，只有练习页外面套了
      // `buildCameraTheme()`（`theme.dart` 文件头）。那层 `Theme` 是在
      // `main.dart` 的 `_Stage.exercise` 那一支里加的，**删掉它不会有任何
      // 编译错误、也不会有别的测试红** —— 只是练习页跟着变成浅色，
      // 而浅色底会把骨架的对比度吃掉，那正是这一段深色存在的唯一理由。
      //
      // 断言的是**这一屏真实的 `Theme.of`**，不是 `buildCameraTheme()` 的
      // 返回值：后者只证明了那个函数写对了，证明不了它被挂上去了。
      final context = tester.element(find.byType(SquatPage));
      expect(Theme.of(context).brightness, Brightness.dark,
          reason: '练习页没套深色主题 —— 相机画面上那层骨架会看不清');
    });

    testWidgets('这台设备上已经有档案：不再问一遍，直接进首页', (tester) async {
      _phoneSized(tester);
      _fakeProfileChannel(tester, stored: _storedProfile.encode());
      await tester.pumpWidget(const VitalTeenApp());

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(ProfilePage), findsNothing);
      // **「记住」这件事必须看得见。** 只在表单里预填的话，一个上次留下的年龄
      // 看起来像是「已经确认过」—— 那正是当初决定不持久化时给出的理由，
      // 而现在它靠首页这张卡片来答（见 `profile.dart` 顶上那段）。
      expect(find.text(profileSummaryLine(_storedProfile)), findsOneWidget);
    });

    testWidgets('首页点深蹲 → 预览页 →「开始」才进相机页，返回键回首页而不是退出应用', (tester) async {
      _phoneSized(tester);
      _fakeProfileChannel(tester, stored: _storedProfile.encode());
      await tester.pumpWidget(const VitalTeenApp());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _settleStage(tester);

      // 首页上还没有相机 —— 「点开只能做深蹲」这个说法在首页是可以被否证的。
      expect(find.byType(SquatPage), findsNothing);

      await tester.tap(find.text('深蹲'));
      await _settleStage(tester);
      // 预览页上照样没有相机：它是一张会动的示意图，不是一路后台预热。
      expect(find.byType(SquatPage), findsNothing);

      await tester.tap(find.text('开始'));
      await _settleStage(tester);
      expect(find.byType(SquatPage), findsOneWidget);

      // 标题栏上那个箭头：tooltip 是给读屏与长按用的，
      // 也是这条测试唯一能把它和「切前后摄像头」区分开的东西。
      await tester.tap(find.byTooltip('返回动作列表'));
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(SquatPage), findsNothing);
    });

    testWidgets('系统返回键：深蹲页回首页', (tester) async {
      // **和上面那条不是一回事。** 那条点的是标题栏上的箭头（走 `onExit`），
      // 这条走的是系统的返回手势/按键（走 `main.dart` 那个 `PopScope`）。
      // 两条路都得通 —— 用户站在两米外够不到箭头时用的就是手势。
      _phoneSized(tester);
      _fakeProfileChannel(tester, stored: _storedProfile.encode());
      await tester.pumpWidget(const VitalTeenApp());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _settleStage(tester);
      await tester.tap(find.text('深蹲'));
      await _settleStage(tester);
      await tester.tap(find.text('开始'));
      await _settleStage(tester);
      expect(find.byType(SquatPage), findsOneWidget);

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(SquatPage), findsNothing);
    });

    testWidgets('系统返回键：首次填资料时退不掉 —— 不填就是进不去', (tester) async {
      // 「不填就是不想用」那条规矩的落点是**两个入口**：资料页上没有取消按钮，
      // 返回键也不接。只做前一半的话，用户按一下返回就会发现自己在首页上，
      // 而首页每一张卡都需要一份资料 —— 那是一个长得像 bug 的状态。
      _phoneSized(tester);
      _fakeProfileChannel(tester);
      await tester.pumpWidget(const VitalTeenApp());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _settleStage(tester);
      expect(find.byType(ProfilePage), findsOneWidget);

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
    });

    testWidgets('开屏会自己交棒，交完之后界面停在静止状态', (tester) async {
      // 要守的是**这一屏不会一直赖着**。原先它是一条「动画不循环」的守卫
      // （循环的动画会让 `pumpAndSettle` 永远等不到静止）；现在这一屏不画画
      // 任何会变的东西、只等一个 `Timer`，但「等得完、等完就走」这条没变，
      // 而它仍然是这一段唯一能被自动验证的部分。
      //
      // 所以这里先**显式把时间推过时长**再 `pumpAndSettle`。反过来的顺序
      // （直接 `pumpAndSettle`）在这条上会假绿或者假红：等 `Timer` 的这段时间里
      // 没有帧要画，它立刻就会返回，于是要么断言失败，要么断言的是上一屏。
      _fakeProfileChannel(tester);
      await tester.pumpWidget(
        const MaterialApp(
          home: AppEntry(splashDuration: Duration(milliseconds: 300)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // 交棒之后停在下一屏。这台设备上没有档案，所以下一屏是资料页
      //（欢迎页删掉之后，开屏后面直接就是它）。
      expect(find.byType(SplashPage), findsNothing);
      expect(find.byType(ProfilePage), findsOneWidget);
    });

    testWidgets('零时长等于不放这一屏，直接进资料页', (tester) async {
      // 深蹲页的用例都得先经过入口，每条都等一段动画没有意义。
      _fakeProfileChannel(tester);
      await tester.pumpWidget(
        const MaterialApp(home: AppEntry(splashDuration: Duration.zero)),
      );
      await _settleStage(tester);

      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(SplashPage), findsNothing);
      expect(_splashArtwork, findsNothing);
    });
  });

  group('参考分', () {
    testWidgets('分数、评级词与「参考分」三个都得出，少一个都读不懂', (tester) async {
      await _show(tester, ScoreBadge(score: _score(score: 86)));

      expect(find.text('86'), findsOneWidget);
      // 光一个 86 没人知道算好算坏 —— 五级词是文档里就有的说法，
      // 不是这一层发明的。
      expect(find.text('良'), findsOneWidget);
      expect(find.text('参考分'), findsOneWidget);
    });

    testWidgets('未核定就一定要标出来，核定之后自己消失', (tester) async {
      await _show(tester, ScoreBadge(score: _score(provisional: true)));
      expect(find.text('阈值待核定 · 仅参考'), findsOneWidget);

      await _show(tester, ScoreBadge(score: _score(provisional: false)));
      // 角标由数据决定，不是写死的文案 —— 权重核定之后不需要有人记得来删它。
      expect(find.text('阈值待核定 · 仅参考'), findsNothing);
    });

    testWidgets('不同评级用不同颜色，而且都不是错误色', (tester) async {
      final colors = <FormRating, Color>{};
      for (final rating in FormRating.values) {
        await _show(tester, ScoreBadge(score: _score(rating: rating)));
        final number = tester.widget<Text>(find.text('86'));
        colors[rating] = number.style!.color!;
      }

      // 五级五色：同色的话评级词就白写了，而分数只差一两分时
      // 用户根本看不出自己变好了没有。
      expect(colors.values.toSet(), hasLength(FormRating.values.length));
      // **没有红色。** 一个未核定的分数不该长着判决书的样子。
      final error = buildCameraTheme().colorScheme.error;
      expect(colors.values, isNot(contains(error)));
    });

    testWidgets('分数挤在反馈卡片的标题行里，与它评的那次同时出现', (tester) async {
      await _show(
        tester,
        RepFeedbackCard(
          feedback: _kneeValgusFeedback,
          score: _score(score: 74, rating: FormRating.fair),
        ),
      );

      expect(find.text('第 5 个 · 膝内扣倾向（需关注）'), findsOneWidget);
      expect(find.text('74'), findsOneWidget);
      expect(find.text('中'), findsOneWidget);
      // 分数是这一下的错误算出来的，所以它必须和那些错误在同一个控件里。
      expect(find.text('膝内扣倾向'), findsOneWidget);
    });

    testWidgets('没有分数时卡片照常画，不画破折号也不画 0', (tester) async {
      // 「没有分数」和「0 分」在屏幕上长得太像，而含义正好相反。
      await _show(tester, const RepFeedbackCard(feedback: _kneeValgusFeedback));

      expect(find.text('第 5 个 · 膝内扣倾向（需关注）'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });

  group('计数抬头显示', () {
    testWidgets('显示计数、相位与膝角', (tester) async {
      await _show(
        tester,
        CountingHud(
          view: _view(repCount: 7, machineState: 'STANDING', kneeAngle: 172.4),
        ),
      );

      expect(find.text('7'), findsOneWidget);
      expect(find.text('站立'), findsOneWidget);
      expect(find.text('172°'), findsOneWidget);
    });

    testWidgets('膝角不可用时显示破折号而不是留着上一个读数', (tester) async {
      await _show(
        tester,
        CountingHud(view: _view(repCount: 3, machineState: 'BOTTOM')),
      );

      expect(find.text('膝角 —'), findsOneWidget);
      // 底下那根条也不该出现 —— 它此刻没有值可表示。
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('状态机状态认不出来时不显示相位', (tester) async {
      await _show(tester, CountingHud(view: _view(machineState: '')));

      expect(find.text('站立'), findsNothing);
      expect(find.text('下蹲'), findsNothing);
    });

    testWidgets('丢弃的 rep 要解释，否则看起来就是计数器坏了', (tester) async {
      await _show(
        tester,
        CountingHud(view: _view(repCount: 9, discardedReps: 3)),
      );

      expect(find.textContaining('有 3 次没计入'), findsOneWidget);
    });

    testWidgets('没有丢弃就不提这件事', (tester) async {
      await _show(tester, CountingHud(view: _view(repCount: 9)));

      expect(find.textContaining('没计入'), findsNothing);
    });

    testWidgets('中断过就要说', (tester) async {
      await _show(tester, CountingHud(view: _view(interrupted: true)));

      expect(find.textContaining('离开过画面'), findsOneWidget);
    });

    testWidgets('计时制动作显示的是本段撑了多久，计数退到下面一行', (tester) async {
      // 平板支撑（`ActionSpec.isTimed`）。一段 40 秒的支撑被显示成「1」，
      // 用户会以为计数器没在看他 —— 所以大字换成那个在走的计时器。
      await _show(
        tester,
        CountingHud(
          view: _view(repCount: 3, machineState: 'HOLD_OK', holdMs: 12400),
          stateLabels: plankHudStateLabels,
          discardedReason: plankSpec.discardedReason,
          isTimed: true,
        ),
      );

      expect(find.text('12.4'), findsOneWidget);
      expect(find.text('秒'), findsOneWidget);
      expect(find.text('撑住'), findsOneWidget);
      // 计数**不能消失**：计时器归零之后屏幕上就什么都没留下了，
      // 用户没法知道自己刚才那一段算没算上。
      expect(find.text('本组 3 段'), findsOneWidget);
      // 单位不能还是「个」—— 平板支撑的 rep 是一段。
      expect(find.text('个'), findsNothing);
    });

    testWidgets('计时制动作不画膝角条 —— 它恒在 180° 上下，是一条假的证据', (tester) async {
      // 站着是这样、撑着也是这样。一条不动的条不是「相机在量我」的证据，
      // 而这一屏上真正的证据是那个在走的计时器。
      await _show(
        tester,
        CountingHud(
          view: _view(machineState: 'HOLD_OK', kneeAngle: 176.0, holdMs: 3200),
          stateLabels: plankHudStateLabels,
          isTimed: true,
        ),
      );

      expect(find.textContaining('膝角'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('计时制动作的丢弃说「段」，不说「次」', (tester) async {
      await _show(
        tester,
        CountingHud(
          view: _view(repCount: 2, discardedReps: 1, holdMs: 800),
          stateLabels: plankHudStateLabels,
          discardedReason: plankSpec.discardedReason,
          isTimed: true,
        ),
      );

      expect(find.textContaining('有 1 段没计入'), findsOneWidget);
      expect(find.textContaining('次没计入'), findsNothing);
    });
  });

  group('单次反馈卡片', () {
    testWidgets('没有问题时也照常显示', (tester) async {
      await _show(
        tester,
        const RepFeedbackCard(
          feedback: RepFeedbackView(
            repIndex: 3,
            headline: '第 3 个 · 完成得不错',
            faults: [],
            clean: true,
          ),
        ),
      );

      expect(find.text('第 3 个 · 完成得不错'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('未核定的故障要挂「仅提示」角标', (tester) async {
      await _show(tester, const RepFeedbackCard(feedback: _kneeValgusFeedback));

      expect(find.text('膝内扣倾向'), findsOneWidget);
      expect(find.text('需关注'), findsOneWidget);
      expect(find.text('待核定 · 仅提示'), findsOneWidget);
      // 带数字的细节。**只说「膝内扣倾向」等于什么都没说** ——
      // 用户无法据此知道自己是差一点还是差很多。
      expect(find.text('额状面膝角 12°（参考值 8°）'), findsOneWidget);
    });

    testWidgets('未核定的项不用错误色', (tester) async {
      await _show(tester, const RepFeedbackCard(feedback: _kneeValgusFeedback));

      final scheme = buildCameraTheme().colorScheme;

      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      for (final text in texts) {
        expect(text.style?.color, isNot(scheme.error),
            reason: '「${text.data}」用了错误色，而这条判定还不能驱动扣分');
      }
    });
  });

  group('站位自检清单', () {
    testWidgets('还没见过任何一帧时四行都是「还不知道」', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport.empty(),
          sawFrame: false,
          cameraRunning: true,
        ),
      );

      expect(find.text('人在画面里'), findsOneWidget);
      expect(find.text('全身入镜'), findsOneWidget);
      expect(find.text('距离合适'), findsOneWidget);
      expect(find.text('站成 45°'), findsOneWidget);

      // 四行都还是问号：**「还不知道」不能画成红叉** ——
      // 那会让人照着一个不存在的问题去调整站位。
      expect(find.byIcon(Icons.help_outline), findsNWidgets(4));
      expect(find.byIcon(Icons.error_outline), findsNothing);

      // 相机在跑、画面里没人 —— 必须有一条指令，否则用户对着一屏问号
      // 不知道该干什么，而「站到画面里」正是此刻唯一要做的事。
      expect(find.textContaining('请站到画面里'), findsOneWidget);
    });

    testWidgets('相机还没起来时说「正在启动」，不指挥用户去调整站位', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport.empty(),
          sawFrame: false,
          cameraRunning: false,
        ),
      );

      expect(find.textContaining('正在启动相机'), findsOneWidget);
      expect(find.textContaining('请站到画面里'), findsNothing);
    });

    testWidgets('人一旦进画面，横幅就让位给四行具体的结论', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport.empty(),
          sawFrame: true,
          cameraRunning: true,
        ),
      );

      expect(find.textContaining('请站到画面里'), findsNothing);
      expect(find.textContaining('正在启动相机'), findsNothing);
    });

    testWidgets('立定跳远换掉「站到画面中间」那句 —— 它会往前跳一米多', (tester) async {
      // 第一行的补充说明默认是给**原地动作**写的：站到画面正中，别站在边上。
      // 立定跳远照它站，跳出去的那一段就全在画面外 —— 落地没被看见，
      // 一次都数不上，而屏幕上什么错都不报。一句正确的话搬到会位移的
      // 动作上正好是反的，所以它必须随动作换。
      const missingAll = PositionReport(
        view: CameraView.oblique45,
        viewStable: true,
        issues: [
          PositionIssue(PositionIssueCode.missingTorso, '上身没入镜。'),
          PositionIssue(PositionIssueCode.missingLegs, '腿没入镜。'),
          PositionIssue(PositionIssueCode.missingLeftFoot, '左脚没入镜。'),
        ],
      );

      await _show(
        tester,
        const PositionChecklist(
          report: missingAll,
          sawFrame: true,
          cameraRunning: true,
        ),
      );
      expect(find.textContaining('别站在边上'), findsOneWidget, reason: '不给提示时仍是原来那句');

      await _show(
        tester,
        PositionChecklist(
          report: missingAll,
          sawFrame: true,
          cameraRunning: true,
          // 取的是真实 spec，不是抄一份字面量：抄一份的话，改了文案而这里
          // 没跟着改，测试依然绿 —— 而它验的正是「页面拿到的是哪一句」。
          framingHint: sljSpec.framingHint,
        ),
      );
      expect(
        find.textContaining('别站在边上'),
        findsNothing,
        reason: '立定跳远上那句话是反的：照它站，落地全在画面外',
      );
      expect(find.textContaining('往前跳的那一米'), findsOneWidget);
    });

    testWidgets('整人出画时要说「请站到画面里」—— 不要求这个动作先发左脚那条', (tester) async {
      // 第一行（`CheckLine.present`）的判据是「躯干与腿这两组缺失同时出现」。
      // **它曾经还要求 `missingLeftFoot` 一起出现**，而那个码只在必需集里
      // 有 `leftHeel` 的动作上才会发（深蹲、立定跳远）—— 于是另外四个动作
      //（开合跳、俯卧撑、仰卧起坐、跳绳）整人出画时，第一行反而亮着绿勾：
      // 人不在画面里，清单说「人在画面里」。
      //
      // 这里用跳绳的必需集（有脚尖、没有脚跟），因为它正好也是这一轮新加
      // `missingFeet` 的那个动作 —— 两个码都不该影响这条判据。
      expect(ropeSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(ropeSpec.requiredLandmarks, contains(L.leftFootIndex));

      await _show(
        tester,
        PositionChecklist(
          report: const PositionReport(
            view: CameraView.oblique45,
            viewStable: true,
            // **刻意只有躯干与腿这两条**：这就是「人整个不在画面里」时
            // 门禁实际会发出的那一组码。
            issues: [
              PositionIssue(PositionIssueCode.missingTorso, '上身没入镜。'),
              PositionIssue(PositionIssueCode.missingLegs, '腿没入镜。'),
            ],
          ),
          sawFrame: true,
          cameraRunning: true,
          framingHint: ropeSpec.framingHint,
        ),
      );
      expect(
        find.textContaining('架稳'),
        findsOneWidget,
        reason: '整人出画时那句要换成这个动作自己的站位提示',
      );
    });

    testWidgets('缺腿脚时给出怎么改，而不只是哪里不对', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport(
            view: CameraView.oblique45,
            viewStable: true,
            issues: [
              PositionIssue(
                PositionIssueCode.missingLegs,
                '膝盖或脚踝没有完整入镜。请后退半步，让双腿整个进画面。',
              ),
            ],
          ),
          sawFrame: true,
          cameraRunning: true,
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(
        find.text('膝盖或脚踝没有完整入镜。请后退半步，让双腿整个进画面。'),
        findsOneWidget,
      );
    });

    testWidgets('正对镜头必须被拦，并说明为什么', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport(
            view: CameraView.frontal,
            viewStable: true,
            issues: [
              PositionIssue(
                PositionIssueCode.facingFront,
                '请侧身 45° —— 正对镜头时膝盖的弯曲在画面上看不出来，计数会一直是 0。',
              ),
            ],
          ),
          sawFrame: true,
          cameraRunning: true,
        ),
      );

      expect(
        find.text('请侧身 45° —— 正对镜头时膝盖的弯曲在画面上看不出来，计数会一直是 0。'),
        findsOneWidget,
      );
    });

    testWidgets('没正对镜头也要画在「机位」那一行上', (tester) async {
      // 开合跳要的是正面，`notFacingFront` 是它的拦住理由。
      // 这个码漏在 `viewCodes` 外面时的表现最难查：**按钮是灰的、四行全绿**——
      // 用户被拦住而屏幕上没有一行说得出为什么。
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport(
            view: CameraView.oblique45,
            viewStable: true,
            issues: [
              PositionIssue(
                PositionIssueCode.notFacingFront,
                '请正对镜头 —— 侧着身子时双腿张开的幅度量不出来。',
              ),
            ],
          ),
          sawFrame: true,
          cameraRunning: true,
        ),
      );

      expect(find.textContaining('请正对镜头'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('提示级的问题不画成拦住', (tester) async {
      await _show(
        tester,
        const PositionChecklist(
          report: PositionReport(
            view: CameraView.sagittal,
            viewStable: true,
            issues: [
              PositionIssue(
                PositionIssueCode.facingSide,
                '完全侧对镜头也能计数，但膝内扣判定会不可用。稍微转回来一点更好。',
                blocking: false,
              ),
            ],
          ),
          sawFrame: true,
          cameraRunning: true,
        ),
      );

      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });
  });
}

/// 一条典型的未核定判定：措辞已弱化、带角标、带数字。
const RepFeedbackView _kneeValgusFeedback = RepFeedbackView(
  repIndex: 5,
  headline: '第 5 个 · 膝内扣倾向（需关注）',
  faults: [
    FaultView(
      code: 'KNEE_VALGUS',
      title: '膝内扣倾向',
      detail: '额状面膝角 12°（参考值 8°）',
      severityLabel: '需关注',
      scorable: false,
      notice: '待核定 · 仅提示',
      severity01: 0.4,
    ),
  ],
  clean: false,
);
