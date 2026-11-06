/// 会话状态机测试：**自检 → 标定 → 计数 → 本组结束**。
///
/// 这一层是主机上唯一能跑「整条产品流程」的地方，所以这里钉的是
/// **只在真机上才会暴露、而真机上又很难复现**的那几件事：
///
/// - 门禁没过时点「开始」必须无效（否则用户会得到一屏没有意义的数字）。
/// - 标定途中人走开，这次标定必须作废。**错误的站立基线不会报错** ——
///   它只会让后面每一个 rep 的个体化阈值都偏掉，而偏了多少没人看得出。
/// - 计数途中人走开再回来，要承认「这次可能不准」。这是长时丢失可能拼出
///   假 rep 的已知缺口（领域层的 `abandonCurrentRep` 本轮不动）在会话层的
///   兜底说法。
/// - 节流真的在节流 —— 每帧发布一次就等于每帧 setState，
///   而那正是 Phase 0 量过的帧率所不能承受的。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_squat.dart';

/// 本地阈值表。数值只为本测试服务，**不是**体育判定依据。
///
/// 三类键必须齐，缺一个就在构造期抛：五条判定（`FaultPresenter`）、
/// 五个错误权重（`FormScorer`）、一条评级切点（同样是 `FormScorer`）。
/// 权重这里取平方数而不是随包的 1.0 占位值，为的是让下面那条「权重换了分数
/// 跟着换」的用例真的能分辨 —— 全 1.0 时归一化会把差异抹平。
ThresholdTable _table() => ThresholdTable(
      [
        for (final (key, value) in const [
          ('squat.min_depth_knee_angle', 100.0),
          ('squat.knee_valgus_angle_notice', 10.0),
          ('squat.trunk_lean_max_delta', 30.0),
          ('squat.heel_rise_ratio_max_delta', 0.15),
          ('squat.asymmetry_index_max', 0.10),
          ('squat.fault_weight.knee_valgus', 4.0),
          ('squat.fault_weight.insufficient_depth', 3.0),
          ('squat.fault_weight.excessive_trunk_lean', 2.0),
          ('squat.fault_weight.heel_rise', 1.0),
          ('squat.fault_weight.asymmetry', 1.0),
        ])
          Threshold(
            key: key,
            actionCode: squatActionCode,
            featureCode: '',
            value: value,
            unit: 'deg',
            sourceType: SourceType.literature,
            version: 'test',
          ),
        Threshold(
          key: 'squat.form_score_rating_breakpoints',
          actionCode: squatActionCode,
          featureCode: '',
          value: 0.0,
          unit: 'score',
          sourceType: SourceType.literature,
          version: 'test',
          severityBreakpoints: const [60.0, 70.0, 80.0, 90.0],
        ),
      ],
      version: 'test',
    );

/// 一局走到「正在计数」的会话。返回时已经数了 [warmupReps] 个 rep。
class _Fixture {
  _Fixture({
    int warmupReps = 0,
    int interruptionThresholdMs = 1500,
    int autoFinishRestMs = 5000,
  }) {
    session = SquatSession(
      thresholds: _table(),
      interruptionThresholdMs: interruptionThresholdMs,
      // 用例里的门槛取 5 秒而不是产品的 10 秒：这里测的是「够久就收工」这条
      // 判据本身，不是那个具体的秒数。
      //
      // **它必须明显高于合成动作里的 `保持站立` 时长。** `squatRepFrames`
      // 头尾各有 16 帧站立（@33ms ≈ 0.53 秒），于是两次 rep 之间有约 1.06 秒
      // 是连着站着的 —— 门槛取 1 秒时，自动收工会在两次 rep 中间触发，
      // 而那条用例真正想测的东西（数了十个）就再也测不到了。
      // 产品的 10 秒对 1 秒的组内停顿有九倍余量，这里照着这个比例留。
      autoFinishRestMs: autoFinishRestMs,
    );
    _clock = 0;
    _feed(standFrames(count: 20, startTimestampMs: _clock));
    expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
    _feed(standFrames(count: 20, startTimestampMs: _clock));
    expect(session.view.value.phase, SessionPhase.counting);
    for (var i = 0; i < warmupReps; i++) {
      doRep();
    }
  }

  late final SquatSession session;
  late int _clock;

  void _feed(List<PoseFrame> frames) {
    for (final frame in frames) {
      session.feed(frame);
      _clock += 33;
    }
  }

  /// 喂一帧，时间戳接着走。
  void feedOne(PoseFrame frame) {
    session.feed(frame);
    _clock += 33;
  }

  /// 在当前时刻喂一帧指定膝角。
  ///
  /// **中断检测的用例必须用它，不能自己编时间戳** —— 编一个「很大的数」
  /// 会让「只走开一小会儿」那条用例也越过阈值，于是测的就不是间隔长短了。
  /// 间隔必须是 [leaveFor] 真正推出来的那个。
  void feedAt(double kneeDeg) {
    feedOne(squatPose(kneeDeg, timestampMs: _clock));
  }

  /// 人走了。一帧都不喂 —— 这就是相机没检出人的样子。
  void leave({int frames = 1}) {
    for (var i = 0; i < frames; i++) {
      session.feed(null);
      _clock += 33;
    }
  }

  /// 人走了 [ms] 毫秒之后回来。
  void leaveFor(int ms) {
    session.feed(null);
    _clock += ms;
  }

  /// 完整做一次深蹲。
  void doRep({double bottomDeg = 120}) {
    _feed(squatRepFrames(bottomDeg: bottomDeg, startTimestampMs: _clock));
  }

  /// 只蹲到一半（还没回到站立）。
  ///
  /// 时间戳必须跟着时钟走：**时间戳为 0 的帧不参与中断检测**（会话拿不到
  /// 时间就判不了间隔），用 `timestampMs: 0` 造帧会让这条用例永远绿。
  void descendHalfway() {
    _feed(framesForAngles(
      [
        ...List.filled(16, standDeg),
        ...List.filled(12, 140.0),
        ...List.filled(12, 120.0),
      ],
      startTimestampMs: _clock,
    ));
  }
}

void main() {
  group('自检门禁', () {
    test('相机还没看到人时，点开始无效', () {
      final session = SquatSession(thresholds: _table());

      expect(session.view.value.sawFrame, isFalse);
      expect(session.view.value.canBeginCalibration, isFalse);
      expect(session.beginCalibration(), isFalse);
      expect(session.view.value.phase, SessionPhase.position);
    });

    test('人站好之后门禁放行', () {
      final session = SquatSession(thresholds: _table());
      for (final frame in standFrames(count: 25)) {
        session.feed(frame);
      }

      expect(session.view.value.sawFrame, isTrue);
      expect(session.view.value.canBeginCalibration, isTrue);
      expect(session.beginCalibration(), isTrue);
      expect(session.view.value.phase, SessionPhase.calibrating);
    });

    test('离得太远时门禁拦住 —— 这一局算出来的数没有意义', () {
      final session = SquatSession(thresholds: _table());
      for (var i = 0; i < 25; i++) {
        // 缩到一半大小：机位判别不受影响（它是个比值），但身高占比掉出下限。
        session.feed(squatPose(standDeg, timestampMs: i * 33, scale: 0.5));
      }

      expect(session.view.value.position.blocking, isTrue);
      expect(session.view.value.canBeginCalibration, isFalse);
      expect(session.beginCalibration(), isFalse);
    });
  });

  group('标定', () {
    test('标定需要足够的帧，进度如实反映', () {
      final session = SquatSession(thresholds: _table(), minCalibrationFrames: 15);
      for (final frame in standFrames(count: 20)) {
        session.feed(frame);
      }
      session.beginCalibration();

      session.feed(squatPose(standDeg, timestampMs: 1000));
      expect(session.view.value.phase, SessionPhase.calibrating);
      expect(session.view.value.calibrationFrames, 1);
      expect(session.view.value.calibrationTarget, 15);
      expect(session.view.value.calibrationProgress, closeTo(1 / 15, 1e-9));
    });

    test('标定完成后自动进入计数', () {
      final fixture = _Fixture();

      expect(fixture.session.view.value.phase, SessionPhase.counting);
      expect(fixture.session.view.value.repCount, 0);
    });

    test('标定途中人走开，这次标定作废并退回自检', () {
      final session = SquatSession(thresholds: _table());
      for (final frame in standFrames(count: 20)) {
        session.feed(frame);
      }
      expect(session.beginCalibration(), isTrue);
      for (final frame in standFrames(count: 5, startTimestampMs: 1000)) {
        session.feed(frame);
      }
      expect(session.view.value.calibrationFrames, 5);

      // 人走了 —— 相机不再检出人。
      session.feed(null);

      expect(session.view.value.phase, SessionPhase.position);
      expect(session.view.value.calibrationFrames, 0);
      // 窗口被清空了，所以必须重新站够时间才放行。
      expect(session.view.value.canBeginCalibration, isFalse);
    });

    test('作废之后重新站好可以重来', () {
      final session = SquatSession(thresholds: _table());
      for (final frame in standFrames(count: 20)) {
        session.feed(frame);
      }
      session.beginCalibration();
      session.feed(null);

      var clock = 100000;
      for (var i = 0; i < 25; i++) {
        session.feed(squatPose(standDeg, timestampMs: clock));
        clock += 33;
      }

      expect(session.view.value.canBeginCalibration, isTrue);
      expect(session.beginCalibration(), isTrue);
    });
  });

  group('计数', () {
    test('做十个深蹲就数到十个', () {
      final fixture = _Fixture();
      for (var i = 0; i < 10; i++) {
        fixture.doRep();
      }

      expect(fixture.session.view.value.repCount, 10);
      expect(fixture.session.view.value.discardedReps, 0);
    });

    test('每个 rep 都有反馈卡片，序号从 1 数起', () {
      final fixture = _Fixture();
      fixture.doRep();

      final feedback = fixture.session.view.value.lastRep;
      expect(feedback, isNotNull);
      expect(feedback!.repIndex, 1);
      expect(feedback.headline, contains('第 1 个'));
    });

    test('膝角读数跟着下蹲走', () {
      // 验收标准里那条「角度随下蹲下降、起身回升」。它同时能抓到
      // 「特征码写错」和「左右腿搞反」这两种不会报错的错。
      //
      // 两帧之间刻意隔开 200 ms：视图是按 `publishIntervalMs`（10 Hz）刷新的，
      // 隔 10 ms 喂两帧，第二次根本不会发布 —— 这不是缺陷，是设计，
      // 所以断言必须落在设计承诺的节奏上。
      final fixture = _Fixture();

      fixture.feedOne(squatPose(standDeg, timestampMs: 10_000));
      expect(fixture.session.view.value.kneeAngle, closeTo(standDeg, 1.0));

      fixture.feedOne(squatPose(120.0, timestampMs: 10_200));
      expect(fixture.session.view.value.kneeAngle, closeTo(120.0, 1.0));
    });

    test('人不在画面里时膝角是空的，而不是停在上一个读数上', () {
      final fixture = _Fixture();
      fixture.feedOne(squatPose(120.0, timestampMs: 10));
      expect(fixture.session.view.value.kneeAngle, isNotNull);

      fixture.leave();

      expect(fixture.session.view.value.kneeAngle, isNull);
      expect(fixture.session.view.value.machineState, isEmpty);
    });

    test('浅蹲被丢弃时计数不动，但丢弃数要说出来', () {
      // 丢弃是静默的：用户看到的是「我做了 12 个，它只数了 9 个」。
      // 界面得能解释，所以这个数必须一路传到视图里。
      final fixture = _Fixture();
      final before = fixture.session.view.value.repCount;
      fixture.doRep(bottomDeg: 150);

      expect(fixture.session.view.value.repCount, before);
      expect(fixture.session.view.value.discardedReps, greaterThan(0));
    });
  });

  group('中断提示', () {
    test('蹲到一半走开很久再回来，标记为「可能不准」', () {
      final fixture = _Fixture();
      fixture.descendHalfway();

      fixture.leaveFor(3000);
      fixture.feedAt(120.0);

      expect(fixture.session.view.value.interrupted, isTrue);
    });

    test('走开一小会儿不算中断 —— 门禁神经质的代价是用户学会无视它', () {
      final fixture = _Fixture();
      fixture.descendHalfway();

      fixture.leaveFor(300);
      fixture.feedAt(120.0);

      expect(fixture.session.view.value.interrupted, isFalse);
    });

    test('门槛恰好等于设定值时算中断（下界闭合）', () {
      // 判据写的是「间隔 < 阈值就不算」，所以恰好等于阈值会算成中断。
      // 方向本身是任意的，钉住它是为了别让人在改动中无意把它翻过来 ——
      // 翻了以后症状是「有人被漏报」，而漏报不会有人来报 bug。
      final fixture = _Fixture(interruptionThresholdMs: 1500);
      fixture.descendHalfway();

      fixture.leaveFor(1500);
      fixture.feedAt(120.0);

      expect(fixture.session.view.value.interrupted, isTrue);
    });

    test('走开时人本来站着，就不算中断 —— 没欠下任何一次 rep', () {
      final fixture = _Fixture();
      fixture.feedAt(standDeg);

      fixture.leaveFor(3000);
      fixture.feedAt(standDeg);

      expect(fixture.session.view.value.interrupted, isFalse);
    });

    test('新开一组会清掉中断标记', () {
      final fixture = _Fixture();
      fixture.descendHalfway();
      fixture.leaveFor(3000);
      fixture.feedAt(120.0);
      expect(fixture.session.view.value.interrupted, isTrue);

      fixture.session.startNewSet();

      expect(fixture.session.view.value.interrupted, isFalse);
    });
  });

  group('发布节流', () {
    test('同一时刻的连续帧只发布一次 —— 每帧 setState 会拖垮帧率', () {
      final session = SquatSession(thresholds: _table(), publishIntervalMs: 100);
      for (final frame in standFrames(count: 20)) {
        session.feed(frame);
      }

      var notifications = 0;
      session.view.addListener(() => notifications++);
      // 20 帧时间戳完全相同：节流下应当最多放行第一次。
      for (var i = 0; i < 20; i++) {
        session.feed(squatPose(standDeg, timestampMs: 100));
      }

      expect(notifications, lessThanOrEqualTo(1));
      session.dispose();
    });

    test('数到一个 rep 时立即发布，不等节流窗口', () {
      final fixture = _Fixture();
      var notifications = 0;
      fixture.session.view.addListener(() => notifications++);

      fixture.doRep();

      // 一个 rep 的帧流跨了 2000+ 毫秒，节流本来也会放行；这条钉的是
      // 「计数事件走的是 force 那条路」，即使用户把帧率压到很低也一样。
      expect(notifications, greaterThan(0));
      expect(fixture.session.view.value.repCount, 1);
    });
  });

  group('本组结束', () {
    test('结束后出汇总，且与逐次判定同源', () {
      final fixture = _Fixture();
      // 120° 未达到 100° 的深度线 → 每次都应判出「下蹲深度不足」。
      // 反过来 80° 是蹲得比要求的还深，不该报错 —— 深度线是「膝角必须
      // 不大于」，方向搞反的话这条会绿、而「浅蹲被丢弃」那条会红。
      for (var i = 0; i < 3; i++) {
        fixture.doRep(bottomDeg: 120);
      }
      fixture.session.finishSet();

      final view = fixture.session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(view.summary, isNotNull);
      expect(view.summary!.repCount, view.repCount);
      expect(view.summary!.faultStats, isNotEmpty);
    });

    test('结束后管线上残留的帧不再改变任何东西', () {
      final fixture = _Fixture();
      fixture.doRep();
      fixture.session.finishSet();
      final frozen = fixture.session.view.value;

      fixture.doRep();

      expect(fixture.session.view.value.repCount, frozen.repCount);
      expect(fixture.session.view.value.phase, SessionPhase.finished);
    });

    test('新开一组：清计数与反馈，但保留标定，不用再站一次', () {
      final fixture = _Fixture();
      fixture.doRep();
      fixture.session.finishSet();

      fixture.session.startNewSet();

      final view = fixture.session.view.value;
      expect(view.phase, SessionPhase.position);
      expect(view.repCount, 0);
      expect(view.lastRep, isNull);
      expect(view.summary, isNull);
      // 门禁窗口被清了，得重新站；但标定还在，所以点开始就能直接数。
      for (var i = 0; i < 25; i++) {
        fixture.feedOne(squatPose(standDeg, timestampMs: 0));
      }
      expect(fixture.session.beginCalibration(), isTrue);
      fixture.doRep();
      expect(fixture.session.view.value.repCount, 1);
    });

    test('没在计数时结束本组是空操作', () {
      final session = SquatSession(thresholds: _table());
      session.finishSet();

      expect(session.view.value.phase, SessionPhase.position);
      expect(session.view.value.summary, isNull);
    });
  });

  group('参考分', () {
    // 分数是给人看的，所以这里的断言全是**屏幕上说不说得通**这一类：
    // 有没有数、跟反馈对不对得上、换一组会不会把上一组的带过来。

    test('每数到一个 rep 就有一个分数，且与那次的反馈同时出现', () {
      final fixture = _Fixture();
      expect(fixture.session.view.value.lastRepScore, isNull);

      fixture.doRep(bottomDeg: 120); // 深度不足

      final view = fixture.session.view.value;
      expect(view.lastRep, isNotNull);
      expect(view.lastRepScore, isNotNull);
      expect(view.lastRepScore!.score, inInclusiveRange(0, 100));
      // 同一时刻一起更新，所以“第 N 次的错误配第 M 次的分数”不可能发生。
      expect(view.lastRep!.repIndex, view.repCount);
    });

    test('每次 rep 的分数跟着那一次的错误走，不是整组的平均分', () {
      final fixture = _Fixture();
      fixture.doRep(bottomDeg: 120); // 深度不足 → 扣分
      final shallow = fixture.session.view.value.lastRepScore!.score;

      fixture.doRep(bottomDeg: 80); // 蹲到位 → 不该扣分
      final deep = fixture.session.view.value.lastRepScore!.score;

      expect(deep, greaterThan(shallow));
      expect(deep, 100);
    });

    test('本组结束后出组级分数，与逐次那个不是一回事', () {
      final fixture = _Fixture();
      for (var i = 0; i < 3; i++) {
        fixture.doRep(bottomDeg: 120);
      }
      expect(fixture.session.view.value.lastRepScore, isNotNull);

      fixture.session.finishSet();

      final view = fixture.session.view.value;
      expect(view.setScore, isNotNull);
      expect(view.setScore!.score, inInclusiveRange(0, 100));
      // 三次都犯了同一个错 → 出现率 1.0，组级扣分不该比单次更轻。
      expect(view.setScore!.score, lessThanOrEqualTo(view.lastRepScore!.score));
    });

    // 「随包那一份阈值表算出来一定是参考分」由 `form_score_test.dart` 里的
    // 「随包发出的那五个权重」一条负责 —— 本文件的表是本地的 literature 表，
    // 在这里断言 provisional 只会测出这张表是假的。

    test('新开一组会把上一组的分数清掉', () {
      final fixture = _Fixture();
      fixture.doRep(bottomDeg: 120);
      fixture.session.finishSet();
      expect(fixture.session.view.value.setScore, isNotNull);

      fixture.session.startNewSet();

      final view = fixture.session.view.value;
      expect(view.setScore, isNull);
      expect(view.lastRepScore, isNull);
      // 与上一组的反馈卡片一起清 —— 留着任何一个都会让人以为那是本组的。
      expect(view.lastRep, isNull);
      expect(view.summary, isNull);
    });

    test('一个都没数到时没有组级分数，不是一个满分', () {
      final fixture = _Fixture();
      fixture.session.finishSet();

      final view = fixture.session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(view.summary!.repCount, 0);
      expect(view.setScore, isNull);
    });
  });

  group('站着不动自动收工', () {
    // **用户在两米开外，够不到「结束本组」那个按钮。** 45° 斜机位本来就把
    // 人和手机分开了，做完一组还要走回来按一下，等于要求他为了一个按钮
    // 放弃刚才的站位。所以站直不动够久就自动结束。

    test('数到过 rep 之后，站直够久会自己结束并出汇总', () {
      final fixture = _Fixture(warmupReps: 1);

      // 门槛是 5 秒，一帧 33 ms —— 喂 200 帧（6.6 秒）留足余量。
      fixture._feed(standFrames(count: 200, startTimestampMs: fixture._clock));

      final view = fixture.session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(view.summary, isNotNull);
      // 汇总必须和手动结束同源 —— 否则自动收工会给出一份不一样的数。
      expect(view.summary!.repCount, view.repCount);
      expect(view.repCount, 1);
    });

    test('只站一小会儿不算结束 —— 组内的停顿是常事', () {
      final fixture = _Fixture(warmupReps: 1);

      fixture._feed(standFrames(count: 10, startTimestampMs: fixture._clock));

      expect(fixture.session.view.value.phase, SessionPhase.counting);
    });

    test('一个 rep 都没数到时不会自己结束', () {
      // 否则用户刚站好、还没开始动，这一组就被结束了。
      final fixture = _Fixture();

      fixture._feed(standFrames(count: 90, startTimestampMs: fixture._clock));

      expect(fixture.session.view.value.phase, SessionPhase.counting);
    });

    test('中途动过就重新计时，不累加', () {
      final fixture = _Fixture(warmupReps: 1);

      // 两次各站 0.8 秒（加上动作尾巴也远不到 5 秒），中间蹲一下把计时清掉。
      for (var i = 0; i < 2; i++) {
        fixture._feed(standFrames(count: 24, startTimestampMs: fixture._clock));
        expect(fixture.session.view.value.phase, SessionPhase.counting,
            reason: '每次单独算都不到门槛，不能因为「累计」而结束');
        fixture.doRep();
      }
    });

    test('帧时间戳为 0 时不自动结束 —— 没有时钟就不做时间上的判断', () {
      final fixture = _Fixture(warmupReps: 1);

      for (var i = 0; i < 60; i++) {
        fixture.feedOne(squatPose(standDeg, timestampMs: 0));
      }

      expect(fixture.session.view.value.phase, SessionPhase.counting);
    });

    test('自动结束后再开一组，计时从头开始', () {
      final fixture = _Fixture(warmupReps: 1);
      fixture._feed(standFrames(count: 200, startTimestampMs: fixture._clock));
      expect(fixture.session.view.value.phase, SessionPhase.finished);

      fixture.session.startNewSet();
      for (var i = 0; i < 25; i++) {
        fixture.feedOne(squatPose(standDeg, timestampMs: fixture._clock));
      }
      fixture.session.beginCalibration();
      fixture.doRep();
      // 新的一组只站了很短一会儿。**上一组残留的计时起点若没被清掉，
      // 这里会因为「距那个起点已经过去十几秒」而当场结束。**
      fixture._feed(standFrames(count: 10, startTimestampMs: fixture._clock));

      expect(fixture.session.view.value.phase, SessionPhase.counting);
    });
  });
}
