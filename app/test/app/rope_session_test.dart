/// 跳绳在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/rope_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **基线集漏了 `footHeight`** —— 它是三条分段线的零点。漏了它（或者让标定器
///   退回默认三基线集）的表现是标定条卡在 0、屏幕无报错、永远进不了计数。
/// - **必需点名单里没有脚尖** —— 跳绳离了 `foot_index` 连「有没有离地」都判不了，
///   而**站对了的人也可能因为两只脚出画而一次都数不上**。
/// - **[ActionSpec.framingHint] 没说要架稳手机** —— 全仓库只有这个动作拿
///   **画面下缘**当零点，「离地」相对的是地面而不是本人；手机一动这条线就跟着动。
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

import '../support/synthetic_rope.dart';

/// 随包发出的阈值表。与 `test/domain/rope_test.dart` 的「真实阈值表」组同款。
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

/// 帧时间戳连续的投喂器。与 `jj_session_test.dart` 同款。
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

  /// 喂一段「人不在画面里」。
  ///
  /// 真机上这就是相机检不出人 —— 会话收到的是 `null`，不是一帧坏姿态。
  /// **时钟照走**：丢帧期间时间在流逝，`interruptionThresholdMs` 量的正是它。
  void feedLoss(int frames) {
    for (var i = 0; i < frames; i++) {
      session.feed(null);
      clock += 33;
    }
  }
}

/// 走到「计数中」的会话，附带投喂器。**收尾时人双脚站在地面上。**
///
/// 标定用的就是这个站姿，而且**必须是它**：跳绳的 `footHeight` 基线代表
/// 「脚尖高出画面下缘多少」，只有站在地面上才成立（见 `rope.dart` 文件头）。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: ropeSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(ropeStandingFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(ropeStandingFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

/// 按 spec 装一台门禁 —— 与会话里装法逐字相同的那几项。
CameraPositionMonitor _monitorFor(ActionSpec spec, List<PoseFrame> frames) {
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

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: ropeSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(ropeStandingFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(ropeStandingFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '站立基线攒够之后应当自动进计数。**这一步同时证明基线集是对的** ——'
            '跳绳的第三个基线量是 `footHeight`（脚尖高出画面下缘多少），'
            '若这一项没被采到，`Calibrator` 会一直返回 `null`：标定条卡在 0、'
            '不报错，而这行断言只会说「还没到计数」',
      );

      driver.feed(ropeRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final view = session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(
        view.repCount,
        1,
        reason: '站 → 腾空 → 落地缓冲 → 站回地面是一次标准跳绳。数不上通常是'
            '防抖参数被换回引擎默认（那一组会把状态机拖慢一整个相位），'
            '或者是分段线/基线零点被动过',
      );
      expect(view.discardedReps, 0);
      expect(view.summary, isNotNull);
      expect(
        view.setScore,
        isNotNull,
        reason: '一次都没数到的一组返回 null 是对的；这里数到了，就该有分',
      );
      expect(
        view.setScore!.provisional,
        isTrue,
        reason: '随包的阈值全是 pending_review，分数必须带「暂定」标',
      );
    });

    test('标准一跳在真实阈值下一条错误都不命中', () {
      // 领域层那条同样的断言用的是内联表。这一条问的是**随包的数值**会不会
      // 把标准动作误判 —— 内联表的数值只为本测试服务，管不着这件事。
      //
      // 这一条对跳绳格外要紧：随包的缓冲阈值（150°）离合成帧里「有缓冲」的
      // 读数（150°）只差一点，而它与封存线（站立 175° − 8° = 167°）的关系
      // 决定了这条判定会不会对每一个人都命中。缝一窄，这条测试就会红 ——
      // 那正是它要拦住的事。
      final (session, driver) = _countingSession();

      driver.feed(ropeRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final summary = session.view.value.summary!;
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
      );
    });

    test('标定期丢一次人，重来之后仍然标定得完', () {
      // **专抓接缝的侧门。** 标定期丢帧会让会话重建标定器
      //（`squat_session.dart` 的 `_onLostFrame`）。那一处漏改的表现与主线那次
      // 一模一样：标定条卡在 0、屏幕无报错 —— 而它几个月都未必被触发一次。
      // 跳绳比别的动作更怕这一处：它的基线集多一个 `footHeight`，
      // 退回默认三基线集之后仍然「能标定完」（另外两项采得到），
      // 于是坏的地方只在**分段线零点**上，而那是一次数不上的种子。
      final session = SquatSession(thresholds: _realTable(), spec: ropeSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(ropeStandingFrames(count: 20));
      expect(session.beginCalibration(), isTrue);

      driver.feed(ropeStandingFrames(count: 5, startTimestampMs: driver.clock));
      expect(session.view.value.calibrationFrames, greaterThan(0));

      driver.feedLoss(3);
      expect(
        session.view.value.phase,
        SessionPhase.position,
        reason: '标定期人走了，这次标定作废、退回自检',
      );
      expect(session.view.value.calibrationFrames, 0);

      driver.feed(ropeStandingFrames(count: 20, startTimestampMs: driver.clock));
      expect(session.beginCalibration(), isTrue, reason: '重新站好之后要能重来');
      driver.feed(ropeStandingFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '重建的那台标定器必须仍然是跳绳那一套基线集',
      );
    });
  });

  group('站位门禁', () {
    test('45° 斜前方放行 —— 跳绳与深蹲同向，要侧身', () {
      // 跳绳的分段信号 `foot_height_ratio` 与单脚跳判定用的 `foot_gap_ratio`
      // 都声明 `[sagittal, oblique45]`，所以主链路机位就是它的机位。
      final report = _monitorFor(
        ropeSpec,
        ropeStandingFrames(count: 30),
      ).report;
      expect(report.view, CameraView.sagittal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isFalse);
      expect(report.canStart, isTrue);
    });

    test('正视拦住跳绳 —— 分段信号在那个机位下不可用', () {
      // 正视下 `foot_height_ratio` 与 `foot_gap_ratio` 都判 `view_mismatch`：
      // 特征不可用时**规则不命中、也不报错**，而这里更重一层 ——
      // `foot_height_ratio` 是分段信号，没了它状态机永远不离开 `GROUND`，
      // 一次都数不上，HUD 上却一直显示着正确的「双脚着地」。
      final report = _monitorFor(ropeSpec, ropeFacingFrontFrames()).report;

      expect(report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isTrue);
      expect(report.canStart, isFalse);
    });

    test('拦人时说的是跳绳自己的话，不是深蹲或开合跳那一句', () {
      final report = _monitorFor(ropeSpec, ropeFacingFrontFrames()).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingFront,
      );
      expect(issue.message, ropeSpec.blockingAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句解释的是「膝盖的弯曲看不出来」—— 跳绳不是这么失效的',
      );
      expect(issue.message, isNot(jjFrontalAdvice));
      expect(issue.message, isNot(puSpec.blockingAdvice));
    });

    test('起始提示说的是「把手机架稳」，不是立定跳远那句', () {
      // 这一句三处都用（自检清单、计数屏、开跳前的语音，见 `ActionSpec.framingHint`），
      // 而它在跳绳上承担的是**这个动作唯一成立的前提**：全仓库只有它拿画面下缘
      // 当零点（`foot_height_ratio`），而「离地」相对的是地面、不是本人 ——
      // 手机跟着转，这条线就跟着动，判定全歪而不报错。
      expect(ropeSpec.framingHint, isNotNull);
      expect(ropeSpec.framingHint, contains('架稳'));
      expect(ropeSpec.framingHint, isNot(sljSpec.framingHint));
    });

    test('左脚跟出画不拦跳绳，但同一批帧照样拦深蹲', () {
      // 跳绳的名单里**没有脚跟**：它三条判定一条都不碰脚跟（不判脚跟离地），
      // 标定也不采（`ropeSpec.calibrationBaselines` 里是 `footHeight`，
      // 不是 `heelRiseRatio`）。带上它的后果是侧身跳绳的人左脚一出画就被拦住，
      // 拦他的理由说的是「脚跟离地判定做不了」—— 一件这个动作根本不做的事。
      expect(ropeSpec.requiredLandmarks, isNot(contains(L.leftHeel)));

      final frames = [
        for (var i = 0; i < 30; i++)
          ropePose(
            timestampMs: i * 33,
            visibilityOverrides: const {L.leftHeel: 0.0},
          ),
      ];

      final rope = _monitorFor(ropeSpec, frames);
      expect(
        rope.report.issues.map((i) => i.code),
        isNot(contains(PositionIssueCode.missingLeftFoot)),
      );

      // 对照组：同一批帧喂给深蹲，必须照样为左脚跟出画拦人 ——
      // 少了它，这条测试在「那条判据整个失效」时也会绿。
      final squat = _monitorFor(squatSpec, frames);
      expect(
        squat.report.issues.map((i) => i.code),
        contains(PositionIssueCode.missingLeftFoot),
      );
    });

    test('两只脚尖都出画：拦跳绳，且病因说的是「数不出数」', () {
      // **这是跳绳与深蹲共用的那类点里最容易说错病因的一处。**
      // 两支都要脚尖，但理由完全不同：深蹲缺的是脚跟（少判一条），
      // 跳绳缺的是脚尖（`foot_height_ratio` 的分子 —— 分段信号，
      // 缺了就是 0 个计数）。共用一个码的话，跳绳用户被拦住时屏幕上说的是
      // 「脚跟离地判定做不了」，真正的原因一个字都没说。
      final frames = [
        for (var i = 0; i < 30; i++)
          ropePose(
            timestampMs: i * 33,
            visibilityOverrides: const {
              L.leftFootIndex: 0.0,
              L.rightFootIndex: 0.0,
            },
          ),
      ];

      final rope = _monitorFor(ropeSpec, frames);
      final codes = rope.report.issues.map((i) => i.code).toList();
      expect(codes, contains(PositionIssueCode.missingFeet));
      expect(
        codes,
        isNot(contains(PositionIssueCode.missingLeftFoot)),
        reason: '两条拦人提示同时出现时，其中一条说着这个动作从来不做的事',
      );
      expect(rope.report.blocking, isTrue);

      // 对照组：深蹲要脚跟，所以它走的是 `missingLeftFoot` 那一路，
      // 而**不该**冒出跳绳这条。少了它，两个码哪天被合并成一条也看不出来。
      final squat = _monitorFor(squatSpec, frames);
      final squatCodes = squat.report.issues.map((i) => i.code).toList();
      expect(squatCodes, contains(PositionIssueCode.missingLeftFoot));
      expect(squatCodes, isNot(contains(PositionIssueCode.missingFeet)));
    });
  });
}
