//插图位：图在画图，图不在画兜底
library;

import 'package:flutter/material.dart';

class IllustrationSlot extends StatelessWidget {
  const IllustrationSlot({
    super.key,
    required this.path,
    required this.fallback,
    this.fit = BoxFit.cover,
  });
  final String path;
  final Widget fallback;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      path,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}
