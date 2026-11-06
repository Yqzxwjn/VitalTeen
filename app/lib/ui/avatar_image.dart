//头像：用户自己的图 / 首字母兜底
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'design.dart';

class AvatarImage extends StatelessWidget {
  const AvatarImage({super.key, required this.path, required this.fallback});
  final String? path;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final source = path;
    if (source == null) return fallback;
    return Image.file(
      File(source),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

/// 首字母兜底。
///
/// **一块实色，不是渐变。** 深的品牌蓝在浅色页面上已经够重，再叠一层渐变
/// 只会让这个圆看起来像另一个应用的组件；首字母本身才是要认得出来的东西。
Widget initialAvatar({required String name, required double size}) {
  return DecoratedBox(
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: AppColors.brand,
    ),
    child: Center(
      child: Text(
        name.characters.first,
        style: TextStyle(
          fontSize: size * 0.4,
          height: 1,
          fontWeight: FontWeight.w600,
          color: AppColors.onDark,
        ),
      ),
    ),
  );
}
