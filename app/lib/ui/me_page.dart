//「我的」页：档案、等级与三个入口
library;

import 'package:flutter/material.dart';

import '../app/growth.dart';
import '../app/history.dart' show streakDays;
import '../app/profile.dart';
import '../app/session_record.dart';
import 'app_icons.dart';
import 'avatar_image.dart';
import 'design.dart';
import 'illustration_slot.dart';
import 'privacy_note.dart';

/// 「关于」里那三步。
typedef HowItWorksStep = ({AppGlyph icon, String title, String body});

const List<HowItWorksStep> kHowItWorksSteps = [
  (
    icon: AppGlyph.posture,
    title: '站好',
    body: '离手机两米左右，侧身站成 45°。正对镜头的话，屈膝、蹬伸这些幅度在画面上'
        '几乎看不出来，计数会一直是 0 —— 所以站错了应用会拦住你。',
  ),
  (
    icon: AppGlyph.timer,
    title: '标定',
    body: '站直别动几秒钟。应用记下你站立时的膝盖角度，之后的判断都跟它比 —— '
        '腿长比例不同的人，同样的姿势本来就不该用同一把尺子量。',
  ),
  (
    icon: AppGlyph.workout,
    title: '开始做',
    body: '倒计时三个数自动开始。做完一个，屏幕上给一次反馈和一个参考分；'
        '做完一组，出整组的汇总。全程不用碰手机。',
  ),
];

class MePage extends StatelessWidget {
  const MePage({
    super.key,
    required this.profile,
    required this.onEditProfile,
    required this.onClearData,
    this.avatarPath,
    this.onChangeAvatar,
    this.records = const [],
    this.onOpenGrowth,
    this.now,
  });
  final Profile profile;
  final VoidCallback onEditProfile;
  final Future<bool> Function() onClearData;
  final String? avatarPath;
  final VoidCallback? onChangeAvatar;
  final List<SessionRecord> records;
  final VoidCallback? onOpenGrowth;

  /// 只给测试用；跑起来时拿当前时间
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的资料'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: AppPageBody(
          children: [
            _Header(
              profile: profile,
              avatarPath: avatarPath,
              onChangeAvatar: onChangeAvatar,
            ),
            const SizedBox(height: Space.s300),
            _LevelCard(
              records: records,
              now: now ?? DateTime.now(),
              onOpen: onOpenGrowth,
            ),
            const SizedBox(height: Space.s200),
            _FactCard(
              profile: profile,
              stale: needsProfileRefresh(profile, DateTime.now()),
              onEditProfile: onEditProfile,
            ),
            const SizedBox(height: Space.s200),
            _ActionsCard(
              onEditProfile: onEditProfile,
              onAbout: () => _showAbout(context),
              onClearData: () => _confirmClear(context),
            ),
            const SizedBox(height: Space.s300),
            const _LocalOnlyLine(),
          ],
        ),
      ),
    );
  }

  Future<void> _showAbout(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关于健知行绎'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '手机对着你做一个动作，应用数次数、看角度。'
                '判断全部按你填的资料来做，不跟别人比。',
                style: AppText.body6.copyWith(
                  color: AppColors.inkSoft,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: Space.s200),
              for (final step in kHowItWorksSteps) ...[
                _AboutStep(step: step),
                const SizedBox(height: Space.s100),
              ],
              const SizedBox(height: Space.s50),
              const PrivacyNote(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除本机数据'),
        content: Text(
          '资料、练习记录和头像都会从这台手机上删掉，删了就找不回来。',
          style: AppText.body6.copyWith(
            color: AppColors.inkSoft,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final cleared = await onClearData();
    if (cleared) return;
    messenger.showSnackBar(const SnackBar(
      content: Text('没能清干净，请再试一次。'),
    ));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile, this.avatarPath, this.onChangeAvatar});
  final Profile profile;
  final String? avatarPath;
  final VoidCallback? onChangeAvatar;
  static const double _size = 72;

  @override
  Widget build(BuildContext context) {
    final name = profileDisplayName(profile);
    return Row(
      children: [
        _avatar(name),
        const SizedBox(width: Space.s200),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.heading5.copyWith(color: AppColors.ink),
              ),
              const SizedBox(height: Space.s25),
              Text(
                profileSummaryLine(profile),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption5.copyWith(color: AppColors.inkSoft),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _avatar(String name) {
    final circle = ClipOval(
      child: SizedBox.square(
        dimension: _size,
        child: AvatarImage(
          path: avatarPath,
          fallback: IllustrationSlot(
            path: 'assets/images/avatar.webp',
            fallback: initialAvatar(name: name, size: _size),
          ),
        ),
      ),
    );
    final onChange = onChangeAvatar;
    if (onChange == null) return circle;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChange,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(right: 0, bottom: 0, child: _cameraBadge()),
        ],
      ),
    );
  }

  Widget _cameraBadge() {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brand,
        // 一圈与页面同色的描边：头像本身也是品牌蓝，没有它这枚角标会糊在圆里。
        border: Border.all(color: AppColors.paper, width: 2),
      ),
      child: const Center(
        child: AppIcon(
          AppGlyph.camera,
          size: 15,
          color: AppColors.onDark,
          strokeWidth: 1.5,
        ),
      ),
    );
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.records, required this.now, this.onOpen});
  final List<SessionRecord> records;
  final DateTime now;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final streak = streakDays(records, now);
    final level = levelForStreak(streak);
    final next = nextLevelOf(level);
    final tasks = dailyTasks(records, now);
    final done = doneTaskCount(tasks);
    final progress = tasks.isEmpty ? 0.0 : done / tasks.length;
    return AppTappableCard(
      onTap: onOpen,
      color: AppColors.brandDeep,
      borderColor: AppColors.brandDeep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.onDark.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${level.level}',
                  style: AppText.heading6.copyWith(color: AppColors.onDark),
                ),
              ),
              const SizedBox(width: Space.s100),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Lv.${level.level} ${level.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title3.copyWith(
                        color: AppColors.onDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Space.s25),
                    Text(
                      _subtitle(streak, next),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption5.copyWith(
                        color: AppColors.onDarkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              if (onOpen != null) ...[
                const SizedBox(width: Space.s50),
                AppIcon(
                  AppGlyph.chevronRight,
                  size: 20,
                  color: AppColors.onDark.withValues(alpha: 0.55),
                ),
              ],
            ],
          ),
          const SizedBox(height: Space.s200),
          ClipRRect(
            borderRadius: Radii.pillAll,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: Space.s75,
              color: AppColors.sky,
              backgroundColor: AppColors.onDark.withValues(alpha: 0.16),
            ),
          ),
          const SizedBox(height: Space.s75),
          Text(
            '今日任务 $done/${tasks.length}',
            style: AppText.caption5.copyWith(color: AppColors.onDarkSoft),
          ),
        ],
      ),
    );
  }

  String _subtitle(int streak, GrowthLevel? next) {
    final base = streak == 0 ? '今天还没练' : '连续打卡 $streak 天';
    if (next == null) return '$base · 已经到顶了';
    return '$base · 再连练 ${next.streak - streak} 天升级';
  }
}

class _FactCard extends StatelessWidget {
  const _FactCard({
    required this.profile,
    required this.stale,
    required this.onEditProfile,
  });
  final Profile profile;
  final bool stale;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const EyebrowLabel('身体数据'),
          const SizedBox(height: Space.s75),
          Text(
            profileBodyLine(profile),
            style: AppText.body1.copyWith(color: AppColors.ink),
          ),
          const SizedBox(height: Space.s50),
          Text(
            '更新于 ${formatProfileDate(profile.updatedAt)}',
            style: AppText.caption5.copyWith(color: AppColors.inkFaint),
          ),
          if (stale) ...[
            const SizedBox(height: Space.s100),
            InkWell(
              onTap: onEditProfile,
              borderRadius: Radii.smAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s25),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: AppIcon(
                        AppGlyph.timer,
                        size: 16,
                        color: AppColors.warningInk,
                        strokeWidth: 1.5,
                      ),
                    ),
                    const SizedBox(width: Space.s75),
                    Expanded(
                      child: Text(
                        '$profileStaleFact —— 点这里更新。',
                        style: AppText.caption5.copyWith(
                          color: AppColors.warningInk,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.onEditProfile,
    required this.onAbout,
    required this.onClearData,
  });
  final VoidCallback onEditProfile;
  final VoidCallback onAbout;
  final VoidCallback onClearData;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionRow(
            glyph: AppGlyph.edit,
            label: '编辑资料',
            onTap: onEditProfile,
          ),
          const Hairline(indent: Space.s200, endIndent: Space.s200),
          _ActionRow(
            glyph: AppGlyph.info,
            label: '关于健知行绎',
            onTap: onAbout,
          ),
          const Hairline(indent: Space.s200, endIndent: Space.s200),
          _ActionRow(
            glyph: AppGlyph.trash,
            label: '清除本机数据',
            subtitle: '资料、练习记录和头像一起删，删了就找不回来',
            onTap: onClearData,
            danger: true,
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.glyph,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  final AppGlyph glyph;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.ink;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.lgAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s200,
          vertical: Space.s200,
        ),
        child: Row(
          children: [
            AppIcon(
              glyph,
              size: 20,
              color: danger ? AppColors.danger : AppColors.inkSoft,
            ),
            const SizedBox(width: Space.s100),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: AppText.title3.copyWith(color: color),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: Space.s25),
                    Text(
                      subtitle!,
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
              size: 18,
              color: AppColors.inkFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// 页脚：这台手机是这份数据的唯一位置。
///
/// 它对应的是产品边界，不是一句免责声明 —— 换机不会同步，删除不可恢复。
class _LocalOnlyLine extends StatelessWidget {
  const _LocalOnlyLine();

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
              '资料和练习记录只存在这台手机上，换台手机不会同步。',
              style: AppText.caption5.copyWith(color: AppColors.inkFaint),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutStep extends StatelessWidget {
  const _AboutStep({required this.step});
  final HowItWorksStep step;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AppIcon(
            step.icon,
            size: 18,
            color: AppColors.brand,
            strokeWidth: 1.5,
          ),
        ),
        const SizedBox(width: Space.s75),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                step.title,
                style: AppText.body5.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Space.s25),
              Text(
                step.body,
                style: AppText.caption5.copyWith(
                  color: AppColors.inkSoft,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
