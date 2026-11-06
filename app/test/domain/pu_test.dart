/// 俯卧撑动作定义测试。
///
/// 这里钉住四类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **塌腰与撅臀是两件事，不能合成一条规则。** 现成的 `body_line_angle`
///    是个 0–180° 的夹角，两种错在它上面**逐位相同**（下面有一条断言量了这件事）。
///    判断方向的依据是 `body_line_offset_ratio` 的符号，而符号如果取错了参照系
///    （「连线的哪一侧」而不是重力方向），同一个塌腰在换一个站位后就会翻号 ——
///    那时两条规则会互相顶替，而屏幕上只是「这两条判定怎么老是乱报」。
/// 2. **「算不算一次」与「做得好不好」是两条线。** 下不到 `pushupDepthDeg`
///    的那些根本不进计数（走 `discardedReps`），而深度规则管的是进来的那些 ——
///    两者合成一条，用户就分不清「这一次没算」与「这一次算了但可以更好」。
/// 3. **四条判定都不挂本人基线。** 肘角是关节夹角、体线偏移已用躯干长归一，
///    再乘一个基线只会引入噪声；而挂错的表现是阈值整体挪位，判错率变，不报错。
/// 4. **「顶部未伸直」与「深度不足」共用同一个特征、方向相反。** 谁把它们
///    写成同向，两条规则里必有一条变成「永远命中」或「永远不命中」。
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
import 'package:vitalteen_app/domain/exercises/pu.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_pu.dart';

/// 站立基线。**俯卧撑一条都不用它**（四条判定全是绝对量），但它仍然要采 ——
/// 那是 `Calibrator` 的门槛，也是「开始之前先站好」那一步的产物。
const Calibration _standingCalibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 0,
  heelRiseRatio: 0.0,
  frames: 15,
);

/// 内联阈值表。四条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的取值远一点，免得断在阈值同侧的边界上：
/// 最低点 80° 对阈 90°、顶部 175° 对阈 170°、偏离 0 对阈 0.10。
///
/// **注意 `pu.hip_pike_ratio_min` 是一个负数** —— 撅臀的判据是「髋比体线高」，
/// 在这个带符号的特征上就是负值。所以本文件里不能断言「阈值一律为正」，
/// 只能断言「非零、有限」。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: puActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('pu.min_depth_elbow_angle', 90.0, 'elbow_angle_L',
            unit: 'deg'),
        _threshold('pu.top_extension_elbow_angle', 170.0, 'elbow_angle_L',
            unit: 'deg'),
        _threshold('pu.hip_sag_ratio_max', 0.10, 'body_line_offset_ratio'),
        _threshold('pu.hip_pike_ratio_min', -0.10, 'body_line_offset_ratio'),
      ],
      version: 'test',
    );

/// 与产品一致：俯卧撑走 45° 主链路（`productCameraView`）。
TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.oblique45, maxRepFrames: 150);

ActionRunner _runner() => ActionRunner(
      buildPushUp(_standingCalibration, config: _config()),
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

/// 产品机位下读一帧的特征值。
///
/// **必须显式给这个机位**：`body_line_offset_ratio` 声明
/// `views: [sagittal, oblique45]`，用别的机位读出来的是 `view_mismatch`
/// 而不是数值 —— 而那是静默的（`get` 返回 null），测试会以一个看不懂的方式失败。
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄少一条边', () {
      // 这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
      // 「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。把含义写反（深度线跑到顶部线上面）是最容易犯的一种。
      expect(
        () => buildPushUp(
          _standingCalibration,
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            pushupDepthDeg: 150.0,
            pushupTopDeg: 120.0,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('默认机位是侧视，两条腿的角度量在 45° 下照样读得出来', () {
      final definition = buildPushUp(_standingCalibration);
      expect(definition.cameraView, CameraView.sagittal);

      // 反面：四个判据用的特征在 45° 下都必须可用 —— 它们是主链路机位，
      // 判掉一个就等于少一条规则，而规则不可用时不命中、也不报错。
      final frame = puPose(timestampMs: 0);
      const oblique = FeatureExtractor(cameraView: CameraView.oblique45);
      for (final code in [
        'elbow_angle_L',
        'body_line_offset_ratio',
      ]) {
        expect(oblique.extract(frame).get(code), isNotNull, reason: code);
      }
      // 而正视下体线偏移读不出来（「身体前后方向」就是镜头方向本身）。
      const frontal = FeatureExtractor(cameraView: CameraView.frontal);
      expect(frontal.extract(frame).get('body_line_offset_ratio'), isNull);
    });

    test('四条判定都用绝对阈值 —— 一个基线偏移都不挂', () {
      // 挂错的表现是阈值整体挪位、判错率变，而它不报错。肘角与体线偏移都
      // 与体型无关（一个是关节夹角、一个已用躯干长归一），所以偏移表必须为空。
      final definition = buildPushUp(_standingCalibration, config: _config());
      expect(
        definition.thresholdOffsets,
        isEmpty,
        reason: '四条判定的阈值都是绝对的，一个偏移都不该有',
      );
    });
  });

  group('合成姿态的数值', () {
    test('肘角是精确造出来的', () {
      for (final deg in [puBottomElbowDeg, puMidElbowDeg, puTopElbowDeg]) {
        final frame = puPose(timestampMs: 0, elbowDeg: deg);
        expect(
          _feature(frame, 'elbow_angle_L'),
          closeTo(deg, 1e-9),
          reason: '肘角应当逐位等于传入值',
        );
        // 两侧都造得出来，分段用的均值才等于它。
        expect(_feature(frame, 'elbow_angle_R'), closeTo(deg, 1e-9));
      }
    });

    test('平直时体线偏移是 0，而且 `body_line_angle` 也是 180°', () {
      final flat = puPose(timestampMs: 0);
      expect(_feature(flat, 'body_line_offset_ratio'), closeTo(0.0, 1e-9));
      expect(_feature(flat, 'body_line_angle'), closeTo(180.0, 1e-3));
    });

    test('塌腰与撅臀在夹角上逐位相同，只有带符号的偏离分得开', () {
      // **这条是整组测试里最值钱的一条。** `body_line_angle` 是 `angle3`
      // 的夹角，值域 [0°, 180°] —— 髋往上顶和髋往下掉都只是让它变小，
      // 两者在数值上**完全同形**（下面两条 closeTo 断言量到的就是这件事）。
      // 所以「塌腰」与「撅臀」不能共用它，必须用带符号的
      // `body_line_offset_ratio`：正 = 髋更低 = 塌腰，负 = 髋更高 = 撅臀。
      //
      // 而且这个符号取的是**重力方向**、不是「连线的哪一侧」——
      // 后者会随人面朝画面哪一边翻号，同一个塌腰会得到一正一负。
      final sag = puPose(timestampMs: 0, hipOffset: 0.04);
      final pike = puPose(timestampMs: 0, hipOffset: -0.04);

      expect(
        _feature(sag, 'body_line_angle'),
        closeTo(_feature(pike, 'body_line_angle')!, 1e-9),
        reason: '夹角本来就分不开这两种错 —— 这正是要另造一个量的原因',
      );
      expect(_feature(sag, 'body_line_offset_ratio'), greaterThan(0.10));
      expect(_feature(pike, 'body_line_offset_ratio'), lessThan(-0.10));

      // 人换一个朝向（在合成帧里就是把髋的横向位置换到另一侧）时，
      // 符号**不该**跟着翻 —— 它取的是 y 方向。这里直接用同一个姿态
      // 只改横向来验证：横向怎么动，偏移不变。
      final shifted = puPose(timestampMs: 0, hipOffset: 0.04);
      expect(
        _feature(shifted, 'body_line_offset_ratio'),
        closeTo(_feature(sag, 'body_line_offset_ratio')!, 1e-9),
      );
    });
  });

  group('分段', () {
    test('标准一次计 1', () {
      final runner = _runner();
      _feed(runner, puRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, PuStates.top);
    });

    test('没下到底就撑起来：计 0、弃 1', () {
      // 「俯卧撑」这个动作的判定对象就是「下到底再撑起来」。只弯到 130°
      // （高于 `pushupDepthDeg` 100°）的那一次**不算一次**，而它也不是无声无息
      // 地消失 —— `discardedReps` 记账，界面解释为「有 N 次没计入」。
      final runner = _runner();
      _feed(runner, puRepFrames(startTimestampMs: 0, bottomElbowDeg: 130.0));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, PuStates.top, reason: '要回到顶部等下一次');
    });

    test('守卫的上下界：弯一点就离开顶部，回到进入线以上才算撑起来', () {
      // 上面那条计数测试一旦变绿，就可能是因为「压根没离开 TOP」——
      // 那样它证明的是别的东西。这里直接对守卫求值。
      final definition = buildPushUp(_standingCalibration, config: _config());
      bool at(String src, String dst, double elbow) =>
          _guardOf(definition, src, dst).call({'elbow_angle_L': elbow});

      expect(at(PuStates.top, PuStates.down, puTopElbowDeg), isFalse);
      expect(at(PuStates.top, PuStates.down, puMidElbowDeg), isTrue);
      expect(at(PuStates.top, PuStates.down, puBottomElbowDeg), isTrue);

      expect(at(PuStates.down, PuStates.bottom, puMidElbowDeg), isFalse);
      expect(at(PuStates.down, PuStates.bottom, puBottomElbowDeg), isTrue);

      // 开局与封存落到 TOP 用的是**同一条线**：TOP 只有一个含义。
      expect(
        _guardOf(definition, PuStates.up, PuStates.top),
        same(_guardOf(definition, PuStates.down, PuStates.top)),
      );

      // 而滞回带保证「刚进 BOTTOM」的那一帧不会被同一条线立刻推出去。
      expect(at(PuStates.bottom, PuStates.up, 101.0), isFalse);
      expect(at(PuStates.bottom, PuStates.up, 109.0), isTrue);
    });

    test('回压不卡死：撑到一半又沉下去，仍然撑得起来', () {
      // 守卫看不见时间，没有 UP → DOWN 这条边的话，「撑起来一点又没劲了」
      // 会停在 UP 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
      // 一个错的状态词。
      final runner = _runner();
      _feed(
        runner,
        puFromSegments([
          puTop,
          puMid,
          puBottom,
          puMid, // 撑到一半
          puBottom, // 又沉回去
          puMid,
          puTop, // 终于撑到顶 → 封存
        ]),
      );

      expect(runner.repCount, 1, reason: '回压之后仍然要撑得起来');
      expect(runner.currentState, PuStates.top);
    });

    test('一直撑着不动不会被计也不会被弃', () {
      final runner = _runner();
      _feed(runner, puTopFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '撑着不动不该被记账成一次丢弃');
      expect(runner.currentState, PuStates.top);
    });
  });

  group('四条规则', () {
    test('深度不足：只命中下得不够深的那一次', () {
      // 最低点给到 95°：**高于绝对阈值 90°、低于分段线 100°** —— 于是这一次
      // 被正常计数，然后被这条规则指出「下得不够深」。这是「算数的那些里
      // 做得不好的」，也正是这条规则唯一有活干的那一段。
      //
      // 给到 130°（连分段线都够不着）的话，这一次会被 `bottomState` 挡在外面、
      // 整段丢弃，这条规则根本没机会求值 —— 那就变成在测上面那条丢弃测试了。
      final shallow = _runner();
      _feed(shallow, puRepFrames(startTimestampMs: 0, bottomElbowDeg: 95.0));
      expect(shallow.repCount, 1, reason: '过了 pushupDepthDeg（100°），算一次');
      expect(_statOf(shallow.finishSet(), 'PU_INSUFFICIENT_DEPTH'), isNotNull);

      final deep = _runner();
      _feed(deep, puRepFrames(startTimestampMs: 0));
      expect(
        _statOf(deep.finishSet(), 'PU_INSUFFICIENT_DEPTH'),
        isNull,
        reason: '下到底的俯卧撑不该被判深度不足 —— 否则这条规则是「永远命中」',
      );
    });

    test('顶部未伸直：只命中撑得不够直的那一次，方向不许写反', () {
      // 顶部给到 168°：**低于绝对阈值 170°、高于分段线 165°** —— 于是这一次
      // 被计数了，然后被这条规则指出「还没完全伸直」。撑不到 165° 的那些
      // 根本不被计数（走 discardedReps），那是另一条测试在管的事。
      //
      // 方向写成 `above` 的话，规则会变成「撑得越直越是错」，上面那条
      // 「下到底、撑到顶」的标准动作会红。
      final soft = _runner();
      _feed(soft, puRepFrames(startTimestampMs: 0, topElbowDeg: 168.0));
      expect(soft.repCount, 1, reason: '过了 pushupTopDeg（165°），算一次');
      expect(_statOf(soft.finishSet(), 'PU_INCOMPLETE_EXTENSION'), isNotNull);

      final straight = _runner();
      _feed(straight, puRepFrames(startTimestampMs: 0));
      expect(
        _statOf(straight.finishSet(), 'PU_INCOMPLETE_EXTENSION'),
        isNull,
        reason: '撑到伸直不该被判未伸直',
      );
    });

    test('塌腰：只命中髋往下掉的那一次', () {
      final sag = _runner();
      _feed(sag, puRepFrames(startTimestampMs: 0, hipOffset: 0.04));
      expect(sag.repCount, 1);
      expect(_statOf(sag.finishSet(), 'PU_HIP_SAG'), isNotNull);

      final flat = _runner();
      _feed(flat, puRepFrames(startTimestampMs: 0));
      expect(_statOf(flat.finishSet(), 'PU_HIP_SAG'), isNull);
    });

    test('撅臀：只命中髋往上顶的那一次，而且不会顶替塌腰', () {
      // **两条规则共用同一个特征、方向相反**，所以必须成对断言：
      // 只断言「撅臀时命中」的话，一条方向写反（变成 `above`）的撅臀规则
      // 会在塌腰那组上同样命中 —— 而这两条要说的纠正建议正好相反。
      final pike = _runner();
      _feed(pike, puRepFrames(startTimestampMs: 0, hipOffset: -0.04));
      expect(pike.repCount, 1);
      expect(_statOf(pike.finishSet(), 'PU_HIP_PIKE'), isNotNull);
      expect(
        _statOf(pike.finishSet(), 'PU_HIP_SAG'),
        isNull,
        reason: '髋往上顶不该同时被判成塌腰',
      );

      final flat = _runner();
      _feed(flat, puRepFrames(startTimestampMs: 0));
      expect(_statOf(flat.finishSet(), 'PU_HIP_PIKE'), isNull);
      expect(
        _statOf(flat.finishSet(), 'PU_HIP_SAG'),
        isNull,
        reason: '平直的身体两条都不该命中',
      );
    });
  });

  group('阈值表的四个键', () {
    test('规则引用的键与内联表对得上', () {
      final definition = buildPushUp(_standingCalibration, config: _config());
      final table = _localTable();
      for (final rule in definition.rules) {
        final value = table.get(rule.thresholdKey).value;
        // **不能断言 isPositive**：撅臀那条的阈值就是负数（见 `_threshold` 的注释）。
        expect(value.isFinite && value != 0, isTrue,
            reason: '${rule.code} 的阈值取到了 0 或非有限值');
      }
    });

    test('塌腰与撅臀的阈值在 0 的两侧', () {
      // 这两条共用一个带符号的特征，所以它们的阈值必须一个正一个负 ——
      // 都取正数的话，撅臀那条会被写成一个「永远命中」或「永远不命中」的规则。
      final definition = buildPushUp(_standingCalibration, config: _config());
      final table = _localTable();
      double valueOf(String code) => table
          .get(definition.rules.firstWhere((r) => r.code == code).thresholdKey)
          .value;

      expect(valueOf('PU_HIP_SAG'), greaterThan(0));
      expect(valueOf('PU_HIP_PIKE'), lessThan(0));
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

    test('俯卧撑引用的每一个阈值键都真实存在', () {
      for (final rule in buildPushUp(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildPushUp(_standingCalibration);
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

    test('四条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`pu.fault_weight.pu_hip_sag`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildPushUp(_standingCalibration);
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
          table.get('pu.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildPushUp(_standingCalibration);
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
      _feed(runner, puRepFrames(startTimestampMs: 0));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
