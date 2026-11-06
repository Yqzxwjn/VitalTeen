/// 几何算子与姿态帧的测试。
///
/// 这里挑的是**跨语言一致性最容易被破坏的两处**：
///
/// 1. **坐标还原必须按宽高分别折算** —— 折错了不会报错，只会静默给出错误角度。
///    用非正方形画幅（720×1280）来验，任何"两轴乘同一个数"的退化都会失败。
/// 2. **atan2 的负零陷阱** —— `atan2(-0.0, -100.0)` 返回 `-π` 而非 `+π`，
///    让纯水平向左的向量得到 `-180.0`，落在文档声明的 `(-180, 180]` 之外。
///    数值上等价，但会让与 Python 的**逐值比对出现假不等**。
///
/// 这两条在 Python 侧都曾经是真 bug，移植时必须一起带过来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/domain/geometry.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

/// 构造一帧：给定画幅与少数几个点，其余填默认。
PoseFrame makeFrame({
  int width = 720,
  int height = 1280,
  Map<L, (double, double)> points = const {},
  double visibility = 1.0,
}) =>
    poseFrameFromPoints(
      points: points,
      frameWidth: width,
      frameHeight: height,
      visibility: visibility,
    );

void main() {
  group('坐标还原', () {
    test('按宽高【分别】折算，而不是乘同一个数', () {
      // 720×1280 是竖屏画幅，宽高差近一倍 —— 退化实现必然暴露
      final frame = makeFrame(points: {L.nose: (0.25, 0.75)});
      final p = frame.pixel(L.nose);
      expect(p.x, closeTo(180.0, 1e-9)); // 0.25 × 720
      expect(p.y, closeTo(960.0, 1e-9)); // 0.75 × 1280
    });

    test('同一归一化点在两种画幅下给出不同像素坐标', () {
      final portrait = makeFrame(width: 720, height: 1280, points: {L.nose: (0.5, 0.5)});
      final landscape = makeFrame(width: 1920, height: 1080, points: {L.nose: (0.5, 0.5)});
      expect(portrait.pixel(L.nose).x, closeTo(360.0, 1e-9));
      expect(landscape.pixel(L.nose).x, closeTo(960.0, 1e-9));
    });

    test('越界的归一化坐标不被截断', () {
      // 人出画时 x/y 可能 <0 或 >1，截断会让角度算错
      final frame = makeFrame(points: {L.nose: (-0.1, 1.2)});
      expect(frame.pixel(L.nose).x, closeTo(-72.0, 1e-9));
      expect(frame.pixel(L.nose).y, closeTo(1536.0, 1e-9));
    });

    test('jointAngle 走的是像素坐标 —— 用归一化坐标会得到不同的角', () {
      // 顶点 (0.5,0.5)，两端各偏移 (-72,-96) 与 (+96,-72) 像素：
      // 在 720×1280 下像素空间恰为 90°
      const w = 720.0, h = 1280.0;
      final vertex = (0.5, 0.5);
      final a = (0.5 - 72 / w, 0.5 - 96 / h);
      final b = (0.5 + 96 / w, 0.5 - 72 / h);
      final frame = makeFrame(points: {L.leftHip: a, L.leftKnee: vertex, L.leftAnkle: b});
      expect(jointAngle(frame, L.leftHip, L.leftKnee, L.leftAnkle), closeTo(90.0, 1e-6));
    });
  });

  group('angle3', () {
    test('顶点是第二个参数', () {
      expect(
        angle3(const PixelPoint(0, 0), const PixelPoint(0, 100), const PixelPoint(100, 100)),
        closeTo(90.0, 1e-9),
      );
    });

    test('交换两端点结果不变', () {
      const a = PixelPoint(0, 0), b = PixelPoint(10, 10), c = PixelPoint(30, 4);
      expect(angle3(a, b, c), closeTo(angle3(c, b, a), 1e-9));
    });

    test('退化时抛异常，而不是返回 NaN 或 0', () {
      expect(
        () => angle3(const PixelPoint(5, 5), const PixelPoint(5, 5), const PixelPoint(9, 9)),
        throwsA(isA<DegenerateGeometryException>()),
      );
    });
  });

  group('倾角 —— 负零陷阱', () {
    test('tiltFromVertical 四个基本方向', () {
      const origin = PixelPoint(0, 0);
      expect(tiltFromVertical(origin, const PixelPoint(0, -100)), closeTo(0.0, 1e-9));
      expect(tiltFromVertical(origin, const PixelPoint(100, 0)), closeTo(90.0, 1e-9));
      expect(tiltFromVertical(origin, const PixelPoint(0, 100)), closeTo(180.0, 1e-9));
      expect(tiltFromVertical(origin, const PixelPoint(-100, 0)), closeTo(-90.0, 1e-9));
    });

    test('tiltFromHorizontal 四个基本方向', () {
      const origin = PixelPoint(0, 0);
      expect(tiltFromHorizontal(origin, const PixelPoint(100, 0)), closeTo(0.0, 1e-9));
      expect(tiltFromHorizontal(origin, const PixelPoint(0, -100)), closeTo(90.0, 1e-9));
      expect(tiltFromHorizontal(origin, const PixelPoint(-100, 0)), closeTo(180.0, 1e-9));
      expect(tiltFromHorizontal(origin, const PixelPoint(0, 100)), closeTo(-90.0, 1e-9));
    });

    test('纯水平向左得到 +180，不是 −180', () {
      // v = (-100, 0) 时 -v[1] = -0.0，而 atan2(-0.0, -100.0) 返回 -π。
      // 没有 _normalizeSignedDegrees 的话这里会是 -180.0。
      final value = tiltFromHorizontal(const PixelPoint(100, 0), const PixelPoint(0, 0));
      expect(value, closeTo(180.0, 1e-9));
      expect(value > 0, isTrue, reason: '落在 (-180, 180] 之外说明负零陷阱没被处理');
    });

    test('不泄漏负零', () {
      // 水平向右曾返回 -0.0；JSON 序列化后会写成 -0.0，
      // 破坏与 Python 的精确比对
      final right = tiltFromHorizontal(const PixelPoint(0, 0), const PixelPoint(100, 0));
      expect(right, closeTo(0.0, 1e-9));
      expect(right.toString().startsWith('-'), isFalse, reason: '输出泄漏了负零');

      final up = tiltFromVertical(const PixelPoint(0, 0), const PixelPoint(0, -100));
      expect(up.toString().startsWith('-'), isFalse);
    });

    test('退化时抛异常', () {
      expect(
        () => tiltFromVertical(const PixelPoint(7, 7), const PixelPoint(7, 7)),
        throwsA(isA<DegenerateGeometryException>()),
      );
    });
  });

  group('其余算子', () {
    test('symmetryIndex 对称时为 0', () {
      expect(symmetryIndex(180.0, 180.0), closeTo(0.0, 1e-12));
      expect(symmetryIndex(90.0, 90.0), closeTo(0.0, 1e-12));
    });

    test('symmetryIndex 与左右顺序无关', () {
      expect(symmetryIndex(80.0, 100.0), closeTo(symmetryIndex(100.0, 80.0), 1e-12));
    });

    test('symmetryIndex 分母为零时抛异常', () {
      expect(
        () => symmetryIndex(0.0, 0.0),
        throwsA(isA<DegenerateGeometryException>()),
      );
    });

    test('signedOffset 图像坐标下顺时针为正', () {
      // a→b 指向图像右侧（3 点钟），顺时针一侧是图像下方（6 点钟）
      expect(
        signedOffset(const PixelPoint(50, 100), const PixelPoint(0, 0), const PixelPoint(100, 0)),
        closeTo(100.0, 1e-9),
      );
      expect(
        signedOffset(const PixelPoint(50, -100), const PixelPoint(0, 0), const PixelPoint(100, 0)),
        closeTo(-100.0, 1e-9),
      );
    });

    test('distRatio 用参考线段归一', () {
      expect(
        distRatio(
          const PixelPoint(0, 0),
          const PixelPoint(3, 4),
          const PixelPoint(0, 0),
          const PixelPoint(10, 0),
        ),
        closeTo(0.5, 1e-12),
      );
    });

    test('angularVelocityDegPerSec 在 dt<=0 时抛异常', () {
      expect(
        () => angularVelocityDegPerSec(10, 20, 0),
        throwsA(isA<DegenerateGeometryException>()),
      );
    });
  });

  group('PoseFrame 的校验与可见性', () {
    test('关键点数量不对时抛异常', () {
      expect(
        () => PoseFrame(
          landmarks: const [],
          frameWidth: 720,
          frameHeight: 1280,
          timestampMs: 0,
        ),
        throwsA(isA<PoseFrameException>()),
      );
    });

    test('画幅必须为正', () {
      expect(
        () => poseFrameFromPoints(points: const {}, frameWidth: 0, frameHeight: 1280),
        throwsA(isA<PoseFrameException>()),
      );
    });

    test('无世界坐标时返回 null，而不是 0', () {
      final frame = makeFrame();
      expect(frame.hasWorld, isFalse);
      expect(frame.world(L.nose), isNull);
    });

    test('可见性判定是 >=（恰好等于阈值算可见）', () {
      final frame = makeFrame(points: {L.leftKnee: (0.5, 0.68)}, visibility: 0.6);
      expect(frame.isVisible(L.leftKnee, 0.6), isTrue);
      expect(frame.isVisible(L.leftKnee, 0.61), isFalse);
    });

    test('allVisible 一票否决', () {
      final frame = makeFrame(points: {L.leftKnee: (0.5, 0.68)}, visibility: 0.4);
      expect(frame.allVisible([L.nose, L.leftKnee], 0.5), isFalse);
    });

    test('躯干长取肩中点到髋中点的距离', () {
      final frame = makeFrame(points: {
        L.leftShoulder: (0.5, 0.2),
        L.rightShoulder: (0.5, 0.2),
        L.leftHip: (0.5, 0.5),
        L.rightHip: (0.5, 0.5),
      });
      // 0.3 × 1280 = 384 像素
      expect(frame.torsoLength(), closeTo(384.0, 1e-6));
    });
  });
}
