library;

import 'package:flutter/material.dart';

class BottomSurface extends StatelessWidget {
  const BottomSurface({
    super.key,
    required this.decoration,
    required this.padding,
    required this.child,
  });
  final Decoration decoration;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gestureBar = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: decoration,
      padding: padding.add(EdgeInsets.only(bottom: gestureBar)),
      child: child,
    );
  }
}
