/// 开合跳在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/jj_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **基线集没换成开合跳那一套** —— 正视机位下 `heel_rise_ratio_L` 恒不可用，
///   沿用默认三基线集的话 `Calibrator.feed` 永远返回 `null`：标定条卡在 0、
///   屏幕上没有任何错误。**这是本轮唯一一处「不改共享组件就做不成这个动作」**，
///   所以「正视帧能标定完」这一条是这一组里最值钱的。
/// - **站位文案忘了换成开合跳的** —— 深蹲那句「请侧身 45°」对开合跳正好是
///   叫他做一个会让这个动作失效的动作，而屏幕上一切正常。
/// - **必需点名单照抄了深蹲的** —— 正对镜头做开合跳的人左脚一出画就被拦住，
///   拦他的理由说的是「脚跟离地判定做不了」，一件这个动作根本不做的事。
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
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_jj.dart';

/// 随包发出的阈值表。与 `test/domain/jj_test.dart` 的「真实阈值表」组同款。
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

/// 帧时间戳连续的投喂器。
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

/// 走到「计数中」的会话，附带投喂器。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: jjSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(jjStandFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(jjStandFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: jjSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(jjStandFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(jjStandFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '站立基线攒够之后应当自动进计数。**这一步同时证明基线集是对的** ——'
            '若它沿用默认三基线集，正视机位下脚跟抬升比恒不可用，'
            '标定会一直卡在 0 且不报错，而这行断言只会说「还没到计数」',
      );

      driver.feed(jjRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final view = session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(view.repCount, 1);
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
      final (session, driver) = _countingSession();

      driver.feed(jjRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final summary = session.view.value.summary!;
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
      );
    });
  });

  group('正面机位', () {
    test('正视站立帧能标定完 —— 这一条就是标定接缝的真机形态', () {
      // 走完整条会话而不是直接构造 `Calibrator`：会话里那台标定器是在
      // **四个时机**分别建出来的（字段初始化、开始标定、复位、标定期丢帧重来），
      // 漏掉任何一个都会让开合跳退回默认三基线集。只测一个构造点等于没测。
      final (session, _) = _countingSession();

      // 反过来说明「上面走到 counting」确实是基线集的功劳，而不是碰巧：
      // 同一批帧喂给一台**要求默认三基线集**的标定器，永远采不满。
      final extractor = FeatureExtractor(cameraView: CameraView.frontal);
      final legacy = Calibrator(minFrames: 5);
      for (var i = 0; i < 30; i++) {
        expect(
          legacy.feed(
            extractor.extract(jjStandFrames(count: 1).single),
          ),
          isNull,
          reason: '正视机位下脚跟抬升比恒不可用，这一帧应当整帧丢弃',
        );
      }
      expect(
        legacy.isReady,
        isFalse,
        reason: '默认三基线集在正视下恒采不满 —— 这正是开合跳必须自己带基线集的原因',
      );
      expect(session.view.value.phase, SessionPhase.counting);
    });

    test('标定期丢一次人，重来之后仍然标定得完', () {
      // **专抓接缝的侧门。** 标定期丢帧会让会话重建标定器
      //（`squat_session.dart` 的 `_onLostFrame`）。那一处漏改的表现与主线那次
      // 一模一样：标定条卡在 0、屏幕无报错 —— 而它几个月都未必被触发一次。
      final session = SquatSession(thresholds: _realTable(), spec: jjSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(jjStandFrames(count: 20));
      expect(session.beginCalibration(), isTrue);

      // 先走一点进度，再把人弄丢 —— 否则「重来」与「刚开始」分不出来。
      driver.feed(jjStandFrames(count: 5, startTimestampMs: driver.clock));
      expect(session.view.value.calibrationFrames, greaterThan(0));

      driver.feedLoss(3);
      expect(
        session.view.value.phase,
        SessionPhase.position,
        reason: '标定期人走了，这次标定作废、退回自检',
      );
      expect(session.view.value.calibrationFrames, 0);

      driver.feed(jjStandFrames(count: 20, startTimestampMs: driver.clock));
      expect(session.beginCalibration(), isTrue, reason: '重新站好之后要能重来');
      driver.feed(jjStandFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '重建的那台标定器必须仍然是开合跳那一套基线集',
      );
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

    test('正视放行，而深蹲在同一批帧上被拦住 —— 极性真的反了', () {
      // 同一批帧喂给两个动作，结论必须相反。只断言「开合跳放行」的话，
      // 一台永远放行的门禁也是绿的。
      final frames = jjStandFrames(count: 30);

      final jj = monitorFor(jjSpec, frames);
      expect(jj.report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(jj.report.blocking, isFalse, reason: '正视是开合跳要的站位');
      expect(jj.report.canStart, isTrue);

      final squat = monitorFor(squatSpec, frames);
      expect(
        squat.report.blocking,
        isTrue,
        reason: '同一个站位，深蹲必须拦住 —— 否则下面那条「文案各说各的」是在比两个都没说的话',
      );
    });

    test('45° 与完全侧对都拦住 —— 不是「只有侧对才拦」', () {
      // **45° 必须一起拦。** 它看起来「转回来一点了」，但额状面的两个量在
      // 45° 下同样判为机位不匹配、直接不可用 —— 那是同一种失效，只是轻一点。
      // 只拦侧视的话，用户会停在 45° 上做出一整组量不出分腿幅度的动作，
      // 而屏幕上只写着一句「请正对镜头」，他会以为自己已经站对了。
      for (final scale in const [0.3, 0.1]) {
        final report = monitorFor(jjSpec, jjStandFrames(count: 30, lateralScale: scale)).report;
        expect(
          report.view,
          isNot(CameraView.frontal),
          reason: 'lateralScale=$scale 应当被读成非正视（读到 ${report.view}）',
        );
        expect(
          report.blocking,
          isTrue,
          reason: 'lateralScale=$scale（${report.view}）必须拦住',
        );
      }
    });

    test('拦人时说的是开合跳自己的话，不是深蹲那句', () {
      final report =
          monitorFor(jjSpec, jjStandFrames(count: 30, lateralScale: 0.3)).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.notFacingFront,
      );
      expect(issue.message, jjFrontalAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句叫他「请侧身 45°」—— 对开合跳正好是叫他做一个让这个动作失效的动作',
      );
      expect(issue.message, isNot(contains('请侧身')));
    });

    test('站对了就不说话 —— 开合跳没有提示级的站位偏差', () {
      final report = monitorFor(jjSpec, jjStandFrames(count: 30)).report;
      expect(
        report.issues,
        isEmpty,
        reason: '站对了还留一条提示，用户会去改一个本来没错的东西：'
            '${report.issues.map((i) => i.message).toList()}',
      );
    });

    test('左脚出画不拦开合跳 —— 它不判脚跟离地', () {
      // 名单里没有 `leftHeel` / `leftFootIndex`，而报告只对**名单里有的**点
      // 出「左脚出画」那条。少了这一层参数化，正对镜头做开合跳的人左脚一出画
      // 就会被拦住，拦他的理由说的是「脚跟离地判定做不了」——
      // 一件这个动作根本不做的事。
      expect(jjSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(jjSpec.requiredLandmarks, isNot(contains(L.leftFootIndex)));

      final frames = [
        for (var i = 0; i < 30; i++)
          jjPose(
            timestampMs: i * 33,
            visibilityOverrides: const {
              L.leftHeel: 0.0,
              L.leftFootIndex: 0.0,
            },
          ),
      ];

      final jj = monitorFor(jjSpec, frames);
      expect(jj.report.canStart, isTrue, reason: '开合跳不该为左脚出画拦人');
      expect(
        jj.report.issues.map((i) => i.code),
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
