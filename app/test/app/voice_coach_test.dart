/// 语音教练的行为测试。
///
/// **这里断言的是「说了哪些话、说了几次」** —— 播报的失败方式几乎全是这两种：
/// 该说的没说（用户站在两米外干等），或者同一句反复念（比不说更烦）。
/// 两者都不会报错，只有把这些话录下来逐条比对才看得见。
///
/// 发声本身（`vitalteen/speech` 通道）不在这里测：那是平台边界，
/// 单测环境里没有它，而这一层被设计成完全不认识它。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/app/voice_coach.dart';
import 'package:vitalteen_app/domain/rules.dart';

/// 一个把话记下来的假发声通道。
class _Recorder {
  final List<String> said = [];

  void call(String text) => said.add(text);

  /// 断言说过，且最近一次说的就是 [text]。
  void expectLast(String text) {
    expect(said, isNotEmpty, reason: '一句话都没说');
    expect(said.last, text);
  }
}

SessionView _view({
  SessionPhase phase = SessionPhase.position,
  int repCount = 0,
  int discardedReps = 0,
  List<PositionIssue> issues = const [],
  SetSummary? summary,
  bool interrupted = false,
  List<int> repDurationsMs = const [],
}) =>
    SessionView(
      phase: phase,
      position: PositionReport(
        view: null,
        viewStable: false,
        issues: issues,
        sampleCount: 30,
      ),
      calibrationFrames: 0,
      calibrationTarget: 15,
      repCount: repCount,
      discardedReps: discardedReps,
      machineState: 'STANDING',
      kneeAngle: null,
      // 默认那一份造的是深蹲的会话，而深蹲不是计时制的动作 ——
      // 这两个数在它身上恒为空（见 SessionView.holdMs / repDurationsMs）。
      // 要验平板支撑的话由用例显式传 `repDurationsMs` 进来。
      holdMs: 0,
      repDurationsMs: repDurationsMs,
      lastRep: null,
      // 语音不念分数，所以这条用例里它一律是 null。真要验「分数进不进语音」，
      // 该在 voice_coach.dart 里加断言，而不是在这里造一个没人读的值。
      lastRepScore: null,
      summary: summary,
      setScore: null,
      interrupted: interrupted,
      sawFrame: true,
    );

FaultStat _stat(String code, String nameZh, int count, {double rate = 0.5}) =>
    FaultStat(
      code: code,
      nameZh: nameZh,
      scorable: false,
      count: count,
      rate: rate,
      repIndices: List.generate(count, (i) => i),
      worstDelta: 3,
    );

void main() {
  group('话术表', () {
    test('每个门禁错误码都有交代，哪怕是「故意不说」', () {
      for (final code in PositionIssueCode.values) {
        expect(hasGatePhrase(code), isTrue,
            reason: '$code 没有登记。门禁卡住用户而语音一声不吭，'
                '而站在两米外的人正是只有这一条通道能用。');
      }
    });

    test('拦人的问题都有话说，提示级的都不说', () {
      // 这条不是形式检查：**播报没法「扫一眼就跳过」**，
      // 说了一条提示级的问题，就等于把它升级成了拦住。
      for (final entry in {
        PositionIssueCode.missingTorso: true,
        PositionIssueCode.missingLegs: true,
        PositionIssueCode.missingLeftFoot: true,
        PositionIssueCode.tooFar: true,
        PositionIssueCode.tooClose: true,
        PositionIssueCode.cropped: true,
        PositionIssueCode.facingFront: true,
        PositionIssueCode.headNotVisible: false,
        PositionIssueCode.facingSide: false,
        PositionIssueCode.viewUnstable: false,
      }.entries) {
        expect(gatePhrase(entry.key) != null, entry.value,
            reason: '${entry.key} 该${entry.value ? '说' : '不说'}');
      }
    });
  });

  group('数字读法', () {
    test('报数用中文，不交给引擎去猜', () {
      expect(chineseNumber(0), '零');
      expect(chineseNumber(1), '一');
      expect(chineseNumber(3), '三');
      expect(chineseNumber(9), '九');
      expect(chineseNumber(10), '十');
      expect(chineseNumber(11), '十一');
      expect(chineseNumber(20), '二十');
      expect(chineseNumber(21), '二十一');
      expect(chineseNumber(99), '九十九');
    });

    test('量词前说「两」不说「二」', () {
      // 报数时说「二」，报个数时说「两个」—— 同一层里两种读法。
      expect(chineseNumber(2), '二');
      expect(chineseQuantity(2), '两');
      expect(chineseQuantity(1), '一');
      expect(chineseQuantity(3), '三');
      // 但不能一刀切把所有 2 换成「两」：十二、二十、二十二里的「二」得留着。
      expect(chineseQuantity(12), '十二');
      expect(chineseQuantity(20), '二十');
      expect(chineseQuantity(22), '二十二');
    });

    test('三位数以上交回引擎 —— 一组深蹲数不到那儿', () {
      // 中文引擎念「105」通常是「一百零五」，够用；
      // 为这个场景写一套读法不值当。**留着这条断言是说明这个取舍是自觉的**，
      // 不是漏掉了。
      expect(chineseNumber(105), '105');
    });
  });

  group('相位跃迁', () {
    test('开始标定就说「站直，别动」', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(phase: SessionPhase.calibrating));

      rec.expectLast('站直，别动');
    });

    test('标定转计数就说「开始」', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(phase: SessionPhase.calibrating));
      coach.onView(_view(phase: SessionPhase.counting));

      rec.expectLast('开始');
    });

    test('开跳前的站位提示跟着「开始」一起说，而且只说一次', () {
      // **说在跳之前**才有用：它是站位提醒，人跳起来之后再听他改不了也来不及。
      // 立定跳远最容易犯的那件事是站到画面正中 —— 那等于主动把跳出去的那一段
      // 让出画面，落地全在画面外，一次都数不上，而屏幕上什么错都不报。
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call, framingHint: sljSpec.framingHint);

      // 会话快照是 10 Hz 推的，同一相位会被喂很多次 —— 提示不能跟着重复。
      for (var i = 0; i < 20; i++) {
        coach.onView(_view(phase: SessionPhase.counting));
      }

      expect(rec.said, ['开始。${sljSpec.framingHint}']);
    });

    test('倒计时读秒，读完了不出声', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onCountdown(3);
      coach.onCountdown(2);
      coach.onCountdown(1);
      coach.onCountdown(0);

      expect(rec.said, ['三', '二', '一']);
    });

    test('相位没变就不重复说', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      // 会话快照是 10 Hz 推的，同一相位会被喂很多次。
      for (var i = 0; i < 20; i++) {
        coach.onView(_view(phase: SessionPhase.calibrating));
      }

      expect(rec.said, ['站直，别动']);
    });
  });

  group('报数', () {
    test('数到一个就说一个', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(phase: SessionPhase.counting));
      coach.onView(_view(phase: SessionPhase.counting, repCount: 1));
      coach.onView(_view(phase: SessionPhase.counting, repCount: 2));
      coach.onView(_view(phase: SessionPhase.counting, repCount: 3));

      expect(rec.said, ['开始', '一', '二', '三']);
    });

    test('同一次计数被喂很多遍也只说一遍', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      for (var i = 0; i < 30; i++) {
        coach.onView(_view(phase: SessionPhase.counting, repCount: 7));
      }

      expect(rec.said, ['开始', '七']);
    });

    test('数得快时只说当前值，不补报中间漏掉的', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(phase: SessionPhase.counting, repCount: 4));
      // 中间那一秒里数到了 8：补报 5、6、7 等于追着现实念一串过期数字。
      coach.onView(_view(phase: SessionPhase.counting, repCount: 8));

      expect(rec.said, ['开始', '四', '八']);
    });

    test('新的一组从零开始，不说「零」', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
          phase: SessionPhase.finished,
          repCount: 10,
          summary: const SetSummary(repCount: 10, faultStats: [])));
      rec.said.clear();

      coach.onView(_view(phase: SessionPhase.counting));

      expect(rec.said, ['开始']);
    });
  });

  group('门禁', () {
    test('拦住时说口语短句，不念界面上那一行', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(issues: const [
        PositionIssue(PositionIssueCode.facingFront, '请侧身 45° —— 正对镜头时膝盖的弯曲在画面上看不出来，计数会一直是 0。'),
      ]));

      // 短句是另写的一份，理由见 `voice_coach.dart` 模块注释：
      // 界面那份带破折号、带只在屏幕上成立的回指，念出来是噪音。
      rec.expectLast('请侧身四十五度，正对镜头数不出数');
    });

    test('同一条问题持续存在只念一遍', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      for (var i = 0; i < 50; i++) {
        coach.onView(_view(issues: const [
          PositionIssue(PositionIssueCode.missingLegs, '膝盖或脚踝没有完整入镜。请后退半步，让双腿整个进画面。'),
        ]));
      }

      expect(rec.said, ['请后退一点，让双腿进画面']);
    });

    test('改好了第一条，下一条接着念', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(issues: const [
        PositionIssue(PositionIssueCode.missingLegs, '缺腿'),
        PositionIssue(PositionIssueCode.tooFar, '太远'),
      ]));
      coach.onView(_view(issues: const [
        PositionIssue(PositionIssueCode.tooFar, '太远'),
      ]));

      expect(rec.said, ['请后退一点，让双腿进画面', '离得有点远，请走近一些']);
    });

    test('提示级的问题不念 —— 念了就等于把它升级成拦住', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(issues: const [
        PositionIssue(PositionIssueCode.facingSide, '完全侧对镜头也能计数。', blocking: false),
        PositionIssue(PositionIssueCode.viewUnstable, '正在判断你的站位。', blocking: false),
      ]));

      expect(rec.said, isEmpty);
    });

    test('问题解决了就不再出声', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(issues: const [
        PositionIssue(PositionIssueCode.tooFar, '太远'),
      ]));
      coach.onView(_view());
      coach.onView(_view());

      expect(rec.said, ['离得有点远，请走近一些']);
    });

    test('标定被打断退回自检时，同一条问题重新念一遍', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      const issues = [PositionIssue(PositionIssueCode.tooFar, '太远')];
      coach.onView(_view(issues: issues));
      coach.onView(_view(phase: SessionPhase.calibrating));
      rec.said.clear();

      // 人挪动了一下，标定作废退回自检 —— 用户此时多半不知道发生了什么，
      // 而屏幕上写着他看不见。这里闭嘴等于让人干等。
      coach.onView(_view(issues: issues));

      expect(rec.said, ['离得有点远，请走近一些']);
    });
  });

  group('本组汇总', () {
    test('报总数与主问题', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 10,
        summary: SetSummary(
          repCount: 10,
          faultStats: [
            _stat('DEPTH', '深度不足', 3, rate: 0.3),
            _stat('KNEE_VALGUS', '膝内扣', 6, rate: 0.6),
          ],
        ),
      ));

      // 主问题取出现率最高的那个；措辞与界面同一来源（`faultTitle`）——
      // 耳朵听到「膝内扣」而屏幕写着「膝内扣倾向」会被当成两件事。
      rec.expectLast('本组结束，一共十个，六次膝内扣倾向。');
    });

    test('没发现问题也要说，否则用户不知道结束了', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 12,
        summary: const SetSummary(repCount: 12, faultStats: []),
      ));

      rec.expectLast('本组结束，一共十二个，没有发现需要留意的地方。');
    });

    test('丢弃次数必须说 —— 它是静默发生的', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 9,
        discardedReps: 2,
        summary: const SetSummary(repCount: 9, faultStats: []),
      ));

      expect(rec.said.last, contains('有两次幅度不够或太快，没计入'));
    });

    test('丢弃的原因随动作换 —— 立定跳远丢的不是「幅度」', () {
      // 同一句话在立定跳远上是错的：它丢的那次不是蹲得不够深，是没跳出去
      // 或者人丢了几帧。听的人会照着一条错的指示去改 —— 以为自己要蹲得更低，
      // 实际上要跳得更用力。
      final rec = _Recorder();
      final coach = VoiceCoach(
        speak: rec.call,
        discardedReason: sljSpec.discardedReason,
      );

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 0,
        discardedReps: 2,
        summary: const SetSummary(repCount: 0, faultStats: []),
      ));

      expect(rec.said.last, contains('有两次没跳到落地缓冲，或动作被打断，没计入'));
      expect(rec.said.last, isNot(contains('幅度')));
    });

    test('中断过就要说，它是「计数可能不准」的唯一线索', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 9,
        interrupted: true,
        summary: const SetSummary(repCount: 9, faultStats: []),
      ));

      expect(rec.said.last, contains('中途离开过画面，计数可能不准'));
    });

    test('汇总只有一次 —— 相位没变就不再念', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      final finished = _view(
        phase: SessionPhase.finished,
        repCount: 5,
        summary: const SetSummary(repCount: 5, faultStats: []),
      );
      for (var i = 0; i < 10; i++) {
        coach.onView(finished);
      }

      expect(rec.said, hasLength(1));
    });
  });

  group('计时制动作的汇总', () {
    /// 平板支撑那一组该说的一句话。**只有它会把「撑了多久」说出口** ——
    /// 屏幕上那个计时器归零之后什么都不剩，报告页要用户低头去看，
    /// 而做完一组的人这时候正喘着气。
    test('报「段」，并把合计时长念出来', () {
      final rec = _Recorder();
      final coach = VoiceCoach(
        speak: rec.call,
        isTimed: true,
        discardedReason: plankSpec.discardedReason,
      );

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 3,
        // 41.0 + 30.0 + 21.0 秒 —— 合计 92 秒，正好是整数秒，
        // 免得这条断言同时在验四舍五入（那是另一个决定，不是这条要说的）。
        repDurationsMs: const [41000, 30000, 21000],
        summary: const SetSummary(repCount: 3, faultStats: []),
      ));

      rec.expectLast('本组结束，一共三段，合计九十二秒，没有发现需要留意的地方。');
    });

    test('时长要取整秒 —— 报数这条通道不念小数点', () {
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call, isTimed: true);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 1,
        repDurationsMs: const [46400],
        summary: const SetSummary(repCount: 1, faultStats: []),
      ));

      // 「四十六秒」而不是「四十六点四秒」：`_quantity` 只认整数，
      // 而裸小数交给引擎读出来的东西各家不同（见本文件顶部那条纪律）。
      expect(rec.said.last, contains('合计四十六秒'));
      expect(rec.said.last, isNot(contains('点')));
    });

    test('丢的是「段」，不是「次」', () {
      final rec = _Recorder();
      final coach = VoiceCoach(
        speak: rec.call,
        isTimed: true,
        discardedReason: plankSpec.discardedReason,
      );

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 0,
        discardedReps: 1,
        summary: const SetSummary(repCount: 0, faultStats: []),
      ));

      expect(rec.said.last, contains('有一段撑得太久，超过了几分钟，没计入'));
      expect(
        rec.said.last,
        isNot(contains('次')),
        reason: '这个动作里被丢掉的那一个就是一段支撑 —— 「一次」听起来是'
            '「一次尝试」，而它本来已经算是一段了，只是不算数',
      );
    });

    test('对照：非计时制动作念的还是「个」，也不念时长', () {
      // 这条是上三条的对照组。**没有它的话，一句写死的「段 + 合计秒」
      // 也能让上面三条全绿**，而那意味着深蹲的每一次汇总都开始说
      // 「一共十个，合计零秒」。
      final rec = _Recorder();
      final coach = VoiceCoach(speak: rec.call);

      coach.onView(_view(
        phase: SessionPhase.finished,
        repCount: 3,
        // 深蹲的会话永远不会填这个列表（见 SessionView.repDurationsMs），
        // 所以对照组的输入与真实情况逐字一致。
        summary: const SetSummary(repCount: 3, faultStats: []),
      ));

      expect(rec.said.last, '本组结束，一共三个，没有发现需要留意的地方。');
      expect(rec.said.last, isNot(contains('秒')));
    });
  });
}
