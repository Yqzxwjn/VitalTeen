/// 仰卧起坐动作定义测试。
///
/// 这里钉住五类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **计数点只能落在 `SEATED` 上。** 落回 `LYING` 的话，「这一次的肩到底贴到
///    垫上没有」这个证据正好落在 rep 缓冲的边界上（缓冲从离开 restingState 开始
///    封存），而且**偏向起得快的人**。下面那条「肩只降到 0.21 就起来」的用例
///    量到的就是这件事 —— 它与「老老实实贴到垫上」在缓冲里给出的读数必须分得开。
/// 2. **坐起线不能取到 1.0。** 那是「躯干严格竖直」的奇点，取它一次标准的
///    仰卧起坐永远不会被计数、且不报任何错；更坏的是臀一离垫比值反倒能越过 1，
///    于是线**奖励正要被罚的那个错**（见 `situp.dart` 文件头）。
/// 3. **「算不算一次」与「做得好不好」是两条线。** 肩没贴到垫上的那些次**照样算
///    一次**（`SU_SHOULDER_NOT_GROUND` 指出来），而躺到一半又坐起来的那些次
///    根本不算（走 `discardedReps`）。合成一条线的话，用户就分不清
///    「这一次没算」与「这一次算了但可以更好」。
/// 4. **三条判定一个基线都不挂。** 肩高比与体线偏移已用躯干长归一、膝角是关节
///    夹角，再乘一个基线只会引入噪声；挂错的表现是阈值整体挪位、判错率变，不报错。
/// 5. **`SU_HIP_LIFT` 取的是整段的 min、方向朝下；`SU_SHOULDER_NOT_GROUND`
///    取的是 `BOTTOM` 段的 min、方向朝上。** 两者共用一个「取最小值」的归约，
///    方向或相位写错的表现是同一件事：这条判定时不时冒出来，看不出病因。
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
import 'package:vitalteen_app/domain/exercises/situp.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_su.dart';

/// 站立基线。**仰卧起坐一条都不用它**（三条判定全是绝对量），但它仍然要采 ——
/// 那是 `Calibrator` 的门槛，也是「开始之前先站好」那一步的产物。
const Calibration _standingCalibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 0,
  heelRiseRatio: 0.0,
  frames: 15,
);

/// 内联阈值表。三条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的读数远一点，免得断在阈值同侧的边界上：
/// 躺平 0.05 对阈 0.10、顶髋 −0.22 对阈 −0.10、屈膝 90° 对阈 120°。
///
/// **注意 `su.hip_lift_ratio_min` 是一个负数** —— 顶髋的判据是「髋比体线高」，
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
      actionCode: situpActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('su.shoulder_to_mat_ratio_max', 0.10,
            'shoulder_height_ratio'),
        _threshold('su.hip_lift_ratio_min', -0.10, 'body_line_offset_ratio'),
        _threshold('su.knee_angle_max', 120.0, 'knee_angle_L', unit: 'deg'),
      ],
      version: 'test',
    );

/// 与产品一致：仰卧起坐走 45° 主链路。
TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.oblique45, maxRepFrames: 600);

ActionRunner _runner() => ActionRunner(
      buildSitUp(_standingCalibration, config: _config()),
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
/// **必须显式给这个机位**：`shoulder_height_ratio` 与 `body_line_offset_ratio`
/// 都声明 `views: [sagittal, oblique45]`，用别的机位读出来的是 `view_mismatch`
/// 而不是数值 —— 而那是静默的（`get` 返回 null），测试会以一个看不懂的方式失败。
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄多一条边', () {
      // 这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
      // 「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。把守平线抬到坐起线上面是最容易犯的一种。
      expect(
        () => buildSitUp(
          _standingCalibration,
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            situpLieRatio: 0.60,
            situpSeatRatio: 0.55,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('坐起线取不到 1.0 —— 那是「躯干严格竖直」的奇点', () {
      // **这条是全文件里最值钱的一条断言。** 臀贴在垫上时肩绕髋转，
      // `shoulder_height_ratio` = 躯干与竖直方向夹角的余弦，于是 1.0 只在
      // 角度恰好为 0 时取到。国标的收势是前倾（肘触膝，约 26°），读数 0.9 ——
      // 取 1.0 的话标准动作**一次都不会被计数**，而且屏幕上没有任何提示。
      final config = _config();
      expect(
        config.situpSeatRatio,
        lessThan(1.0),
        reason: '取到 1.0（或更大）会让标准动作永远坐不起来',
      );
      // 而且要留得下「前倾 26°」这个国标收势：cos(26°) ≈ 0.899。
      expect(
        config.situpSeatRatio,
        lessThan(suShoulderRatio(torsoDeg: suSeatedDeg)),
        reason: '坐起线必须低于国标收势的读数，否则那一次不算数',
      );
    });

    test('默认机位是 45°，两个量在正视下都读不出来', () {
      final definition = buildSitUp(_standingCalibration);
      expect(definition.cameraView, CameraView.oblique45);

      // 正面：四个判据用的特征在 45° 下都必须可用 —— 判掉一个就等于少一条规则，
      // 而规则不可用时不命中、也不报错。
      final frame = suPose(timestampMs: 0);
      const oblique = FeatureExtractor(cameraView: CameraView.oblique45);
      for (final code in ['shoulder_height_ratio', 'body_line_offset_ratio']) {
        expect(oblique.extract(frame).get(code), isNotNull, reason: code);
      }
      // 而正视下两个 y 方向的差都读不出来（「身体的长边」就是镜头方向本身）。
      const frontal = FeatureExtractor(cameraView: CameraView.frontal);
      for (final code in ['shoulder_height_ratio', 'body_line_offset_ratio']) {
        expect(frontal.extract(frame).get(code), isNull, reason: code);
      }
    });

    test('三条判定都用绝对阈值 —— 一个基线偏移都不挂', () {
      // 挂错的表现是阈值整体挪位、判错率变，而它不报错。肩高比与体线偏移都
      // 已用躯干长归一、膝角是关节夹角，三者都与体型无关，所以偏移表必须为空。
      final definition = buildSitUp(_standingCalibration, config: _config());
      expect(
        definition.thresholdOffsets,
        isEmpty,
        reason: '三条判定的阈值都是绝对的，一个偏移都不该有',
      );
    });
  });

  group('合成姿态的数值', () {
    test('肩高比逐位等于闭式解', () {
      // 三个姿态各验一次：躺平（≈0）、途中（≈0.5）、坐起（≈0.9）。
      // 这条同时是合成帧几何的自检 —— 它错了，下面所有分段与规则的用例
      // 都是在测一个别的动作。
      for (final deg in [suLyingDeg, suMidDeg, suSeatedDeg]) {
        final frame = suPose(timestampMs: 0, torsoDeg: deg);
        expect(
          _feature(frame, 'shoulder_height_ratio'),
          closeTo(suShoulderRatio(torsoDeg: deg), 1e-9),
          reason: '躯干角 $deg° 的肩高比应当逐位等于闭式解',
        );
      }
      expect(suShoulderRatio(torsoDeg: suLyingDeg), lessThan(0.10));
      expect(suShoulderRatio(torsoDeg: suSeatedDeg), greaterThan(0.85));
    });

    test('平躺时体线偏移是 0，顶髋把它压成负值', () {
      // **顶髋的判据就是一个负号。** 平躺时肩、髋、踝三点几乎共线，
      // 偏移 ≈ 0；把髋单独顶起来（肩不动），髋就跑到肩-踝连线的上方，读数为负。
      // 与俯卧撑的 `PU_HIP_PIKE` 是同一个量、同一个方向。
      // 平躺时不是严格 0：合成帧的躯干留了 3° 余量（[suLyingDeg]），肩于是比踝
      // 略高，肩-踝连线是斜的。0.02 上下就是这个斜度带来的。
      final flat = suPose(timestampMs: 0, torsoDeg: suLyingDeg);
      expect(_feature(flat, 'body_line_offset_ratio'), closeTo(0.0, 0.05));

      final lifted = suPose(timestampMs: 0, torsoDeg: suLyingDeg, hipLift: 0.05);
      expect(_feature(lifted, 'body_line_offset_ratio'), lessThan(-0.10));
    });

    test('坐起的过程中体线偏移是正的 —— 所以这条规则只能取 min', () {
      // 这条不是「顺便一测」，它钉住的是 `SU_HIP_LIFT` 的归约方式：
      // 起身时髋本来就会落到连线下方（正值），只有取整段的**最小值**
      // 才问得到「有没有把臀顶起来」。改成 `ANY_FRAME` 的话前半段全是越界帧，
      // 每一次仰卧起坐都会被判顶髋。
      final seated = suPose(timestampMs: 0, torsoDeg: suSeatedDeg);
      expect(_feature(seated, 'body_line_offset_ratio'), greaterThan(0.10));
    });

    test('屈膝角是精确造出来的', () {
      for (final deg in [90.0, 120.0, 170.0]) {
        final frame = suPose(timestampMs: 0, kneeDeg: deg);
        expect(
          _feature(frame, 'knee_angle_L'),
          closeTo(deg, 1e-9),
          reason: '屈膝角应当逐位等于传入值',
        );
        // 两侧都造得出来，规则取的那一侧才等于它。
        expect(_feature(frame, 'knee_angle_R'), closeTo(deg, 1e-9));
      }
    });
  });

  group('分段', () {
    test('标准一次计 1', () {
      final runner = _runner();
      _feed(runner, suRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, SitupStates.seated);
    });

    test('躺到一半又坐起来：计 0、弃 1', () {
      // 没躺回垫上的那一次**不算一次**。它也不是无声无息地消失 ——
      // `discardedReps` 记账，界面解释为「有 N 次没计入」。
      //
      // 反面即第 1 条结论：如果计数点落在 LYING 上，这一次会被计成 1 ——
      // 而它连垫子都没碰到。
      final runner = _runner();
      _feed(
        runner,
        suFromSegments([
          suSeated,
          suMid,
          const SuSegment(torsoDeg: suMidDeg), // 又坐回去，全程没到躺平线
          suSeated,
        ]),
      );

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, SitupStates.seated, reason: '要回到坐姿等下一次');
    });

    test('守卫的上下界：躺平线两侧都有滞回带', () {
      // 上面那条计数测试一旦变绿，就可能是因为「压根没离开 SEATED」——
      // 那样它证明的是别的东西。这里直接对守卫求值。
      final definition = buildSitUp(_standingCalibration, config: _config());
      bool at(String src, String dst, double ratio) =>
          _guardOf(definition, src, dst).call({'shoulder_height_ratio': ratio});

      final config = _config();
      final lie = config.situpLieRatio; // 0.25
      final seat = config.situpSeatRatio; // 0.75
      final hyst = config.situpHysteresis; // 0.06

      expect(at(SitupStates.seated, SitupStates.lowering, seat), isFalse);
      expect(at(SitupStates.seated, SitupStates.lowering, seat - hyst - 0.01),
          isTrue);
      expect(at(SitupStates.seated, SitupStates.lowering, lie), isTrue);

      expect(at(SitupStates.lowering, SitupStates.lying, lie + 0.01), isFalse);
      expect(at(SitupStates.lowering, SitupStates.lying, lie), isTrue);

      expect(at(SitupStates.lowering, SitupStates.seated, seat - 0.01), isFalse);
      expect(at(SitupStates.lowering, SitupStates.seated, seat), isTrue);

      expect(at(SitupStates.lying, SitupStates.rising, lie + hyst), isFalse);
      expect(
          at(SitupStates.lying, SitupStates.rising, lie + hyst + 0.01), isTrue);

      expect(at(SitupStates.rising, SitupStates.lying, lie), isFalse);
      expect(at(SitupStates.rising, SitupStates.lying, lie - 0.01), isTrue);

      // 开局与封存落到 SEATED 用的是**同一条线**：SEATED 只有一个含义。
      expect(
        _guardOf(definition, SitupStates.rising, SitupStates.seated),
        same(_guardOf(definition, SitupStates.lowering, SitupStates.seated)),
      );

      // 而「取不到这个量」时一条守卫都不成立 —— 不能拿 0 顶替（0 正是「躺着」，
      // 用它会凭空造出一次「已经躺平了」的结论）。
      for (final (src, dst) in [
        (SitupStates.seated, SitupStates.lowering),
        (SitupStates.lowering, SitupStates.lying),
        (SitupStates.lowering, SitupStates.seated),
        (SitupStates.lying, SitupStates.rising),
        (SitupStates.rising, SitupStates.seated),
        (SitupStates.rising, SitupStates.lying),
      ]) {
        expect(
          _guardOf(definition, src, dst).call(const {}),
          isFalse,
          reason: '$src→$dst 在指标缺失时不该成立',
        );
      }
    });

    test('回退不卡死：起到一半又躺回去，仍然坐得起来', () {
      // 守卫看不见时间，没有 RISING → LYING 这条边的话，「起到一半又没劲了」
      // 会停在 RISING 直到帧上限 —— 既不计数也不丢弃，只是每一帧都显示着
      // 一个错的状态词。
      final runner = _runner();
      _feed(
        runner,
        suFromSegments([
          suSeated,
          suMid,
          suLying,
          suMid, // 起到一半
          suLying, // 又躺回去
          suMid,
          suSeated, // 终于坐起来 → 封存
        ]),
      );

      expect(runner.repCount, 1, reason: '躺回去之后仍然要坐得起来');
      expect(runner.currentState, SitupStates.seated);
    });

    test('一直坐着不动不会被计也不会被弃', () {
      final runner = _runner();
      _feed(runner, suSeatedFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '坐着不动不该被记账成一次丢弃');
      expect(runner.currentState, SitupStates.seated);
    });
  });

  group('三条规则', () {
    test('肩胛未触垫：只命中肩没降到垫上的那一次', () {
      // 躺下时躯干角给到 −78°（比值 ≈ 0.208）：**低于躺平线 0.25、高于绝对阈值
      // 0.10** —— 于是这一次被正常计数，然后被这条规则指出「肩没贴到垫上」。
      // 这是「算数的那些里做得不好的」，也正是这条规则唯一有活干的那一段。
      //
      // 给到 −60°（比值 0.5，够不着躺平线）的话这一次会被 `bottomState` 挡在
      // 外面、整段丢弃，这条规则根本没机会求值 —— 那就变成在测上面那条丢弃测试。
      final shallow = _runner();
      _feed(shallow, suRepFrames(startTimestampMs: 0, lieTorsoDeg: -78.0));
      expect(shallow.repCount, 1, reason: '过了躺平线 0.25，算一次');
      expect(_statOf(shallow.finishSet(), 'SU_SHOULDER_NOT_GROUND'), isNotNull);

      final grounded = _runner();
      _feed(grounded, suRepFrames(startTimestampMs: 0));
      expect(
        _statOf(grounded.finishSet(), 'SU_SHOULDER_NOT_GROUND'),
        isNull,
        reason: '贴到垫上的仰卧起坐不该被判未触垫 —— 否则这条规则是「永远命中」',
      );
    });

    test('臀离垫借力：只命中顶着髋做的那一次，而且不会顶替肩胛那条', () {
      // 两条规则共用「取窗口最小值」这个归约、方向相反（一条 above、一条 below），
      // 而且窗口不同（BOTTOM / ALL）。所以必须成对断言：只断言「顶髋时命中」的话，
      // 一条窗口写错（比如也写成 BOTTOM）的顶髋规则在平躺那组上同样会命中。
      final lifted = _runner();
      _feed(lifted, suRepFrames(startTimestampMs: 0, hipLift: 0.05));
      expect(lifted.repCount, 1, reason: '顶髋不该把这一次挤出计数');
      expect(_statOf(lifted.finishSet(), 'SU_HIP_LIFT'), isNotNull);
      expect(
        _statOf(lifted.finishSet(), 'SU_SHOULDER_NOT_GROUND'),
        isNull,
        reason: '顶髋借力不该同时被判成肩没贴垫',
      );

      final flat = _runner();
      _feed(flat, suRepFrames(startTimestampMs: 0));
      expect(_statOf(flat.finishSet(), 'SU_HIP_LIFT'), isNull);
      expect(_statOf(flat.finishSet(), 'SU_SHOULDER_NOT_GROUND'), isNull,
          reason: '平躺做的那一次两条都不该命中');
    });

    test('屈膝角度不符：只命中腿伸得太直的那一次，方向不许写反', () {
      // 国标要求屈膝约 90°，伸到 150° 是走形的常见做法。阈值取 120°：
      // 90° 合规、150° 命中。
      //
      // 方向写成 `below` 的话，规则会变成「腿越弯越是错」—— 而 `Reduce.max`
      // 配上 `below` 更糟：整段的最大值也小于阈值时才命中，一条永远命中的规则。
      final straight = _runner();
      _feed(straight, suRepFrames(startTimestampMs: 0, kneeDeg: 150.0));
      expect(straight.repCount, 1);
      expect(_statOf(straight.finishSet(), 'SU_KNEE_ANGLE'), isNotNull);

      final bent = _runner();
      _feed(bent, suRepFrames(startTimestampMs: 0));
      expect(
        _statOf(bent.finishSet(), 'SU_KNEE_ANGLE'),
        isNull,
        reason: '屈膝 90° 是国标要求的姿势，不该被判错',
      );
    });
  });

  group('阈值表的三个键', () {
    test('规则引用的键与内联表对得上', () {
      final definition = buildSitUp(_standingCalibration, config: _config());
      final table = _localTable();
      for (final rule in definition.rules) {
        final value = table.get(rule.thresholdKey).value;
        // **不能断言 isPositive**：顶髋那条的阈值就是负数（见 `_threshold` 的注释）。
        expect(value.isFinite && value != 0, isTrue,
            reason: '${rule.code} 的阈值取到了 0 或非有限值');
      }
    });

    test('顶髋的阈值是负数，肩胛与膝角的是正数', () {
      // 三条共用一个「取最小值」的归约，但只有顶髋那条问的是「够不够负」。
      // 都取正数的话，顶髋会被写成一个「永远命中」或「永远不命中」的规则。
      final definition = buildSitUp(_standingCalibration, config: _config());
      final table = _localTable();
      double valueOf(String code) => table
          .get(definition.rules.firstWhere((r) => r.code == code).thresholdKey)
          .value;

      expect(valueOf('SU_HIP_LIFT'), lessThan(0));
      expect(valueOf('SU_SHOULDER_NOT_GROUND'), greaterThan(0));
      expect(valueOf('SU_KNEE_ANGLE'), greaterThan(0));
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表：键名与资产表一致、数值不必一致 —— 于是「资产表里
    // 少了一行」这件事它们一个都发现不了。而漏行的后果很重：`FaultPresenter` 与
    // `FormScorer` 都在**构造期**把键全部解析一遍、缺失即抛，构造点又巧好在
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

    test('仰卧起坐引用的每一个阈值键都真实存在', () {
      for (final rule in buildSitUp(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildSitUp(_standingCalibration);
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
      // 真的取到了值 —— 键名双前缀（`su.fault_weight.su_hip_lift`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildSitUp(_standingCalibration);
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
          table.get('su.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildSitUp(_standingCalibration);
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
      _feed(runner, suRepFrames(startTimestampMs: 0));
      expect(runner.repCount, 1, reason: '真实分段线下这一组也要计得出来');
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
