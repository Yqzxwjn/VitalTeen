/// 立定跳远在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/slj_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间
/// 隔着一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **站位建议忘了换成这个动作的** —— 深蹲那句「膝内扣判定会不可用」在
///   立定跳远上是错的：它没有膝内扣这条判定，损失的是「双脚是不是同时发力」。
///   用户照着一条不存在的后果去调整站位，而屏幕上一切正常。
/// - **机位不是 45°** —— 见「机位」那一组，这条最像注释里的断言，所以要把
///   它变成可执行的：**正视站位的人，特征一样算得出来**，唯一拦住他的是门禁。
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
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_slj.dart';

/// 随包发出的阈值表。与 `test/domain/slj_test.dart` 的「真实阈值表」组同款。
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
///
/// 站立帧的侧向比落在侧视档，门禁只提示、不拦人 —— 门禁本身另有测试。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: sljSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(sljStandFrames(count: 20));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(sljStandFrames(count: 20, startTimestampMs: driver.clock));
  expect(session.view.value.phase, SessionPhase.counting);
  return (session, driver);
}

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: sljSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      // 站立 → 过门禁 → 标定。门禁判的是画面上看起来的机位，
      // 合成站立帧的侧向比落在侧视档（不拦人，只提示）。
      driver.feed(sljStandFrames(count: 20));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(sljStandFrames(count: 20, startTimestampMs: driver.clock));
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '站立基线攒够之后应当自动进计数 —— 这一步会构造 FaultPresenter '
            '与 FormScorer，阈值键缺一个就在这里抛',
      );

      driver.feed(sljRepFrames(startTimestampMs: driver.clock));
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
      final session = SquatSession(thresholds: _realTable(), spec: sljSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(sljStandFrames(count: 20));
      session.beginCalibration();
      driver.feed(sljStandFrames(count: 20, startTimestampMs: driver.clock));
      driver.feed(sljRepFrames(startTimestampMs: driver.clock));
      session.finishSet();

      final summary = session.view.value.summary!;
      expect(
        summary.faultStats,
        isEmpty,
        reason: '命中了：${summary.faultStats.map((s) => s.code).toList()}',
      );
    });
  });

  group('人跳出画面', () {
    // 立定跳远和深蹲不一样：**人会离开原地**。手机架在两米外，跳一次前进
    // 一米多，出画是常态而不是意外。这一组把三种出画时序各演一遍，
    // 钉住各自该有的结果 —— 真机上「一跳都没数上」正是从这里来的。
    //
    // 三种时序的差别只有一个：**丢帧那一刻状态机走到哪了**。

    test('蹬直之后才出画：落地还在画面里，照样计数', () {
      final (session, driver) = _countingSession();

      driver.feed(sljFromSegments([
        const SljSegment(95, count: 12), // 蓄力
        const SljSegment(178, count: 16), // 蹬直 → 已进 FLIGHT
      ], startTimestampMs: driver.clock));

      driver.feedLoss(60); // 腾空中人出画约两秒

      driver.feed(sljFromSegments([
        const SljSegment(115, count: 12), // 落进画面：缓冲
        const SljSegment(175, count: 16), // 站直 → 封存
      ], startTimestampMs: driver.clock));
      session.finishSet();

      final view = session.view.value;
      expect(view.repCount, 1, reason: 'FLIGHT 已经进过，回来蹲下就该被认成落地');
      expect(view.discardedReps, 0);
      expect(view.interrupted, isTrue, reason: '离开过画面这件事本身仍要记下来');
    });

    test('蹬到一半就出画：重同步之后，回来那一下蹲被认成落地', () {
      // **这是真机上最要命的一种。** 蹬伸只到 165（越过蹬伸线 158，够不着
      // 离地线 171）时人出画 —— 出画的瞬间恰好是蹬伸最快的那几帧，太容易了。
      //
      // 修之前（这条测试那时是红的）：状态机停在 LAUNCH，回来那一下蹲被读成
      // **回蹲**（LAUNCH→PREP），站直又把 PREP 推回 LAUNCH、再推进 FLIGHT，
      // 然后停在 FLIGHT 上等超时 —— 一次真跳变成一次丢弃，连一次**本来
      // 看得见**的落地也白白扔掉。
      //
      // 修的是 `lossRecovery`（见 `slj.dart`）：人从长丢失里回来时若停在
      // LAUNCH，就当作已经离地。**落地仍然要靠看得见的蹲下来认定** ——
      // 下面那条相位断言盯的就是这件事：那个蹲下是真的被认出来了，
      // 而不是被跳过、被拿别的帧顶替。
      final (session, driver) = _countingSession();

      driver.feed(sljFromSegments([
        const SljSegment(95, count: 12), // 蓄力 → PREP
        const SljSegment(165, count: 10), // 蹬伸开始 → LAUNCH，但没到 171
      ], startTimestampMs: driver.clock));

      driver.feedLoss(60);

      driver.feed(sljFromSegments([
        const SljSegment(115, count: 12), // 落地缓冲
        const SljSegment(175, count: 16), // 站直 → 封存
      ], startTimestampMs: driver.clock));
      session.finishSet();

      final view = session.view.value;
      expect(view.repCount, 1, reason: '这是一次真跳，不该被丢');
      expect(view.discardedReps, 0);
      expect(view.interrupted, isTrue, reason: '离开过画面这件事本身仍要记下来');

      // 相位的结构性断言（落地相位真的存在、且只覆盖回来之后那一段）
      // 在 `test/domain/slj_test.dart` 的「长丢失重同步」那一组 ——
      // 它要读 `RepWindow`，而会话层不暴露窗口。这里只钉产品后果：
      // 一次真跳被数上了，而且没有被记成一次丢弃。
    });

    test('落地也在画面外：走回来时已经站直', () {
      // 第三种时序：蹬直、飞出去、**连落地都没被看见**，人走回起点时已经站着。
      // 状态机停在 FLIGHT，而 FLIGHT 唯一的出口是「膝角弯到落地线以下」——
      // 站着不动永远不满足，只能等超时。这一种是真的没救：从头到尾没有任何
      // 一帧能证明他落过地，所以此处**如实要求它被丢弃**，不是要求它计数。
      // 写下来是为了标出这条边界，免得有人以为前两条修好了就万事大吉。
      final (session, driver) = _countingSession();

      driver.feed(sljFromSegments([
        const SljSegment(95, count: 12),
        const SljSegment(178, count: 16), // 蹬直 → FLIGHT
      ], startTimestampMs: driver.clock));

      driver.feedLoss(60); // 腾空 + 落地，整段都在画面外

      driver.feed(
        sljStandFrames(count: 130, startTimestampMs: driver.clock),
      );
      session.finishSet();

      final view = session.view.value;
      expect(view.repCount, 0, reason: '没有任何一帧看到落地，这一跳没有被计数的依据');
      expect(view.discardedReps, 1, reason: '但要如实记账，不能装作什么都没发生');
    });
  });

  group('站位建议随动作换', () {
    /// 喂一段稳定帧，返回门禁给出的结论。
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

    test('侧对镜头：立定跳远说的是双脚同时发力，不是膝内扣', () {
      // 合成站立帧的侧向比是 0.20，落在侧视档 —— 门禁只提示、不拦人。
      final frames = sljStandFrames(count: 30);

      final slj = monitorFor(sljSpec, frames);
      expect(slj.report.view, CameraView.sagittal, reason: '这条断言本身要成立才有意义');
      final sljAdvice = slj.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.facingSide)
          .message;
      expect(sljAdvice, contains('双脚'));
      expect(
        sljAdvice,
        isNot(contains('膝内扣')),
        reason: '立定跳远没有膝内扣这条判定 —— 说它会「不可用」是在撒一个不存在的谎',
      );

      // 对照组：同一批帧喂给深蹲，必须还是原来那句话。
      // 少了它，这个测试在「两句都换成了同一句」时也会绿。
      final squat = monitorFor(squatSpec, frames);
      final squatAdvice = squat.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.facingSide)
          .message;
      expect(squatAdvice, contains('膝内扣'));
    });

    test('正对镜头：两个动作拦人的那句也各说各的后果', () {
      // sideGap 0.07 → 侧向比 0.70，落进正视档。
      final frames = sljStandFrames(count: 30, sideGap: 0.07);

      final slj = monitorFor(sljSpec, frames);
      expect(slj.report.view, CameraView.frontal);
      expect(slj.report.blocking, isTrue);
      final sljAdvice = slj.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.facingFront)
          .message;
      expect(sljAdvice, contains('蹬伸'));
      expect(sljAdvice, isNot(contains('膝盖的弯曲')));

      final squat = monitorFor(squatSpec, frames);
      expect(
        squat
            .report.issues
            .firstWhere((i) => i.code == PositionIssueCode.facingFront)
            .message,
        contains('膝盖的弯曲'),
      );
    });
  });

  group('机位必须是 45°', () {
    test('正视站位的人永远开始不了：门禁是唯一拦住他的东西', () {
      // 这条把「为什么机位必须是 oblique45」从注释里的断言变成可执行的。
      //
      // **关键在于对照。** 正视帧与 45° 帧在**特征上完全一样** —— 膝角、对称度、
      // 躯干倾角、髋高比、脚跟抬升比全都只跟矢状面内的点有关，`sljPose` 的
      // `sideGap` 一个都不碰。所以：门禁一失效，一个正对镜头的人会得到一整组
      // 「看着完全正常」的判定，而那些判定是在一个投影完全失真的画面上算出来的。
      // 这就是它必须拦人的理由，也是它只能拦、不能提示的理由。
      final frontal = sljStandFrames(count: 20, sideGap: 0.07);
      final oblique = sljStandFrames(count: 40);

      // 先证明「特征一样」——否则下面那条对照就只是在比两个不同的东西。
      final extractor = FeatureExtractor(cameraView: CameraView.oblique45);
      for (final name in const [
        'knee_angle_L',
        'knee_angle_R',
        'knee_symmetry',
        'trunk_lean',
        'hip_height_ratio',
        'heel_rise_ratio_L',
      ]) {
        expect(
          extractor.extract(frontal.first).get(name),
          extractor.extract(oblique.first).get(name),
          reason: '$name 在两份帧上应当逐位相同 —— 这是「门禁之外无路可走」的前提',
        );
      }

      final session = SquatSession(thresholds: _realTable(), spec: sljSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(frontal);
      expect(session.view.value.canBeginCalibration, isFalse, reason: '正视必须被拦住');
      expect(session.beginCalibration(), isFalse);
      expect(session.view.value.phase, SessionPhase.position);
      expect(session.view.value.calibrationFrames, 0, reason: '标定进度一格都不该走');

      // 换回 45° 帧，立刻走完。
      //
      // 帧数给足 40：门禁是 30 帧的滚动窗口，中位数要等旧结论被挤出窗口才会
      // 翻转（第 16 帧），翻转之后还要再攒 15 帧才敢下结论。给 20 帧的话
      // 窗口才刚翻过来，`canStart` 仍然是假 —— 而那与「机位不对」是两件事，
      // 会让这条测试的失败信息指向错误的方向。
      driver.feed(sljStandFrames(count: 40, startTimestampMs: driver.clock));
      expect(session.view.value.canBeginCalibration, isTrue);
      expect(session.beginCalibration(), isTrue);
      driver.feed(sljStandFrames(count: 20, startTimestampMs: driver.clock));
      expect(session.view.value.phase, SessionPhase.counting);
    });
  });
}
