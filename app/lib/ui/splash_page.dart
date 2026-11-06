//开屏
library;

import 'dart:async';

import 'package:flutter/material.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    required this.onDone,
    this.duration = defaultDuration,
  });
  static const Duration defaultDuration = Duration(milliseconds: 1500);
  static const String artworkPath = 'assets/images/splash.webp';
  final VoidCallback onDone;
  final Duration duration;
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Timer? _handoff;

  @override
  void initState() {
    super.initState();
    _handoff = Timer(widget.duration, () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _handoff?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(
        child: Image.asset(
          SplashPage.artworkPath,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => const Center(
            child: Text(
              '健知行绎',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
                color: Color(0xFF0B3D91),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
