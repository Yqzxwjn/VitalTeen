//进横屏动作前那一层「把手机横过来」引导
library;

import 'package:flutter/material.dart';

import 'illustration_slot.dart';

// 方向锁生效后读不出用户转没转，只能让他自己确认
class LandscapeGuide extends StatelessWidget {
  const LandscapeGuide({super.key, required this.onAcknowledge});
  final VoidCallback onAcknowledge;
  static const String illustrationPath = 'assets/images/rotate_phone.webp';
  static const double illustrationSize = 128;
  static const double compactIllustrationSize = 88;
  static const Key cardKey = Key('landscapeGuideCard');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.orientationOf(context) == Orientation.landscape;
    final title = Text(
      '把手机横过来',
      textAlign: compact ? TextAlign.start : TextAlign.center,
      style: (compact ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)
          ?.copyWith(fontWeight: FontWeight.w700),
    );
    final why = Text(
      '立定跳远、仰卧起坐、坐位体前屈、俯卧撑、平板支撑这几项，'
      '身体是横着铺开的 —— 竖着拍会把头和脚切掉。',
      textAlign: compact ? TextAlign.start : TextAlign.center,
      style: (compact ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
          ?.copyWith(color: scheme.onSurfaceVariant),
    );
    final how = Text(
      '把手机顶部转到左边（逆时针转 90°）。转过来之后，'
      '屏幕上的字应该是正的；如果字是倒的，就朝另一边转。',
      textAlign: compact ? TextAlign.start : TextAlign.center,
      style: (compact ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
          ?.copyWith(color: scheme.onSurfaceVariant),
    );
    final illustration = SizedBox(
      width: compact ? compactIllustrationSize : illustrationSize,
      height: compact ? compactIllustrationSize : illustrationSize,
      child: IllustrationSlot(
        path: illustrationPath,
        fallback: _fallbackIllustration(scheme),
      ),
    );
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onAcknowledge,
        child: const Text('已经横过来了'),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.82),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 16 : 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 700 : 460),
                child: Container(
                  key: cardKey,
                  padding: compact
                      ? const EdgeInsets.fromLTRB(20, 16, 20, 14)
                      : const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(compact ? 18 : 24),
                  ),
                  child: compact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                illustration,
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      title,
                                      const SizedBox(height: 6),
                                      why,
                                      const SizedBox(height: 6),
                                      how,
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            button,
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            illustration,
                            const SizedBox(height: 20),
                            title,
                            const SizedBox(height: 12),
                            why,
                            const SizedBox(height: 12),
                            how,
                            const SizedBox(height: 24),
                            button,
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallbackIllustration(ColorScheme scheme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          Icons.screen_rotation,
          size: illustrationSize * 0.5,
          color: scheme.primary,
        ),
      ),
    );
  }
}
