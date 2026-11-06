/// 品牌图能不能真的装进来，以及两份开屏稿是不是同一张。
///
/// ## 为什么这条值得单独写
///
/// 图片加载失败**不会报错**，它只是不显示。所以坏掉的方式全是**改一个字符串**：
/// `pubspec.yaml` 的 `assets:` 里少一行、文件名改了但常量没跟着改、路径大小写不对。
/// 这三种在开发机上都不会红，要等到装到手机上、或者等到用户说「开屏是白的」。
///
/// 所以它按**运行时会用的那个常量**去 `rootBundle.load`，而不是把路径
/// 再抄一遍 —— 抄一遍的话，常量改错时这条测试跟着一起错，就成了复述。
///
/// ## 第二条守的是「同一个文件抄了两份」
///
/// 开屏稿有两份拷贝：Flutter 那边的 `assets/images/splash.webp`，
/// 与 Android 启动窗口那边的 `res/drawable-nodpi/launch_image.webp`。
/// 两份**必须逐字节相同**：它们是同一屏画面的前后两半，引擎启动时放前一份、
/// Flutter 接手后放后一份，差一点就会在交接处跳一下。
///
/// 这一条不能靠「记得两边一起换」—— 换了 Flutter 那份而忘了 drawable 那份，
/// 应用照跑、测试照绿，只是开屏会闪。所以这里直接比字节。
///
/// 之所以是两份而不是一份：Android 的资源系统读不到 `assets/` 里的东西，
/// 而 Flutter 的 `Image.asset` 读不到 `res/` 里的东西 —— 这一份重复没有
/// 别的解法，只能守着。
///
/// 顺带钉住 WebP 这个格式：谁把 `splash.webp` 换成 PNG 而没改常量，第一条会红。
///
/// `assets/images/` 下另有两张（`brand_logo.webp`、`hero_runner.webp`）来自
/// 已经删掉的欢迎页，现在没有代码引用它们 —— 保留在目录里等插图位用。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/ui/splash_page.dart';

/// Android 启动窗口那张图的路径，**相对于包根目录**（`flutter test` 就是在那儿跑的）。
const String _launchDrawablePath =
    'android/app/src/main/res/drawable-nodpi/launch_image.webp';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('开屏那张图装得进来', () async {
    for (final path in [SplashPage.artworkPath]) {
      final data = await rootBundle.load(path);
      // 下限取 1 KB：这张图是 86 KB，这个数只是用来排除
      // 「文件在、但是空的」这一种 —— 它同样不会报错，只是画不出来。
      expect(data.lengthInBytes, greaterThan(1024), reason: '$path 装进来了却是空的');
    }
  });

  test('启动窗口那张开屏稿与 Flutter 开屏的那张逐字节相同', () async {
    final drawable = File(_launchDrawablePath);
    expect(
      drawable.existsSync(),
      isTrue,
      reason: '找不到 $_launchDrawablePath —— 启动窗口会退回纯白，'
          '而 Flutter 那边照常放出图来，于是开屏先白后跳',
    );

    final asset = await rootBundle.load(SplashPage.artworkPath);
    expect(
      drawable.readAsBytesSync(),
      asset.buffer.asUint8List(),
      reason: '两份开屏稿不一样了。它们是同一屏画面的前后两半，'
          '要在同一步里一起换（做法见 docs/brand-assets.md）',
    );
  });
}
