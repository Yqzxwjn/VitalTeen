/// ML Kit 适配层测试。
///
/// **全部不需要真机。** 索引对齐完全可以在主机上验证 —— 而它恰恰是这一层最危险
/// 的失败方式：错位不抛异常、不让特征变成 null，只让所有角度特征系统性偏掉一点。
/// 等真机上看到「判定结果总觉得不太对」时，病因已经离现场很远了。
///
/// 把这件事钉在单元测试里，意味着它每次提交都会被验证一遍，而不是靠某次真机
/// 调试时恰好注意到。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/platform/mlkit_pose_mapper.dart';

/// 关键点。**坐标按 ML Kit 实际给的量纲填 —— 像素，不是归一化。**
/// 默认值 (500, 500) 是 1000x1000 无旋转画面的正中。
PoseLandmark lm(
  PoseLandmarkType type, {
  double x = 500,
  double y = 500,
  double likelihood = 1.0,
}) =>
    PoseLandmark(type: type, x: x, y: y, z: 0, likelihood: likelihood);

Pose poseOf(List<PoseLandmark> points) =>
    Pose(landmarks: {for (final p in points) p.type: p});

PoseFrame? convert(
  Pose pose, {
  int imageWidth = 1000,
  int imageHeight = 1000,
  InputImageRotation rotation = InputImageRotation.rotation0deg,
  int timestampMs = 0,
}) =>
    poseFrameFromMlKit(
      pose,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      rotation: rotation,
      timestampMs: timestampMs,
    );

void main() {
  group('关键点索引对齐', () {
    test('两边的 33 个点逐位对齐', () {
      expect(PoseLandmarkType.values, hasLength(nLandmarks));
      expect(
        landmarkAlignmentProblems(),
        isEmpty,
        reason: 'ML Kit 与本项目的关键点枚举顺序必须逐位一致',
      );
    });

    test('命名差异有且只有嘴部两点，且位置固定', () {
      // 这条是给上面那条检查上锁的：豁免名单的大小和位置被钉死。
      // 将来 ML Kit 若在别处改了命名，landmarkAlignmentProblems() 会报出来，
      // 而不是被一份悄悄变长的豁免名单盖住 —— 那正是这类检查失效的方式。
      final differing = <String>[
        for (final type in PoseLandmarkType.values)
          if (L.values[type.index].name.toLowerCase() != type.name.toLowerCase())
            '${type.index}:${type.name}',
      ];
      expect(differing, ['9:leftMouth', '10:rightMouth']);
    });
  });

  group('坐标量纲（ML Kit 给像素，本层负责归一化）', () {
    test('像素 → 归一化，再用 pixel() 还原是恒等', () {
      final frame = convert(
        poseOf([lm(PoseLandmarkType.nose, x: 250, y: 125)]),
      )!;
      expect(frame.landmarks[L.nose.index].x, closeTo(0.25, 1e-9));
      expect(frame.landmarks[L.nose.index].y, closeTo(0.125, 1e-9));
      expect(frame.pixel(L.nose).x, closeTo(250, 1e-9));
      expect(frame.pixel(L.nose).y, closeTo(125, 1e-9));
    });

    test('90/270 度必须用转正后的尺寸归一化（交换宽高）', () {
      // 真机实测：前摄 sensorOrientation=270，缓冲 640x480，**转正后 480x640**，
      // 而 ML Kit 的像素是在转正后的那张图里量的。
      //
      // 若照抄缓冲尺寸（640/480）去归一化，x 和 y 会各按错误的轴缩放 ——
      // 画面上的表现是骨架被横竖拉扁，看起来很像「相机没校准」，
      // 是最容易被当成别的问题去查的一类错误。
      final frame = convert(
        poseOf([lm(PoseLandmarkType.nose, x: 240, y: 320)]),
        imageWidth: 640,
        imageHeight: 480,
        rotation: InputImageRotation.rotation270deg,
      )!;
      expect(frame.frameWidth, 480, reason: '存进 PoseFrame 的必须是转正后的宽');
      expect(frame.frameHeight, 640);
      expect(frame.landmarks[L.nose.index].x, closeTo(0.5, 1e-9));
      expect(frame.landmarks[L.nose.index].y, closeTo(0.5, 1e-9));
    });

    test('0/180 度不交换宽高', () {
      final frame = convert(
        poseOf([lm(PoseLandmarkType.nose, x: 320, y: 240)]),
        imageWidth: 640,
        imageHeight: 480,
        rotation: InputImageRotation.rotation180deg,
      )!;
      expect(frame.frameWidth, 640);
      expect(frame.frameHeight, 480);
      expect(frame.landmarks[L.nose.index].x, closeTo(0.5, 1e-9));
      expect(frame.landmarks[L.nose.index].y, closeTo(0.5, 1e-9));
    });

    test('真机实测那一帧的髋部（回归锚点）', () {
      // 2026-10-04 实测：img=640x480 rot=270，
      // hipL=(230.1,460.5) hipR=(169.0,463.3)，鼻 y=194.8，最远点 y=728.1。
      //
      // 这条锚点的价值是把「像素」这个量纲钉死在测试里：哪天有人把归一化去掉，
      // 这两个值会原样变成 230.1 / 169.0，直接越界、断言立刻失败 ——
      // 而那正是当初骨架画在框外、被裁得一点不剩的成因。
      final frame = convert(
        poseOf([
          lm(PoseLandmarkType.leftHip, x: 230.1, y: 460.5),
          lm(PoseLandmarkType.rightHip, x: 169.0, y: 463.3),
        ]),
        imageWidth: 640,
        imageHeight: 480,
        rotation: InputImageRotation.rotation270deg,
      )!;
      expect(frame.landmarks[L.leftHip.index].x, closeTo(0.479, 0.001));
      expect(frame.landmarks[L.leftHip.index].y, closeTo(0.719, 0.001));
      expect(frame.isVisible(L.leftHip, 0.5), isTrue);
    });

    test('越界的点保持越界，不裁剪', () {
      // 人出画时 ML Kit 会外推（实测最远点 y=728.1 > 转正后高 640）。
      // 「这个点在画面外那个方向」是真实信息，裁掉反而丢掉了它。
      final frame = convert(
        poseOf([lm(PoseLandmarkType.leftAnkle, x: 1200, y: 1500)]),
      )!;
      expect(frame.landmarks[L.leftAnkle.index].x, greaterThan(1.0));
      expect(frame.landmarks[L.leftAnkle.index].y, greaterThan(1.0));
    });
  });

  group('姿态转换', () {
    test('检测不到人时返回 null', () {
      expect(
        convert(Pose(landmarks: const <PoseLandmarkType, PoseLandmark>{})),
        isNull,
      );
    });

    test('检出的点按索引归位，未检出的点给 0 可见性', () {
      final frame = convert(
        poseOf([
          lm(PoseLandmarkType.leftHip, x: 400, y: 600),
          lm(PoseLandmarkType.leftKnee, x: 400, y: 750),
        ]),
        timestampMs: 42,
      )!;

      expect(frame.landmarks, hasLength(nLandmarks));
      expect(frame.timestampMs, 42);
      // 归一化坐标 × 帧尺寸 —— 这一步是领域层的铁律，这里只确认乘对了。
      expect(frame.pixel(L.leftHip).x, closeTo(400, 1e-9));
      expect(frame.pixel(L.leftKnee).y, closeTo(750, 1e-9));

      // 未检出的点：可见性 0。于是依赖它的特征判为不可用，
      // 而不是拿一个编造出来的坐标去算角度。
      expect(frame.visibility(L.rightKnee), 0.0);

      final features = FeatureExtractor(cameraView: CameraView.sagittal).extract(frame);
      expect(features.isValid('knee_angle_R'), isFalse);
      expect(features.get('knee_angle_R'), isNull);
    });

    test('坐标非有限值时当作未检出，不让 NaN 流进几何算子', () {
      // NaN 不会抛异常，只会顺着三角函数把整帧的特征变成 NaN，
      // 而判定结果同样是「不越界」—— 一个彻底的静默失败。
      final frame = convert(
        poseOf([lm(PoseLandmarkType.leftHip, x: double.nan)]),
      )!;
      expect(frame.visibility(L.leftHip), 0.0);
    });

    test('可见性原样传递，不被抬成 1', () {
      // 被遮挡的脚部常常只有 0.2–0.4，而它正是脚跟离地判定要用的点。
      final frame = convert(
        poseOf([lm(PoseLandmarkType.leftHeel, likelihood: 0.3)]),
      )!;
      expect(frame.visibility(L.leftHeel), closeTo(0.3, 1e-9));
      expect(frame.isVisible(L.leftHeel, 0.5), isFalse);
    });

    test('可见点计数用于机位自检', () {
      final pose = poseOf([
        lm(PoseLandmarkType.nose),
        lm(PoseLandmarkType.leftEar, likelihood: 0.2),
      ]);
      expect(visibleLandmarkCount(pose), 1);
      expect(visibleLandmarkCount(pose, threshold: 0.1), 2);
    });
  });
}
