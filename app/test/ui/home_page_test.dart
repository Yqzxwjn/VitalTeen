/// 动作首页的测试。
///
/// **这里测的是一件产品规则，不是排版**：未开放的动作照列、必须一眼看出
/// 没上线、而且点得进去 —— 点进去看到的是预览，不是空白。
/// 「一个点进去是空白的入口，比没有入口更伤」这条早先由欢迎页立着
///（那一屏也删掉了，见 `app/README.md` 的「入口流程」），现在只有这张卡片是它的执行方式，
/// 所以它得有测试。
///
/// **这条规则变过一次，测试要跟上**：原先未开放就是「连 `InkWell` 都没有」，
/// 因为那时点进去真的是空白。有了预览页之后，「点得动」不再等于骗人，
/// 而「未开放」那三个字也不能跟着一起消失 —— 能看 ≠ 能练。
///
/// **它现在一次也没有活着的例子**：坐位体前屈上线之后，清单里九项全是 `live`。
/// 所以「未开放长什么样」那几条挂在一个**合成的预留条目**上（[kReservedEntry]），
/// 而不是去遍历一份今天恰好为空的清单 —— 后者会绿着什么也没测，
/// 而下一个动作还在做的时候又得回来重写一遍。
///
/// 第二条是**清单自身的完整性**：已上线的动作是哪几个，是有名单的。
/// 谁把某个动作的状态改成 live 却没写页面（或没写产品身份），这里就红 ——
/// 否则那个 bug 要等到用户点进去才现身，而那时它是一个空白页，
/// 或者是一张点了没反应的卡片。
///
/// 第三条是**横幅那两行字**。它原来是一张资料卡，改版之后压到了插图横幅上，
/// 于是多了两件必须钉住的事：**那一行摘要不能跟着卡片一起消失**（「让资料
/// 看得见」是 `profile.dart` 立下的产品承诺，而这是它唯一还看得见的地方），
/// 以及**横幅上不能出现端到端测试会裸 `find.text` 的那些词**（「开始」
/// 「深蹲」…… 见 `home_page.dart` 文件头）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/greeting.dart';
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/ui/avatar_image.dart';
import 'package:vitalteen_app/ui/exercise_catalog.dart';
import 'package:vitalteen_app/ui/exercise_preview.dart';
import 'package:vitalteen_app/ui/home_page.dart';
import 'package:vitalteen_app/ui/illustration_slot.dart';
import 'package:vitalteen_app/ui/preview_poses.dart';
import 'package:vitalteen_app/ui/theme.dart';

Profile _profile({int daysAgo = 3}) => Profile(
      sex: Sex.female,
      age: 16,
      grade: '高一',
      standardGroup: '高中女子',
      heightCm: 165,
      weightKg: 52.5,
      updatedAt: DateTime.now().subtract(Duration(days: daysAgo)),
    );

Future<List<ExerciseEntry>> _mount(
  WidgetTester tester, {
  Profile? profile,
  String? avatarPath,
  List<ExerciseSection>? sections,
}) async {
  final opened = <ExerciseEntry>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: HomePage(
      profile: profile ?? _profile(),
      onOpenExercise: opened.add,
      avatarPath: avatarPath,
      sections: sections ?? kExerciseSections,
    ),
  ));
  // 卡片图位在没有图时会落到兜底（简笔人形），而缺文件的错误是异步回来的。
  // 不等它，`find.byType(Image)` 那类断言会看到一棵还没定下来的树。
  await tester.pumpAndSettle();
  return opened;
}

/// 一条**预留**条目，装在它自己的分区里，供下面那几条「未开放长什么样」用。
///
/// **为什么要自己造一个。** 目录里九项现在全是 `live` —— 坐位体前屈上线之后，
/// `kExerciseSections` 里一个预留项都没有了。而「未开放的卡片不挂图位、
/// 不画小人、但仍然点得动、名字旁边挂一句『未开放』」是一条立过的产品规则
///（见本文件顶部），**不该因为今天没有活着的例子而失守**。
///
/// 所以让它上合成条目，而不是让那几条断言去遍历一份今天恰好为空的清单 ——
/// 那种写法会**绿着什么也没测**，而下一个动作还在做的时候又得回来重写一遍。
///
/// `code` 用一个真动作不会用的值：预留卡不读 `preview_poses.dart`
/// （那正是要钉住的事之一），所以这个码取不到缩略图也不会出问题。
const ExerciseEntry kReservedEntry = ExerciseEntry(
  code: 'TEST_RESERVED',
  nameZh: '预留动作',
  tagline: '这条只是测试用的预留条目，用来钉住「未开放」那一套长相。',
  status: ExerciseStatus.reserved,
  note: '测试用',
  icon: Icons.straighten,
);

/// 把 [kReservedEntry] 单独装进一个分区。
ExerciseSection _reservedSection() => const ExerciseSection(
      title: '测试分区',
      accent: Color(0xFF5B3BB8),
      entries: [kReservedEntry],
    );

/// 点一个卡片。**先滚到它那儿** —— 横幅把整列往下推了 170 多像素，
/// 而默认测试窗口只有 600 逻辑像素高，靠后那几张卡在窗口外面。
///
/// `tester.tap` 对窗口外的控件**只打一条 warning 不失败**（`WidgetController`），
/// 于是测试会绿着，而它什么都没点到 —— 这是这一带最阴的一种坏法。
Future<void> _tapEntry(WidgetTester tester, String nameZh) async {
  final target = find.text(nameZh);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pump();
}

/// 某张卡片上那个图位。
///
/// 读的是**控件本身**（`tester.widget`），不是它渲染出来的东西 —— 图在不在
/// 决定渲染什么，而这一组断言要问的是「这个位置配的是什么」。
IllustrationSlot _slotOf(WidgetTester tester, ExerciseEntry entry) =>
    tester.widget<IllustrationSlot>(find.descendant(
      of: find.ancestor(of: find.text(entry.nameZh), matching: find.byType(Card)),
      matching: find.byType(IllustrationSlot),
    ));

/// 兜底里画的那个小人。
///
/// 往里找一层是因为兜底外面包着一圈内边距（人形压满 56 像素的方格会顶到边）。
/// 断言不该因为「多包了一个 `Padding`」而红。
StickFigureThumbnail? _figureIn(Widget fallback) => switch (fallback) {
      StickFigureThumbnail() => fallback,
      Padding(child: final Widget child) => _figureIn(child),
      _ => null,
    };

/// 横幅那一整块（外面那个 `ClipRRect`）。
///
/// **锚的是横幅自己那张插图。** 锚问候语那一路往上会穿过好几个 `Stack`
/// （`Scaffold` 与卡片里都有），`find.descendant` 会把同一个孩子数出好几遍；
/// 而横幅那张插图在首页只有一处，它外面那层 `ClipRRect` 也只有一处。
Finder _bannerOf() => find.ancestor(
      of: find.byWidgetPredicate(
          (w) => w is IllustrationSlot && w.path == 'assets/images/hero_home.webp'),
      matching: find.byType(ClipRRect),
    );

void main() {
  group('动作清单本身', () {
    test('编码不重复', () {
      final codes = [for (final e in allExercises()) e.code];
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('已上线的有深蹲、立定跳远、开合跳、俯卧撑、仰卧起坐、跳绳、引体向上、平板支撑与坐位体前屈这九个', () {
      // 这条拦的是：某人把某个占位的状态改成 live，却没写对应的页面。
      // 那一刻首页会多出一个能点、点进去是空白的入口 —— 与其等用户来发现，
      // 不如在这里红。
      //
      // **写成清单而不是「只有一个」**：上线的动作会一个个多起来，
      // 断言数目等于 1 的那一版在加第二个动作时就只能删掉，而删掉之后
      // 这条哨兵就没了。列出名字，它就一直管用 —— 加第十个动作时它会先红，
      // 提醒你去确认页面真的接上了，然后再把名字加进来。
      //
      // 坐位体前屈就是第九个：它上线的这一轮是把 `reserved` 转成 `live`
      // 并补上产品身份（`srtSpec`），这条断言当时先红了，正合用途。
      final live = [for (final e in allExercises()) if (e.isLive) e.code]..sort();
      // 排序是**字典序**，不是按动作长短：「SQUAT」的第 3 个字母是 `Q`，
      // 排在「SU」的 `U` 前面；「SRT」按 `R` 排在「SQUAT」的 `Q` 之后、
      // 「SU」之前；「PULLUP」按 `U` 排在「PU」之后、「ROPE」之前；
      // 「PLANK」按 `L` 排在「PU」之前 —— 与「PULLUP」只差一个字母，
      // 顺序却不相邻。
      expect(
        live,
        ['JJ', 'PLANK', 'PU', 'PULLUP', 'ROPE', 'SLJ', 'SQUAT', 'SRT', 'SU'],
      );
    });

    test('每个已上线的动作都有对应的产品身份', () {
      // 上一条管的是「首页能点」，这一条管的是「点了真的有东西」：
      // `main.dart` 的分派靠 `specForCode` 查表，查不到就静默不响应 ——
      // 表现是一个点下去没反应的卡片，和预留卡长得一样。
      for (final entry in allExercises()) {
        if (!entry.isLive) continue;
        expect(
          specForCode(entry.code),
          isNotNull,
          reason: '${entry.code} 是 live 的，但没有 ActionSpec，点进去不会有任何反应',
        );
      }
    });

    // 「阈值表里有没有这个动作的行」不在这里测：它需要真的构造一次会话，
    // 而那是 `test/app/slj_session_test.dart` 的「真实资产表 · 整条会话」组
    // 在做的事（而且做得更严 —— 缺的键是在标定结束那一刻抛出来的）。
    // 在这里再抄一遍只会得到一条更弱的、还多一个要同步的文件路径。

    test('每个分区都不是空的，每个条目都说得出自己要干什么', () {
      for (final section in kExerciseSections) {
        expect(section.entries, isNotEmpty, reason: section.title);
        for (final entry in section.entries) {
          expect(entry.nameZh, isNotEmpty, reason: entry.code);
          // 预留项的 tagline 尤其重要：那是用户唯一能看到的信息。
          expect(entry.tagline.length, greaterThan(8), reason: entry.code);
        }
      }
    });

    test('预留项都写了什么时候上线或为什么测不了', () {
      // 只有「未开放」三个字的占位卡，用户看不出它是不是被放弃了。
      //
      // 今天清单里没有预留项，所以这一条空转 —— 但**保持它是关系式的、不删**：
      // 下一个动作先摆出来还不给练的时候，它会立刻开始管用。
      for (final entry in allExercises()) {
        if (entry.isLive) continue;
        expect(entry.note, isNotNull, reason: '${entry.nameZh} 缺 note');
      }
      expect(
        kReservedEntry.note,
        isNotNull,
        reason: '合成的那条预留条目自己也得守这条规矩，否则这个循环的模板是空转的',
      );
    });

    test('已上线的动作也要写明它测不出什么', () {
      // 这是本项目一以贯之的口径（设计文档附录 A：单目无标定测不出绝对距离）。
      // 首页文案把它说成能测成绩，就是在承诺一个做不到的东西。
      //
      // **上线之后这条更要紧，不是更不要紧**：立定跳远现在点得进去了，
      // 而「能点进去」本身就会被读成「能测成绩」。所以 note 留在原地。
      final slj = exerciseByCode('SLJ')!;
      expect(slj.isLive, isTrue, reason: '它上线之后才轮到这条断言真的有用');
      expect(slj.tagline + slj.note!, contains('测不出'));
    });

    test('按编码找得到、找不到给 null', () {
      expect(exerciseByCode('SQUAT')?.nameZh, '深蹲');
      expect(exerciseByCode('没有这个码'), isNull);
    });
  });

  group('点得动', () {
    testWidgets('「未开放」的个数与清单一致 —— 今天这个数是 0', (tester) async {
      await _mount(tester);
      // 目录里九项全是 live（坐位体前屈上线了），所以今天左边右边都是 0。
      // **留着它不是为了今天**：下一个动作还在做的时候，`reserved` 会重新
      // 出现在清单里，这条**关系**（有几个未开放就挂几个标签）立刻开始真的
      // 管用 —— 而写成快照式的 `findsNWidgets(0)` 在预留项回来的那天会红得
      // 莫名其妙，逼着下一个人去猜为什么。
      final reserved = allExercises().where((e) => !e.isLive).length;
      expect(find.text('未开放'), findsNWidgets(reserved));
    });

    testWidgets('每一张卡都点得动 —— 包括未开放的', (tester) async {
      // 这一条原来是反过来断言的（未开放的不该有 `InkWell`），改的理由在
      // 本文件顶部。**现在它拦的是相反的错误**：谁把未开放的卡片改回
      // 「点不动」，这里先红。
      //
      // 挂的是**合成的那一个分区**：真清单里今天没有预留项，而这一条的名字
      // 里那半句「包括未开放的」只有它在的时候才成立。
      final opened = await _mount(tester, sections: [_reservedSection()]);

      final title = find.text(kReservedEntry.nameZh);
      expect(title, findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: title, matching: find.byType(Card)),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
        reason: '预留动作点不开，用户就看不到它的预览',
      );

      expect(opened, isEmpty);
    });

    testWidgets('点深蹲回调出 SQUAT', (tester) async {
      final opened = await _mount(tester);
      await _tapEntry(tester, '深蹲');

      expect(opened.map((e) => e.code), ['SQUAT']);
    });

    testWidgets('点立定跳远回调出 SLJ', (tester) async {
      // 上一条只点了深蹲。这一条盯的是**同一个回调对不同条目传的是不是
      // 各自的码** —— 回调写死成某一个动作时，那一条照样绿。
      final opened = await _mount(tester);
      await _tapEntry(tester, '立定跳远');

      expect(opened.map((e) => e.code), ['SLJ']);
    });

    testWidgets('点未开放的也回调，而且带的是它自己的码', (tester) async {
      // 首页**不管这个动作能不能练** —— 它只负责把人送到预览页，
      // 「只能看」那句话是预览页说的。首页在这里替它筛一遍的话，
      // 未开放的卡片就又变回点不动了。
      //
      // 挂合成分区：真清单里今天没有预留项（SRT 上线了），这一条要问的正是
      // 预留项那一条路径。
      final opened = await _mount(tester, sections: [_reservedSection()]);
      await _tapEntry(tester, kReservedEntry.nameZh);

      expect(opened.map((e) => e.code), [kReservedEntry.code]);
    });

    testWidgets('点开合跳（在窗口外面）也回调得到', (tester) async {
      // 这一条盯的是 `_tapEntry` 本身：靠后那几张卡在 600 像素的测试窗口外面，
      // 不先滚过去的话 `tap` 只打一条 warning 就过去了，测试绿着而什么都没点到。
      final opened = await _mount(tester);
      await _tapEntry(tester, '开合跳');

      expect(opened.map((e) => e.code), ['JJ']);
    });
  });

  group('顶部横幅', () {
    testWidgets('问候语带着称呼', (tester) async {
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));
      // 时分档的边界在自己那一组测试里（`test/app/greeting_test.dart`），
      // 这里只确认这句话真的接到了横幅上、而且用的是称呼。
      expect(find.textContaining('小北'), findsWidgets);
      expect(find.textContaining(greetingFor(DateTime.now())), findsOneWidget);
    });

    testWidgets('没填昵称就叫「同学」', (tester) async {
      await _mount(tester);
      expect(
        find.text('${greetingFor(DateTime.now())}，同学'),
        findsOneWidget,
      );
    });

    testWidgets('四行摘要还在 —— 这是「资料看得见」唯一剩下的落点', (tester) async {
      // 资料卡没了，资料页要主动点进去才看得到。这一行要是跟着卡片一起
      // 消失，用户就再也没有一处「顺手看见应用以为我是谁」的地方了。
      // `squat_widgets_test.dart` 也在断这同一行，两处一起才守得住。
      await _mount(tester);
      expect(find.text('女 · 16 岁 · 高一 · 高中女子'), findsOneWidget);
    });

    testWidgets('横幅的图位读的是 hero_home.webp', (tester) async {
      // 与卡片图位同一个理由：**文件名拼错不会报错、不会崩**，只会让图
      // 永远不显示（`errorBuilder` 接到「文件不存在」，转头去画装饰圆弧），
      // 界面看起来一切正常。
      //
      // 断的是控件读的路径，不是画出来的东西 —— 用户把图丢进
      // `assets/images/` 之后这一条照样绿（交付承诺见 `docs/brand-assets.md`）。
      // 卡片读的是 `ex_<code>.webp`（见下面那一组），两个路径不会撞。
      await _mount(tester);

      expect(
        find.byWidgetPredicate(
          (w) => w is IllustrationSlot && w.path == 'assets/images/hero_home.webp',
        ),
        findsOneWidget,
        reason: '首页横幅那张图读的不是 assets/images/hero_home.webp',
      );
    });

    testWidgets('横幅上不出现端到端测试会裸 find.text 的那些词', (tester) async {
      // 横幅在整张清单**上面**，它多出一个同名的字，`squat_widgets_test.dart`
      // 里那些 `tester.tap(find.text('开始'))` 就会一次找到两个然后失败 ——
      // 而失败信息指向的是一个离这里很远的文件。
      //
      // 用最长的昵称去撞：昵称是用户可控的，撞上黑名单的那一天要有测试先红。
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));
      final banner = find.ancestor(
        of: find.textContaining(greetingFor(DateTime.now())),
        matching: find.byType(Stack),
      );

      for (final word in const ['开始', '深蹲', '本组报告', '取消', '保存']) {
        expect(
          find.descendant(of: banner, matching: find.textContaining(word)),
          findsNothing,
          reason: '横幅上出现了「$word」，端到端测试的 tap 会撞上歧义',
        );
      }
    });

    testWidgets('横幅上不出现头像那张图 —— 这里只有用户图与首字母两层', (tester) async {
      // 横幅本来就压在一张插画（`hero_home.webp`）上，再叠一个设计师的默认
      // 头像圆盘只会更花。所以这一层**不套** `IllustrationSlot` ——
      // `AvatarImage` 的兜底直接就是首字母（`avatar_image.dart` 文件头）。
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));

      expect(
        find.byWidgetPredicate((w) =>
            w is IllustrationSlot && w.path == 'assets/images/avatar.webp'),
        findsNothing,
        reason: '横幅上出现了设计师那张默认头像，而那是「我的」页那一层的事',
      );
    });
  });

  group('横幅上的头像', () {
    testWidgets('没选过头像：画的是称呼的第一个字', (tester) async {
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));

      final banner = _bannerOf();
      expect(
        find.descendant(of: banner, matching: find.byType(AvatarImage)),
        findsOneWidget,
      );
      // 首字母画在横幅里 —— 「小」这个字在别处没有，所以不必限定横幅。
      expect(
        find.descendant(of: banner, matching: find.text('小')),
        findsOneWidget,
      );
    });

    testWidgets('选了头像：喂给 Image.file 的是那个路径', (tester) async {
      await _mount(tester, avatarPath: '/nonexistent/vitalteen-banner.png');

      // **必须限定到 `AvatarImage` 里面。** 横幅里这时有两个 `Image`：
      // 背景那张插图，和这个头像 —— 不限定的话 `tester.widget<Image>` 会
      // 一头撞上 `Bad state: Too many elements`。
      final image = tester.widget<Image>(find.descendant(
        of: find.byType(AvatarImage),
        matching: find.byType(Image),
      ));
      expect((image.image as FileImage).file.path,
          '/nonexistent/vitalteen-banner.png');
    });

    testWidgets('横幅仍然不可点 —— 换头像的入口只在「我的」页', (tester) async {
      // 同一件事有两个去处，用户会以为它们不一样（`home_page.dart` 里
      // `_HeroBanner` 的类注释）。所以头像在这里只是「让这屏认得出是谁」。
      await _mount(tester, avatarPath: '/nonexistent/vitalteen-banner.png');

      expect(
        find.descendant(of: _bannerOf(), matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _bannerOf(),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
        reason: '横幅上出现了手势，而它不该有任何可点的地方',
      );
    });

    testWidgets('长昵称 + 头像挤在一起也不溢出', (tester) async {
      // `Expanded` 挡的就是这一条：不加它，这一行的自然宽度是
      // 头像 + 间距 + 文字，而文字那个宽度是自由的 —— 长摘要会把横幅撑破。
      // 溢出在测试里不是 assertion，是**一条被报告的 FlutterError**，
      // 所以「跑过去没红」就是断言本身。
      await _mount(
        tester,
        profile: _profile().copyWith(nickname: '一二三四五六七八九十一二三四'),
        avatarPath: '/nonexistent/vitalteen-banner.png',
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('卡片图位', () {
    // **这一组不把「现在没有图」写死。** 四处插图位的交付承诺是
    // 「图丢进 `app/assets/images/` 即生效，不用改代码」（`docs/brand-assets.md`），
    // 而测试也是代码 —— 用户哪天真把那九张图做出来放进来了，这一组不该红。
    //
    // 所以下面断的全是**与图在不在无关**的东西：图位的路径、以及那个位置的
    // 兜底**是什么控件**。兜底即使在图到位之后也仍然在（图掉了的那天要顶上来），
    // 所以「兜底是这个小、不是空白」这条断言永远成立。
    testWidgets('每张已上线的卡片都有一个读到它自己名字的图位', (tester) async {
      // 这一条盯的是**文件名约定**：`assets/images/ex_<code>.webp`。
      // 一个拼错的动作码不会报错、不会崩，只会让那张图**永远不显示** ——
      // `errorBuilder` 接到「文件不存在」，转头去画兜底，界面看起来一切正常。
      // 这正是 `IllustrationSlot` 换来的好处，也是它唯一带来的风险。
      await _mount(tester);

      for (final entry in allExercises()) {
        if (!entry.isLive) continue;
        expect(
          _slotOf(tester, entry).path,
          'assets/images/ex_${entry.code}.webp',
          reason: '${entry.nameZh} 的图位没读到它自己的文件名',
        );
      }
    });

    testWidgets('没有图时画的是这个动作自己的小人，不是通用图标', (tester) async {
      // 少一个的表现是一块空的渐变方块 —— 而它同时丢掉了「一眼看出这是哪个动作」。
      for (final entry in allExercises()) {
        if (!entry.isLive) continue;
        expect(
          previewThumbnail(entry.code),
          isNotNull,
          reason: '${entry.code} 已上线，卡片上却画不出小人',
        );
      }

      await _mount(tester);
      for (final entry in allExercises()) {
        if (!entry.isLive) continue;
        final figure = _figureIn(_slotOf(tester, entry).fallback);
        expect(figure, isNotNull, reason: '${entry.nameZh} 的兜底里没有简笔小人');
        // 而且要的是**它自己的**那一拍，不是随便一个能画的小人。
        expect(figure!.code, entry.code, reason: '${entry.nameZh} 挂的是别的动作的小人');
      }
    });

    testWidgets('未开放的卡片挂着「未开放」，也没有图位、不画小人', (tester) async {
      // 断言从「不画小人」扩到「连图位都没有」：图位是给已上线动作留的，
      // 未开放的卡片借过来的话，用户会以为它快要能练了。
      //
      // 挂合成分区（理由见 [kReservedEntry]）：真清单里今天没有预留项，
      // 而这一条守的正是预留项那套长相。
      await _mount(tester, sections: [_reservedSection()]);

      expect(find.text('未开放'), findsOneWidget);

      final card = find.ancestor(
        of: find.text(kReservedEntry.nameZh),
        matching: find.byType(Card),
      );
      for (final what in const ['图位', '小人']) {
        final finder = what == '图位'
            ? find.byType(IllustrationSlot)
            : find.byType(StickFigureThumbnail);
        expect(
          find.descendant(of: card, matching: finder),
          findsNothing,
          reason: '${kReservedEntry.nameZh} 还没上线，却挂了已上线才有的 $what',
        );
      }
    });
  });

  // **「资料卡」那一组搬走了**（六项、整数体重、点进资料页、旧了要提醒），
  // 搬去 `me_page_test.dart`。它测的是一条产品规则，而那条规则的家——
  // 那张卡片——跟着这一轮改版从首页挪到了「我的」页。规则没变，断言就不该变。
  //
  // 这里留下的是横幅上那两行字，那是首页**现在**唯一与资料有关的东西。
}
