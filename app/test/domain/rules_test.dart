/// 规则引擎测试。
///
/// 重点不是覆盖率，而是把几条**踩过才知道**的结论钉成回归：
/// 归约方式选错会让每一次合格动作都被误判、未核定阈值绝不能扣分、
/// 不可用特征绝不能被当成 0。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

/// 造一帧：`null` 表示该特征本帧不可用。
FrameFeatures frame(int timestampMs, Map<String, double?> values) {
  final map = <String, FeatureValue>{};
  values.forEach((code, value) {
    map[code] = value == null
        ? FeatureValue.unavailable(
            code: code,
            unit: 'deg',
            coordSpace: 'image_2d',
            reason: 'low_visibility',
          )
        : FeatureValue(
            code: code,
            value: value,
            unit: 'deg',
            coordSpace: 'image_2d',
          );
  });
  return FrameFeatures(timestampMs: timestampMs, values: map);
}

/// 把一串膝角按 33ms 一帧铺成 rep。
List<FrameFeatures> kneeFrames(List<double?> angles) => [
      for (var i = 0; i < angles.length; i++) frame(i * 33, {'knee_angle_L': angles[i]}),
    ];

Threshold threshold(
  String key,
  double value, {
  SourceType sourceType = SourceType.literature,
}) =>
    Threshold(
      key: key,
      actionCode: 'squat',
      featureCode: 'knee_angle_L',
      value: value,
      unit: 'deg',
      sourceType: sourceType,
      version: 'test',
    );

void main() {
  group('归约方式', () {
    // 一次**合格**深蹲的膝角轨迹：下到 90° 再站起来。
    // BOTTOM 相位窗口被投票与停留延迟撑大，必然吃到下降与回升的过渡帧。
    const trajectory = <double>[
      170, 140, // STANDING
      120, 110, 105, // DESCENT（过渡帧）
      100, 95, 90, 95, 100, // BOTTOM
      110, 130, 150, // ASCENT（过渡帧）
      170, 170, 170,
    ];

    RepWindow windowOf(Reduce reduce) => RepWindow(
          index: 0,
          frames: kneeFrames(trajectory),
          // 深度线 100°：合格深蹲要求 BOTTOM 相位最低点达到 ≤100°
          phaseBounds: {
            Phase.bottom: (start: 2, end: 12),
            Phase.stand: (start: 0, end: 1),
          },
        );

    Rule depthRule(Reduce reduce) => Rule(
          code: 'squat_depth_insufficient',
          nameZh: '下蹲深度不足',
          metric: 'knee_angle_L',
          thresholdKey: 'squat_depth_min',
          badSide: Direction.above, // 膝角高于深度线 = 蹲得不够深
          phase: Phase.bottom,
          reduce: reduce,
          severitySpan: 30.0,
        );

    final thresholds = ThresholdTable(
      [threshold('squat_depth_min', 100.0)],
      version: 'test',
    );

    test('Reduce.min 认可一次蹲到 90° 的动作', () {
      final engine = RuleEngine([depthRule(Reduce.min)], thresholds);
      expect(engine.evaluateRep(windowOf(Reduce.min)), isEmpty);
    });

    test('Reduce.anyFrame 把同一次合格动作误判为深度不足', () {
      // 这就是那个教训：过渡帧 120/110/105 与回升帧 110/130/150 全部越界，
      // 越界帧数轻易越过 minViolatingFrames，于是「每一次深蹲都蹲得不够深」。
      final engine = RuleEngine([depthRule(Reduce.anyFrame)], thresholds);
      final faults = engine.evaluateRep(windowOf(Reduce.anyFrame));

      expect(faults, hasLength(1));
      expect(faults.single.code, 'squat_depth_insufficient');
      // 而且报出来的「最严重值」是过渡帧的 150°，完全不是这次动作的最低点。
      expect(faults.single.deviation.measured, 150.0);
    });

    test('站直不动的人，两种归约都判深度不足', () {
      // 靠相位窗口归位：不需要「深度规则」有任何独立逻辑。
      final frames = kneeFrames(List<double>.filled(16, 170));
      const bounds = {Phase.bottom: (start: 0, end: 15)};
      final window = RepWindow(index: 0, frames: frames, phaseBounds: bounds);

      for (final reduce in [Reduce.min, Reduce.anyFrame]) {
        final engine = RuleEngine([depthRule(reduce)], thresholds);
        expect(
          engine.evaluateRep(window),
          hasLength(1),
          reason: 'reduce=$reduce 时站直应当命中深度不足',
        );
      }
    });

    test('中位数归约对单帧抖动不敏感', () {
      // 15 帧 170°，混入 1 帧 80°（噪声）。中位数仍是 170° > 100° → 命中；
      // 而最大值归约就是 170°，最小值归约会被那一帧噪声带到 80° → 漏判。
      final angles = List<double?>.filled(15, 170)..[7] = 80;
      final window = RepWindow(index: 0, frames: kneeFrames(angles));
      final rule = Rule(
        code: 'x',
        nameZh: 'x',
        metric: 'knee_angle_L',
        thresholdKey: 'squat_depth_min',
        badSide: Direction.above,
        reduce: Reduce.median,
      );

      expect(RuleEngine([rule], thresholds).evaluateRep(window), hasLength(1));

      final minRule = Rule(
        code: 'x',
        nameZh: 'x',
        metric: 'knee_angle_L',
        thresholdKey: 'squat_depth_min',
        badSide: Direction.above,
        reduce: Reduce.min,
      );
      expect(RuleEngine([minRule], thresholds).evaluateRep(window), isEmpty);
    });
  });

  group('弹振：Reduce.reversals', () {
    // 这一组的序列都按「坐位体前屈的前伸段」写：髋角从坐直的 90° 往下走。
    //
    //   - 慢慢前伸到 40° 再坐回来 → 序列是「先降后升」，**掉头一次**
    //   - 靠弹振够距离的人 → 一伸一缩一伸一缩，掉头好几次
    //
    // 关键在第二行：两种人**前伸到底的那个角度可能一模一样**（弹的那一下
    // 甚至更远），所以 min/max/median 分不开他们，只有序列的形状分得开。

    /// 匀速前伸：每帧 3° 地从 90°（坐直）降到 42°（前伸到底），再匀速坐回去。
    ///
    /// 用 3°/帧 而不是 1°/帧：死区是 2°，1° 的步子会被整个忽略，
    /// 那样测出来的是「死区很大」而不是「慢慢来的人不掉头」。
    List<double> smoothReach() => [
          for (var value = 90.0; value >= 42.0; value -= 3) value,
          for (var value = 45.0; value <= 90.0; value += 3) value,
        ];

    /// 弹振前伸：同样的行程，但来回弹三趟（五段，四个掉头）。
    ///
    /// **它与 [smoothReach] 的最低点一模一样（都是 42°）** ——
    /// 这正是这条判据存在的理由：弹的那一下够得一点不比慢慢来的近。
    List<double> ballisticReach() => [
          for (var value = 90.0; value >= 42.0; value -= 3) value,
          for (var value = 45.0; value <= 90.0; value += 3) value,
          for (var value = 87.0; value >= 42.0; value -= 3) value,
          for (var value = 45.0; value <= 90.0; value += 3) value,
          for (var value = 87.0; value >= 42.0; value -= 3) value,
        ];

    test('慢慢来的人掉头一次，弹三趟的人掉头四次', () {
      expect(countReversals(smoothReach()), 1);
      expect(countReversals(ballisticReach()), 4);
      expect(
        smoothReach().reduce((a, b) => a < b ? a : b),
        ballisticReach().reduce((a, b) => a < b ? a : b),
        reason: '两者的最低点必须相同 —— 少了它，这条判据拿「够不够远」'
            '就能分开两个人，序列形状那套就白写了',
      );
    });

    test('匀速前伸的读数抖动不算掉头 —— 死区的作用', () {
      // **这一条是这条判据能不能用的分界。** 没有死区的话，一个人匀速前伸时
      // 特征上那一丁点抖动会被数成上百次翻转，躺平的人也被判「弹振借力」。
      //
      // 序列是每帧降 0.6° 的匀速前伸，叠上 ±0.9° 的读数抖动。关掉死区，
      // 那点抖动让差分在 −2.4° 与 +1.2° 之间来回，每一步都掉头。
      final smoothWithJitter = [
        for (var i = 0; i < 200; i++) 90.0 - i * 0.6 + (i.isEven ? 0.9 : -0.9),
      ];

      expect(
        countReversals(smoothWithJitter),
        0,
        reason: '死区之内那一步不算数，方向从头到尾只有一个',
      );
      expect(
        countReversals(smoothWithJitter, deadband: 0),
        greaterThan(100),
        reason: '把死区关掉，同一段匀速前伸被数成上百次掉头 —— 死区不是可选项，'
            '它决定了这条判据是在量弹振还是在量噪声',
      );
    });

    test('死区之外的一点点掉头才算数', () {
      // 摆幅 4°（> 死区 2°）→ 算；摆幅 1°（< 死区）→ 不算。
      // 这一条钉的是死区的**位置**，不是它的具体数值。
      //
      // 五次采样是四步，头一步只用来定方向 —— 所以 50↔54 来回得到的是 3 次。
      expect(countReversals(const [50, 54, 50, 54, 50]), 3);
      expect(countReversals(const [50, 51, 50, 51, 50]), 0);
    });

    test('短序列不与它自己掉头', () {
      expect(countReversals(const []), 0);
      expect(countReversals(const [50.0]), 0);
      expect(countReversals(const [50.0, 45.0]), 0);
      expect(
        countReversals(const [50.0, 45.0, 40.0]),
        0,
        reason: '从头降到尾 —— 一次掉头都没有，第一步只用来定方向',
      );
    });

    test('引擎里走得通：同一段前伸，弹振的那一份命中', () {
      // 直接测 `countReversals` 只证明这个函数对；这一条证明它**接进了规则
      // 引擎** —— `_reduce` 是个穷尽 switch，加成员时漏掉它编译不过，
      // 但「填进去了、填错了一句话」编译得过。
      //
      // 窗口取 `Phase.all`：弹振的证据散在**整次动作**上（前伸段抖、保持段可能
      // 一点不抖），只看 `Phase.bottom` 会漏掉它。下面那个 `phaseBounds` 里
      // 只有 `bottom`，正好也说明这条规则不读它。
      final thresholds = ThresholdTable(
        [threshold('srt.ballistic_reversals_max', 3.0)],
        version: 'test',
      );
      final rule = Rule(
        code: 'SRT_BALLISTIC',
        nameZh: '弹振借力',
        metric: 'hip_angle_L',
        thresholdKey: 'srt.ballistic_reversals_max',
        badSide: Direction.above,
        phase: Phase.all,
        reduce: Reduce.reversals,
        severitySpan: 4.0,
      );
      final engine = RuleEngine([rule], thresholds);

      RepWindow windowOf(List<double> values) => RepWindow(
            index: 0,
            frames: [
              for (var i = 0; i < values.length; i++)
                frame(i * 33, {'hip_angle_L': values[i]}),
            ],
            phaseBounds: {Phase.bottom: (start: 0, end: values.length - 1)},
          );

      expect(
        engine.evaluateRep(windowOf(smoothReach())),
        isEmpty,
        reason: '慢慢前伸的人不该被判弹振',
      );
      final faults = engine.evaluateRep(windowOf(ballisticReach()));
      expect(faults, hasLength(1));
      expect(faults.single.code, 'SRT_BALLISTIC');
      expect(
        faults.single.deviation.measured,
        4.0,
        reason: '报出来的应当是掉头次数本身（4 次），它才是「有多弹」的度量',
      );
    });
  });

  group('阈值治理', () {
    Rule rule() => Rule(
          code: 'squat_knee_valgus',
          nameZh: '膝内扣',
          metric: 'knee_angle_L',
          thresholdKey: 'valgus',
          badSide: Direction.below,
          minViolatingFrames: 3,
        );

    List<FrameFeatures> valgusFrames() => kneeFrames(List<double>.filled(10, 150));

    test('未核定阈值只出提示、不参与扣分', () {
      final table = ThresholdTable(
        [threshold('valgus', 160.0, sourceType: SourceType.pendingReview)],
        version: 'test',
      );
      final faults = RuleEngine([rule()], table).evaluateRep(
        RepWindow(index: 0, frames: valgusFrames()),
      );

      expect(faults, hasLength(1));
      expect(faults.single.scorable, isFalse);
    });

    test('已核定阈值正常参与扣分', () {
      final table = ThresholdTable([threshold('valgus', 160.0)], version: 'test');
      final faults = RuleEngine([rule()], table).evaluateRep(
        RepWindow(index: 0, frames: valgusFrames()),
      );

      expect(faults.single.scorable, isTrue);
    });

    test('requireScorable 拦住试图用未核定阈值扣分的调用', () {
      final table = ThresholdTable(
        [threshold('valgus', 160.0, sourceType: SourceType.pendingReview)],
        version: 'test',
      );
      expect(() => table.requireScorable('valgus'), throwsA(isA<ThresholdException>()));
      expect(table.pendingReview(), hasLength(1));
    });
  });

  group('鲁棒性', () {
    test('不可用特征被跳过，绝不填 0', () {
      // 全部帧的膝角都不可用 → 不产出任何判定。
      // 若把不可用当成 0，0° < 160° 会让每一帧都越界，凭空造出一个「膝内扣」。
      final table = ThresholdTable([threshold('valgus', 160.0)], version: 'test');
      final rule = Rule(
        code: 'squat_knee_valgus',
        nameZh: '膝内扣',
        metric: 'knee_angle_L',
        thresholdKey: 'valgus',
        badSide: Direction.below,
      );

      final faults = RuleEngine([rule], table).evaluateRep(
        RepWindow(index: 0, frames: kneeFrames(List<double?>.filled(10, null))),
      );
      expect(faults, isEmpty);
    });

    test('部分帧不可用时，置信度同时反映越界比例与数据可用率', () {
      final table = ThresholdTable([threshold('valgus', 160.0)], version: 'test');
      final rule = Rule(
        code: 'squat_knee_valgus',
        nameZh: '膝内扣',
        metric: 'knee_angle_L',
        thresholdKey: 'valgus',
        badSide: Direction.below,
      );

      // 10 帧里 5 帧有效，且全部越界 → coverage = 1.0, validity = 0.5
      final angles = <double?>[
        for (var i = 0; i < 10; i++) i.isEven ? 150 : null,
      ];
      final faults = RuleEngine([rule], table).evaluateRep(
        RepWindow(index: 0, frames: kneeFrames(angles)),
      );

      expect(faults, hasLength(1));
      expect(faults.single.confidence, closeTo(0.5, 1e-9));
      expect(faults.single.evidenceTimestamps, [0, 66, 132, 198, 264]);
    });

    test('相位边界越界时收敛到可用范围，而不是抛异常', () {
      final frames = kneeFrames(List<double?>.filled(5, 170.0));
      final window = RepWindow(
        index: 0,
        frames: frames,
        phaseBounds: {
          Phase.bottom: (start: -10, end: 99),
          Phase.stand: (start: 50, end: 60),
        },
      );

      expect(window.select(Phase.bottom), hasLength(5));
      expect(window.select(Phase.stand), isEmpty);
      expect(window.select(Phase.all), hasLength(5));
      // 未声明的相位退化为整段
      expect(window.select(Phase.ascent), hasLength(5));
    });
  });

  group('组级聚合', () {
    final table = ThresholdTable([threshold('valgus', 160.0)], version: 'test');
    Rule valgus() => Rule(
          code: 'squat_knee_valgus',
          nameZh: '膝内扣',
          metric: 'knee_angle_L',
          thresholdKey: 'valgus',
          badSide: Direction.below,
        );

    RepWindow rep(int index, {required bool bad}) => RepWindow(
          index: index,
          frames: kneeFrames(List<double?>.filled(10, bad ? 150 : 170)),
        );

    test('出现率按 rep 计，同一 rep 内重复命中只算一次', () {
      // 两条规则共享同一个错误码，同一次 rep 里都命中 —— 计 1 次而不是 2 次，
      // 否则「3 次里有 2 次膝内扣」会被放大成「4 次」。
      final engine = RuleEngine([valgus(), valgus()], table);
      final summary = engine.evaluateSet([rep(0, bad: true), rep(1, bad: false), rep(2, bad: true)]);

      expect(summary.repCount, 3);
      expect(summary.faultStats, hasLength(1));
      expect(summary.faultStats.single.count, 2);
      expect(summary.faultStats.single.rate, closeTo(0.6667, 1e-9));
      expect(summary.faultStats.single.repIndices, [0, 2]);
    });

    test('可扣分与仅提示分成两组', () {
      final pending = ThresholdTable(
        [threshold('valgus', 160.0, sourceType: SourceType.pendingReview)],
        version: 'test',
      );
      final summary = RuleEngine([valgus()], pending).evaluateSet([rep(0, bad: true)]);

      expect(summary.scorableFaults, isEmpty);
      expect(summary.notices, hasLength(1));
    });

    test('primaryFault 并列时取排序靠前的一个', () {
      // 两个错误码出现率与最坏偏离都相同。Python 的 max() 返回第一个最大值，
      // 这里必须一致，否则端侧与服务端会给出不同的「主问题」。
      Rule twin(String code) => Rule(
            code: code,
            nameZh: code,
            metric: 'knee_angle_L',
            thresholdKey: 'valgus',
            badSide: Direction.below,
          );
      final engine = RuleEngine([twin('aaa'), twin('zzz')], table);
      final summary = engine.evaluateSet([rep(0, bad: true)]);

      expect(summary.faultStats.map((s) => s.code), ['aaa', 'zzz']);
      expect(summary.primaryFault()!.code, 'aaa');
    });

    test('空组不除零', () {
      final summary = RuleEngine([valgus()], table).evaluateSet([]);
      expect(summary.repCount, 0);
      expect(summary.faultStats, isEmpty);
      expect(summary.primaryFault(), isNull);
    });
  });

  group('规则定义校验', () {
    Rule build({int minViolatingFrames = 3, double? severitySpan}) => Rule(
          code: 'r',
          nameZh: 'r',
          metric: 'knee_angle_L',
          thresholdKey: 'k',
          badSide: Direction.above,
          minViolatingFrames: minViolatingFrames,
          severitySpan: severitySpan,
        );

    test('minViolatingFrames 必须 >= 1', () {
      expect(() => build(minViolatingFrames: 0), throwsA(isA<RuleException>()));
      expect(() => build(minViolatingFrames: 1), returnsNormally);
    });

    test('severitySpan 必须为正或 null', () {
      expect(() => build(severitySpan: 0), throwsA(isA<RuleException>()));
      expect(() => build(severitySpan: -1), throwsA(isA<RuleException>()));
      expect(() => build(severitySpan: 30), returnsNormally);
      expect(() => build(), returnsNormally);
    });
  });
}
