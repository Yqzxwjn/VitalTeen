/// 开合跳动作定义测试。
///
/// 这里钉住四类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **只开到一半的跳不算一次。** `OPEN` 是 `bottomState`，而那四条分段线
///    全部相对本人站立基线 —— 于是「开了一半」既可能被判成一次计数，也可能
///    被判成一次丢弃，两者的差别只在一根线上，而界面上都不会报错。
/// 2. **三条判定的方向各自都对。** 尤其 `JJ_KNEE_VALGUS`：`frontal_knee_angle_*`
///    的约定与 `knee_angle_*` 相反（直腿 0° 而不是 180°），写成 `below` 的表现
///    只是「这条判定老是误报」，看不出病因。
/// 3. **两条「幅度不足」类规则跑在整段上。** 把窗口切到只在「已经开到位」时才
///    存在的状态上，恰好会让它在最需要它的人身上失明 —— 所以正例与反例都要有。
/// 4. **相位只映射一个状态，而且真的只覆盖那一段。** `RepWindow.select` 在相位
///    缺失时静默返回整段，于是「只看落地那一刻」会悄悄变成「看整次动作」。
///
/// 阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
/// 与真实资产的对照在「真实阈值表」那组里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/jj.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_jj.dart';

/// 正面机位下的站立基线。**`heelRiseRatio` 是空的** —— 那正是这一轮要修的事：
/// 正面机位采不到脚跟抬升比，而开合跳也不需要它。
const Calibration _standingCalibration = Calibration(
  kneeAngle: jjStandDeg,
  trunkLean: 0,
  // 正面机位下这个量恒不可用（`heel_rise_ratio_L` 声明 [sagittal, oblique45]），
  // 而且开合跳不判脚跟离地 —— 给 null 就是真实会话里的样子。
  heelRiseRatio: null,
  legSpread: jjStandSpread,
  frames: 15,
);

/// 内联阈值表。三条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的取值远一点，免得断在阈值同侧的边界上：
/// 分腿峰值 2.0 对阈 1.20、手臂 175° 对阈 150°、膝内扣约 11.8° 对阈 8°。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: jjActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('jj.spread_min_ratio', 1.20, 'leg_spread_ratio'),
        _threshold('jj.arm_min_angle', 150.0, 'shoulder_angle_min', unit: 'deg'),
        _threshold(
          'jj.knee_valgus_angle_notice',
          8.0,
          'frontal_knee_angle_max',
          unit: 'deg',
        ),
      ],
      version: 'test',
    );

TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.frontal, maxRepFrames: 90);

ActionRunner _runner() => ActionRunner(
      buildJj(_standingCalibration, config: _config()),
      thresholds: _localTable(),
      calibration: _standingCalibration,
    );

void _feed(ActionRunner runner, List<PoseFrame> frames) {
  for (final frame in frames) {
    runner.feed(frame);
  }
}

/// 取出某个状态的出边守卫，用来单独验证分段条件。
Guard _guardOf(ActionDefinition definition, String src, String dst) =>
    definition.transitions
        .firstWhere((t) => t.src == src && t.dst == dst)
        .guard;

/// 取出某条错误的组级统计，没有则返回 null。
FaultStat? _statOf(SetSummary summary, String code) {
  for (final stat in summary.faultStats) {
    if (stat.code == code) return stat;
  }
  return null;
}

/// 正面机位下读一帧的特征值。
///
/// **必须显式给正面机位**：`leg_spread_ratio` 与 `frontal_knee_angle_max`
/// 都声明 `views: [frontal]`，用别的机位读出来的是 `view_mismatch` 而不是数值 ——
/// 而那是静默的（`get` 返回 null），测试会以一个看不懂的方式失败。
const FeatureExtractor _frontal = FeatureExtractor(cameraView: CameraView.frontal);

double? _feature(PoseFrame frame, String code) => _frontal.extract(frame).get(code);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄少一条边', () {
      // 这几条线全是可调的工程参数。调乱之后状态机不会报错，只会少一条边
      // 或者多一条「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。
      expect(
        () => buildJj(
          _standingCalibration,
          // 滞回带比起步线还大：CLOSED 与 OPENING 之间没有空间。
          config: const TrackingConfig(
            cameraView: CameraView.frontal,
            spreadEnterDelta: 0.10,
            spreadHysteresis: 0.30,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );

      expect(
        () => buildJj(
          _standingCalibration,
          // 到位线比起步线还低：OPEN 一进就成立。
          config: const TrackingConfig(
            cameraView: CameraView.frontal,
            spreadEnterDelta: 0.60,
            spreadFullDelta: 0.40,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('没有分腿基线时抛，而不是拿 0 顶上', () {
      // 取 0 的后果不是「差一点」：四条分段线会全部落在 0.1 上下，
      // 于是几乎任何站姿都在 OPEN 里，每一次抖动都被计成一次开合跳，
      // **而且不报错**。
      expect(
        () => buildJj(
          const Calibration(
            kneeAngle: jjStandDeg,
            trunkLean: 0,
            heelRiseRatio: null,
            frames: 15,
          ),
          config: _config(),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('默认机位是正面 —— 换掉它两条判定会静默消失', () {
      final definition = buildJj(_standingCalibration);
      expect(definition.cameraView, CameraView.frontal);

      // 反面：45° 下两个额状面特征都判 `view_mismatch`，
      // 而特征不可用时规则不命中、也不报错。
      final frame = jjPose(timestampMs: 0, spread: jjJumpSpread);
      const oblique = FeatureExtractor(cameraView: CameraView.oblique45);
      expect(oblique.extract(frame).get('leg_spread_ratio'), isNull);
      expect(oblique.extract(frame).get('frontal_knee_angle_max'), isNull);
    });
  });

  group('合成姿态的数值', () {
    test('分腿比与手臂角度是精确造出来的', () {
      // 判定测试要断的是「越没越过阈值」，所以这两个必须能算得准 ——
      // 它们分别是两条规则的自变量。
      for (final spread in [0.0, jjStandSpread, 1.0, jjJumpSpread]) {
        final frame = jjPose(timestampMs: 0, spread: spread);
        expect(
          _feature(frame, 'leg_spread_ratio'),
          closeTo(spread, 1e-9),
          reason: '分腿比应当逐位等于传入值',
        );
      }

      for (final deg in [jjArmDownDeg, 90.0, jjArmUpDeg]) {
        final frame = jjPose(timestampMs: 0, armDeg: deg);
        expect(
          _feature(frame, 'shoulder_angle_min'),
          closeTo(deg, 1e-9),
          reason: '肩角应当逐位等于传入值',
        );
        // 两侧都造得出来，`min` 才等于它。
        expect(_feature(frame, 'shoulder_angle_L'), closeTo(deg, 1e-9));
        expect(_feature(frame, 'shoulder_angle_R'), closeTo(deg, 1e-9));
      }
    });

    test('直腿时额状面膝角为 0，内扣时变大 —— 与膝角的方向相反', () {
      // **这条是 1.3.1 那处测量的可执行版本。** 两个「膝角」的约定正好相反：
      // 直腿时 `knee_angle_*` 是 180°、`frontal_knee_angle_*` 是 0°。
      // 谁把 `JJ_KNEE_VALGUS` 的方向改成 `below`，下面那条断言会红。
      final straight = jjPose(timestampMs: 0, spread: jjJumpSpread, kneeInward: 0);
      // 容差 1e-3° 而不是逐位相等：合成的膝点是「髋踝中点」，在实数上严格共线，
      // 但 `(hx+ax)/2 − hx` 与 `ax − (hx+ax)/2` 是两条不同的浮点路径 ——
      // 实测两个角各偏 1.2e-6°（`knee_angle_L` 读回来是 179.99999879）。
      // **这是浮点的表现，不是膝歪了**：1e-3 仍然比这里要辨别的信号
      // （内扣 0.02 → 11.4°）小四个数量级。
      expect(_feature(straight, 'frontal_knee_angle_max'), closeTo(0.0, 1e-3));
      expect(_feature(straight, 'knee_angle_L'), closeTo(180.0, 1e-3));

      final valgus = jjPose(timestampMs: 0, spread: jjJumpSpread, kneeInward: 0.02);
      final angle = _feature(valgus, 'frontal_knee_angle_max')!;
      expect(
        angle,
        greaterThan(8.0),
        reason: '0.02 的膝点内移应当在设计文档 §5.2 的最小可检测差异（约 8°）之上',
      );
      expect(_feature(valgus, 'knee_angle_L')!, lessThan(180.0));
    });
  });

  group('分段', () {
    test('标准一次计 1', () {
      final runner = _runner();
      _feed(runner, jjRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, JjStates.closed);
    });

    test('只开到一半就合上：计 0、弃 1', () {
      // 「开合」这个动作的判定对象是「开」到没到位。只到一半的跳**不算一次**，
      // 而它也不是无声无息地消失 —— `discardedReps` 记账，界面解释为
      // 「有 N 次没计入（幅度不够或太快）」。
      final runner = _runner();
      _feed(runner, jjRepFrames(startTimestampMs: 0, peakSpread: jjHalfSpread));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, JjStates.closed, reason: '要回到站立态等下一跳');
    });

    test('守卫的上下界：开到一半进得去 OPENING，回到基线才回得去 CLOSED', () {
      // 上面那条计数测试一旦变绿，就可能是因为「压根没离开 CLOSED」——
      // 那样它证明的是别的东西。这里直接对守卫求值。
      final definition = buildJj(_standingCalibration, config: _config());
      bool at(String src, String dst, double spread) =>
          _guardOf(definition, src, dst)
              .call({'leg_spread_ratio': spread});

      expect(at(JjStates.closed, JjStates.opening, jjStandSpread), isFalse);
      expect(at(JjStates.closed, JjStates.opening, jjHalfSpread), isTrue);
      expect(at(JjStates.closed, JjStates.opening, jjJumpSpread), isTrue);

      expect(at(JjStates.opening, JjStates.open, jjHalfSpread), isFalse);
      expect(at(JjStates.opening, JjStates.open, jjJumpSpread), isTrue);

      // 开局与封存落到 CLOSED 用的是**同一条线**：CLOSED 只有一个含义。
      expect(_guardOf(definition, JjStates.opening, JjStates.closed),
          same(_guardOf(definition, JjStates.closing, JjStates.closed)));

      // 而滞回带保证「刚进 OPENING」的那一帧不会被同一条线立刻推回去。
      expect(at(JjStates.opening, JjStates.closed, jjOpenLine), isFalse);
    });

    test('回弹不卡死：合到一半又张开，仍然合得拢', () {
      // 守卫看不见时间，没有 CLOSING → OPEN 这条边的话，「落地后弹一下又开」
      // 会停在 CLOSING 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
      // 一个错的状态词。
      final runner = _runner();
      _feed(
        runner,
        jjFromSegments([
          jjClosed,
          jjOpenFull,
          const JjSegment(spread: 0.30), // 合到一半（低于 openLine）
          jjOpenFull, // 又张开
          const JjSegment(spread: jjStandSpread), // 终于合拢 → 封存
        ]),
      );

      expect(runner.repCount, 1, reason: '回弹之后仍然要合得拢');
      expect(runner.currentState, JjStates.closed);
    });

    test('站着不动不会被计也不会被弃', () {
      final runner = _runner();
      _feed(runner, jjStandFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '站着不动不该被记账成一次丢弃');
      expect(runner.currentState, JjStates.closed);
    });

    test('相位只覆盖合拢那一段，而不是整次动作', () {
      // 与立定跳远那组同一条理由：`RepWindow.select` 在相位缺失时**静默**返回
      // 整段，于是「只看落地那一刻」会悄悄变成「看整次动作」——
      // 而 `JJ_KNEE_VALGUS` 就再也不会因为「落地时才内扣」而漏判。
      final runner = _runner();
      _feed(runner, jjRepFrames(startTimestampMs: 0));

      final window = runner.windows.single;
      final contact = window.select(Phase.contact);
      expect(contact, isNotEmpty);
      expect(
        contact.length,
        lessThan(window.frames.length),
        reason: '相位退化成了整段，等于规则在整次动作上求值',
      );
      // 开合跳只映射这一个相位；别的相位取出来必然退化成整段。
      expect(window.phaseBounds.keys, [Phase.contact]);
      // 触地段在末尾：它之后只剩「已经在站立态」的收尾帧。
      expect(
        window.phaseBounds[Phase.contact]!.start,
        greaterThan(window.frames.length ~/ 2),
      );
    });

    test('分腿一直不够时超时丢弃 —— 不会无限挂着一个未完成的 rep', () {
      final runner = _runner();
      _feed(runner, jjFromSegments([
        jjClosed,
        // 0.30 低于 openLine（0.42），压根没离开 CLOSED —— 那就连丢弃都不该有。
        const JjSegment(spread: 0.30, count: 120),
      ]));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '没离开过站立态，就没有「一次」可丢');
    });
  });

  group('三条规则', () {
    test('分腿幅度不足：只命中开得不够的那一跳', () {
      // 峰值不给到位的那个跳**必须进得去 OPEN**，否则它会被 `bottomState`
      // 挡在外面、整段被丢弃，这条规则于是根本没机会求值 —— 而它恰恰是
      // 最该对这种人说话的那条。所以峰值要落在**到位线 0.92 与绝对阈值 1.20
      // 之间**（这里取 1.05）：这正是「本人站姿窄（基线小）、相对线偏低，
      // 于是跳了但跳得不够开」的那种人。
      //
      // 峰值取到阈值以上（比如 1.5）的话，这条测试会变成在证「没超阈值就不判」——
      // 那是另一件事，而且它在下面「标准一次」那条里已经被覆盖了。
      final low = _runner();
      _feed(low, jjRepFrames(startTimestampMs: 0, peakSpread: 1.05));
      expect(low.repCount, 1, reason: '过了 fullLine（0.92），算一次');
      expect(_statOf(low.finishSet(), 'JJ_INSUFFICIENT_SPREAD'), isNotNull);

      final good = _runner();
      _feed(good, jjRepFrames(startTimestampMs: 0));
      expect(good.repCount, 1);
      expect(
        _statOf(good.finishSet(), 'JJ_INSUFFICIENT_SPREAD'),
        isNull,
        reason: '标准开合跳不该被判幅度不足 —— 否则这条规则是「永远命中」',
      );
    });

    test('手臂上举幅度不足：只命中举得不够的那一跳', () {
      final low = _runner();
      _feed(low, jjRepFrames(startTimestampMs: 0, peakArmDeg: 90.0));
      expect(low.repCount, 1);
      expect(_statOf(low.finishSet(), 'JJ_INSUFFICIENT_ARM'), isNotNull);

      final good = _runner();
      _feed(good, jjRepFrames(startTimestampMs: 0));
      expect(_statOf(good.finishSet(), 'JJ_INSUFFICIENT_ARM'), isNull);
    });

    test('手臂只举了一侧时算不足 —— 取的是两只里较小的那个', () {
      // 一侧举到顶、另一侧垂着：如果指标取的是 max（或"哪侧看得清就用哪侧"），
      // 这一跳会被判合格，而用户明明只举了一只手。
      final runner = _runner();
      _feed(
        runner,
        jjFromSegments([
          jjClosed,
          const JjSegment(
            spread: jjJumpSpread,
            armDeg: jjArmUpDeg,
            rightArmDeg: jjArmDownDeg,
          ),
          const JjSegment(spread: jjStandSpread),
        ]),
      );

      expect(runner.repCount, 1);
      expect(_statOf(runner.finishSet(), 'JJ_INSUFFICIENT_ARM'), isNotNull);
    });

    test('落地膝内扣：只命中内扣的那一跳，而且方向不许写反', () {
      // 方向写成 `below` 时，规则会变成「腿越直越算内扣」：
      // 上面那条「合规」用例会红，而它在真机上只表现为「这条判定老是误报」。
      final valgus = _runner();
      _feed(valgus, jjRepFrames(startTimestampMs: 0, kneeInward: 0.02));
      expect(valgus.repCount, 1);
      expect(_statOf(valgus.finishSet(), 'JJ_KNEE_VALGUS'), isNotNull);

      final straight = _runner();
      _feed(straight, jjRepFrames(startTimestampMs: 0));
      expect(
        _statOf(straight.finishSet(), 'JJ_KNEE_VALGUS'),
        isNull,
        reason: '直腿落地不该被判膝内扣',
      );
    });

    test('内扣只出现在张开段时不命中 —— 这条规则判的是触地那一刻', () {
      // 与上一条成对存在。少了它，把相位从 `contact` 改成 `all` 也不会被发现，
      // 而那样这条规则会因为「最高点那一下膝有点歪」就报错。
      final runner = _runner();
      _feed(
        runner,
        jjFromSegments([
          jjClosed,
          const JjSegment(
            spread: jjJumpSpread,
            armDeg: jjArmUpDeg,
            kneeInward: 0.02,
          ),
          const JjSegment(spread: jjStandSpread, kneeInward: 0.0),
        ]),
      );

      expect(runner.repCount, 1);
      expect(_statOf(runner.finishSet(), 'JJ_KNEE_VALGUS'), isNull);
    });

    test('三条规则都用绝对阈值 —— 没有一条挂在分腿基线上', () {
      // 给 `jj.spread_min_ratio` 挂 `BaselineOffset(legSpread, k)` 是一个
      // 看起来很合理的"个体化"，而它会让这条规则**永远不触发**：
      // 并腿站立时分腿比接近 0，于是阈值也接近 0，而峰值恒大于 0。
      // 这条断言把「阈值原样来自表」变成可执行的。
      final definition = buildJj(_standingCalibration, config: _config());
      expect(
        definition.thresholdOffsets,
        isEmpty,
        reason: '三条判定的阈值都是绝对的，一个偏移都不该有',
      );
    });
  });

  group('阈值表的三个键', () {
    test('规则引用的键与内联表对得上', () {
      final definition = buildJj(_standingCalibration, config: _config());
      final table = _localTable();
      for (final rule in definition.rules) {
        expect(
          table.get(rule.thresholdKey).value,
          isPositive,
          reason: '${rule.code} 的阈值取到了 0 或负数',
        );
      }
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表：键名与资产表一致、数值不必一致 —— 于是「资产表里
    // 少了一行」这件事它们一个都发现不了。而漏行的后果很重：`FaultPresenter` 与
    // `FormScorer` 都在**构造期**把键全部解析一遍、缺失即抛，构造点又恰好在
    // `_buildRunner` 里 —— 也就是用户做完一组、标定刚结束的那一刻。一组白做。
    late ThresholdTable table;

    setUpAll(() {
      final file = File('assets/thresholds/thr_2026-10_v1.json');
      if (!file.existsSync()) {
        fail(
          '找不到阈值表：${file.absolute.path}\n'
          '它由 scripts/sync_assets.py 从 shared/thresholds/ 同步而来，'
          '请先运行该脚本。',
        );
      }
      table = ThresholdTable.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    });

    test('开合跳引用的每一个阈值键都真实存在', () {
      for (final rule in buildJj(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildJj(_standingCalibration);
      expect(
        () => FaultPresenter(definition: definition, thresholds: table),
        returnsNormally,
        reason: '阈值键缺一个就会在这里抛 —— 而线上那是在一组做完之后',
      );
      expect(
        () => FormScorer(definition: definition, thresholds: table),
        returnsNormally,
      );
    });

    test('三条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`jj.fault_weight.jj_knee_valgus`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildJj(_standingCalibration);
      final scorer = FormScorer(definition: definition, thresholds: table);
      final keyByCode = {for (final r in definition.rules) r.code: r.thresholdKey};

      final score = scorer.scoreRep([
        for (final rule in definition.rules)
          Fault(
            code: rule.code,
            nameZh: rule.nameZh,
            scorable: table.get(rule.thresholdKey).mayDriveScoring,
            confidence: 1.0,
            evidenceTimestamps: const [],
            deviation: Deviation(
              feature: 'x',
              measured: 1.0,
              threshold: 0.0,
              deltaSigned: 1.0,
              severity01: 0.5,
            ),
          ),
      ]);

      expect(score.terms, hasLength(definition.rules.length));
      for (final term in score.terms) {
        expect(
          term.weight,
          allOf(greaterThan(0), predicate<double>((w) => w.isFinite, '有限')),
          reason: '${term.code} 的权重取自 ${keyByCode[term.code]}',
        );
      }
      expect(scorer.weightSum, greaterThan(0));
    });

    test('评级切点正好 4 个且严格升序，构造期就数过', () {
      final breakpoints =
          table.get('jj.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildJj(_standingCalibration);
      final scorer = FormScorer(definition: definition, thresholds: table);
      expect(
        scorer.weightsVerified,
        isFalse,
        reason: '权重已核定的话，下面那条断言就该改成「随核定状态」',
      );

      final runner = ActionRunner(
        definition,
        thresholds: table,
        calibration: _standingCalibration,
      );
      _feed(runner, jjRepFrames(startTimestampMs: 0));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
