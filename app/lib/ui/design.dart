//设计系统：颜色、间距、圆角、字号与动效曲线
//
//**全应用只有这一处定义视觉常量。** 页面里不再出现 18.0、EdgeInsets.all(14)
//这类数字 —— 它们要么出自 [Space]，要么出自 [AppText]，要么说明为什么例外。
//一条页面上「看起来差不多」的间距，正是界面开始显得像模板的地方。
//
//字号全部落在 Tailwind 的默认字阶上（12/14/16/18/20/24/30/36/48），
//每一档的名字与 `ai-design-skills` 的 B1 文本样式一一对应：
//Heading 是标题、Title 是卡片与列表项、Body 是正文、Button 是按钮内文字、
//Caption 是说明与角标。别在页面里临时 `copyWith(fontSize: 19)`。
library;

import 'package:flutter/material.dart';

/// 颜色令牌。
///
/// 品牌四色（[brand]/[sky]/[leaf]/[orange]）取自 `docs/brand-assets.md`，
/// 是标志本身的填色，不随这一版界面改。其余是界面自己的中性色与语义色。
abstract final class AppColors {
  /// 页面底色。比卡片暗一档，让白卡片自己浮起来，不用描边也分得清。
  static const Color paper = Color(0xFFF2F4F7);

  /// 卡片与浮层。
  static const Color card = Color(0xFFFFFFFF);

  /// 主文字。
  static const Color ink = Color(0xFF111A24);

  /// 次级文字：说明、摘要、正文里的旁支。
  static const Color inkSoft = Color(0xFF3E4956);

  /// 三级文字：时间、计数、脚注、占位符。
  ///
  /// 这一档在 12 像素上仍然要过 AA 对比度（白底约 5:1、纸色底约 4.6:1）——
  /// 脚注再浅，就变成了「看起来像没写完」。
  static const Color inkFaint = Color(0xFF5F6A76);

  /// 分隔线。**只画在卡片内部或列表之间**，不给卡片描单边。
  static const Color hairline = Color(0xFFE2E7EE);

  /// 需要更明确边界时用（例如输入框）。
  static const Color hairlineStrong = Color(0xFFCBD4DF);

  static const Color brand = Color(0xFF0B3D91);
  static const Color brandDeep = Color(0xFF072B66);
  static const Color brandTint = Color(0xFFE9EFF9);
  static const Color brandTintStrong = Color(0xFFD6E2F5);

  static const Color sky = Color(0xFF16A9E0);
  static const Color skyTint = Color(0xFFE3F2FA);

  static const Color leaf = Color(0xFF3F7D2A);
  static const Color leafTint = Color(0xFFEAF2E3);

  static const Color orange = Color(0xFFF7911E);
  static const Color orangeTint = Color(0xFFFDF1E1);

  static const Color violet = Color(0xFF5B3BB8);
  static const Color violetTint = Color(0xFFEFEAFB);

  static const Color danger = Color(0xFFB3362A);
  static const Color dangerTint = Color(0xFFFBEBE9);

  /// 警示文案用的深琥珀，白底上对比度足够。
  static const Color warningInk = Color(0xFF8A4B06);

  /// 首页横幅那种深底上的文字。
  static const Color onDark = Color(0xFFFFFFFF);
  static const Color onDarkSoft = Color(0xFFC9D3E2);

  /// 深色相机页。
  static const Color cameraSurface = Color(0xFF080C10);
  static const Color cameraPanel = Color(0xFF141A22);

  /// 练习热力图的五档。浅 → 深，最后一档是品牌深蓝。
  static const List<Color> heatRamp = [
    Color(0xFFE3E8F0),
    Color(0xFFBFD5F2),
    Color(0xFF7FAAE6),
    Color(0xFF2F6BC4),
    Color(0xFF0B3D91),
  ];
}

/// 间距令牌。只有这些值。
///
/// 命名沿用设计稿的 Spacing-XXX（数字是百分之一档），所以 `s200` 就是 16。
abstract final class Space {
  static const double s0 = 0;
  static const double s25 = 2;
  static const double s50 = 4;
  static const double s75 = 8;
  static const double s100 = 12;
  static const double s200 = 16;
  static const double s300 = 24;
  static const double s400 = 32;
  static const double s500 = 40;
  static const double s600 = 48;
  static const double s700 = 64;
  static const double s800 = 80;
  static const double s900 = 96;
}

/// 圆角令牌。只允许这几档。
abstract final class Radii {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static BorderRadius get xsAll => BorderRadius.circular(xs);
  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
  static BorderRadius get xlAll => BorderRadius.circular(xl);
  static BorderRadius get pillAll => BorderRadius.circular(pill);
}

/// 动效。
///
/// 只有一条曲线：起步快、收尾慢，落位时像有重量。**不用 `Curves.ease`
/// 这类浏览器默认值** —— 它们到位太软，界面会显得没有做工。
abstract final class Motion {
  static const Curve curve = Cubic(0.22, 1, 0.36, 1);

  /// 颜色与透明度的变化。
  static const Duration fast = Duration(milliseconds: 300);

  /// 位置与尺寸的变化。
  static const Duration base = Duration(milliseconds: 500);

  /// 整页切换。
  static const Duration page = Duration(milliseconds: 400);
}

/// 文本样式。字阶与字重都从这里取，页面里不自己拼。
abstract final class AppText {
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;

  /// 每个样式都带同一份中文回退链。
  ///
  /// 这一步不能省：`ThemeData.fontFamilyFallback` 只作用于 `TextTheme`，
  /// 而 AppBar 的标题、按钮的 `textStyle` 这些**组件级**样式是整份替换的，
  /// 不会去合并正文的主题 —— 漏了就会出现「正文正常、标题变成方块」。
  static TextStyle _style({
    required double size,
    required double lineHeight,
    required FontWeight weight,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontSize: size,
      height: lineHeight / size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      fontFamilyFallback: kCjkFallback,
    );
  }

  static final TextStyle heading1 = _style(
    size: 60,
    lineHeight: 60,
    weight: semibold,
    letterSpacing: -0.5,
  );
  static final TextStyle heading2 = _style(
    size: 48,
    lineHeight: 48,
    weight: semibold,
    letterSpacing: -0.4,
  );
  static final TextStyle heading3 = _style(
    size: 36,
    lineHeight: 40,
    weight: semibold,
    letterSpacing: -0.3,
  );
  static final TextStyle heading4 = _style(
    size: 30,
    lineHeight: 36,
    weight: semibold,
    letterSpacing: -0.2,
  );
  static final TextStyle heading5 = _style(
    size: 24,
    lineHeight: 32,
    weight: semibold,
    letterSpacing: -0.1,
  );
  static final TextStyle heading6 = _style(
    size: 20,
    lineHeight: 28,
    weight: semibold,
  );

  static final TextStyle title1 = _style(
    size: 20,
    lineHeight: 28,
    weight: medium,
  );
  static final TextStyle title2 = _style(
    size: 18,
    lineHeight: 28,
    weight: medium,
  );
  static final TextStyle title3 = _style(
    size: 16,
    lineHeight: 24,
    weight: medium,
  );
  static final TextStyle title4 = _style(
    size: 14,
    lineHeight: 20,
    weight: medium,
  );
  static final TextStyle title5 = _style(
    size: 12,
    lineHeight: 16,
    weight: medium,
  );

  static final TextStyle body1 = _style(
    size: 16,
    lineHeight: 24,
    weight: semibold,
  );
  static final TextStyle body2 = _style(
    size: 16,
    lineHeight: 24,
    weight: medium,
  );
  static final TextStyle body3 = _style(
    size: 16,
    lineHeight: 24,
    weight: FontWeight.w400,
  );
  static final TextStyle body4 = _style(
    size: 14,
    lineHeight: 20,
    weight: semibold,
  );
  static final TextStyle body5 = _style(
    size: 14,
    lineHeight: 20,
    weight: medium,
  );
  static final TextStyle body6 = _style(
    size: 14,
    lineHeight: 20,
    weight: FontWeight.w400,
  );

  static final TextStyle buttonLg = _style(
    size: 18,
    lineHeight: 28,
    weight: semibold,
  );
  static final TextStyle buttonMd = _style(
    size: 16,
    lineHeight: 24,
    weight: semibold,
  );
  static final TextStyle buttonSm = _style(
    size: 14,
    lineHeight: 20,
    weight: semibold,
  );
  static final TextStyle buttonXsm = _style(
    size: 12,
    lineHeight: 16,
    weight: semibold,
  );

  static final TextStyle caption1 = _style(
    size: 14,
    lineHeight: 20,
    weight: medium,
  );
  static final TextStyle caption2 = _style(
    size: 14,
    lineHeight: 20,
    weight: FontWeight.w400,
  );
  static final TextStyle caption3 = _style(
    size: 12,
    lineHeight: 16,
    weight: semibold,
  );
  static final TextStyle caption4 = _style(
    size: 12,
    lineHeight: 16,
    weight: medium,
  );
  static final TextStyle caption5 = _style(
    size: 12,
    lineHeight: 16,
    weight: FontWeight.w400,
  );
}

/// 中文语境下选了系统自带的黑体：应用里九成文字是汉字，
/// 而 Geist、Manrope 这些西文字体没有汉字字形 —— 混排会在第一个汉字处
/// 掉回系统字体，同一行里两套字重、两套基线。
///
/// 所以字体的身份由**字阶、字重、字距与颜色**来建立，而不是换一套字形。
/// 这个列表依次尝试：Android 的 Noto Sans SC / 小米 MiSans、
/// 华为 HarmonyOS Sans、iOS 的苹方，最后落到各家系统默认。
const List<String> kCjkFallback = [
  'Noto Sans SC',
  'Source Han Sans SC',
  'MiSans',
  'HarmonyOS Sans SC',
  'PingFang SC',
  'Microsoft YaHei',
];

/// 一段带字距的小标签，用作分区眉题。
class EyebrowLabel extends StatelessWidget {
  const EyebrowLabel(
    this.text, {
    super.key,
    this.color = AppColors.inkFaint,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppText.caption3.copyWith(
        color: color,
        letterSpacing: 1.4,
      ),
    );
  }
}

/// 卡片的统一外壳。
///
/// **圆角、描边、留白只在这里决定一次。** 页面里再出现的 `Card`
/// 都应该是它，除非那张卡片有自己的点击语义（这时用 [AppCard.tappable]）。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.s200),
    this.color = AppColors.card,
    this.borderColor = AppColors.hairline,
    this.radius = Radii.lg,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;
  final double radius;

  /// 卡片里还要再压一层会画到圆角外的内容（图片、水波纹）时开它。
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: borderColor),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 可以点的卡片。水波纹被裁在圆角里，按下时还有一点下沉。
class AppTappableCard extends StatefulWidget {
  const AppTappableCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Space.s200),
    this.color = AppColors.card,
    this.borderColor = AppColors.hairline,
    this.radius = Radii.lg,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;
  final double radius;

  @override
  State<AppTappableCard> createState() => _AppTappableCardState();
}

class _AppTappableCardState extends State<AppTappableCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: Motion.fast,
      curve: Motion.curve,
      child: Card(
        color: widget.color,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.radius),
          side: BorderSide(color: widget.borderColor),
        ),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.radius),
          onHighlightChanged: (value) => setState(() => _pressed = value),
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );
  }
}

/// 一枚状态角标。底色是 tint，文字是同一色相的深色 —— 不用描边，
/// 因为描边角标在密集列表里会看起来像按钮。
class StatusTag extends StatelessWidget {
  const StatusTag(
    this.label, {
    super.key,
    this.foreground = AppColors.brand,
    this.background = AppColors.brandTint,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s75,
        vertical: Space.s25,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Radii.pillAll,
      ),
      child: Text(
        label,
        style: AppText.caption4.copyWith(color: foreground),
      ),
    );
  }
}

/// 一条带说明的细线。卡片内部的分段用它，不给卡片描单边。
class Hairline extends StatelessWidget {
  const Hairline({
    super.key,
    this.indent = Space.s0,
    this.endIndent = Space.s0,
    this.color = AppColors.hairline,
  });

  final double indent;
  final double endIndent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: indent,
      endIndent: endIndent,
      color: color,
    );
  }
}

/// 页面的统一骨架：同一档左右留白、同一个最大宽度、同一段底部安全距离。
///
/// 390 宽的机器上两侧各留 [Space.s200]，正文最大 460 —— 平板与折叠屏上
/// 版面不会被拉成一行读不到头的长句。
class AppPageBody extends StatelessWidget {
  const AppPageBody({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(
      Space.s200,
      Space.s100,
      Space.s200,
      Space.s400,
    ),
    this.maxWidth = 460,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// 分区的眉题：编号 + 标题 + 右侧计量。
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.index,
    this.trailing,
  });

  final String title;

  /// 分区序号，写成「01」「02」。它不是装饰：清单是按分区读的，
  /// 有编号之后用户能一眼看出「这一组还剩几个分区」。
  final String? index;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: Space.s50,
        right: Space.s50,
        bottom: Space.s100,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (index != null) ...[
            Text(
              index!,
              style: AppText.caption3.copyWith(
                color: AppColors.brand,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: Space.s75),
          ],
          Text(
            title,
            style: AppText.title2.copyWith(
              color: AppColors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(
              trailing!,
              style: AppText.caption5.copyWith(color: AppColors.inkFaint),
            ),
        ],
      ),
    );
  }
}
