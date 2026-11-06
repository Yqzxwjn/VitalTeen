//主题：浅色的应用主体 + 练习页那一屏专用的深色主题
//
//**视觉常量不在这里定义。** 颜色、间距、圆角与文本样式都在 `design.dart`；
//这个文件只负责把它们接到 Material 的各处默认值上（AppBar、Card、
//NavigationBar、按钮、输入框、对话框）。页面里若还要写死一个尺寸或颜色，
//先回去看 `design.dart` 里有没有对应的令牌。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';

/// 品牌四色。取自 `docs/brand-assets.md` 里标志本身的填色，不随界面改版。
const Color vitalBlue = AppColors.brand;
const Color vitalSky = AppColors.sky;
const Color vitalGreen = AppColors.leaf;
const Color vitalOrange = AppColors.orange;

const Color vitalOnBrand = AppColors.onDark;
const Color vitalCard = AppColors.card;
const Color vitalHairline = AppColors.hairline;
const Color vitalInk = AppColors.ink;
const Color vitalSeed = AppColors.brand;
const Color vitalAccent = AppColors.sky;
const Color vitalSurface = AppColors.paper;
const Color vitalOverlay = Color(0xE60B1017);
const Color vitalCameraSurface = AppColors.cameraSurface;

const List<Color> vitalHeatRamp = AppColors.heatRamp;

const SystemUiOverlayStyle vitalLightSystemBars = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
);

const SystemUiOverlayStyle vitalCameraSystemBars = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
);

const List<FontFeature> tabularFigures = [FontFeature.tabularFigures()];

/// 九成文字是汉字，字体身份靠字阶、字重与字距建立，见 `design.dart` 的说明。
const List<String> _fallback = kCjkFallback;

ThemeData buildVitalTeenTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.brand,
    onPrimary: AppColors.onDark,
    primaryContainer: AppColors.brandTint,
    onPrimaryContainer: AppColors.brandDeep,
    secondary: AppColors.sky,
    onSecondary: AppColors.onDark,
    secondaryContainer: AppColors.skyTint,
    onSecondaryContainer: const Color(0xFF07506B),
    tertiary: AppColors.leaf,
    onTertiary: AppColors.onDark,
    tertiaryContainer: AppColors.leafTint,
    onTertiaryContainer: const Color(0xFF20480F),
    error: AppColors.danger,
    onError: AppColors.onDark,
    errorContainer: AppColors.dangerTint,
    onErrorContainer: AppColors.danger,
    surface: AppColors.card,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.inkSoft,
    surfaceContainerLowest: AppColors.card,
    surfaceContainerLow: AppColors.paper,
    surfaceContainer: AppColors.paper,
    surfaceContainerHigh: const Color(0xFFE9EDF3),
    surfaceContainerHighest: const Color(0xFFE2E7EE),
    outline: AppColors.inkFaint,
    outlineVariant: AppColors.hairline,
    surfaceTint: Colors.transparent,
  );

  final text = _textTheme();

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.paper,
    canvasColor: AppColors.paper,
    fontFamilyFallback: _fallback,
    textTheme: text,
  );

  /// 组件级文本样式必须**从主题的正文样式上长出来**，见文件末尾的
  /// [_component]。
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      systemOverlayStyle: vitalLightSystemBars,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: Space.s200,
      toolbarHeight: 56,
      titleTextStyle: _component(base, AppText.title2).copyWith(
        color: AppColors.ink,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.lgAll,
        side: const BorderSide(color: AppColors.hairline),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      space: 1,
      thickness: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: AppColors.onDark,
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: Space.s300),
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        textStyle: _component(base, AppText.buttonMd),
        elevation: 0,
      ).copyWith(
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.onDark.withValues(alpha: 0.14);
          }
          return null;
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: Space.s300),
        side: const BorderSide(color: AppColors.hairlineStrong),
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        textStyle: _component(base, AppText.buttonMd),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.brand,
        textStyle: _component(base, AppText.buttonSm),
        shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.card,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.s200,
        vertical: Space.s200,
      ),
      labelStyle: _component(base, AppText.body6).copyWith(color: AppColors.inkSoft),
      hintStyle: _component(base, AppText.body6).copyWith(color: AppColors.inkFaint),
      helperStyle: _component(base, AppText.caption5).copyWith(color: AppColors.inkFaint),
      border: _fieldBorder(AppColors.hairlineStrong),
      enabledBorder: _fieldBorder(AppColors.hairlineStrong),
      focusedBorder: _fieldBorder(AppColors.brand, width: 1.6),
      errorBorder: _fieldBorder(AppColors.danger),
      focusedErrorBorder: _fieldBorder(AppColors.danger, width: 1.6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.card,
        foregroundColor: AppColors.inkSoft,
        selectedBackgroundColor: AppColors.brand,
        selectedForegroundColor: AppColors.onDark,
        side: const BorderSide(color: AppColors.hairline),
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        textStyle: _component(base, AppText.buttonSm),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      indicatorColor: AppColors.brandTint,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return _component(base, AppText.caption4).copyWith(
          color: selected ? AppColors.brand : AppColors.inkFaint,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: selected ? AppColors.brand : AppColors.inkFaint,
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: _component(base, AppText.body6).copyWith(color: AppColors.onDark),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      insetPadding: const EdgeInsets.all(Space.s200),
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: Radii.xlAll),
      titleTextStyle: _component(base, AppText.heading6).copyWith(color: AppColors.ink),
      contentTextStyle: _component(base, AppText.body6).copyWith(color: AppColors.inkSoft),
      insetPadding: const EdgeInsets.symmetric(horizontal: Space.s300),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: AppColors.inkSoft,
      textColor: AppColors.ink,
      titleTextStyle: _component(base, AppText.title3).copyWith(color: AppColors.ink),
      subtitleTextStyle: _component(base, AppText.caption5).copyWith(color: AppColors.inkFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.s200),
      minVerticalPadding: Space.s100,
      horizontalTitleGap: Space.s100,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.paper,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: _component(base, AppText.caption4).copyWith(color: AppColors.inkSoft),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s75,
        vertical: Space.s25,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.brand,
      linearTrackColor: AppColors.hairline,
      linearMinHeight: 8,
      circularTrackColor: AppColors.hairline,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? AppColors.onDark
            : AppColors.card;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? AppColors.brand
            : AppColors.hairlineStrong;
      }),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: AppColors.brand,
      inactiveTrackColor: AppColors.hairline,
      thumbColor: AppColors.brand,
      overlayColor: AppColors.brand.withValues(alpha: 0.10),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: Radii.smAll,
      ),
      textStyle: _component(base, AppText.caption5).copyWith(color: AppColors.onDark),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.brand,
      selectionColor: AppColors.brandTintStrong,
      selectionHandleColor: AppColors.brand,
    ),
    splashFactory: InkRipple.splashFactory,
    visualDensity: VisualDensity.standard,
  );
}

OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: Radii.mdAll,
    borderSide: BorderSide(color: color, width: width),
  );
}

/// 组件级文本样式必须**从主题的正文样式上长出来**。
///
/// `ThemeData` 会把平台默认字体族补进 `textTheme`，但 AppBar 的标题、
/// 按钮的 `textStyle` 这些是整份替换的样式，不会去合并正文 ——
/// 只给 `AppText`（字族为 null）的话，那一行文字会绕过主题的字体族，
/// 在缺字的字体上退成方块。`merge` 保留字体族，只覆盖字号、字重与字距。
TextStyle _component(ThemeData base, TextStyle spec) =>
    base.textTheme.bodyMedium!.merge(spec);

/// 深色那一屏（练习页）用。
///
/// 它不跟着浅色主题走：那一屏的背景是相机画面，任何浅色底都会把画面切成
/// 两块。除了底色与几个面板色，其余仍取自同一套字阶与间距。
ThemeData buildCameraTheme() {
  const onSurface = Color(0xFFECF1F7);
  const onSurfaceSoft = Color(0xFF9AA7B6);
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: Brightness.dark,
  ).copyWith(
    surface: AppColors.cameraSurface,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceSoft,
    primary: AppColors.sky,
    onPrimary: const Color(0xFF00201C),
    surfaceContainerHigh: AppColors.cameraPanel,
    surfaceContainerHighest: const Color(0xFF1D242D),
    outlineVariant: const Color(0xFF3A434E),
    outline: onSurfaceSoft,
  );
  final text = _textTheme().apply(
    bodyColor: onSurface,
    displayColor: onSurface,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.cameraSurface,
    canvasColor: AppColors.cameraSurface,
    fontFamilyFallback: _fallback,
    textTheme: text,
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: onSurface,
      systemOverlayStyle: vitalCameraSystemBars,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: _component(base, AppText.title3).copyWith(
        color: onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.cameraPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.mdAll,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      space: 1,
      thickness: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.sky,
      linearTrackColor: Color(0xFF232B35),
      linearMinHeight: 8,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.sky,
        foregroundColor: const Color(0xFF00201C),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        textStyle: _component(base, AppText.buttonMd),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.cameraPanel,
      contentTextStyle: _component(base, AppText.body6).copyWith(color: onSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
    ),
  );
}

TextTheme _textTheme() {
  return TextTheme(
    displayLarge: AppText.heading1,
    displayMedium: AppText.heading2,
    displaySmall: AppText.heading3,
    headlineLarge: AppText.heading4,
    headlineMedium: AppText.heading5,
    headlineSmall: AppText.heading6,
    titleLarge: AppText.title1,
    titleMedium: AppText.title3,
    titleSmall: AppText.body4,
    bodyLarge: AppText.body3,
    bodyMedium: AppText.body6,
    bodySmall: AppText.caption5,
    labelLarge: AppText.caption1,
    labelMedium: AppText.caption4,
    labelSmall: AppText.caption5,
  ).apply(fontFamilyFallback: _fallback);
}
