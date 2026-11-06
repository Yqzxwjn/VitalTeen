library;

import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design.dart';

const String kPrivacyNoteText =
    '画面不出手机。动作识别全部在这台设备上算完，视频不会被保存，也不会上传。';

class PrivacyNote extends StatelessWidget {
  const PrivacyNote({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.s100),
      decoration: BoxDecoration(
        borderRadius: Radii.mdAll,
        color: AppColors.leafTint,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: AppIcon(
              AppGlyph.lock,
              size: 18,
              color: AppColors.leaf,
              strokeWidth: 1.5,
            ),
          ),
          const SizedBox(width: Space.s75),
          Expanded(
            child: Text(
              kPrivacyNoteText,
              style: AppText.caption5.copyWith(
                color: const Color(0xFF2C5518),
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
