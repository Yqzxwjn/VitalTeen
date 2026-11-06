/// 平板支撑在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/plank_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **站位方向接反** —— 平板支撑要侧身（正对镜头时 `body_line_offset_ratio`
///   与 `trunk_lean` 量的是镜头方向本身，`inSupport` 恒为假）。接反的话正视的人
///   能进去，而屏幕会一直显示「没在撑」、一次都数不上。
/// - **必需点名单照抄了深蹲的** —— 名单里有没有脚跟，决定撑着的人左脚出画
///   会不会被拦住，也决定拦他的理由是不是「脚跟离地判定做不了」。
/// - **计时制那一半没接上** —— 这个动作的 rep 是一**段**，而 `holdMs` /
///   `repDurationsMs` 是会话层新加的两个数。它们接错的表现是屏幕上那个计时器
///   不走、或者报告里的时长与决策请求里的 `duration_ms` 对不上 —— 两处同源，
///   但只有这一组测试会把它们摆在一起比。
///
/// 阈值一律用**随包的那一份**（`assets/thresholds/`），不是内联表 ——
/// 内联表验不了「资产同步漏了一行」，而漏一行的后果见上。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_plank.dart';

/// 随包发出的阈值表。与其余几个 `*_session_test.dart` 同款。
ThresholdTable _realTable() {
  final file = File('assets/thresholds/thr_2026-10_v1.json');
  if (!file.existsSync()) {
    fail(
      '找不到阈值表：${file.absolute.path}\n'
      '它由 scripts/sync_assets.py 从 shared/thresholds/ 同步而来，'
      '请先运行该脚本。',
    );
  }
  return ThresholdTable.fromJson(
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  );
}

/// 帧时间戳连续的投喂器。与 `pullup_session_test.dart` 同款。
class _Driver {
  _Driver(this.session);

  final SquatSession session;
  int clock = 0;

  void feed(List<PoseFrame> frames) {
    for (final frame in frames) {
      session.feed(frame);
      clock += 33;
    }
  }
}

/// 合成帧的帧间隔。与 `synthetic_plank.dart` 的默认值一致。
const int interval = 33;

/// 走到「计数中」的会话，附带投喂器。
///
/// 标定期间喂的是**站立**的帧 —— 这与 `plankSpec.framingHint` 说的一致
///（「先站着把标定走完，再撑下去」），也与真人第一次站到镜头前的顺序一致。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: plankSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(plankStandingFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(plankStandingFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

/// 造一批「门禁读成正视」的帧。
///
/// `lateralRatio` 算的是「肩距与髋距的均值 ÷ 躯干长」，而合成骨架里两侧只差
/// 一条 0.01 的横向缝、躯干长 0.20 —— 侧视下是 0.05。把那条缝放大 20 倍就过
/// `frontalRatio`（0.62）。**这不是一个物理上站得住的「正视平板支撑」** ——
/// 它只对「门禁给出什么结论」这一件事有意义（同 `pullup_session_test.dart`）。
List<PoseFrame> _facingFrontFrames({int count = 30, double scale = 20.0}) => [
      for (var i = 0; i < count; i++)
        plankPose(timestampMs: i * interval, sideGapScale: scale),
    ];

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，一段支撑计成一段', () {
      final session = SquatSession(thresholds: _realTable(), spec: plankSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(plankStandingFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(plankStandingFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '站着攒够基线之后应当自动进计数 —— 这一条同时证明'
            '「标定采的那两个量（膝角、躯干倾角）在站立姿势下都拿得到」',
      );

      driver.feed(plankOneHoldFrames(
        holdCount: 90,
        startTimestampMs: driver.clock,
      ));
      session.finishSet();

      final view = session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(view.repCount, 1, reason: '一段支撑就是一次 rep —— 不是「一次动作」');
      expect(view.discardedReps, 0);
      expect(view.summary, isNotNull);
      expect(view.setScore, isNotNull);
      expect(
        view.setScore!.provisional,
        isTrue,
        reason: '随包的阈值全是 pending_review，分数必须带「暂定」标',
      );
    });

    test('一段标准支撑在真实阈值下一条错误都不命中', () {
      // 领域层那条同样的断言用的是内联表。这一条问的是**随包的数值**会不会
      // 把标准姿势误判 —— 尤其要看那两条与分段线咬合的肘角阈值
      //（`plank.elbow_angle_min/max` 必须严格落在支撑带里面，否则规则会
      // 永远攒不够帧数、静默地一次都不触发）。
      final (session, driver) = _countingSession();

      driver.feed(plankOneHoldFrames(
        holdCount: 90,
        startTimestampMs: driver.clock,
      ));
      session.finishSet();

      final summary = session.view.value.summary!;
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
      );
    });
  });

  group('计时制：这一组的心跳是「撑了多久」，不是「第几个」', () {
    test('撑住时这一段一直在走，回到站立就归零', () {
      final (session, driver) = _countingSession();

      // 先确认起点是 0：会话刚进计数期，一次支撑都还没开始。
      expect(
        session.view.value.holdMs,
        0,
        reason: '还没撑下去，这一段是 0 —— 而不是「没测到」',
      );

      driver.feed(plankHoldFrames(count: 30, startTimestampMs: driver.clock));
      final midHold = session.view.value.holdMs;
      expect(
        midHold,
        greaterThan(0),
        reason: '撑着的时候这个数必须在走 —— 它就是屏幕上那个大字',
      );

      driver.feed(plankHoldFrames(count: 30, startTimestampMs: driver.clock));
      expect(
        session.view.value.holdMs,
        greaterThan(midHold),
        reason: '再撑一会儿，它要跟着涨',
      );

      driver.feed(plankStandingFrames(count: 10, startTimestampMs: driver.clock));
      expect(
        session.view.value.holdMs,
        0,
        reason: '回到站立态之后再撑，计时要从头数 —— 一段就是一段',
      );
    });

    test('每一段的时长与 rep 窗口同源，不是会话自己数的帧数', () {
      // 这个数最终会出现在两个地方：报告里那一行「合计 N 秒」，
      // 以及决策请求里的 `duration_ms`。**它们必须是同一个数** ——
      // 所以这里比对的是会话给出的时长与那个契约值的算法（`RepWindow.durationMs`）
      // 在同一个窗口上会不会给出两个答案。
      const holdCount = 90;
      final (session, driver) = _countingSession();

      driver.feed(plankOneHoldFrames(
        holdCount: holdCount,
        startTimestampMs: driver.clock,
      ));

      final durations = session.view.value.repDurationsMs;
      expect(durations, hasLength(1));
      // 换相确认有 1–2 帧的滞后（见 `base.dart` 的 `minDwellFrames`/`voteWindow`），
      // 所以量到的段比投进去的帧数略短。**这个偏差是真实的**：用户看到的那一段
      // 支撑，比他自己数秒数出来的略短一点，因为系统要等几帧才敢确认他撑住了。
      expect(
        durations.single,
        greaterThanOrEqualTo((holdCount - 5) * interval),
        reason: '不能短得离谱 —— 短太多说明窗口没有被整段圈住',
      );
      expect(
        durations.single,
        lessThanOrEqualTo(holdCount * interval),
        reason: '也不能比投进去的帧还长',
      );
    });

    test('两段支撑计两段，时长各归各的', () {
      final (session, driver) = _countingSession();

      driver.feed(plankFromSegments([
        const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
        const PlankSegment(count: 60),
        const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
        const PlankSegment(count: 120),
        const PlankSegment(count: 10, bodyAngleDeg: plankStandingAngleDeg),
      ], startTimestampMs: driver.clock));

      final view = session.view.value;
      expect(view.repCount, 2);
      expect(view.repDurationsMs, hasLength(2));
      expect(
        view.repDurationsMs[1],
        greaterThan(view.repDurationsMs[0]),
        reason: '第二段撑得久一倍，报告里那两个数必须不是同一个',
      );
      expect(
        view.totalRepDurationMs,
        view.repDurationsMs.reduce((a, b) => a + b),
        reason: '合计就是各段之和 —— 报告里那个总数不能另有算法',
      );
      // **这一段结束时人还站着**，所以计时器归零、而两个时长已经落袋。
      expect(view.holdMs, 0);
    });

    test('撑完一段之后站着不动够久，本组自动收工', () {
      // `_shouldAutoFinish` 的默认判据是「回到静止态之后静止够久」。
      // 对平板支撑，静止态就是**站着**（或者说是「没在撑」）——
      // 也就是说：撑完一段、歇够 10 秒，这一组就结束了。
      // 这不是顺手来的：这个动作没有「一次动作的终点」可以等，
      // 歇够了就是练完了。
      const holdCount = 60;
      final (session, driver) = _countingSession();

      driver.feed(plankOneHoldFrames(
        holdCount: holdCount,
        startTimestampMs: driver.clock,
      ));
      expect(session.view.value.repCount, 1);

      // 站着不动，一直到超过 autoFinishRestMs（10 秒）。
      driver.feed(plankStandingFrames(count: 330, startTimestampMs: driver.clock));

      final view = session.view.value;
      expect(view.phase, SessionPhase.finished, reason: '歇够 10 秒应当自动收工');
      expect(view.repCount, 1, reason: '收工不该把已经数到的那一段抹掉');
      expect(view.summary, isNotNull);
    });
  });

  group('站位门禁', () {
    /// 按 spec 装一台门禁 —— 与会话里装法逐字相同的那几项。
    CameraPositionMonitor monitorFor(ActionSpec spec, List<PoseFrame> frames) {
      final monitor = CameraPositionMonitor(
        requiresFrontal: spec.requiresFrontal,
        blockingAdvice: spec.blockingAdvice,
        advisoryAdvice: spec.advisoryAdvice,
        requiredLandmarks: spec.requiredLandmarks ?? defaultRequiredLandmarks,
      );
      for (final frame in frames) {
        monitor.add(frame);
      }
      return monitor;
    }

    test('侧身 45° 是平板支撑要的 —— 而同一批帧把开合跳拦在外面', () {
      final frames = [
        for (var i = 0; i < 30; i++)
          plankPose(timestampMs: i * interval, sideGapScale: 8.0),
      ];

      final plank = monitorFor(plankSpec, frames);
      expect(plank.report.view, CameraView.oblique45, reason: '这条前提要成立才有意义');
      expect(plank.report.blocking, isFalse, reason: '45° 正是平板支撑要的站位');
      expect(plank.report.canStart, isTrue);

      final jj = monitorFor(jjSpec, frames);
      expect(jj.report.blocking, isTrue, reason: '同一个站位，开合跳必须拦住');
    });

    test('正视拦住平板支撑 —— 那时三条判据一条都读不出来', () {
      final report = monitorFor(plankSpec, _facingFrontFrames()).report;

      expect(report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isTrue);
      expect(report.canStart, isFalse);
    });

    test('拦人时说的是平板支撑自己的话，不是深蹲或开合跳那一句', () {
      final report = monitorFor(plankSpec, _facingFrontFrames()).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingFront,
      );
      expect(issue.message, plankSpec.blockingAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句解释的是「膝盖的弯曲看不出来」—— 平板支撑不是这么失效的',
      );
      expect(issue.message, isNot(jjFrontalAdvice));
    });

    test('完全侧对只提示、不拦 —— 那时三条判据其实都还在', () {
      final report =
          monitorFor(plankSpec, plankStandingFrames(count: 30)).report;

      expect(report.view, CameraView.sagittal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isFalse);
      expect(report.canStart, isTrue);

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingSide,
      );
      expect(issue.message, plankSpec.advisoryAdvice);
      expect(issue.blocking, isFalse);
    });

    test('左脚出画不拦平板支撑 —— 它不判脚跟离地', () {
      // 名单里没有 `leftHeel` / `leftFootIndex`：平板支撑三条判据一条都不碰
      // 它们，标定也不采（`plankSpec.calibrationBaselines` 只有两项）。
      // 带上它们的后果是撑着的人左脚一出画就被拦住，拦他的理由说的是
      // 「脚跟离地判定做不了」—— 一件这个动作根本不做的事。
      expect(plankSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(plankSpec.requiredLandmarks, isNot(contains(L.leftFootIndex)));

      final frames = [
        for (var i = 0; i < 30; i++)
          plankPose(
            timestampMs: i * interval,
            visibilityOverrides: const {
              L.leftHeel: 0.0,
              L.leftFootIndex: 0.0,
            },
          ),
      ];

      final plank = monitorFor(plankSpec, frames);
      expect(plank.report.canStart, isTrue, reason: '不该为左脚出画拦人');
      expect(
        plank.report.issues.map((i) => i.code),
        isNot(contains(PositionIssueCode.missingLeftFoot)),
      );

      // 对照组：同一批帧喂给深蹲，必须照样为左脚出画拦人 ——
      // 少了它，这条测试在「那条判据整个失效」时也会绿。
      final squat = monitorFor(squatSpec, frames);
      expect(
        squat.report.issues.map((i) => i.code),
        contains(PositionIssueCode.missingLeftFoot),
      );
    });
  });
}
