/// 相机帧转换测试。
///
/// **全部不需要真机。** 而这一段恰恰是「错了不报错」的重灾区：
/// 字节少拼一半不会抛异常，只会让模型在一张半截是垃圾的图上推理；
/// 格式号认错同样不抛异常，只是模型按错的布局去读同一块缓冲。
/// 两者的现象都是「判定结果总觉得不太对」，反推不回本文件。
///
/// 所以这里逐条钉住的是**可观察的后果**，而不是「函数返回了非 null」这种
/// 证明不了任何事的断言：拼出来的字节序列长什么样、格式号 17/35/256 各自
/// 解析成什么、拿不到格式时是不是**返回 null 而不是兜底**。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:vitalteen_app/platform/camera_frame_conversion.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// 一个能反查「谁被读了几次」的平面，用来证明单平面路径没有复制。
Uint8List sample(int base, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (base + i) & 0xFF));

void main() {
  group('packPlanes', () {
    test('单个平面直接返回原缓冲，不复制', () {
      final plane = sample(0, 12);
      expect(identical(packPlanes([plane]), plane), isTrue);
    });

    test('多个平面按顺序首尾相接', () {
      final packed = packPlanes([sample(1, 4), sample(10, 3), sample(20, 2)]);

      expect(packed.length, 9);
      expect(packed, equals(bytes([1, 2, 3, 4, 10, 11, 12, 20, 21])));
    });

    test('三平面 yuv420 的拼接长度等于各平面之和', () {
      // 一张 4x2 的 yuv420：Y 占 8 字节，U、V 各占 2 字节。
      // **这条钉的是「只传第一个平面」那个错误的后果** ——
      // 只传 Y 也能推理、也不报错，只是色度全丢、模型在灰度图上找关键点。
      final packed = packPlanes([
        sample(0, 8),
        sample(100, 2),
        sample(200, 2),
      ]);

      expect(packed.length, 12);
      expect(packed.sublist(8), equals(bytes([100, 101, 200, 201])));
    });

    test('平面为空时返回空缓冲，不抛异常', () {
      expect(packPlanes([]), isEmpty);
    });
  });

  group('resolveInputImageFormat', () {
    test('17 是 Android 的 NV21', () {
      expect(resolveInputImageFormat(17), InputImageFormat.nv21);
    });

    test('35 是 Android 的 YUV_420_888', () {
      expect(resolveInputImageFormat(35), InputImageFormat.yuv_420_888);
    });

    test('Android 的 JPEG(256) 解析失败 —— 这是对的，不是漏配', () {
      // `InputImageFormat` 根本没有 jpeg 这一项（只有 nv21 / yv12 /
      // yuv_420_888 / yuv420 / bgra8888）。JPEG 是一整张压缩图，
      // 不能按裸字节缓冲喂给 ML Kit。
      //
      // 所以这条路径的**正确行为就是返回 null、由调用方计一次 badfmt** ——
      // 而不是想办法把它塞进去。某些设备配置下相机确实会给 JPEG，
      // 那时我们应该在日志里看见 badfmt 涨，而不是看见模型在一堆压缩字节上
      // 瞎找关键点。
      expect(resolveInputImageFormat(256), isNull);
    });

    test('iOS 的 FourCharCode 不是 int，按「不认识」处理而不是崩', () {
      // `ImageFormat.raw` 声明为 `dynamic`，iOS 侧给的是 FourCharCode。
      // 这一条钉的是「不要写成 `raw as int`」—— 那样会在 iOS 上直接抛异常，
      // 而正确行为是让调用方计一次 badfmt 并继续。
      expect(resolveInputImageFormat('420f'), isNull);
      expect(resolveInputImageFormat(null), isNull);
    });

    test('不认识的格式号返回 null，不做兜底猜测', () {
      expect(resolveInputImageFormat(9999), isNull);
    });
  });

  group('buildInputImage', () {
    test('正常路径：元数据取自入参，字节是拼好的那一块', () {
      final image = buildInputImage(
        width: 640,
        height: 480,
        planes: [sample(0, 4), sample(50, 2)],
        bytesPerRow: 640,
        rotation: InputImageRotation.rotation270deg,
        rawFormat: 17,
      );

      expect(image, isNotNull);
      expect(image!.bytes, equals(bytes([0, 1, 2, 3, 50, 51])));
      expect(image.metadata!.size.width, 640);
      expect(image.metadata!.size.height, 480);
      expect(image.metadata!.rotation, InputImageRotation.rotation270deg);
      expect(image.metadata!.format, InputImageFormat.nv21);
    });

    test('bytesPerRow 用传入的行跨距，不拿 width 顶替', () {
      // 有些设备会按 16/64 字节对齐行宽，那时行跨距大于宽度。
      // 这一条钉的是「别自作聪明用 width」—— 用错会得到一张斜切的图，
      // 而斜切的关键点看起来像模型不准，不像缓冲区算错了。
      final image = buildInputImage(
        width: 630,
        height: 480,
        planes: [sample(0, 8)],
        bytesPerRow: 640,
        rotation: InputImageRotation.rotation90deg,
        rawFormat: 17,
      );

      expect(image!.metadata!.bytesPerRow, 640);
      expect(image.metadata!.size.width, 630);
    });

    test('格式号不认识时返回 null —— 让调用方记一次 badfmt', () {
      final image = buildInputImage(
        width: 640,
        height: 480,
        planes: [sample(0, 4)],
        bytesPerRow: 640,
        rotation: InputImageRotation.rotation90deg,
        rawFormat: 'not-a-format',
      );

      expect(image, isNull);
    });

    test('一个平面都没有时返回 null，而不是送一块空缓冲给模型', () {
      final image = buildInputImage(
        width: 640,
        height: 480,
        planes: const [],
        bytesPerRow: 640,
        rotation: InputImageRotation.rotation90deg,
        rawFormat: 17,
      );

      expect(image, isNull);
    });

    test('零度旋转原样透传，不被改写成 90', () {
      // 旋转值错了的表现是骨架整体躺倒，而它看起来像「模型坏了」。
      final image = buildInputImage(
        width: 480,
        height: 640,
        planes: [sample(0, 4)],
        bytesPerRow: 480,
        rotation: InputImageRotation.rotation0deg,
        rawFormat: 17,
      );

      expect(image!.metadata!.rotation, InputImageRotation.rotation0deg);
    });
  });
}
