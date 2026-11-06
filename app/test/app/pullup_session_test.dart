/// 引体向上在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/pullup_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **站位方向接反** —— 引体向上要侧身（正对镜头时前后摆动在画面上看不出来，
///   `PULLUP_SWING` 会静默地变成一条永不触发的规则）。接反的话正视的人能进去，
///   而整组结束时报告里只字不提借力。
/// - **必需点名单照抄了深蹲的** —— 名单里有没有脚跟，决定挂在杠上的人左脚出画
///   会不会被拦住，也决定拦他的理由是不是「脚跟离地判定做不了」。
/// - **基线集多采了一个没人读、含义还是错的量** —— 标定时这个人是**挂在杠上**的，
///   下标定采出来的「站立基线」按定义就不是站立姿势下的数（见 `pullupSpec`）。
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

import '../support/synthetic_pullup.dart';

/// 随包发出的阈值表。与 `test/domain/pullup_test.dart` 的「真实阈值表」组同款。
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

/// 帧时间戳连续的投喂器。与 `pu_session_test.dart` 同款。
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
///
/// 标定期间喂的是**直臂悬垂**的帧 —— 引体向上的标定就是在杠上完成的，
/// 这也是本项目里唯一一个「站立基线不是在站着的时候采的」动作。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: pullupSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(pullupHangFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(pullupHangFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

/// 造一批「门禁读成正视」的帧。
///
/// `lateralRatio` 算的是「肩距与髋距的均值 ÷ 躯干长」，而合成骨架里两侧只差
/// 一条 0.01 的横向缝、躯干长 0.20 —— 侧视下是 0.05。把那条缝放大 20 倍就过
/// `frontalRatio`（0.62）。**这不是一个物理上站得住的「正视引体向上」** ——
/// 它只对「门禁给出什么结论」这一件事有意义，见 `synthetic_pullup.dart` 里
/// `sideGapScale` 的注释。
List<PoseFrame> _facingFrontFrames({int count = 30, double scale = 20.0}) => [
      for (var i = 0; i < count; i++)
        pullupPose(timestampMs: i * 33, sideGapScale: scale),
    ];

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: pullupSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(pullupHangFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(pullupHangFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '挂在杠上攒够基线之后应当自动进计数。引体向上只采框架强制要求的'
            '两项（`BaselineKey.alwaysRequired`），所以这一步同时证明'
            '「只采两项也能标定完」，以及「下标定用的直臂悬垂姿势是稳的」',
      );

      driver.feed(pullupRepFrames(startTimestampMs: driver.clock));
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
      // 引体向上这三条尤其要问一遍：其中一条的阈值是**负数**
      // （`pullup.chin_over_dy_max`，下颌过杠在那个带符号的量上就是负值），
      // 谁把符号弄反都会在这里露出来。
      final (session, driver) = _countingSession();

      driver.feed(pullupRepFrames(startTimestampMs: driver.clock));
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

    test('侧身 45° 是引体向上要的 —— 而同一批帧把开合跳拦在外面', () {
      // 引体向上回到主链路，站位要求与深蹲、俯卧撑同向。**但这不是「照抄深蹲」**：
      // 它必须与开合跳的结论相反，否则下面那条「文案各说各的」是在比两个
      // 都没说的话。
      final frames = [
        for (var i = 0; i < 30; i++) pullupPose(timestampMs: i * 33, sideGapScale: 8.0),
      ];

      final pullup = monitorFor(pullupSpec, frames);
      expect(pullup.report.view, CameraView.oblique45, reason: '这条前提要成立才有意义');
      expect(pullup.report.blocking, isFalse, reason: '45° 正是引体向上要的站位');
      expect(pullup.report.canStart, isTrue);

      final jj = monitorFor(jjSpec, frames);
      expect(
        jj.report.blocking,
        isTrue,
        reason: '同一个站位，开合跳必须拦住 —— 它要的是正视',
      );
    });

    test('正视拦住引体向上 —— 摆动那条在那样的站位下会一直不响', () {
      // 这一条与俯卧撑那条**不是同一回事**，必须分开说：俯卧撑正视时
      // `body_line_offset_ratio` 声明了机位门控，特征直接不可用、规则消失；
      // 而引体向上那三个特征**一个门控都没有** —— 正对镜头时特征照样算得出数，
      // 只是 `trunk_lean` 量的是「在画面上偏离竖直多少」，不再表示身体前后荡没荡。
      // 所以这里是**语义**消失而不是数值消失，屏幕上一样不报错。
      final report = monitorFor(pullupSpec, _facingFrontFrames()).report;

      expect(report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isTrue);
      expect(report.canStart, isFalse);
    });

    test('拦人时说的是引体向上自己的话，不是深蹲或开合跳那一句', () {
      final report = monitorFor(pullupSpec, _facingFrontFrames()).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingFront,
      );
      expect(issue.message, pullupSpec.blockingAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句解释的是「膝盖的弯曲看不出来」—— 引体向上不是这么失效的',
      );
      expect(issue.message, isNot(jjFrontalAdvice));
    });

    test('完全侧对只提示、不拦 —— 那时三条判定其实都还在', () {
      // 与俯卧撑、跳绳同一种处境：纯侧视下远侧手臂容易被躯干挡住，
      // 肘角会时断时续（守卫用一侧可见时的均值兜着），但计数照常。
      // 所以这里是**提示级**，不是拦人级 —— 拦了的话，用户会去改一个
      // 本来就能数的站位。
      final report = monitorFor(pullupSpec, pullupHangFrames(count: 30)).report;

      expect(report.view, CameraView.sagittal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isFalse, reason: '纯侧视下有缺点，但数得着');
      expect(report.canStart, isTrue);

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingSide,
      );
      expect(issue.message, pullupSpec.advisoryAdvice);
      expect(issue.blocking, isFalse);
    });

    test('左脚出画不拦引体向上 —— 它不判脚跟离地', () {
      // 名单里没有 `leftHeel` / `leftFootIndex`：引体向上四条判定一条都不碰它们，
      // 标定也不采（`pullupSpec.calibrationBaselines` 只有两项）。带上它们的后果是
      // 挂在杠上的人左脚一出画就被拦住，拦他的理由说的是「脚跟离地判定做不了」——
      // 一件这个动作根本不做的事。
      expect(pullupSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(pullupSpec.requiredLandmarks, isNot(contains(L.leftFootIndex)));

      final frames = [
        for (var i = 0; i < 30; i++)
          pullupPose(
            timestampMs: i * 33,
            visibilityOverrides: const {
              L.leftHeel: 0.0,
              L.leftFootIndex: 0.0,
            },
          ),
      ];

      final pullup = monitorFor(pullupSpec, frames);
      expect(pullup.report.canStart, isTrue, reason: '引体向上不该为左脚出画拦人');
      expect(
        pullup.report.issues.map((i) => i.code),
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

    test('手看不见拦不住任何人，而计数会静默地变成 0 —— 现状钉在这里', () {
      // **这条断言不是「这样没问题」，是把现状钉住。**
      //
      // 名单里有双腕（`pullupSpec.requiredLandmarks`），但门禁的缺失判据只有
      // 「躯干 / 腿 / 左脚」三组 —— 名单里超出这三组的点今天**不产生 blocking**
      // （这条边界记在 `camera_position_check_test.dart` 里）。而手腕恰恰是
      // `elbow_angle_*` 的完整依赖：手看不见，肘角算不出来，状态机永远停在
      // `HANG`，**一次都数不上、屏幕上不报任何错**。
      //
      // 产品上靠两句话兜着：`pullupSpec.framingHint`（架手机时就说清楚），
      // 以及 `PoseQualityTracker` 的覆盖率 —— 它用的是**同一份名单**，
      // 所以手腕出画会在导出的 `pose_quality` 里记上一笔。
      // 门禁本身不拦，是记下来的边界，不是默认它不存在。
      final frames = [
        for (var i = 0; i < 40; i++)
          pullupPose(
            timestampMs: i * 33,
            visibilityOverrides: const {L.leftWrist: 0.0, L.rightWrist: 0.0},
          ),
      ];

      expect(
        monitorFor(pullupSpec, frames).report.blocking,
        isFalse,
        reason: '门禁不管手腕 —— 这一条就是在钉这件事',
      );

      final session = SquatSession(thresholds: _realTable(), spec: pullupSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);
      driver.feed(frames);
      expect(session.beginCalibration(), isTrue, reason: '照样能进标定');
      driver.feed([
        for (var i = 0; i < 40; i++)
          pullupPose(
            timestampMs: driver.clock + i * 33,
            visibilityOverrides: const {L.leftWrist: 0.0, L.rightWrist: 0.0},
          ),
      ]);
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '肘角不可用不影响标定（标定只采膝角与躯干倾角）',
      );

      driver.feed(pullupRepFrames(
        startTimestampMs: driver.clock,
        visibilityOverrides: const {L.leftWrist: 0.0, L.rightWrist: 0.0},
      ));
      session.finishSet();
      expect(
        session.view.value.repCount,
        0,
        reason: '一次都数不上 —— 而屏幕上不会有任何提示说手看不见',
      );
    });
  });
}
