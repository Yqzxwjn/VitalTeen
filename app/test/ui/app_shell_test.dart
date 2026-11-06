/// 四标签外壳的测试。
///
/// 这个壳有三件事**只能在这里**验，别处都够不着：
///
/// 1. **返回键的新语义。** 站在「开始运动」上按返回是退出应用，站在另外三个
///    标签上是切回「开始运动」，而从预览页/练习页/资料页回来落哪个标签各不
///    相同 —— 这些答案全在 `main.dart` 的 `_backTarget` 一处，而它读的是
///    `_stage` 与 `_tab` 两个字段。写成两条独立的 switch 时，`canPop` 与
///    `onPopInvoked` 迟早有一处漏改，表现是「按返回键没反应」。
/// 2. **`IndexedStack` 的代价。** 它保留四个标签的 `State`（滚动位置因此还在），
///    但**不包 `TickerMode`** —— 未选中那三页里的 Ticker 照跑。所以这一层
///    自己包了一层，而这里要验的是它真的生效（`TickerMode.of` 报了 false），
///    不是「代码里写了那个单词」。
/// 3. **练习页盖住底栏是结构性的。** 那一屏里壳根本不在树上，
///    而不是「底栏被藏起来了」。
/// 4. **方向的装配。** 「哪一屏该锁哪个方向」这条规则本身在
///    `platform/orientation_test.dart` 里当纯函数穷举过，但「它有没有被接上」
///    只能从首页点进一个动作、一路走到练习页才看得出来（`main.dart` 的
///    `_go` 是 `_stage` 的唯一写入口，靠的就是那一处）。
///
/// ## 标签清单是这一层唯一的守卫
///
/// 底栏、`IndexedStack`、`_Tab` 三处的顺序**必须一一对应**，而顺序错开不会报
/// 任何错 —— 只是点击切到隔壁那一页。所以下面每一条断言里那个标签清单都要
/// 一起维护：加一个标签就三处一起加，这里跟着加。
///
/// ## 为什么全程走真通道
///
/// 与 `squat_widgets_test.dart` 同一条口径：装假的是那个 `MethodChannel`，
/// 而不是给 `AppEntry` 开口子。多开一个注入口的代价是它会与真路径漂移 ——
/// 测试覆盖的会是一条真机上不存在的路。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart' show Sex;
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/main.dart';
import 'package:vitalteen_app/ui/avatar_image.dart';
import 'package:vitalteen_app/ui/bottom_surface.dart';
import 'package:vitalteen_app/ui/growth_page.dart';
import 'package:vitalteen_app/ui/history_page.dart';
import 'package:vitalteen_app/ui/home_page.dart';
import 'package:vitalteen_app/ui/landscape_gate.dart';
import 'package:vitalteen_app/ui/me_page.dart';
import 'package:vitalteen_app/ui/posture_page.dart';
import 'package:vitalteen_app/ui/profile_page.dart';
import 'package:vitalteen_app/ui/squat_page.dart';
import 'package:vitalteen_app/ui/theme.dart';

import '../support/orientation_spy.dart';

Profile _profile() => Profile(
      sex: Sex.male,
      age: 15,
      grade: '初三',
      standardGroup: '初中男子',
      heightCm: 170,
      weightKg: 55,
      updatedAt: DateTime(2026, 9, 1),
    );

SessionRecord _record({
  String actionCode = 'SQUAT',
  String actionNameZh = '深蹲',
  int repCount = 12,
  int? score = 85,
}) {
  return SessionRecord(
    actionCode: actionCode,
    actionNameZh: actionNameZh,
    finishedAt: DateTime.now(),
    repCount: repCount,
    isTimed: false,
    score: score,
    provisional: false,
  );
}

/// 三个通道背后那点「盘」。
class _Prefs {
  _Prefs({this.profile, this.history, this.avatar});

  String? profile;
  String? history;

  /// 假盘上的头像文件路径；`null` ＝没选过（界面上画首字母）。
  String? avatar;

  /// 下一次 `pick` 报什么。默认「用户取消了」—— 那是这条通道最常见的
  /// 归宿（点开相册又退出来），也让「什么都没发生」成为默认预期。
  String pickResult = 'cancelled';

  /// `pickResult == 'picked'` 时换上的那个路径。
  String? pickedPath;
}

/// 装上资料、历史、头像三个假通道，返回那块盘。
///
/// ## 为什么三个都要装
///
/// 前两个的理由是老账（见下）：只装一个的话另一次调用会走到
/// `MissingPluginException` 上，而那是**被吞掉、退化成空表**的，
/// 于是测试**照样绿**，只是它悄悄测的是「读失败的那条路」。
/// 真要测读成功，就得把它也装上。
///
/// **头像这一条不一样，而且反过来了。** 没装它的后果不是「悄悄退化」，
/// 而是**整个入口卡死**：没有 handler 的通道在 `testWidgets` 下
/// **永不 resolve** —— 它不抛 `MissingPluginException`，那个 `await`
/// 就永远停在那儿。曾经 `AppEntry` 在「开始」的必经之路上 `await`
/// 了一次头像路径，于是本文件十五条用例一起挂在欢迎页上。
/// 现在那条路已经摘掉了（`main.dart` 的 [_loadAvatarPath] 是发了不管的），
/// 但**仍然要装**：不装就等于这一族用例跑的永远是「头像读不出来」那条路，
/// 而换头像那个功能一次都没被走过。
_Prefs _fakeChannels(
  WidgetTester tester, {
  Profile? profile,
  List<SessionRecord>? history,
  String? avatar,
  String pickResult = 'cancelled',
  String? pickedPath,
}) {
  final prefs = _Prefs(
    profile: profile?.encode(),
    history: history == null ? null : encodeHistory(history),
    avatar: avatar,
  )..pickResult = pickResult
   ..pickedPath = pickedPath;
  final messenger = tester.binding.defaultBinaryMessenger;

  void install(String name, String? Function() read, void Function(String?) write) {
    final channel = MethodChannel(name);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'load':
          return read();
        case 'save':
          write(call.arguments as String?);
          return true;
        case 'clear':
          write(null);
          return true;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  install('vitalteen/profile', () => prefs.profile, (v) => prefs.profile = v);
  install('vitalteen/history', () => prefs.history, (v) => prefs.history = v);

  // 头像那条通道**方法名与前两条不同**（`path` / `pick` / `clear`），
  // 硬塞进上面那个 `install` 会让三个假通道长得不一样却读起来一样。
  final avatarChannel = MethodChannel('vitalteen/avatar');
  messenger.setMockMethodCallHandler(avatarChannel, (call) async {
    switch (call.method) {
      case 'path':
        return prefs.avatar;
      case 'pick':
        // 原生侧选完就把图拷进私有目录并把键指过去 —— 假盘照这个语义
        // 直接改自己的值，于是「选好之后再 `path` 一次」拿到的就是新的那个。
        if (prefs.pickResult == 'picked') prefs.avatar = prefs.pickedPath;
        return prefs.pickResult;
      case 'clear':
        prefs.avatar = null;
        return true;
      default:
        return null;
    }
  });
  addTearDown(() => messenger.setMockMethodCallHandler(avatarChannel, null));

  return prefs;
}

/// 把测试窗口调成一台正常手机的形状。默认的 800×600 装不下四个标签的内容。
void _phoneSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 等一次页面切换走完。
Future<void> _settleStage(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 挂上入口并走进壳里。**跳过开屏**（`Duration.zero`），开屏有自己的测试。
/// 返回那块假盘 —— 有几条用例要在之后查盘上的值。
///
/// 有档案的直接进壳；没档案的会落在资料页（欢迎页已经删掉，
/// 开屏之后不再有一屏「开始」要点）。
Future<_Prefs> _enterShell(
  WidgetTester tester, {
  Profile? profile,
  List<SessionRecord>? history,
  String? avatar,
  String pickResult = 'cancelled',
  String? pickedPath,
}) async {
  _phoneSized(tester);
  final prefs = _fakeChannels(
    tester,
    profile: profile,
    history: history,
    avatar: avatar,
    pickResult: pickResult,
    pickedPath: pickedPath,
  );
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: const AppEntry(splashDuration: Duration.zero),
  ));
  await _settleStage(tester);
  return prefs;
}

/// 按一次系统返回键。**不能用 `tester.pageBack()`** —— 那个是点标题栏上
/// 那个箭头，而这里要验的恰恰是「没有箭头的时候返回键去哪」。
Future<void> _pressSystemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await tester.pump();
}

/// 底栏上那个标签。**必须限定在 `NavigationBar` 里面**：四个标签的文字
/// 与四个页面的标题、正文都可能重字（「历史记录」与历史页上任何一处），
/// 不限定的话 `tap` 会撞上歧义。
Finder _destination(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(_destination(label));
  await _settleStage(tester);
}

/// 某一个页面里那个头像喂给 `Image.file` 的路径。
///
/// **必须限定到那个页面**：四个标签都挂在 `IndexedStack` 上，两处头像同时
/// 在树上。首页里还有一堆别的 `Image`（卡片图位），所以还要再收一层 ——
/// 只有 `AvatarImage` 里面那一个才是头像。
String _avatarPathIn(WidgetTester tester, Type page) {
  final image = tester.widget<Image>(find.descendant(
    of: find.byType(page),
    matching: find.descendant(
      of: find.byType(AvatarImage),
      matching: find.byType(Image),
    ),
  ));
  return (image.image as FileImage).file.path;
}

/// 某一个页面里那个可点的头像。
Finder _avatarIn(Type page) => find.descendant(
      of: find.byType(page),
      matching: find.byType(AvatarImage),
    );

/// 壳上那个 `PopScope`。
///
/// **不能用 `find.byType(PopScope)`。** `PopScope` 是泛型的（`PopScope<T>`），
/// 而 `byType` 比的是 `runtimeType` 全等 —— 裸名字在 Dart 里是
/// `PopScope<dynamic>`，与树上那个 `PopScope<Object?>` 不是同一个类型，
/// 于是一个都找不到，报出来是一句与泛型毫无关系的 "Bad state: No element"。
Finder get _shellPopScope => find.ancestor(
      of: find.byType(NavigationBar),
      matching: find.byWidgetPredicate((widget) => widget is PopScope),
    );

/// 返回键会不会被这一层拦下。
bool _shellCanPop(WidgetTester tester) =>
    tester.widget<PopScope<Object?>>(_shellPopScope).canPop;

/// 某个标签的子树里，Ticker 是不是活的。
///
/// `skipOffstage: false`：未选中的标签正是**不在台上**的那几个，而它们才是
/// 这条断言唯一有意义的对象。找不到它们的话，这条测试只会验「选中的那个
/// 标签是活的」—— 那是一句废话。
///
/// 读的是 `valuesOf`（`of` 在这个版本已经废弃）：前者才是
/// `SingleTickerProviderStateMixin` 现在真正读的那个值。
bool _tickingInside(WidgetTester tester, Type page) {
  final element = tester.element(find.byType(page, skipOffstage: false));
  return TickerMode.valuesOf(element).enabled;
}

void main() {
  group('底栏与四个标签', () {
    testWidgets('四个标签都在，默认落在「开始运动」', (tester) async {
      await _enterShell(tester, profile: _profile());

      expect(find.byType(NavigationBar), findsOneWidget);
      for (final label in const ['开始运动', '历史记录', '体态', '我的']) {
        expect(_destination(label), findsOneWidget, reason: label);
      }

      expect(find.byType(HomePage), findsOneWidget);
      // 另外三个标签**不在台上**：`IndexedStack` 只把选中的那个交给
      // 默认的 finder（`_IndexedStackElement.debugVisitOnstageChildren`）。
      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(PosturePage), findsNothing);
      expect(find.byType(MePage), findsNothing);
    });

    testWidgets('点「历史记录」切过去，再点「我的」也切得过去', (tester) async {
      await _enterShell(tester, profile: _profile());

      await _tapTab(tester, '历史记录');
      expect(find.byType(HistoryPage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);

      // **「体态」夹在「历史记录」与「我的」之间。** 这一条盯的正是三处
      // （`_Tab` / `IndexedStack` / `destinations`）的顺序有没有错开：
      // 错开的话，点「体态」会切到隔壁那一页，而且不报任何错。
      await _tapTab(tester, '体态');
      expect(find.byType(PosturePage), findsOneWidget);
      expect(find.byType(HistoryPage), findsNothing);

      await _tapTab(tester, '我的');
      expect(find.byType(MePage), findsOneWidget);
      expect(find.byType(PosturePage), findsNothing);

      await _tapTab(tester, '开始运动');
      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('壳上是浅色主题 —— 深色只属于练习页那一屏', (tester) async {
      // 把整个壳套进 `buildCameraTheme()` 不会有任何编译错误、也不会有别的
      // 测试红，只是三个浅色页面全变成深色。那条断言比的是**这一屏真实的
      // `Theme.of`**，不是 `buildVitalTeenTheme()` 的返回值。
      await _enterShell(tester, profile: _profile());
      final context = tester.element(find.byType(NavigationBar));
      expect(Theme.of(context).brightness, Brightness.light);
    });
  });

  group('切标签不丢状态', () {
    testWidgets('滚到一半切走再切回来，还停在原地', (tester) async {
      // 这是 `IndexedStack` 换来的全部好处。改成条件构建的话，整棵子树连
      // `State` 一起被丢掉，用户会在动作清单里翻了半天、去「我的」看一眼
      // 再回来时被弹回顶部。
      await _enterShell(tester, profile: _profile());

      double homeOffset() => tester
          .state<ScrollableState>(find.descendant(
            of: find.byType(HomePage),
            matching: find.byType(Scrollable),
          ))
          .position
          .pixels;

      expect(homeOffset(), 0);
      await tester.drag(find.byType(HomePage), const Offset(0, -240));
      await tester.pumpAndSettle();
      final scrolled = homeOffset();
      expect(scrolled, greaterThan(0), reason: '没滚动起来，下面那条断言就没有意义');

      await _tapTab(tester, '我的');
      await _tapTab(tester, '开始运动');

      expect(homeOffset(), scrolled);
    });

    testWidgets('未选中的标签里 Ticker 是停的', (tester) async {
      // **`IndexedStack` 不包 `TickerMode`。** 它只让未选中的孩子不画、
      // 不接收点击、不进语义树（`RenderIndexedStack`），而 Ticker 照跑 ——
      // 现在四个标签都没有常驻动画看不出差别，但 `exercise_preview.dart`
      // 里就有一个 `repeat()` 的现成例子，而这份清单会继续长。
      //
      // 断言的是 `TickerMode.of` 报什么，不是「代码里写了 `TickerMode` 这个
      // 单词」：`SingleTickerProviderStateMixin` 读的就是前者。
      await _enterShell(tester, profile: _profile());

      expect(_tickingInside(tester, HomePage), isTrue,
          reason: '选中的标签必须是活的，否则整页动画都停了');

      await _tapTab(tester, '我的');
      expect(_tickingInside(tester, MePage), isTrue);
      expect(_tickingInside(tester, HomePage), isFalse);
      expect(_tickingInside(tester, HistoryPage), isFalse);
      expect(_tickingInside(tester, PosturePage), isFalse);

      // 后台那一层是真的没有在调度帧。这一条比上面弱得多（没有动画时它
      // 本来就该是 0），留着是因为它同时兜住「有东西在偷偷 `repeat()`」。
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('返回键', () {
    testWidgets('「历史记录」上按返回：切回「开始运动」，不退出应用', (tester) async {
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '历史记录');

      expect(_shellCanPop(tester), isFalse,
          reason: '站在历史记录上按返回不该退出应用');

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('「我的」上按返回：同样切回「开始运动」', (tester) async {
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '我的');

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('「体态」上按返回：也切回「开始运动」', (tester) async {
      // `_backTarget` 的规则是「不是 workout 就回 workout」，所以新标签
      // 自动落在里面 —— 这一条钉的是它真的自动落进去了：谁把那个判断写成
      // 逐个标签列举，漏掉「体态」的话，站在这页按返回会直接退出应用。
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '体态');

      expect(_shellCanPop(tester), isFalse, reason: '站在体态上按返回不该退出应用');

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('「开始运动」上按返回：交给系统（也就是退出应用），标签不动', (tester) async {
      // 主机测试里断言不了「退出了应用」，能断言的是**这一层没有拦它**：
      // `canPop` 为 true 表示返回键会走到底，而界面停在原地。
      await _enterShell(tester, profile: _profile());

      expect(_shellCanPop(tester), isTrue);

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('资料的两条路', () {
    testWidgets('从「我的」去编辑：保存之后落回「我的」，不是「开始运动」', (tester) async {
      // 从哪儿来回哪儿去。落错标签的表现是用户改完体重，一抬头发现自己
      // 站在动作清单上，还得再点一次底栏。
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '我的');

      await tester.tap(find.text('编辑资料'));
      await _settleStage(tester);
      expect(find.byType(ProfilePage), findsOneWidget);

      await tester.tap(find.text('保存'));
      await _settleStage(tester);

      expect(find.byType(MePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
    });

    testWidgets('首次填写：保存之后落「开始运动」', (tester) async {
      // 首填的人是一路走向训练的。落「我的」的表现是他填完资料，
      // 迎面看到的是自己刚填的那张脸，还得自己找路去练。
      _phoneSized(tester);
      _fakeChannels(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: const AppEntry(splashDuration: Duration.zero),
      ));
      await _settleStage(tester);
      expect(find.byType(ProfilePage), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, '年龄'), '16');
      await tester.enterText(find.widgetWithText(TextFormField, '年级'), '高一');
      await tester.enterText(
          find.widgetWithText(TextFormField, '身高（厘米）'), '172');
      await tester.enterText(
          find.widgetWithText(TextFormField, '体重（公斤）'), '58.5');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('换头像', () {
    testWidgets('在「我的」页换一张，切回首页横幅那一份也换了', (tester) async {
      // **这是这一组唯一真正跨页的一条。** 两处头像挂在同一个 `_Shell`
      // 字段上（`main.dart` 的 `_avatarPath`），而 `_Shell` 每帧重建、
      // 四个页面一起挂在 `IndexedStack` 上 —— 所以换完是立刻的，
      // 不需要切标签触发重建。这一条钉的就是那个「一次 `setState` 两处都换」。
      final prefs = await _enterShell(
        tester,
        profile: _profile(),
        avatar: '/nonexistent/avatar-old.png',
        pickResult: 'picked',
        pickedPath: '/nonexistent/avatar-new.png',
      );

      await _tapTab(tester, '我的');
      expect(_avatarPathIn(tester, MePage), '/nonexistent/avatar-old.png');

      await tester.tap(_avatarIn(MePage));
      await _settleStage(tester);

      expect(_avatarPathIn(tester, MePage), '/nonexistent/avatar-new.png');
      expect(prefs.avatar, '/nonexistent/avatar-new.png', reason: '新路径要落到盘上');

      await _tapTab(tester, '开始运动');
      expect(
        _avatarPathIn(tester, HomePage),
        '/nonexistent/avatar-new.png',
        reason: '首页横幅那一份没跟着换 —— 两处没有挂在同一个值上',
      );
    });

    testWidgets('用户在相册里点了返回：什么都不发生，也不弹东西', (tester) async {
      // **取消不是失败。** 用户按返回键退出相册是一次正常操作，
      // 拿一句「没能换头像」去回答它比不响应更让人不安
      //（`platform/avatar_store.dart` 的 `AvatarPickOutcome`）。
      final prefs = await _enterShell(
        tester,
        profile: _profile(),
        avatar: '/nonexistent/avatar-old.png',
        pickResult: 'cancelled',
      );

      await _tapTab(tester, '我的');
      await tester.tap(_avatarIn(MePage));
      await _settleStage(tester);

      expect(_avatarPathIn(tester, MePage), '/nonexistent/avatar-old.png');
      expect(prefs.avatar, '/nonexistent/avatar-old.png');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('换失败：弹一句，头像不动', (tester) async {
      final prefs = await _enterShell(
        tester,
        profile: _profile(),
        avatar: '/nonexistent/avatar-old.png',
        pickResult: 'failed',
      );

      await _tapTab(tester, '我的');
      await tester.tap(_avatarIn(MePage));
      await _settleStage(tester);

      expect(find.text('没能换头像，请再试一次。'), findsOneWidget);
      expect(_avatarPathIn(tester, MePage), '/nonexistent/avatar-old.png');
      expect(prefs.avatar, '/nonexistent/avatar-old.png');
    });

    testWidgets('清除本机数据把头像也清掉了', (tester) async {
      // 头像**不在档案那份记录里**（它是私有目录里的一个文件），所以
      // 「清除本机数据」最容易漏的就是它。漏掉的表现是「重填档案之后，
      // 头像从上一份资料里冒出来」—— 那看起来像没清干净。
      final prefs = await _enterShell(
        tester,
        profile: _profile(),
        avatar: '/nonexistent/avatar-old.png',
      );

      await _tapTab(tester, '我的');
      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await _settleStage(tester);

      expect(prefs.avatar, isNull, reason: '盘上那个头像键还留着');
      // 清干净之后回到首次填写，「我的」页整个不在台上了。
      expect(find.byType(MePage), findsNothing);
    });
  });

  group('历史', () {
    testWidgets('进壳时读一次盘，历史页立刻就有', (tester) async {
      await _enterShell(
        tester,
        profile: _profile(),
        history: [_record(actionNameZh: '深蹲')],
      );

      await _tapTab(tester, '历史记录');

      // 「深蹲」在动作清单里也有，但那时 HomePage 不在台上 —— 默认 finder
      // 只看得见选中的那个标签。
      expect(find.text('深蹲'), findsOneWidget);
      expect(find.text('还没有练习记录'), findsNothing);
    });

    testWidgets('盘上什么都没有：历史页给的是空状态', (tester) async {
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '历史记录');

      expect(find.text('还没有练习记录'), findsOneWidget);
    });

    testWidgets('切到「历史记录」会重读一次盘 —— 写落盘晚了也追得上', (tester) async {
      // 这一条盯的是**那次写入与那次重读的竞态**。练习页写盘是异步的
      //（`_persistRecord` 不 await，界面不等盘），而进壳时的重读可能赶在
      // 写落盘之前 —— 那一次读到的是还没有这条记录的盘。
      //
      // 这里用一个假盘**精确地复现那一刻**：进壳时盘是空的，之后才写进去，
      // 等价于「用户退出练习页时写还挂在半路」。真正的练习页在主机测试里
      // 到不了 `finished`（没有相机），所以这条竞态只能这样验。
      final prefs = _fakeChannels(tester, profile: _profile());
      _phoneSized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: const AppEntry(splashDuration: Duration.zero),
      ));
      await _settleStage(tester);

      // 进壳那一次重读拿到的是空盘。
      await _tapTab(tester, '历史记录');
      expect(find.text('还没有练习记录'), findsOneWidget);

      // 写落盘了。用户离开这一页再回来 —— 没有这条重读的话，他会一直看着
      // 「还没有练习记录」，直到重启应用。
      prefs.history = encodeHistory([_record(actionNameZh: '深蹲')]);
      await _tapTab(tester, '开始运动');
      await _tapTab(tester, '历史记录');

      expect(find.text('还没有练习记录'), findsNothing);
      expect(find.text('深蹲'), findsOneWidget);
    });

    testWidgets('切到「体态」也会重读一次盘 —— 与历史页是同一条理由', (tester) async {
      // **体态页吃的是同一列记录**，所以它有一模一样的竞态：进壳那次重读可能
      // 赶在写落盘之前。不重读的话，用户刚练完的那一组进不了分母，而这一页
      // 会照旧结论说话 —— 表现是「练了却不算数」，且不会自己变回来。
      final prefs = _fakeChannels(tester, profile: _profile());
      _phoneSized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: const AppEntry(splashDuration: Duration.zero),
      ));
      await _settleStage(tester);

      // 进壳那一次重读拿到的是空盘。
      await _tapTab(tester, '体态');
      expect(find.text('还没有可以看的记录'), findsOneWidget);

      // 用户练完的那几组落盘了。
      prefs.history = encodeHistory([
        for (var i = 0; i < 8; i++)
          SessionRecord(
            actionCode: 'SQUAT',
            actionNameZh: '深蹲',
            finishedAt: DateTime.now().subtract(Duration(days: i)),
            repCount: 12,
            isTimed: false,
            score: 85,
            provisional: false,
            faultCounts: const {'EXCESSIVE_TRUNK_LEAN': 3},
          ),
      ]);
      await _tapTab(tester, '开始运动');
      await _tapTab(tester, '体态');

      expect(find.text('还没有可以看的记录'), findsNothing);
      expect(find.text('上身前倾倾向'), findsOneWidget);
    });
  });

  group('底栏什么时候不在', () {
    testWidgets('动作预览页盖住底栏 —— 结构性的，不是藏起来的', (tester) async {
      // 预览页与练习页是独立的两屏，壳在它们出现时**不在树上**。
      // 这一条与 `squat_widgets_test.dart` 里练习页那一条是同一件事的两半：
      // 那里验的是「不让相机页进壳」，这里验的是「预览页也不进」。
      await _enterShell(tester, profile: _profile());
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.tap(find.text('深蹲'));
      await _settleStage(tester);

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(HomePage), findsNothing);
    });
  });

  group('清除本机数据', () {
    testWidgets('清干净了：回到首次填写，壳整个不在了', (tester) async {
      final prefs = _fakeChannels(tester);
      _phoneSized(tester);
      prefs.profile = _profile().encode();
      prefs.history = encodeHistory([_record()]);

      await tester.pumpWidget(MaterialApp(
        theme: buildVitalTeenTheme(),
        home: const AppEntry(splashDuration: Duration.zero),
      ));
      await _settleStage(tester);
      await _tapTab(tester, '我的');

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await _settleStage(tester);

      // 「读不出来就问一次」与「刚清完」走到同一个地方 —— 用户看不出差别，
      // 也不需要看出差别。
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      // 盘上真的没了，而不是只在内存里假装没了。
      expect(prefs.profile, isNull);
      expect(prefs.history, isNull);
    });
  });

  // 「该锁哪个方向」那条规则本身在 `platform/orientation_test.dart` 里穷举过
  // （纯函数，八种组合）。这一组问的是**另一件事**：这条规则有没有真的被接上。
  //
  // 接错的失败方式是静默的 —— 方向调用照样发出去、照样成功，只是发的是错的
  // 那一个，而屏幕上什么都看不出来。所以这里必须从「点开一个动作」一路走到
  // 练习页，验的是整条装配：`_go` 是 `_stage` 的唯一写入口、`SquatPage` 上报
  // 过报告态、`resumed` 时重钉。少接一根线，这里就红。
  //
  // **这一组验不到报告那一次。** 「练完出报告时转回竖屏」要一组真的做完
  // （起相机、喂帧、走完状态机），主机上做不到 —— 它是计划里那条真机验收
  // （验收清单第 4 条）。规则那一半（`reportShown` 为真时落竖屏）在
  // `orientation_test.dart` 里已经穷举，这里缺的只是「SquatPage 有没有把它
  // 报上来」这一根线。
  group('方向：进练习页锁横屏，其余每一屏都竖屏', () {
    /// 点开一个动作的卡片，走到它的预览页。
    Future<void> openPreview(WidgetTester tester, String nameZh) async {
      await tester.tap(find.text(nameZh));
      await _settleStage(tester);
    }

    /// 从预览页按「开始」，走进练习页，**等它把身体那一层渲染出来**。
    ///
    /// 练习页进来第一件事是读阈值表（`squat_page.dart` 的 `_boot`），而它走的是
    /// 资产通道 —— 回复来自真实事件循环，`pump` 推的那个假时钟推不动它。
    /// 不放真实事件循环跑一下，页面会永远停在转圈上：`_loaded` 到不了 `_Ready`，
    /// `_body` 不渲染，于是「引导在不在」这件事根本无从验起（不是「没有引导」，
    /// 是「还没有页面」—— 两者在这个断言下长得一模一样）。
    ///
    /// 所以这里交替放真实事件循环与推帧，直到看见 `BottomSurface`：
    /// **它只在 `_body` 的浮层里**，也就是「读表那一关过了」的记号。
    /// 用固定时长的 `delayed` 也可以，但那种写法会随机器快慢时绿时红 ——
    /// 而它红的方式偏偏是「引导不见了」，看起来像功能坏了。
    ///
    /// 这一段**只为了让页面自己走完**，没有给 `SquatPage` 或 `AppEntry`
    /// 开任何注入口 —— 与这个文件一贯的口径一致。
    Future<void> startExercise(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, '开始'));
      await _settleStage(tester);

      // **先把这个进程里的资产缓存清掉。** `rootBundle` 是进程级的单例
      //（`CachingAssetBundle`），它把「正在读」的那个 `Future` 按 key 存下来，
      // 而那个 `Future` 是在**上一个用例的假时钟**里建起来的 —— 上一个用例
      // 一结束，它的 zone 就没了，于是后面每一个用例都等在同一个永远不完成的
      // `Future` 上。表现是本组里只有第一条用例过得了读表那一关。
      (rootBundle as CachingAssetBundle).clear();

      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(BottomSurface).evaluate().isNotEmpty) return;
      }
      fail('练习页一直停在读阈值表上 —— `_boot` 没走完');
    }

    testWidgets('立定跳远：预览页竖屏，进练习页切成横屏并出引导', (tester) async {
      await _enterShell(tester, profile: _profile());
      final spy = OrientationSpy(tester);

      await openPreview(tester, '立定跳远');
      expect(
        spy.last,
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
        reason: '预览页是竖屏 —— 那一屏看的是动作简笔画，横过来没有好处',
      );

      await startExercise(tester);

      expect(
        spy.last,
        [DeviceOrientation.landscapeLeft],
        reason: '进练习页那一下必须钉横屏。**只有一个朝向** —— 两个横的朝向'
            '是「跟着传感器走」，引导图上那句「往哪边转」就时对时错',
      );
      expect(
        find.byType(LandscapeGuide),
        findsOneWidget,
        reason: '锁横屏与出引导是同一件事的两半：手机还竖着拿的用户会先看到'
            '一个躺倒的界面',
      );
    });

    testWidgets('引导确认之后就不在了', (tester) async {
      await _enterShell(tester, profile: _profile());
      await openPreview(tester, '立定跳远');
      await startExercise(tester);

      await tester.tap(find.text('已经横过来了'));
      await _settleStage(tester);

      expect(find.byType(LandscapeGuide), findsNothing);
      expect(find.byType(SquatPage), findsOneWidget, reason: '人还在练习页上');
    });

    testWidgets('深蹲：练习页也是竖屏，而且没有引导', (tester) async {
      // 站姿动作竖着拍更满，强制横过来只会把画面浪费在两侧。这一条同时是
      // 「`requiresLandscape` 被真的读到了」的对照组 —— 少了它，
      // 上面那条在「所有动作都锁横屏」时也会绿。
      await _enterShell(tester, profile: _profile());
      final spy = OrientationSpy(tester);

      await openPreview(tester, '深蹲');
      await startExercise(tester);

      expect(
        find.byType(SquatPage),
        findsOneWidget,
        reason: '这条前提要成立才有意义',
      );
      expect(
        find.byType(BottomSurface),
        findsOneWidget,
        reason: '页面已经渲染出身体那一层了 —— 少了它，下面那条「没有引导」'
            '在页面还停在转圈时也会绿',
      );
      expect(spy.last, [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      expect(find.byType(LandscapeGuide), findsNothing);
    });

    testWidgets('退出练习页就回到竖屏', (tester) async {
      // 练习页上的返回走的是 `_goShell`，也就是 `_go` 那条唯一的路 ——
      // 这一条验的是它真的把方向也带回来了。
      await _enterShell(tester, profile: _profile());
      await openPreview(tester, '立定跳远');
      await startExercise(tester);
      final spy = OrientationSpy(tester);

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(spy.last, [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });
  });

  group('成长页', () {
    /// 首页那张打卡卡。**必须限定在首页里**：四个标签挂在同一个 `IndexedStack`
    /// 上，「我的」那张等级卡上也有「连续打卡」三个字。
    Finder homeCard() => find.descendant(
          of: find.byType(HomePage),
          matching: find.textContaining('连续打卡'),
        );

    testWidgets('首页那张卡点得动，返回回「开始运动」', (tester) async {
      await _enterShell(
        tester,
        profile: _profile(),
        history: [_record(actionNameZh: '深蹲')],
      );

      await tester.tap(homeCard());
      await _settleStage(tester);
      expect(find.byType(GrowthPage), findsOneWidget);
      expect(find.text('我的成长'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await _settleStage(tester);

      expect(find.byType(GrowthPage), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      expect(_destination('开始运动'), findsOneWidget);
    });

    testWidgets('从「我的」那张等级卡进来，返回回「我的」', (tester) async {
      // 从哪来回哪去：在「我的」上点开，返回不该把人扔到「开始运动」。
      await _enterShell(tester, profile: _profile());
      await _tapTab(tester, '我的');

      await tester.tap(find.descendant(
        of: find.byType(MePage),
        matching: find.textContaining('Lv.'),
      ));
      await _settleStage(tester);
      expect(find.byType(GrowthPage), findsOneWidget);

      await _pressSystemBack(tester);
      await _settleStage(tester);

      expect(find.byType(GrowthPage), findsNothing);
      expect(find.byType(MePage), findsOneWidget);
    });
  });
}
