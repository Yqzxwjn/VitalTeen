/// `pose_quality` 五项的统计测试。
///
/// **这里断言的是「算出来的数与喂进去的帧对得上」**，因为这一层的失败方式是
/// 安静地报出一个好看的数字：决策层拿到 `mean_visibility: 0.95` 会以为数据
/// 干净，而它没有任何办法复核 —— 除了这五个数，它什么都看不到。
///
/// 所以重点在两处：分母取得对不对（帧数、间隔数），以及**算不出来时会不会
/// 硬编一个数**。后者尤其要紧：契约里 `fps_mean` 是严格大于 0 的，拿 0 去填
/// 会被服务端拒收，而 400 离真正的病因（这一组根本没有带时钟的帧）很远。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/pose_quality_tracker.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

import '../support/synthetic_squat.dart';

/// 时间轴起点。**不能是 0** —— 追踪器把 `timestampMs <= 0` 当作「这帧没有
/// 时钟」（合成帧就是那个样子），从 0 起算会让整个测试落进「算不出来」那一档，
/// 而断言看见的只是一个 `null`，离病因很远。
const int _base = 10000;

/// 一帧站立，[ms] 是相对 [_base] 的毫秒数。
PoseFrame _frame(
  int ms, {
  double visibility = 1.0,
  Map<L, double>? overrides,
}) =>
    squatPose(
      standDeg,
      timestampMs: _base + ms,
      visibility: visibility,
      visibilityOverrides: overrides,
    );

void main() {
  group('算不出来就不编', () {
    test('一帧都没有 → null', () {
      expect(PoseQualityTracker().quality, isNull);
    });

    test('只有一帧 → null', () {
      // 单帧没有「帧率」也没有「最大间隔」可言。
      final tracker = PoseQualityTracker()..add(_frame(0), viewStable: true);
      expect(tracker.quality, isNull);
    });

    test('两帧都没有时钟 → null', () {
      final tracker = PoseQualityTracker()
        ..add(squatPose(standDeg, timestampMs: 0), viewStable: true)
        ..add(squatPose(standDeg, timestampMs: 0), viewStable: true);
      expect(tracker.quality, isNull,
          reason: '时间跨度为零时帧率无从谈起，填 0 会被服务端拒收');
    });

    test('两帧时间戳相同 → null', () {
      final tracker = PoseQualityTracker()
        ..add(_frame(1000), viewStable: true)
        ..add(_frame(1000), viewStable: true);
      expect(tracker.quality, isNull);
    });

    test('合成帧（时间戳为 0）不该被算进帧率', () {
      // 拿 0 当时间戳的帧混进来会把跨度撑大，凭空算出一个偏低的帧率 ——
      // 而那个数看起来完全正常。
      final noClock = squatPose(standDeg, timestampMs: 0);
      final tracker = PoseQualityTracker()
        ..add(noClock, viewStable: true)
        ..add(_frame(0), viewStable: true)
        ..add(_frame(1000), viewStable: true);

      final quality = tracker.quality!;
      expect(quality.fpsMean, closeTo(1.0, 1e-9),
          reason: '带时钟的两帧间隔 1000ms → 1 fps；三帧里有几帧没时钟不影响');
      expect(quality.gapMaxMs, 1000);
    });
  });

  group('五项各自的数', () {
    test('帧率按间隔数算，不是按帧数', () {
      // 11 帧、每帧间隔 33ms：跨度 330ms，间隔是 10 个 → 30.3 fps。
      // 按帧数算会得到 33.3，差 10% —— 恰好是那种「看着差不多」的错。
      final tracker = PoseQualityTracker();
      for (var i = 0; i < 11; i++) {
        tracker.add(_frame(i * 33), viewStable: true);
      }

      expect(tracker.quality!.fpsMean, closeTo(10 * 1000 / 330, 1e-9));
    });

    test('最大间隔取相邻两帧之差的最大值', () {
      final tracker = PoseQualityTracker()
        ..add(_frame(0), viewStable: true)
        ..add(_frame(33), viewStable: true)
        ..add(_frame(1500), viewStable: true) // 人走开了 1.5 秒
        ..add(_frame(1533), viewStable: true);

      expect(tracker.quality!.gapMaxMs, 1500 - 33);
    });

    test('可见性取全体关键点的帧均值', () {
      final tracker = PoseQualityTracker()
        ..add(_frame(0), viewStable: true)
        ..add(_frame(33, visibility: 0.5), viewStable: true);

      expect(tracker.quality!.meanVisibility, closeTo(0.75, 1e-9));
    });

    test('缺一个必需点就算覆盖不全', () {
      // coverage_ok_ratio 问的是「算特征要用的点齐不齐」，
      // 所以它盯的是必需点集，不是平均可见性 —— 两者可以差很远。
      final tracker = PoseQualityTracker()
        ..add(_frame(0), viewStable: true)
        ..add(_frame(33, overrides: {L.leftKnee: 0.2}), viewStable: true);

      final quality = tracker.quality!;
      expect(quality.coverageOkRatio, closeTo(0.5, 1e-9));
      expect(quality.meanVisibility, greaterThan(0.9),
          reason: '33 个点里只有一个掉了，平均值几乎不动 —— '
              '这正是为什么光看平均值会漏掉「关键点没了」');
    });

    test('不参与计数的点掉了不算覆盖不全', () {
      // 右手腕不在必需集里。把它算进去会让 coverage_ok_ratio 报低，
      // 而低到一定程度决策层就会弃权 —— 为一件不影响判定的事。
      final tracker = PoseQualityTracker()
        ..add(_frame(0), viewStable: true)
        ..add(_frame(33, overrides: {L.rightWrist: 0.1}), viewStable: true);

      expect(tracker.quality!.coverageOkRatio, 1.0);
    });

    test('可见性门槛与门禁同值，0.5 不算缺失', () {
      final tracker = PoseQualityTracker()
        ..add(_frame(0, overrides: {L.leftKnee: 0.5}), viewStable: true)
        ..add(_frame(33, overrides: {L.leftKnee: 0.49}), viewStable: true);

      expect(tracker.quality!.coverageOkRatio, closeTo(0.5, 1e-9));
    });

    test('机位把握度是稳定帧的占比', () {
      final tracker = PoseQualityTracker()
        ..add(_frame(0), viewStable: true)
        ..add(_frame(33), viewStable: false)
        ..add(_frame(66), viewStable: false)
        ..add(_frame(99), viewStable: false);

      expect(tracker.quality!.viewConfidence, closeTo(0.25, 1e-9));
    });
  });

  group('分组之间互不串味', () {
    test('reset 之后一切归零', () {
      final tracker = PoseQualityTracker();
      for (var i = 0; i < 10; i++) {
        tracker.add(_frame(i * 33, visibility: 0.5), viewStable: false);
      }
      tracker.reset();

      // 清空后连「算不出来」都回到了初始态。
      expect(tracker.quality, isNull);
      tracker.add(_frame(0), viewStable: true);
      expect(tracker.quality, isNull, reason: 'reset 后只有一帧，仍在算不出来那一档');

      tracker.add(_frame(33), viewStable: true);
      final quality = tracker.quality!;
      expect(quality.meanVisibility, 1.0);
      expect(quality.viewConfidence, 1.0);
      expect(quality.gapMaxMs, 33);
    });

    test('时间戳回退（换了一组重来）不会把间隔算成负数', () {
      // 上一组最后一帧 ts=5000，新一组从 ts=0 开始。若不清空，
      // 差值 -5000 会被当成一个「很大的负间隔」—— 而负数比任何正数都小，
      // 于是 gap_max_ms 会永远停在 0，看起来像是从没中断过。
      final tracker = PoseQualityTracker()
        ..add(_frame(5000), viewStable: true)
        ..add(_frame(5000 + 33), viewStable: true);

      expect(tracker.quality!.gapMaxMs, 33);
      tracker.reset();
      tracker.add(_frame(0), viewStable: true);
      tracker.add(_frame(33), viewStable: true);

      expect(tracker.quality!.gapMaxMs, 33);
    });
  });
}
