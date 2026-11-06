/// 立定跳远动作定义测试。
///
/// 这里钉住四类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **四个相位区间必然齐全，且各自短于整段。** `RepWindow.select` 在区间缺失时
///    静默返回整段（`rules.dart:252-254`），于是「只在落地段求值」的规则会悄悄变成
///    「在整次动作上求值」——不报错，只是判的东西不是它声称的东西。立定跳远的状态
///    图让这件事走不到（LAND 只从 FLIGHT 来、FLIGHT 只从 LAUNCH 来、LAUNCH 只从
///    PREP 来），这条测试是那句话的可执行版本。
/// 2. **假跳必然超时不计数。** 状态机分不出「蹬直到站起来」与「蹬直到跳起来」——
///    两者在膝角这根轴上完全一样，守卫又看不见时间。唯一的分界是有没有落地缓冲。
/// 3. **收腿不被当成落地。** 少了 `landingHipFloor` 那道门槛，落地缓冲规则会变成
///    一条永远不再触发的规则：收腿越标准越被判成缓冲充足。
/// 4. **五条规则各自的相位与方向。** 每条都要有正例与反例，否则「阈值取反」
///    「相位写错」都不会被发现。
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
import 'package:vitalteen_app/domain/exercises/slj.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_slj.dart';

const Calibration _standingCalibration = Calibration(
  kneeAngle: sljStandDeg,
  trunkLean: 0,
  heelRiseRatio: 0,
  frames: 15,
);

/// 内联阈值表。分段线见 [sljBendLine] 那一组常量的注释。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: sljActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('slj.prejump_foot_off_max_delta', 0.15, 'heel_rise_ratio_L'),
        _threshold('slj.takeoff_symmetry_max', 0.10, 'knee_symmetry'),
        _threshold('slj.landing_symmetry_max', 0.10, 'knee_symmetry'),
        // 落地缓冲线取 140°：合成序列里「有缓冲」落在 115°、「没缓冲」落在 155°，
        // 两边各留 15° 余量，免得测试断在阈值同侧的边界上。
        _threshold('slj.landing_buffer_min_knee_angle', 140.0, 'knee_angle_L', unit: 'deg'),
        _threshold('slj.trunk_lean_max_delta', 15.0, 'trunk_lean', unit: 'deg'),
      ],
      version: 'test',
    );

ActionRunner _runner({TrackingConfig? config}) => ActionRunner(
      buildSlj(_standingCalibration, config: config),
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

/// 动作开始前的站立段。
///
/// 状态机要最近 `voteWindow`（5）帧里至少 4 帧同类证据才提交一次转移，
/// 冷启动时窗口还要从零攒起 —— 段太短根本走不到 PREP。
const SljSegment _stand = SljSegment(sljStandDeg, count: 16);

/// 蓄力段：95° 远低于前蹲线 150°，进得干净。
const SljSegment _prep = SljSegment(95.0, count: 12);

/// 落地缓冲段：115° 低于落地线 163°、又远低于缓冲线 140°。
const SljSegment _softLanding = SljSegment(115.0, count: 12);

/// 收尾站立段。回到站立态的那一帧封存 rep。
const SljSegment _recover = SljSegment(sljStandDeg, count: 16);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄少一条边', () {
      // 这几条线全是可调的工程参数。调乱之后状态机不会报错，只会少一条边
      // 或者多一条「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。
      expect(
        () => buildSlj(
          _standingCalibration,
          // 落地线 171 越过了站立线 167：LAND 一进去就会被送回 STANDING。
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            minBendDeg: 25.0,
            landingFlexDeg: 4.0,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('默认配置合法', () {
      expect(() => buildSlj(_standingCalibration), returnsNormally);
    });
  });

  group('分段', () {
    test('一次完整立定跳远计 1 次，四个相位区间齐全且按顺序排列', () {
      final runner = _runner();
      _feed(runner, sljRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1);
      expect(runner.discardedReps, 0);

      final window = runner.windows.single;
      expect(window.index, 1, reason: 'rep 序号从 1 起算，供报告直接显示「第 N 次」');

      const phases = [Phase.prep, Phase.takeoff, Phase.flight, Phase.landing];
      for (final phase in phases) {
        expect(window.phaseBounds.keys, contains(phase), reason: '$phase 区间缺失');
      }
      for (var i = 1; i < phases.length; i++) {
        expect(
          window.phaseBounds[phases[i]]!.start,
          greaterThan(window.phaseBounds[phases[i - 1]]!.start),
          reason: '${phases[i]} 应当排在 ${phases[i - 1]} 之后',
        );
      }
    });

    test('四个相位区间各自严格短于整段 —— 整段退化在本动作上走不到', () {
      // 这条是本动作状态图**最值钱的性质**：LAND 只能从 FLIGHT 来、FLIGHT 只能从
      // LAUNCH 来、LAUNCH 只能从 PREP 来，所以每个被封存的 rep 必然走完全程。
      // 谁把某条边拆了（比如给 LAUNCH 加一条直通 LAND 的捷径），这里先红。
      final runner = _runner();
      _feed(runner, sljRepFrames(startTimestampMs: 0));
      final window = runner.windows.single;

      for (final phase in [Phase.prep, Phase.takeoff, Phase.flight, Phase.landing]) {
        final slice = window.select(phase);
        expect(slice, isNotEmpty, reason: '$phase 一帧都取不到');
        expect(
          slice.length,
          lessThan(window.frames.length),
          reason: '$phase 退化成了整段，等于规则在整次动作上求值',
        );
      }
    });

    test('「蹲一下又站起来」不计入、不卡死，且会超时丢弃并复位', () {
      // 它走得到 FLIGHT（蹬伸段与真跳一模一样），然后人站直不动 ——
      // 没有落地缓冲，`FLIGHT → LAND` 永远不触发。这不是缺陷而是本设计的
      // 已知代价：分不出假跳与真跳，只能等 `maxRepFrames` 超时。
      // 收尾那 140 帧是刻意的，要让它**真的**越过 120 帧上限，
      // 才能验证 RepTracker 会复位而不是永远挂着半个 rep。
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          const SljSegment(95.0, count: 14), // PREP
          const SljSegment(178.0, count: 14), // LAUNCH → FLIGHT
          const SljSegment(sljStandDeg, count: 140), // 站着不动
        ]),
      );

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(
        runner.currentState,
        SljStates.standing,
        reason: '必须复位回站立态等下一段，否则这一组再也数不出任何动作',
      );
    });

    test('回蹲（蹬伸到一半又蹲回去）不卡死，最终仍数出一次', () {
      // 回退边是正确性的一部分：只写一路向前的链条时，用户在 LAUNCH 里蹲回去
      // 就再也出不去了。
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(170.0, count: 8), // 蹬起一点 → LAUNCH
          const SljSegment(95.0, count: 12), // 又蹲回去 → PREP
          const SljSegment(178.0, count: 16), // 这次蹬直 → FLIGHT
          _softLanding,
          _recover,
        ]),
      );

      expect(runner.repCount, 1);
      expect(runner.currentState, SljStates.standing);
    });
  });

  group('人出画后的重同步', () {
    // 立定跳远与深蹲最不一样的一点：**人会离开原地**。手机架在两米外，
    // 跳一次前进一米多，出画是常态而不是意外。
    //
    // 出画时状态机停在哪个状态是随机的，而多半就停在 LAUNCH：出画的瞬间
    // 恰好是蹬伸最快的那几帧，膝角刚过蹬伸线（158°）、还够不着离地线（171°）。
    // 停在 LAUNCH 的后果不是「少计一次」——是**连环丢掉一次本来看得见的落地**：
    // 回来蹲下被读成回蹲（LAUNCH→PREP），站直又把 PREP 推回 LAUNCH、再推进
    // FLIGHT，最后停在 FLIGHT 上等 `maxRepFrames` 超时。
    //
    // 修法是 [ActionDefinition.lossRecovery]（`slj.dart` 里只登记
    // LAUNCH→FLIGHT 一条）。这一组既钉住它成立，也钉住它的**边界** ——
    // 它只承认「人已经离地」，落地仍然要靠**看得见**的那一下蹲。
    test('停在 LAUNCH：重同步后回来那一下蹲被认成落地，四个相位仍然齐全', () {
      final runner = _runner();
      final before = sljFromSegments([
        _stand,
        _prep,
        const SljSegment(165.0, count: 12), // 蹬到一半 → LAUNCH，够不着 171
      ]);
      _feed(runner, before);
      expect(
        runner.currentState,
        SljStates.launch,
        reason: '这段的前提：出画那一刻确实停在 LAUNCH —— 前提不成立的话下面全是空转',
      );

      expect(runner.recoverFromLoss(), isTrue);
      expect(runner.currentState, SljStates.flight, reason: '按登记的那条边落到 FLIGHT');
      expect(
        runner.recoverFromLoss(),
        isFalse,
        reason: 'FLIGHT 没有再登记的边：重复调用是空操作，不会一路往前推',
      );

      _feed(
        runner,
        sljFromSegments(
          [
            _softLanding, // 回来那一下蹲 —— 这一次是**看得见**的
            _recover,
          ],
          startTimestampMs: before.last.timestampMs + 33,
        ),
      );

      expect(runner.repCount, 1, reason: '蹬伸那几帧没看见，但落地看见了，这是一次真跳');
      expect(runner.discardedReps, 0);

      // 相位的结构性断言。**重同步之后这一条不是自动成立的**：
      // 重同步要是不给旧的那一段收尾，后面的帧会被记进 LAUNCH 的区间里，
      // 而错相位不报错 —— 只会让落地缓冲、落地同步两条规则去评一段
      // 不属于它的帧。这里逐个相位核一遍。
      final window = runner.windows.single;
      for (final phase in [Phase.prep, Phase.takeoff, Phase.flight, Phase.landing]) {
        expect(window.phaseBounds.keys, contains(phase), reason: '$phase 区间缺失');
        expect(
          window.select(phase).length,
          lessThan(window.frames.length),
          reason: '$phase 退化成了整段，等于规则在整次动作上求值',
        );
      }
      expect(
        window.select(Phase.landing).length,
        lessThanOrEqualTo(_softLanding.count + _recover.count),
        reason: '落地相位只该覆盖「回来之后」那一段，不该把出画前的帧也圈进来',
      );
    });

    test('重同步只把人放进空中：回来时已经站直，仍然不算数', () {
      // 这是上面那条的边界，也是它与「直接封存一次落地」的分界线。
      // 改成 LAUNCH→LAND 的话这条会红 —— 而那正是**编分数**：
      // 落地缓冲、落地同步两条规则读的都是 landing 相位，人走回来那几帧
      // 会被拿去评「缓冲够不够」，一个没有任何一帧看到过落地的分数。
      final runner = _runner();
      final before = sljFromSegments([
        _stand,
        _prep,
        const SljSegment(165.0, count: 12),
      ]);
      _feed(runner, before);
      runner.recoverFromLoss();

      _feed(
        runner,
        sljFromSegments(
          [const SljSegment(sljStandDeg, count: 140)], // 走回来时已经站着
          startTimestampMs: before.last.timestampMs + 33,
        ),
      );

      expect(runner.repCount, 0, reason: '没有任何一帧看到落地，就没有计数的依据');
      expect(runner.discardedReps, 1, reason: '但要如实记账，不能装作什么都没发生');
      expect(runner.currentState, SljStates.standing, reason: '超时之后要复位等下一跳');
    });

    test('不在一次 rep 里时是空操作 —— 站着不动不会被推着走', () {
      // `recoverFromLoss` 挂在「离开静止态之后」这一段缓冲上。若它不管这件事，
      // 一段长丢失结束时会把一个站着不动的人推进 FLIGHT，下一帧的站立姿态
      // 什么守卫都不满足，只能等超时 —— 用户站着没跳，却被告知丢了一次。
      final runner = _runner();
      _feed(runner, sljStandFrames(count: 20));

      expect(runner.recoverFromLoss(), isFalse);
      expect(runner.currentState, SljStates.standing);
      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '站着不动不该被记账成一次丢弃');
    });
  });

  group('落地门槛', () {
    test('髋不高于膝就不算落地 —— 否则收腿越标准，缓冲越「充足」', () {
      // 守卫单独测，因为它是这条规则里最容易「看起来一切正常」的一处：
      // 门槛失效时状态机走得更「顺」，只是 LAND 相位变成了那一段收腿。
      final guard = _guardOf(
        buildSlj(_standingCalibration),
        SljStates.flight,
        SljStates.land,
      );

      expect(
        guard({'knee_angle_L': 100.0, 'knee_angle_R': 100.0, 'hip_height_ratio': 1.5}),
        isTrue,
      );
      expect(
        guard({'knee_angle_L': 100.0, 'knee_angle_R': 100.0, 'hip_height_ratio': -0.5}),
        isFalse,
        reason: '收腹举腿：膝折到胸口，髋中点已经低于膝中点',
      );
      expect(
        guard({'knee_angle_L': 100.0, 'knee_angle_R': 100.0}),
        isFalse,
        reason: '特征不可用时不能默认放行 —— 那会把遮挡变成一次落地',
      );
      expect(
        guard({'knee_angle_L': 170.0, 'knee_angle_R': 170.0, 'hip_height_ratio': 1.5}),
        isFalse,
        reason: '膝还没屈到落地线以下，根本不是落地',
      );
    });

    test('收腿不会被当成落地段 —— 门槛的端到端回归（含拆掉门槛的对照组）', () {
      // 刻意让收腿（100°）比真正的落地（155°）还深。这是本设计里最难自查的
      // 失败模式：门槛失效时状态机走得更「顺」，一切正常，只是 landing 相位
      // 变成了那一段收腿，于是「落地缓冲不足」**静默失效** ——
      // 一次真的没缓冲的落地被它自己那一段收腿掩盖过去。
      //
      // 所以这里不只断言「门槛在的时候对」，还跑一遍拆掉门槛的对照组，
      // 断言「门槛不在的时候确实错」。否则这条测试可能只是在空转。
      final frames = sljFromSegments([
        _stand,
        _prep,
        const SljSegment(178.0, count: 16), // LAUNCH → FLIGHT
        const SljSegment(100.0, count: 12, kneeLift: 0.20), // 收腹举腿
        const SljSegment(155.0, count: 14), // 真正的落地缓冲
        _recover,
      ]);

      double lowestKnee(ActionRunner runner) {
        final knees = runner.windows.single
            .select(Phase.landing)
            .map((f) => f.get('knee_angle_L'))
            .whereType<double>()
            .toList();
        expect(knees, isNotEmpty, reason: '落地段一帧都取不到');
        return knees.reduce((a, b) => a < b ? a : b);
      }

      final gated = _runner();
      _feed(gated, frames);
      expect(gated.repCount, 1);
      expect(lowestKnee(gated), closeTo(155.0, 1.0), reason: '落地段里混进了收腿的帧');
      expect(
        _statOf(gated.finishSet(), 'SLJ_LAND_STIFF'),
        isNotNull,
        reason: '落地屈膝只有 155°，缓冲不足应当命中；没命中说明落地段被抓错了',
      );

      // 对照组：门槛放到 -1.0（收腿时 hip 约 -0.5，仍然放行）。
      final ungated = _runner(
        config: const TrackingConfig(
          cameraView: CameraView.oblique45,
          minBendDeg: 25.0,
          maxRepFrames: 120,
          landingHipFloor: -1.0,
        ),
      );
      _feed(ungated, frames);
      expect(ungated.repCount, 1, reason: '门槛不该影响计数，只影响分段');
      expect(lowestKnee(ungated), closeTo(100.0, 1.0), reason: '落地段退化成了收腿');
      expect(
        _statOf(ungated.finishSet(), 'SLJ_LAND_STIFF'),
        isNull,
        reason: '这就是门槛失效的样子：真的没缓冲，却什么都不报',
      );
    });
  });

  group('端到端：姿态 → 特征 → 状态机 → 规则', () {
    test('标准一跳五条错误一条都不命中', () {
      // 反例组的总闸。任何一条规则的方向写反、相位写错、阈值取值离谱，
      // 都会让这条先红 —— 单看正例是发现不了的。
      final runner = _runner();
      _feed(runner, sljRepFrames(startTimestampMs: 0));

      final summary = runner.finishSet();
      expect(summary.repCount, 1);
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
      );
    });

    test('落地缓冲不足 → SLJ_LAND_STIFF 命中', () {
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(178.0, count: 16),
          const SljSegment(155.0, count: 14), // 屈到 155° 就停住了
          _recover,
        ]),
      );

      final stat = _statOf(runner.finishSet(), 'SLJ_LAND_STIFF');
      expect(stat, isNotNull);
      expect(stat!.rate, 1.0);
      expect(stat.scorable, isTrue, reason: '内联表标的是 literature');
    });

    test('同一段轨迹落地屈得更深就该放行 —— 判据是最低点，不是越界帧计数', () {
      // 与上一条的唯一差别是落地段膝角。若缓冲规则误用 anyFrame 计数，
      // 落地前后那些过渡帧会全部算作越界，于是**每一次落地都被误判**，
      // 正是深蹲 INSUFFICIENT_DEPTH 注释里警告过的那个错误。
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(178.0, count: 16),
          _softLanding,
          _recover,
        ]),
      );

      expect(_statOf(runner.finishSet(), 'SLJ_LAND_STIFF'), isNull);
    });

    test('起跳双脚不同步 → SLJ_TAKEOFF_ASYNC 命中', () {
      // 一条腿先蹬直、另一条还差 28°。均值 164° 已越蹬伸线（158）进得了 LAUNCH，
      // 但还不到腾空线（171）—— 于是整段都留在 takeoff 相位里被这条规则看见。
      //
      // 这个「两腿差值不可能太大」是设计使然：差得再多，均值就够不到腾空线，
      // 这一跳根本不会被计数（见 slj.dart 文件头「一条被刻意去掉的边」）。
      // 所以两条同步规则能抓的是**中等幅度**的不同步，抓不到「一条腿完全不发力」——
      // 那种情况表现为漏计，不是误判。
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(178.0, count: 14, rightKneeDeg: 150.0),
          const SljSegment(180.0, count: 12, rightKneeDeg: 178.0),
          _softLanding,
          _recover,
        ]),
      );

      final stat = _statOf(runner.finishSet(), 'SLJ_TAKEOFF_ASYNC');
      expect(stat, isNotNull, reason: '膝角对称指数 2×28/328 ≈ 0.17，越过 0.10');
      expect(stat!.rate, 1.0);
    });

    test('落地双脚不同步 → SLJ_LAND_ASYNC 命中', () {
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(178.0, count: 16),
          const SljSegment(115.0, count: 14, rightKneeDeg: 145.0),
          _recover,
        ]),
      );

      expect(_statOf(runner.finishSet(), 'SLJ_LAND_ASYNC'), isNotNull);
    });

    test('蓄力时前掌离地 → SLJ_PREJUMP_HEEL_OFF 命中', () {
      // 码名叫 HEEL_OFF（脚跟抬起），中文名叫「前掌离地」—— 两者指向相反方向。
      // 规则取绝对值再与本人站立基线比，一次覆盖两个方向，这是有意的。
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          const SljSegment(95.0, count: 12, heelRise: 0.25),
          const SljSegment(178.0, count: 16),
          _softLanding,
          _recover,
        ]),
      );

      // 判据是「蓄力段**持续**出现」——姿态类问题，按越界帧数计（下限 2 帧）。
      expect(_statOf(runner.finishSet(), 'SLJ_PREJUMP_HEEL_OFF'), isNotNull);
    });

    test('蹬伸段躯干前倾过大 → SLJ_TRUNK_CONTROL 命中', () {
      final runner = _runner();
      _feed(
        runner,
        sljFromSegments([
          _stand,
          _prep,
          const SljSegment(178.0, count: 16, trunkLeanDeg: 40.0),
          _softLanding,
          _recover,
        ]),
      );

      expect(_statOf(runner.finishSet(), 'SLJ_TRUNK_CONTROL'), isNotNull);
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表，键名与资产表一致、数值不必一致 —— 于是「资产表里
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

    test('立定跳远引用的每一个阈值键都真实存在', () {
      for (final rule in buildSlj(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildSlj(_standingCalibration);
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

    test('五条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`slj.fault_weight.slj_land_stiff`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildSlj(_standingCalibration);
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
          table.get('slj.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildSlj(_standingCalibration);
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
      _feed(runner, sljRepFrames(startTimestampMs: 0));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
