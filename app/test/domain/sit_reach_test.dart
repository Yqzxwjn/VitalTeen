/// 坐位体前屈动作定义测试。
///
/// 这里钉住六类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **计数点只能落在 `SIT_UPRIGHT` 上。** 落到 `HOLDING` 上的话，
///    「这一次腿伸直了没有」这个证据正好落在 rep 缓冲的边界上（缓冲从离开
///    restingState 开始封存），而且**偏向折得快的人**。下面那条「伸到一半又坐直」
///    的用例量到的就是这件事 —— 它与「老老实实前伸到底」在缓冲里给出的读数
///    必须分得开。
/// 2. **两条规则的窗口不一样，而且必须不一样。** `SRT_KNEE_BENT` 取 `Phase.bottom`
///    （屈膝要在前伸到底那一刻才说明问题），`SRT_BALLISTIC` 取 `Phase.all`
///    （弹振发生在**前伸的过程中**，抖到位就停住的人保持段可以一点也不抖）。
///    窗口写反的表现是同一件事：这条判定时不时冒出来，看不出病因 ——
///    所以下面两条各自都有反例（前伸途中屈膝 / 平稳前伸）。
/// 3. **「算不算一次」与「做得好不好」是两条线。** 伸到一半的那些次根本不算
///    （走 `discardedReps`），而弹振、屈膝的那些次**照样算一次**（由对应规则
///    指出来）。合成一条线的话，用户就分不清「这一次没算」与「这一次算了但可以更好」。
/// 4. **两条判定一个基线都不挂。** 膝角与髋角都是关节夹角，与本人身材无关；
///    挂错的表现是阈值整体挪位、判错率变，不报错。
/// 5. **`hip_angle_L` 是「越小越前折」**，所以这一份的分段线比较方向与仰卧起坐
///    那一份**正好相反**（那边是越大越躺平）。照抄仰卧起坐的写法会让四条守卫
///    全部反向，而状态机仍然「跑得动」—— 只是计数变成了「折得越浅越算一次」。
/// 6. **标定与定义之间的接缝。** 上面每一条用的都是手写的 `_seatedCalibration`，
///    于是「45° 机位下这组基线根本采不满」这类错一条都发现不了 —— 而它的表现
///    同样是静默的：标定条卡在 0、屏幕上没有任何错误。最后那一组真喂一遍坐姿帧。
///
/// 阈值一律用**内联表**，数值只为本测试服务，不是体育判定依据 ——
/// 与真实资产的对照在「真实阈值表」那组里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/sit_reach.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_srt.dart';

/// 坐姿基线。**两条判定一条都不用它**（膝角与髋角都是绝对量），
/// 但它仍然要采 —— 那是 `Calibrator` 的门槛，也是「开始之前先坐好」那一步的产物。
const Calibration _seatedCalibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 0,
  heelRiseRatio: 0.0,
  frames: 15,
);

/// 内联阈值表。两条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的读数远一点，免得断在阈值同侧的边界上：
/// 伸直的膝 175° 对阈 150°、屈膝的 140° 对阈 150°；
/// 平稳前伸掉头 1 次对阈 3 次、弹振 5 次对阈 3 次。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: sitReachActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('srt.knee_angle_min', 150.0, 'knee_angle_L', unit: 'deg'),
        _threshold('srt.ballistic_reversals_max', 3.0, 'hip_angle_L',
            unit: 'count'),
      ],
      version: 'test',
    );

/// 与产品一致：坐位体前屈走 45° 主链路。
TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.oblique45, maxRepFrames: 600);

ActionRunner _runner() => ActionRunner(
      buildSitReach(_seatedCalibration, config: _config()),
      thresholds: _localTable(),
      calibration: _seatedCalibration,
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
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

/// 一帧帧读 `hip_angle_L`（缺失的帧跳过），用来把合成的序列直接喂给
/// 归约函数 —— 这样「弹振是几次」这件事不必靠规则命中与否反推。
List<double> _hipAnglesOf(List<FrameFeatures> frames) => [
      for (final frame in frames) ?frame.get('hip_angle_L'),
    ];

/// 同上，喂进去的是合成帧。两条取数路径都要有：前者验合成器的形状，
/// 后者验**封存下来的那个窗口**里的形状（相位标签只有那里才有）。
List<double> _hipAngles(List<PoseFrame> frames) =>
    _hipAnglesOf([for (final frame in frames) _productView.extract(frame)]);

/// 某个相位里 `knee_angle_L` 的最小值。**必须逐帧取、不能整段平均** ——
/// 规则用的是 `Reduce.min`，与它对齐才问得到同一件事。
double _kneeMin(RepWindow window, Phase phase) {
  final values = [
    for (final frame in window.select(phase)) ?frame.get('knee_angle_L'),
  ];
  expect(values, isNotEmpty, reason: '$phase 那一段里一帧膝角都没有');
  return values.reduce((a, b) => a < b ? a : b);
}

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄多一条边', () {
      // 这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
      // 「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。
      //
      // **要把保持线抬到坐直线上面**（这里是 90 对 75），这才是髋角这一侧的
      // 常见错法：照抄仰卧起坐那份写法的人，会下意识觉得「线越高越难」。
      expect(
        () => buildSitReach(
          _seatedCalibration,
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            sitReachUprightDeg: 75.0,
            sitReachHoldingDeg: 90.0,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('默认机位是 45°，两个量在正视下也算得出来 —— 所以正拍是静默失败', () {
      final definition = buildSitReach(_seatedCalibration);
      expect(definition.cameraView, CameraView.oblique45);

      // **与仰卧起坐那一份的同类断言正好相反，这是刻意的。**
      // 仰卧起坐的两个量带机位门控，正拍下是 `null`；而这里的两个量
      //（`hip_angle_L`、`knee_angle_L`）都没有门控，正拍下**照样有数**。
      //
      // 于是正对镜头时没有一处会报错：前折发生在镜头方向本身上面，
      // 肩朝镜头挪过去，画面里的髋角几乎不变 —— 状态机永远停在 `SIT_UPRIGHT`，
      // 一次都数不上，而 HUD 一直显示「坐直」（那正好是实情的一半）。
      // 所以 45° 那件事只能靠 `srtSpec.blockingAdvice` 用话讲清楚，
      // 特征层是拦不住的。
      final frame = srtPose(timestampMs: 0);
      for (final code in ['hip_angle_L', 'knee_angle_L']) {
        expect(_productView.extract(frame).get(code), isNotNull, reason: code);
        const frontal = FeatureExtractor(cameraView: CameraView.frontal);
        expect(frontal.extract(frame).get(code), isNotNull,
            reason: '$code 在正视下也应该「算得出来」—— 这正是它危险的地方');
      }
    });

    test('两条判定都用绝对阈值 —— 一个基线偏移都不挂', () {
      // 挂错的表现是阈值整体挪位、判错率变，而它不报错。膝角与髋角都是
      // 关节夹角，与体型无关，所以偏移表必须为空。
      final definition = buildSitReach(_seatedCalibration, config: _config());
      expect(
        definition.thresholdOffsets,
        isEmpty,
        reason: '两条判定的阈值都是绝对的，一个偏移都不该有',
      );
    });
  });

  group('合成姿态的数值', () {
    test('髋角逐位等于 90° 减去前折角', () {
      // 三个姿态各验一次：坐直（90）、途中（65）、前伸到底（40）。
      // 这条同时是合成帧几何的自检 —— 它错了，下面所有分段与规则的用例
      // 都是在测一个别的动作。
      for (final deg in [srtUprightDeg, srtMidDeg, srtReachDeg]) {
        final frame = srtPose(timestampMs: 0, torsoLeanDeg: deg);
        expect(
          _feature(frame, 'hip_angle_L'),
          closeTo(srtHipAngleDeg(torsoLeanDeg: deg), 1e-9),
          reason: '前折角 $deg° 的髋角应当逐位等于闭式解',
        );
      }
      expect(srtHipAngleDeg(torsoLeanDeg: srtUprightDeg), greaterThan(75.0));
      expect(srtHipAngleDeg(torsoLeanDeg: srtReachDeg), lessThan(55.0));
    });

    test('膝角是精确造出来的', () {
      for (final deg in [140.0, 160.0, 175.0]) {
        final frame = srtPose(timestampMs: 0, kneeDeg: deg);
        expect(
          _feature(frame, 'knee_angle_L'),
          closeTo(deg, 1e-9),
          reason: '膝角应当逐位等于传入值',
        );
        // 两侧都造得出来，规则取的那一侧才等于它。
        expect(_feature(frame, 'knee_angle_R'), closeTo(deg, 1e-9));
      }
    });

    test('弹振序列掉头 5 次，平稳序列 1 次', () {
      // **直接对归约函数取值**，而不是反推两条规则的命中与否：这样「弹振是
      // 几次」与「阈值该定多少」是两件可以分别检查的事。
      //
      // 平稳那一次是 1 而不是 0：一次「下到底再上来」本身就有一次掉头
      //（`countReversals` 的第一步只用来定初始方向、不计入）。所以阈值
      // 不能定成 0 或 1 —— 那会把所有人的每一次标准动作都判成弹振。
      //
      // 弹振那一次的 5 = 摆的 4 次 + 最后起身那 1 次（两边都有它，
      // 所以真正把它与平稳那一次分开的是前面那 4 次）。
      expect(
        countReversals(_hipAngles(srtBallisticFrames(startTimestampMs: 0))),
        5,
      );
      expect(
        countReversals(_hipAngles(srtRepFrames(startTimestampMs: 0))),
        1,
      );
    });
  });

  group('分段', () {
    test('标准一次计 1', () {
      final runner = _runner();
      _feed(runner, srtRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);
      expect(runner.currentState, SitReachStates.upright);
    });

    test('伸到一半又坐直：计 0、弃 1', () {
      // 没伸到底的那一次**不算一次**。它也不是无声无息地消失 ——
      // `discardedReps` 记账，界面解释为「有 N 次没计入」。
      //
      // 反面即第 1 条结论：如果计数点落在 HOLDING 上，这一次会被计成 1 ——
      // 而它连「前伸到底」那条线都没碰到。
      final runner = _runner();
      _feed(
        runner,
        srtFromSegments([
          srtUpright,
          srtMid, // 前伸途中
          srtMid, // 又坐回去，全程没到保持线
          srtUpright,
        ]),
      );

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, SitReachStates.upright,
          reason: '要坐直等下一次');
    });

    test('守卫的上下界：两条线两侧都有滞回带', () {
      // 上面那条计数测试一旦变绿，就可能是因为「压根没离开 SIT_UPRIGHT」——
      // 那样它证明的是别的东西。这里直接对守卫求值。
      final definition = buildSitReach(_seatedCalibration, config: _config());
      bool at(String src, String dst, double hipDeg) =>
          _guardOf(definition, src, dst).call({'hip_angle_L': hipDeg});

      final config = _config();
      final upright = config.sitReachUprightDeg; // 75
      final holding = config.sitReachHoldingDeg; // 55
      final hyst = config.sitReachHysteresisDeg; // 8

      // 离开坐直线往下折，要折过整条滞回带才算动起来。
      expect(at(SitReachStates.upright, SitReachStates.reaching, upright),
          isFalse);
      expect(
          at(SitReachStates.upright, SitReachStates.reaching,
              upright - hyst - 0.01),
          isTrue);
      // 而「伸到底」这一侧**不含**滞回带：到达线就是到达线。
      expect(at(SitReachStates.reaching, SitReachStates.holding, holding + 0.01),
          isFalse);
      expect(at(SitReachStates.reaching, SitReachStates.holding, holding),
          isTrue);

      // 假动作：前伸途中又坐直（用的是与正常收势**同一条**线）。
      expect(at(SitReachStates.reaching, SitReachStates.upright, upright - 0.01),
          isFalse);
      expect(at(SitReachStates.reaching, SitReachStates.upright, upright), isTrue);

      // 离开保持位往回坐，要坐过整条滞回带才算开始坐回。
      expect(at(SitReachStates.holding, SitReachStates.returning,
              holding + hyst),
          isFalse);
      expect(
          at(SitReachStates.holding, SitReachStates.returning,
              holding + hyst + 0.01),
          isTrue);

      expect(at(SitReachStates.returning, SitReachStates.upright, upright - 0.01),
          isFalse);
      expect(at(SitReachStates.returning, SitReachStates.upright, upright),
          isTrue);

      // 回退：坐到一半又伸回去。
      expect(at(SitReachStates.returning, SitReachStates.holding, holding),
          isTrue);
      expect(at(SitReachStates.returning, SitReachStates.holding, holding + 0.01),
          isFalse);

      // 开局与封存落到 SIT_UPRIGHT 用的是**同一条线**：SIT_UPRIGHT 只有一个含义。
      expect(
        _guardOf(definition, SitReachStates.returning, SitReachStates.upright),
        same(_guardOf(
            definition, SitReachStates.reaching, SitReachStates.upright)),
      );

      // 而「取不到这个量」时一条守卫都不成立 —— 不能拿 0 顶替（0 正是
      // 「折到极限」，用它会凭空造出一次「已经前伸到底」的结论）。
      for (final (src, dst) in [
        (SitReachStates.upright, SitReachStates.reaching),
        (SitReachStates.reaching, SitReachStates.holding),
        (SitReachStates.reaching, SitReachStates.upright),
        (SitReachStates.holding, SitReachStates.returning),
        (SitReachStates.returning, SitReachStates.upright),
        (SitReachStates.returning, SitReachStates.holding),
      ]) {
        expect(
          _guardOf(definition, src, dst).call(const {}),
          isFalse,
          reason: '$src→$dst 在指标缺失时不该成立',
        );
      }
    });

    test('回退不卡死：坐到一半又伸回去，仍然坐得直', () {
      // 守卫看不见时间，没有 RETURNING → HOLDING 这条边的话，「坐到一半
      // 又没劲了」会停在 RETURNING 直到帧上限 —— 既不计数也不丢弃，
      // 只是每一帧都显示着一个错的状态词。
      final runner = _runner();
      _feed(
        runner,
        srtFromSegments([
          srtUpright,
          srtMid,
          srtReach, // 伸到底
          srtMid, // 坐到一半（已越过 63°，进了 RETURNING）
          srtReach, // 又伸回去
          srtMid,
          srtUpright, // 终于坐直 → 封存
        ]),
      );

      expect(runner.repCount, 1, reason: '伸回去之后仍然要坐得直');
      expect(runner.currentState, SitReachStates.upright);
    });

    test('一直坐着不动不会被计也不会被弃', () {
      final runner = _runner();
      _feed(runner, srtUprightFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '坐着不动不该被记账成一次丢弃');
      expect(runner.currentState, SitReachStates.upright);
    });
  });

  group('两条规则', () {
    test('屈膝：只命中前伸到底那一段真的弯着的那一次', () {
      // **这一条钉住的是 `SRT_KNEE_BENT` 的窗口。** 「前伸途中膝盖松了一下、
      // 到底之后又伸直了」在前伸途中膝角只有 140°，但它**不该被判屈膝** ——
      // 前伸途中膝盖松一下没人管得着，屈膝只有在前伸到底那一刻才说明问题
      //（膝盖一弯，上身就「够」得更远，那正是成绩要排除的作弊姿势）。
      //
      // 窗口若写成 `Phase.all`，这一次会被判屈膝；写成 `Phase.bottom` 才不判。
      final passing = _runner();
      _feed(passing, srtKneeBentInReachingFrames(startTimestampMs: 0));
      expect(passing.repCount, 1, reason: '它前伸到底了，算一次');
      expect(
        _statOf(passing.finishSet(), 'SRT_KNEE_BENT'),
        isNull,
        reason: '前伸途中膝松一下不算屈膝 —— 这条规则看的是保持那一段',
      );
      // 而且要把「弯在哪儿」摆出来，别让人以为这条是因为「压根没读到这个量」
      // 才没命中：同一个窗口里，前伸段的最小膝角是那个屈着的值，
      // 保持段的最小膝角是伸直的。
      final window = passing.windows.single;
      expect(_kneeMin(window, Phase.descent), closeTo(srtBentKneeDeg, 1e-9));
      expect(_kneeMin(window, Phase.bottom),
          closeTo(srtStraightKneeDeg, 1e-9));

      // 反过来：全程屈膝 —— 保持那一段也是弯的，必须命中。
      final bent = _runner();
      _feed(bent, srtRepFrames(startTimestampMs: 0, kneeDeg: srtBentKneeDeg));
      expect(bent.repCount, 1, reason: '屈膝不该把这一次挤出计数');
      expect(_statOf(bent.finishSet(), 'SRT_KNEE_BENT'), isNotNull);

      // 腿伸直的正常那一次必须干净 —— 否则这条是「永远命中」。
      final straight = _runner();
      _feed(straight, srtRepFrames(startTimestampMs: 0));
      expect(_statOf(straight.finishSet(), 'SRT_KNEE_BENT'), isNull);
    });

    test('弹振借力：只命中来回弹的那一次，平稳的那一次不命中', () {
      // **这一条钉住的是 `SRT_BALLISTIC` 的窗口与归约。** 弹的两下前伸到底的
      // 角度**完全一样**（都到 `srtReachDeg`），只有序列的形状分得开 ——
      // 所以窗口必须取 `Phase.all`：只看 `Phase.bottom` 会把「抖到位就停住」
      // 的人漏掉，而那正是这条判定唯一要抓的姿势。
      //
      // 归约换成 `Reduce.min` / `Reduce.max` 之类的量比较也不行：那些只看得见
      // 一个点，两种人的那个点一样。
      final ballistic = _runner();
      _feed(ballistic, srtBallisticFrames(startTimestampMs: 0));
      expect(ballistic.repCount, 1,
          reason: '弹振的人前伸到底的角度其实是够的，所以照样算一次');
      expect(_statOf(ballistic.finishSet(), 'SRT_BALLISTIC'), isNotNull);

      // **窗口为什么必须是 `Phase.all`，看这一对数字就明白：** 同一次动作，
      // 前伸到底那一段数出来 **0** 次掉头（那人在这段里是静的），整段数出来
      // **5** 次。窗口写成 `Phase.bottom` 的话，这条判定对「抖到够远了就停住」
      // 的那些人一次都不会响 —— 而那正是它唯一要抓的姿势。
      final window = ballistic.windows.single;
      expect(countReversals(_hipAnglesOf(window.select(Phase.bottom))), 0);
      expect(countReversals(_hipAnglesOf(window.select(Phase.all))), 5);

      final steady = _runner();
      _feed(steady, srtRepFrames(startTimestampMs: 0));
      expect(
        _statOf(steady.finishSet(), 'SRT_BALLISTIC'),
        isNull,
        reason: '平稳前伸只掉头 1 次，不该被判成弹振 —— 否则这条是「永远命中」',
      );
    });

    test('两条判定互不顶替：弹振那一次腿是伸直的', () {
      // 两条规则打的是同一段动作里的两件不同的事。弹振那一次的屈膝判据
      // 必须干净 —— 否则报告会一次说两句话，而用户只做错了一件。
      final ballistic = _runner();
      _feed(ballistic, srtBallisticFrames(startTimestampMs: 0));

      final summary = ballistic.finishSet();
      expect(_statOf(summary, 'SRT_BALLISTIC'), isNotNull);
      expect(_statOf(summary, 'SRT_KNEE_BENT'), isNull);
    });
  });

  group('阈值表的两个键', () {
    test('规则引用的键与内联表对得上，而且取值非零、有限', () {
      final definition = buildSitReach(_seatedCalibration, config: _config());
      final table = _localTable();
      for (final rule in definition.rules) {
        final value = table.get(rule.thresholdKey).value;
        expect(value.isFinite && value != 0, isTrue,
            reason: '${rule.code} 的阈值取到了 0 或非有限值');
      }
    });

    test('两个键的取值与规则的方向配得上', () {
      // 膝角取正值、方向朝下（越小越弯）；掉头次数是无量纲的次数、方向朝上
      //（抖得越多越糟）。**两条规则的方向不许写反** —— 写反的表现是
      // 「标准动作永远命中」或者「永远不命中」，而两者都不会报错。
      final definition = buildSitReach(_seatedCalibration, config: _config());

      final kneeBent = definition.rules.firstWhere((r) => r.code == 'SRT_KNEE_BENT');
      expect(kneeBent.badSide, Direction.below);
      expect(kneeBent.reduce, Reduce.min);
      expect(kneeBent.phase, Phase.bottom);

      final ballistic =
          definition.rules.firstWhere((r) => r.code == 'SRT_BALLISTIC');
      expect(ballistic.badSide, Direction.above);
      expect(ballistic.reduce, Reduce.reversals);
      expect(ballistic.phase, Phase.all,
          reason: '弹振发生在前伸的过程里，窗口只看底部会漏掉绝大多数');
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

    test('坐位体前屈引用的每一个阈值键都真实存在', () {
      for (final rule in buildSitReach(_seatedCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildSitReach(_seatedCalibration);
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

    test('两条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`srt.fault_weight.srt_ballistic`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildSitReach(_seatedCalibration);
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
          table.get('srt.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildSitReach(_seatedCalibration);
      final scorer = FormScorer(definition: definition, thresholds: table);
      expect(
        scorer.weightsVerified,
        isFalse,
        reason: '权重已核定的话，下面那条断言就该改成「随核定状态」',
      );

      final runner = ActionRunner(
        definition,
        thresholds: table,
        calibration: _seatedCalibration,
      );
      _feed(runner, srtRepFrames(startTimestampMs: 0));
      expect(runner.repCount, 1, reason: '真实分段线下这一组也要计得出来');
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });

  group('真实标定：坐姿帧 → 标定 → 定义', () {
    // 上面每一条用的都是手写的 `_seatedCalibration`（文件头第 6 条）。于是
    // 「这一组基线在 45° 机位下根本采不满」这类错一条都发现不了 —— 而它的表现
    // 是标定条卡在 0、屏幕上没有任何错误，用户只会以为这个功能坏了。
    //
    // `buildSitReach` 还要读 `calibration.kneeAngle` 与 `trunkLean`，所以标定
    // 走不完的话连定义都建不起来，而抛点在会话里 —— 也就是用户做完标定那一刻。

    Calibration calibrateSeated() {
      // 用的是 **spec 声明的那一份基线集与那个机位**，不是随手挑的：基线量与
      // 机位绑死，spec 里写着 45°、基线集里某一个量在 45° 下采不到的话，
      // 下面这句 `isNotNull` 就会红。这就是「机位写错了」的哨兵。
      final extractor = FeatureExtractor(cameraView: srtSpec.cameraView);
      final calibrator = Calibrator(
        required: srtSpec.calibrationBaselines,
        minFrames: 15,
      );
      for (var i = 0; i < 15; i++) {
        calibrator.feed(extractor.extract(srtPose(timestampMs: i * 33)));
      }
      final calibration = calibrator.calibration;
      expect(
        calibration,
        isNotNull,
        reason: '标定没走完 —— spec 声明的某个基线量在 '
            '${srtSpec.cameraView.name} 机位下拿不到',
      );
      return calibration!;
    }

    test('坐姿帧采出来的基线就是合成时摆的那个姿势', () {
      // 标定「走完了」不等于「采对了」：中途换错了特征（比如把躯干倾角读成
      // 髋角）时标定照样走完，两条判定的读数却整体挪位 —— 而膝角与髋角都是
      // 绝对量，不挂基线，所以下面那些规则用例一条都不会红。
      final calibration = calibrateSeated();
      expect(calibration.frames, 15);
      expect(
        calibration.kneeAngle,
        closeTo(srtStraightKneeDeg, 1.0),
        reason: '坐直时腿是伸直的（$srtStraightKneeDeg°）',
      );
      expect(
        calibration.trunkLean,
        closeTo(0.0, 1.0),
        reason: '坐直时躯干是竖直的',
      );
    });

    test('这份测试的机位与 spec 声明的是同一个', () {
      // 两边各写死一个机位的话，「建定义并跑一组」在一个机位下测、产品在另一个
      // 机位下跑 —— 这种不一致不会报错，只会让上面那条测试测的不是产品那条路。
      expect(srtSpec.cameraView, _config().cameraView);
    });

    test('用采出来的那份标定建定义并跑一组，照样计得出来', () {
      final calibration = calibrateSeated();
      final runner = ActionRunner(
        buildSitReach(calibration, config: _config()),
        thresholds: _localTable(),
        calibration: calibration,
      );

      _feed(runner, srtRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1, reason: '这一组是标准动作');
      expect(runner.discardedReps, 0);
    });
  });
}
