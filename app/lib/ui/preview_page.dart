//动作预览页：示意 + 说明 +「开始」
library;

import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design.dart';
import 'exercise_catalog.dart';
import 'exercise_preview.dart';

class PreviewPage extends StatelessWidget {
  const PreviewPage({
    super.key,
    required this.entry,
    required this.onBack,
    this.onStart,
    this.framingHint,
  });
  final ExerciseEntry entry;
  final VoidCallback onBack;
  final VoidCallback? onStart;
  final String? framingHint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.nameZh),
        leading: IconButton(
          icon: const AppIcon(AppGlyph.arrowLeft, size: 22),
          onPressed: onBack,
          tooltip: '返回',
        ),
      ),
      body: SafeArea(
        child: AppPageBody(
          children: [
            AppCard(
              padding: const EdgeInsets.fromLTRB(
                Space.s100,
                Space.s200,
                Space.s100,
                Space.s200,
              ),
              child: ExercisePreview(code: entry.code),
            ),
            const SizedBox(height: Space.s300),
            Text(
              entry.tagline,
              style: AppText.caption2.copyWith(
                color: AppColors.inkSoft,
                height: 1.7,
              ),
            ),
            if (entry.note != null) ...[
              const SizedBox(height: Space.s100),
              _line(AppGlyph.info, entry.note!),
            ],
            if (framingHint != null) ...[
              const SizedBox(height: Space.s100),
              _line(AppGlyph.camera, framingHint!),
            ],
            const SizedBox(height: Space.s400),
            if (onStart != null)
              FilledButton(
                onPressed: onStart,
                child: const Text('开始'),
              )
            else
              _notYetOpen(),
          ],
        ),
      ),
    );
  }

  Widget _line(AppGlyph glyph, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AppIcon(
            glyph,
            size: 16,
            color: AppColors.inkFaint,
            strokeWidth: 1.5,
          ),
        ),
        const SizedBox(width: Space.s75),
        Expanded(
          child: Text(
            text,
            style: AppText.caption5.copyWith(
              color: AppColors.inkSoft,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }

  Widget _notYetOpen() {
    return Container(
      padding: const EdgeInsets.all(Space.s100),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: Radii.mdAll,
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: AppIcon(
              AppGlyph.timer,
              size: 18,
              color: AppColors.inkFaint,
              strokeWidth: 1.5,
            ),
          ),
          const SizedBox(width: Space.s100),
          Expanded(
            child: Text(
              '上面是它的动作示意，先看看它长什么样 —— '
              '现在还没有能跟着练的版本，所以这一格暂时没有「开始」。',
              style: AppText.caption5.copyWith(
                color: AppColors.inkSoft,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
