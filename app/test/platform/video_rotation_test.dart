/// 旋转角合成的测试。
///
/// 这是横屏功能的**唯一**一处可以在主机上穷尽验证的正确性 —— 骨架歪 90°
/// 在真机上只能靠「站位清单报得对不对」间接看出来，而这里能把四个设备方向 ×
/// 两种镜头 × 多个传感器朝向全走一遍。
///
/// 期望值全部由 `camera_android` 的 `getVideoOrientation()`
/// （`DeviceOrientationManager.java:174-202`）直接推出，不是「试出来的」。
/// **如果哪天这里的期望值与真机现象对不上，错的是真机路径上的调用，不是这些数** ——
/// 预览与骨架同源这一条是对齐的前提。
///
/// 另有一条**回归**性质：同一台相机上，四个设备方向必须给出四个**互不相同**的角。
/// 旧实现（只在 `start()` 里用 `sensorOrientation` 算一次）在这条上必红 ——
/// 它对四个方向返回同一个值，而那正是「横屏后骨架躺倒」的病因。
library;

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:vitalteen_app/platform/video_rotation.dart';

/// 后摄常见的 `sensorOrientation`；前摄常见的另一个值。两者不同是常态。
const int _backSensor = 90;
const int _frontSensor = 270;

void main() {
  group('后摄（不加负号）', () {
    test('竖持：传感器朝向就是全部', () {
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.portraitUp,
          sensorOrientation: _backSensor,
          isFrontFacing: false,
        ),
        90,
      );
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.portraitDown,
          sensorOrientation: _backSensor,
          isFrontFacing: false,
        ),
        270,
      );
    });

    test('横持：加上设备方向那一项', () {
      // 90 + 270 = 360 → 0；90 + 90 = 180。
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.landscapeLeft,
          sensorOrientation: _backSensor,
          isFrontFacing: false,
        ),
        0,
      );
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.landscapeRight,
          sensorOrientation: _backSensor,
          isFrontFacing: false,
        ),
        180,
      );
    });
  });

  group('前摄（负号只作用于设备方向那一项）', () {
    test('竖持', () {
      // -0 + 270 = 270；-180 + 270 + 360 = 450 → 90。
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.portraitUp,
          sensorOrientation: _frontSensor,
          isFrontFacing: true,
        ),
        270,
      );
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.portraitDown,
          sensorOrientation: _frontSensor,
          isFrontFacing: true,
        ),
        90,
      );
    });

    test('横持', () {
      // -270 + 270 + 360 = 360 → 0；-90 + 270 + 360 = 540 → 180。
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.landscapeLeft,
          sensorOrientation: _frontSensor,
          isFrontFacing: true,
        ),
        0,
      );
      expect(
        mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.landscapeRight,
          sensorOrientation: _frontSensor,
          isFrontFacing: true,
        ),
        180,
      );
    });

    test('负号不作用于 sensorOrientation', () {
      // 若把 `-angle + sensorOrientation` 写成 `-(angle + sensorOrientation)`，
      // 这一条会红：那两行的差正好是两倍的 sensorOrientation。
      final up = mlkitRotationDegrees(
        deviceOrientation: DeviceOrientation.portraitUp,
        sensorOrientation: _frontSensor,
        isFrontFacing: true,
      );
      final down = mlkitRotationDegrees(
        deviceOrientation: DeviceOrientation.portraitDown,
        sensorOrientation: _frontSensor,
        isFrontFacing: true,
      );
      expect((up - down + 360) % 360, 180, reason: '只差 180，不是 180 加两倍传感器朝向');
    });
  });

  group('回归：这正是横屏要修的那个 bug', () {
    test('同一台相机，四个设备方向必须给出四个互不相同的角', () {
      for (final (sensor, front) in [(_backSensor, false), (_frontSensor, true)]) {
        final angles = DeviceOrientation.values
            .map((o) => mlkitRotationDegrees(
                  deviceOrientation: o,
                  sensorOrientation: sensor,
                  isFrontFacing: front,
                ))
            .toSet();
        // 旧实现四个方向返回同一个值 —— 横屏下预览转了、骨架没转。
        expect(
          angles.length,
          4,
          reason: 'sensor=$sensor front=$front 的四个方向只算出了 $angles',
        );
      }
    });

    test('对同一台相机，横持与竖持的差恰好是 90 的奇数倍', () {
      // 「手机转 90°，转正所需的角也必须跟着变 90°」——这条不成立时，
      // 骨架与预览就必然错开一个 90° 的整数倍。
      for (final (sensor, front) in [(_backSensor, false), (_frontSensor, true)]) {
        final up = mlkitRotationDegrees(
          deviceOrientation: DeviceOrientation.portraitUp,
          sensorOrientation: sensor,
          isFrontFacing: front,
        );
        for (final o in [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
          DeviceOrientation.portraitDown,
        ]) {
          final other = mlkitRotationDegrees(
            deviceOrientation: o,
            sensorOrientation: sensor,
            isFrontFacing: front,
          );
          final delta = (other - up + 360) % 360;
          expect(delta % 90, 0, reason: '$o 与竖持的差 $delta 不是 90 的倍数');
          expect(delta, isNot(0), reason: '$o 算出来与竖持一样，方向没起作用');
        }
      }
    });
  });

  test('任何组合都落在 ML Kit 认得的四个角上', () {
    for (final o in DeviceOrientation.values) {
      for (final sensor in [0, 90, 180, 270, 360, 450]) {
        for (final front in [false, true]) {
          final deg = mlkitRotationDegrees(
            deviceOrientation: o,
            sensorOrientation: sensor,
            isFrontFacing: front,
          );
          expect(
            InputImageRotationValue.fromRawValue(deg),
            isNotNull,
            reason: 'o=$o sensor=$sensor front=$front 算出了 $deg',
          );
        }
      }
    }
  });
}
