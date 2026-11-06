/// 「我的」页的测试。
///
/// 上半组是从 `home_page_test.dart` 的「资料卡」那一组**搬过来的**，不是重写的：
/// 那五条测的是一条产品规则（**资料要看得见、旧了要提醒、而且绝不自动加年龄**），
/// 而这条规则的家随着那张卡片一起从首页搬到了这里。规则没有变，所以断言也
/// 不该变 —— 改的只是入口（原先点整张卡，现在点「编辑资料」那一行）。
///
/// 下半组是这一页新有的三件事：昵称怎么称呼、关于对话框、以及清除本机数据。
/// 最后一件是全应用唯一不可逆的动作，三条路都要钉住：**取消不删、失败要说、
/// 成功不吭声**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/ui/app_icons.dart';
import 'package:vitalteen_app/ui/avatar_image.dart';
import 'package:vitalteen_app/ui/illustration_slot.dart';
import 'package:vitalteen_app/ui/me_page.dart';
import 'package:vitalteen_app/ui/privacy_note.dart';
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

Future<void> _mount(
  WidgetTester tester, {
  Profile? profile,
  VoidCallback? onEditProfile,
  Future<bool> Function()? onClearData,
  String? avatarPath,
  VoidCallback? onChangeAvatar,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: MePage(
      profile: profile ?? _profile(),
      onEditProfile: onEditProfile ?? () {},
      onClearData: onClearData ?? () async => true,
      avatarPath: avatarPath,
      onChangeAvatar: onChangeAvatar,
    ),
  ));
  await tester.pumpAndSettle();
}

/// 把某个插图位的兜底**单独画一次**，返回一个能对它断言的树。
///
/// 为什么不直接断言屏幕上那个字：**图在不在是资产的事，不是代码的事。**
/// 按 `docs/brand-assets.md`，用户把 `avatar.webp` 丢进 `assets/images/`
/// 头像就该换成那张图，而这个文件一行都不该改 —— 测试也是代码。
/// 所以这里绕开 `Image.asset`（它的 `errorBuilder` 只看文件在不在），
/// 直接把兜底那一个控件画出来：断的是「兜底是什么」，与图在不在无关。
Future<void> _pumpFallback(WidgetTester tester, IllustrationSlot slot) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: Center(child: slot.fallback),
  ));
  await tester.pumpAndSettle();
}

/// 「我的」页上那个头像图位。每一页只有一个，所以不加限定也找得到。
IllustrationSlot _avatarSlot(WidgetTester tester) =>
    tester.widget<IllustrationSlot>(find.byType(IllustrationSlot));

/// 头像右下角那个「能换」的角标。
///
/// 断的是应用自己那套线性图标里的相机，而不是 Material 的字形 ——
/// 重设计之后这两个标记不再混用。
Finder _cameraBadge() => find.byWidgetPredicate(
      (widget) => widget is AppIcon && widget.glyph == AppGlyph.camera,
    );

void main() {
  group('资料摆出来了', () {
    testWidgets('六项与更新日期都摆在上面', (tester) async {
      final profile = _profile(daysAgo: 3);
      await _mount(tester, profile: profile);

      expect(find.text('女 · 16 岁 · 高一 · 高中女子'), findsOneWidget);
      expect(find.text('身高 165 cm · 体重 52.5 kg'), findsOneWidget);
      // 日期要按**档案里那个时间**断言，不是「今天」——
      // 写成今天的话这条测试只在当天填的资料上成立。
      expect(
        find.textContaining(formatProfileDate(profile.updatedAt)),
        findsOneWidget,
      );
    });

    testWidgets('整数体重不显示小数点', (tester) async {
      // 「体重 52.0 kg」看起来像是精确到 0.1 的测量，但用户只填了 52。
      await _mount(tester, profile: _profile().copyWith(weightKg: 52));
      expect(find.text('身高 165 cm · 体重 52 kg'), findsOneWidget);
    });

    testWidgets('标题不与底栏那个标签逐字相同', (tester) async {
      // 底栏上它叫「我的」。标题再写一遍的话，屏幕上会出现两个一模一样的词，
      // 而测试里 `find.text('我的')` 会一次找到两个 —— 那是个离改动很远的
      // 文件里才会红的东西。
      await _mount(tester);
      expect(find.text('我的'), findsNothing);
      expect(find.text('我的资料'), findsOneWidget);
    });
  });

  group('昵称', () {
    testWidgets('填了就叫昵称', (tester) async {
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));
      expect(find.text('小北'), findsOneWidget);
    });

    testWidgets('没填就叫「同学」，不是空着一块', (tester) async {
      // 一个空着的位置看着像出了错，而「同学」是这类应用对未成年用户
      // 最自然的称呼（`profile.dart` 的 `profileDisplayName`）。
      await _mount(tester);
      expect(find.text('同学'), findsOneWidget);
    });

    testWidgets('头像图位读的是 avatar.webp，兜底画的是称呼的第一个字', (tester) async {
      await _mount(tester, profile: _profile().copyWith(nickname: '小北'));

      final slot = _avatarSlot(tester);
      expect(slot.path, 'assets/images/avatar.webp');

      await _pumpFallback(tester, slot);
      expect(find.text('小'), findsOneWidget);
    });

    testWidgets('昵称以 emoji 开头时，取到的是整个 emoji 不是半个', (tester) async {
      // `name[0]` 取到的是代理对的前一半，画出来是一个「口」。
      //
      // 这条与图在不在无关，走的也是兜底那一个控件：兜底即使在图放进来之后
      // 也仍然存在（图掉了的那天它要顶上来），而首字取错的代价是
      // 用户头像上永远挂着一个「口」。
      await _mount(tester, profile: _profile().copyWith(nickname: '🏃阿哲'));

      await _pumpFallback(tester, _avatarSlot(tester));
      expect(find.text('🏃'), findsOneWidget);
    });
  });

  group('资料旧了', () {
    testWidgets('填了不到一年：不提示更新', (tester) async {
      await _mount(tester, profile: _profile(daysAgo: 300));
      expect(find.textContaining('一年多前'), findsNothing);
    });

    testWidgets('填满一年：提示更新，且不擅自改年龄', (tester) async {
      // 提示里必须还是用户填的那个年龄 —— 自动加一岁是替用户编数据。
      await _mount(tester, profile: _profile(daysAgo: 400));

      expect(find.textContaining('一年多前'), findsOneWidget);
      expect(find.text('女 · 16 岁 · 高一 · 高中女子'), findsOneWidget);
    });

    testWidgets('提示那句写着「点这里更新」，那就得真的点得动', (tester) async {
      var edits = 0;
      await _mount(
        tester,
        profile: _profile(daysAgo: 400),
        onEditProfile: () => edits++,
      );

      await tester.tap(find.textContaining('一年多前'));
      await tester.pump();

      expect(edits, 1);
    });
  });

  group('编辑资料', () {
    testWidgets('点那一行去改资料', (tester) async {
      var edits = 0;
      await _mount(tester, onEditProfile: () => edits++);
      await tester.tap(find.text('编辑资料'));
      await tester.pump();

      expect(edits, 1);
    });
  });

  group('换头像', () {
    testWidgets('传了 onChangeAvatar：点头像触发一次，并挂一个相机角标', (tester) async {
      var changes = 0;
      await _mount(tester, onChangeAvatar: () => changes++);

      // **角标是唯一的线索。** 一个能点的头像与一个不能点的头像长得
      // 一模一样 —— 没有它，没人知道那儿能点。
      expect(_cameraBadge(), findsOneWidget);

      await tester.tap(find.byType(AvatarImage));
      await tester.pump();

      expect(changes, 1);
    });

    testWidgets('没传 onChangeAvatar：点不动，也不画角标', (tester) async {
      // 钉住那个可选参数的语义 —— 它是「纯展示」与「可换」的分水岭，
      // 网上（`main.dart` 的 `_Shell`）传的是可换的那一份。
      await _mount(tester);

      expect(_cameraBadge(), findsNothing);
      expect(
        find.ancestor(
          of: find.byType(AvatarImage),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('传了 avatarPath 时圆里画的是那张图，不是首字母', (tester) async {
      // 路径是编的（文件不存在）—— 这里要的是「`Image.file` 真的被喂了那个
      // 路径」，不是「图能画出来」。文件不存在时走 `errorBuilder` 退回首字母，
      // 而那条路正是 `avatar_image_test.dart` 要单独钉的东西。
      await _mount(tester, avatarPath: '/nonexistent/vitalteen-avatar.png');

      final image = tester.widget<Image>(find.descendant(
        of: find.byType(AvatarImage),
        matching: find.byType(Image),
      ));
      expect((image.image as FileImage).file.path,
          '/nonexistent/vitalteen-avatar.png');
      // 中间那一层（设计师那张默认头像）这时不该在树上 —— 用户图赢了。
      expect(find.byType(IllustrationSlot), findsNothing);
    });
  });

  group('关于', () {
    testWidgets('点开是一个对话框，里面说的是画面去哪了', (tester) async {
      await _mount(tester);
      expect(find.text(kPrivacyNoteText), findsNothing);

      await tester.tap(find.text('关于健知行绎'));
      await tester.pumpAndSettle();

      expect(find.text(kPrivacyNoteText), findsOneWidget);
    });

    testWidgets('点「知道了」关掉', (tester) async {
      await _mount(tester);
      await tester.tap(find.text('关于健知行绎'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.text(kPrivacyNoteText), findsNothing);
    });
  });

  group('清除本机数据', () {
    testWidgets('先弹确认框，说清后果', (tester) async {
      var clears = 0;
      await _mount(tester, onClearData: () async {
        clears++;
        return true;
      });

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();

      // 断言要**限定在对话框里**：卡片上那一行的副标题也写着「删了就找不回来」
      //（同一句话在按之前就该看得到），不限定的话这里会一次找到两个。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('删了就找不回来'),
        ),
        findsOneWidget,
      );
      // **点开确认框本身不删任何东西。**
      expect(clears, 0);
    });

    testWidgets('两处文案都把头像枚举进去 —— 它也是被删掉的三样之一', (tester) async {
      // 头像是**后来才加进来的第三样**，而这两句话原本只写「资料和练习记录」。
      // 漏枚举不会让别的测试变红，用户在删完之后才发现头像也没了 ——
      // 所以这里断的是**具体那句话**，不是「含有『删了就找不回来』」。
      await _mount(tester, onClearData: () async => true);

      // 卡片上那一行，点之前就该看得到。
      expect(find.text('资料、练习记录和头像一起删，删了就找不回来'), findsOneWidget);

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('资料、练习记录和头像都会从这台手机上删掉，删了就找不回来。'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('点「取消」：什么都不发生', (tester) async {
      var clears = 0;
      await _mount(tester, onClearData: () async {
        clears++;
        return true;
      });

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(clears, 0);
    });

    testWidgets('点「删除」：清一次', (tester) async {
      var clears = 0;
      await _mount(tester, onClearData: () async {
        clears++;
        return true;
      });

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(clears, 1);
    });

    testWidgets('清成功了不吭声 —— 页面这时已经被换掉', (tester) async {
      await _mount(tester, onClearData: () async => true);

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('没清干净要说一声', (tester) async {
      // **失败时内存与盘都不动**（由调用方保证），这里只负责让用户知道
      // 刚才那一下没有生效 —— 否则他会以为删掉了，而下次打开资料又回来了。
      await _mount(tester, onClearData: () async => false);

      await tester.tap(find.text('清除本机数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('没能清干净，请再试一次。'), findsOneWidget);
    });
  });
}
