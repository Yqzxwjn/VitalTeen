///屏幕方向的唯一主人，只有 main.dart 调它
library;

import 'package:flutter/services.dart';

enum AppOrientation {
  portrait,
  practice,
}

Future<void> applyOrientation(AppOrientation orientation) {
  return switch (orientation) {
    AppOrientation.portrait => SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    AppOrientation.practice => SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]),
  };
}

AppOrientation orientationFor({
  required bool exercise,
  required bool reportShown,
  required bool requiresLandscape,
}) {
  return exercise && !reportShown && requiresLandscape
      ? AppOrientation.practice
      : AppOrientation.portrait;
}
