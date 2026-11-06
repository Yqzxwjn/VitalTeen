library;

import 'package:flutter/material.dart';

import 'design.dart';

class OutlineTag extends StatelessWidget {
  const OutlineTag(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s75,
        vertical: Space.s25,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairlineStrong),
        borderRadius: Radii.pillAll,
      ),
      child: Text(
        label,
        style: AppText.caption5.copyWith(color: AppColors.inkFaint),
      ),
    );
  }
}

class ProvisionalTag extends StatelessWidget {
  const ProvisionalTag({super.key});
  @override
  Widget build(BuildContext context) => const OutlineTag('阈值待核定 · 仅参考');
}
