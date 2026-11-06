/// 俯卧撑在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/pu_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **站位方向接反** —— 俯卧撑要侧身（45° 下 `body_line_offset_ratio` 才可用），
///   与开合跳正好相反。接反的话正视的人能进去，而那两条判定
///   **静默消失** —— 用户做完一整组，报告里只字不提塌腰。
/// - **必需点名单照抄了深蹲的** —— 名单里有没有脚跟，决定趴下之后左脚出画
///   会不会被拦住，也决定拦他的理由是不是「脚跟离地判定做不了」。
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

import '../support/synthetic_pu.dart';

/// 随包发出的阈值表。与 `test/domain/pu_test.dart` 的「真实阈值表」组同款。
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
}

/// 走到「计数中」的会话，附带投喂器。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: puSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(puTopFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(puTopFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

/// 造一批「门禁读成正视」的帧。
///
/// 侧视下 `lateralRatio` 是 0.05，放大那条 0.01 的横向缝 20 倍就过 `frontalRatio`
/// （0.62）。**这不是一个物理上站得住的「正视俯卧撑」** —— 它只对「门禁给出什么
/// 结论」这一件事有意义，见 `synthetic_pu.dart` 里 `sideGapScale` 的注释。
List<PoseFrame> _facingFrontFrames({int count = 30, double scale = 20.0}) => [
      for (var i = 0; i < count; i++)
        puPose(timestampMs: i * 33, sideGapScale: scale),
    ];

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: puSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(puTopFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(puTopFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '站立基线攒够之后应当自动进计数。俯卧撑只采框架强制要求的两项'
            '（`BaselineKey.alwaysRequired`），所以这一步同时证明'
            '「只采两项也能标定完」',
      );

      driver.feed(puRepFrames(startTimestampMs: driver.clock));
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

    test('标准一次在真实阈值下一条错误都不命中', () {
      // 领域层那条同样的断言用的是内联表。这一条问的是**随包的数值**会不会
      // 把标准动作误判 —— 内联表的数值只为本测试服务，管不着这件事。
      //
      // 这一条对俯卧撑格外要紧：塌腰/撅臀那两条的阈值是 ±0.10 而平直的身体读 0，
      // 看似余量很大，但那两条**共用同一个特征**，谁把符号弄反都会在这里露出来。
      final (session, driver) = _countingSession();

      driver.feed(puRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final summary = session.view.value.summary!;
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
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

    test('侧身 45° 是俯卧撑要的 —— 而同一批帧把开合跳拦在外面', () {
      // 俯卧撑回到主链路，站位要求与深蹲同向。**但这不是「照抄深蹲」**：
      // 它必须与开合跳的结论相反，否则下面那条「文案各说各的」是在比两个
      // 都没说的话。
      final frames = [
        for (var i = 0; i < 30; i++) puPose(timestampMs: i * 33, sideGapScale: 8.0),
      ];

      final pu = monitorFor(puSpec, frames);
      expect(pu.report.view, CameraView.oblique45, reason: '这条前提要成立才有意义');
      expect(pu.report.blocking, isFalse, reason: '45° 正是俯卧撑要的站位');
      expect(pu.report.canStart, isTrue);

      final jj = monitorFor(jjSpec, frames);
      expect(
        jj.report.blocking,
        isTrue,
        reason: '同一个站位，开合跳必须拦住 —— 它要的是正视',
      );
    });

    test('正视拦住俯卧撑 —— 两条判定在那样的站位下静默消失', () {
      // `body_line_offset_ratio` 声明 `[sagittal, oblique45]`。正视下
      // 「身体的前后方向」就是镜头方向本身，那个特征恒不可用，而**特征不可用时
      // 规则不命中、也不报错** —— 塌腰与撅臀会一起消失，报告里只字不提。
      final report = monitorFor(puSpec, _facingFrontFrames()).report;

      expect(report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isTrue);
      expect(report.canStart, isFalse);
    });

    test('拦人时说的是俯卧撑自己的话，不是深蹲或开合跳那一句', () {
      final report = monitorFor(puSpec, _facingFrontFrames()).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingFront,
      );
      expect(issue.message, puSpec.blockingAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句解释的是「膝盖的弯曲看不出来」—— 俯卧撑不是这么失效的',
      );
      expect(issue.message, isNot(jjFrontalAdvice));
    });

    test('完全侧对只提示、不拦 —— 那时四条判定其实都还在', () {
      // 与开合跳不同：俯卧撑的判据不是二元的。纯侧视下
      // `body_line_offset_ratio` 照常可用（它声明里有 `sagittal`），
      // 只是两条手臂在画面上重合、远侧那只容易被挡住，肘角会时断时续。
      // 所以这里是**提示级**，不是拦人级 —— 拦了的话，用户会去改一个
      // 本来就能数的站位。
      final report = monitorFor(puSpec, puTopFrames(count: 30)).report;

      expect(report.view, CameraView.sagittal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isFalse, reason: '纯侧视下有缺点，但数得着');
      expect(report.canStart, isTrue);

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingSide,
      );
      expect(issue.message, puSpec.advisoryAdvice);
      expect(issue.blocking, isFalse);
    });

    test('左脚出画不拦俯卧撑 —— 它不判脚跟离地', () {
      // 名单里没有 `leftHeel` / `leftFootIndex`：俯卧撑四条判定一条都不碰它们，
      // 标定也不采（`puSpec.calibrationBaselines` 只有两项）。带上它们的后果是
      // 趴下之后左脚一出画就被拦住，拦他的理由说的是「脚跟离地判定做不了」——
      // 一件这个动作根本不做的事。
      expect(puSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(puSpec.requiredLandmarks, isNot(contains(L.leftFootIndex)));

      final frames = [
        for (var i = 0; i < 30; i++)
          puPose(
            timestampMs: i * 33,
            visibilityOverrides: const {
              L.leftHeel: 0.0,
              L.leftFootIndex: 0.0,
            },
          ),
      ];

      final pu = monitorFor(puSpec, frames);
      expect(pu.report.canStart, isTrue, reason: '俯卧撑不该为左脚出画拦人');
      expect(
        pu.report.issues.map((i) => i.code),
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
