//首页：今日横幅 + 打卡卡 + 分区动作清单
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/greeting.dart';
import '../app/profile.dart';
import '../app/session_record.dart';
import 'app_icons.dart';
import 'avatar_image.dart';
import 'design.dart';
import 'exercise_catalog.dart';
import 'exercise_preview.dart' show StickFigureThumbnail;
import 'growth_card.dart';
import 'illustration_slot.dart';

/// 首页。
///
/// 三块，从上到下就是一天的顺序：**我是谁**（横幅）、**今天走到哪了**
/// （打卡卡）、**今天练什么**（分区清单）。清单按发力部位分组，因为用户
/// 点进来时想的是「今天练腿还是练核心」，不是「第九个动作是什么」。
///
/// 横幅上不允许出现任何手势：换头像只在「我的」页有入口，同一个动作两个去处
/// 会让人以为它们不一样。同理，横幅也不挂整页共用的 CTA ——「开始」这个词在
/// 这一页只属于预览页那个按钮。
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.profile,
    required this.onOpenExercise,
    this.avatarPath,
    this.sections = kExerciseSections,
    this.records = const [],
    this.now,
    this.onOpenGrowth,
  });
  final Profile profile;
  final ValueChanged<ExerciseEntry> onOpenExercise;
  final String? avatarPath;
  final List<ExerciseSection> sections;
  final List<SessionRecord> records;

  /// 只给测试用；跑起来时拿当前时间
  final DateTime? now;
  final VoidCallback? onOpenGrowth;

  @override
  Widget build(BuildContext context) {
    final today = now ?? DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日训练'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: AppPageBody(
          children: [
            _HeroBanner(
              profile: profile,
              avatarPath: avatarPath,
              now: today,
            ),
            const SizedBox(height: Space.s300),
            GrowthCard(
              records: records,
              now: today,
              onOpen: onOpenGrowth,
            ),
            const SizedBox(height: Space.s400),
            for (var index = 0; index < sections.length; index++) ...[
              _section(context, sections[index], index),
              const SizedBox(height: Space.s200),
            ],
            const SizedBox(height: Space.s75),
            const _PrivacyLine(),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, ExerciseSection section, int index) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeading(
          title: section.title,
          index: '${index + 1}'.padLeft(2, '0'),
          trailing: '${section.entries.length} 个动作',
        ),
        for (final entry in section.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s75),
            child: _ExerciseCard(
              entry: entry,
              accent: section.accent,
              onTap: () => onOpenExercise(entry),
            ),
          ),
      ],
    );
  }
}

/// 顶部横幅。
///
/// 底是**一块实色深蓝**，不是渐变：渐变在深色上会把文字压出脏边，而且
/// 换图之后它会跟图的颜色打架。图位仍然读 `hero_home.webp`，图不在时画
/// 一组同心弧线（见 [_MotionArcs]）—— 那是这一页自己的图形语言，不是占位符。
class _HeroBanner extends StatelessWidget {
  const _HeroBanner({
    required this.profile,
    required this.now,
    this.avatarPath,
  });

  final Profile profile;
  final DateTime now;
  final String? avatarPath;

  static const double _avatarSize = 52;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: Radii.xlAll,
      child: Stack(
        children: [
          // 三层底：实色 → 图（或兜底图形，压在同一个深底上）→ 内容。
          // 图用透明度压暗，而不是盖一层渐变遮罩：遮罩会把兜底图形也一起
          // 压没，而且换图之后文字对比度会跟着图变。
          const Positioned.fill(child: ColoredBox(color: AppColors.brandDeep)),
          const Positioned.fill(
            child: Opacity(
              opacity: 0.5,
              child: IllustrationSlot(
                path: 'assets/images/hero_home.webp',
                fallback: _MotionArcs(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.s200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '健知行绎',
                      style: AppText.caption3.copyWith(
                        color: AppColors.onDark,
                        letterSpacing: 2.4,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${now.month}月${now.day}日',
                      style: AppText.caption5.copyWith(
                        color: AppColors.onDarkSoft,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s700),
                Row(
                  children: [
                    ClipOval(
                      child: SizedBox.square(
                        dimension: _avatarSize,
                        child: AvatarImage(
                          path: avatarPath,
                          fallback: initialAvatar(
                            name: profileDisplayName(profile),
                            size: _avatarSize,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s100),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${greetingFor(now)}，${profileDisplayName(profile)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.heading6.copyWith(
                              color: AppColors.onDark,
                            ),
                          ),
                          const SizedBox(height: Space.s25),
                          Text(
                            profileSummaryLine(profile),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption5.copyWith(
                              color: AppColors.onDarkSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 横幅的兜底图形：五道向右下扫出去的弧，加一个定位点。
///
/// 它说的是「动作的轨迹」——与简笔人形那套图形是同一件事的另一种说法。
/// 全部用极低的白色透明度，所以压暗层与文字都不会被它干扰。
class _MotionArcs extends StatelessWidget {
  const _MotionArcs();

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: CustomPaint(painter: _MotionArcsPainter()),
    );
  }
}

class _MotionArcsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.98, size.height * 0.30);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      stroke
        ..color = AppColors.onDark.withValues(alpha: 0.30 - i * 0.045)
        ..strokeWidth = 1.4;
      final radius = size.height * (0.32 + i * 0.22);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        math.pi * 0.62,
        math.pi * 0.78,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_MotionArcsPainter oldDelegate) => false;
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.entry,
    required this.accent,
    required this.onTap,
  });

  final ExerciseEntry entry;
  final Color accent;
  final VoidCallback onTap;

  static const double _tile = 56;

  @override
  Widget build(BuildContext context) {
    final live = entry.isLive;
    return AppTappableCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Space.s200),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _tileWidget(live),
          const SizedBox(width: Space.s200),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.nameZh,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title3.copyWith(
                          color: live ? AppColors.ink : AppColors.inkFaint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!live) ...[
                      const SizedBox(width: Space.s75),
                      const StatusTag(
                        '未开放',
                        foreground: AppColors.inkFaint,
                        background: AppColors.paper,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.s25),
                Text(
                  entry.tagline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption5.copyWith(
                    color: live ? AppColors.inkSoft : AppColors.inkFaint,
                  ),
                ),
                if (entry.note != null) ...[
                  const SizedBox(height: Space.s75),
                  Text(
                    entry.note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption5.copyWith(
                      color: AppColors.inkFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Space.s75),
          const AppIcon(
            AppGlyph.chevronRight,
            size: 20,
            color: AppColors.inkFaint,
          ),
        ],
      ),
    );
  }

  /// 已上线的卡片：图位 + 这个动作自己的简笔人形，底色是分区的浅色。
  ///
  /// **未开放的不挂图位、不画小人**：图位是「能练」的信号，借给它用会让人
  /// 以为它快上线了（这条规则有测试盯着，见 `test/ui/home_page_test.dart`）。
  Widget _tileWidget(bool live) {
    if (!live) {
      return Container(
        width: _tile,
        height: _tile,
        decoration: BoxDecoration(
          color: AppColors.paper,
          borderRadius: Radii.mdAll,
        ),
        child: const Center(
          child: AppIcon(
            AppGlyph.lock,
            size: 22,
            color: AppColors.inkFaint,
          ),
        ),
      );
    }
    return Container(
      width: _tile,
      height: _tile,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: Radii.mdAll,
      ),
      child: IllustrationSlot(
        path: 'assets/images/ex_${entry.code}.webp',
        fallback: Padding(
          padding: const EdgeInsets.all(6),
          child: StickFigureThumbnail(code: entry.code, color: accent),
        ),
      ),
    );
  }
}

/// 页脚那一句话。隐私在这个应用里不是一条条款，而是产品能在教室里用的前提，
/// 所以它跟着清单一起出现在最后一屏，而不是埋在「关于」里。
class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.s50),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: AppIcon(
              AppGlyph.lock,
              size: 16,
              color: AppColors.inkFaint,
              strokeWidth: 1.5,
            ),
          ),
          const SizedBox(width: Space.s75),
          Expanded(
            child: Text(
              '画面不出手机：识别在这台设备上算完，视频不保存也不上传。',
              style: AppText.caption5.copyWith(color: AppColors.inkFaint),
            ),
          ),
        ],
      ),
    );
  }
}
