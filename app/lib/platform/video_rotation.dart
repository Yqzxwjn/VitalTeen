///算送进姿态模型的旋转角，跟设备方向和镜头朝向有关
library;

import 'package:flutter/services.dart' show DeviceOrientation;

// 镜像插件的 getVideoOrientation，改一边会错 90°
int mlkitRotationDegrees({
  required DeviceOrientation deviceOrientation,
  required int sensorOrientation,
  required bool isFrontFacing,
}) {
  var angle = switch (deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeLeft => 270,
    DeviceOrientation.landscapeRight => 90,
  };
  if (isFrontFacing) angle = -angle;
  return (angle + sensorOrientation + 360) % 360;
}
