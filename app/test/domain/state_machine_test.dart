/// 状态机测试。
///
/// **这三条防抖机制存在的唯一理由就是抵抗抖动。** 所以这里的测试重点不是
/// 「能不能转移」，而是「该不动的时候绝不动」：
///
/// - 边界附近的抖动不能让状态来回跳（滞回 + 投票）
/// - 刚进新状态不能被下一条边立刻带走（最短停留）
/// - 坏数据不能让状态机崩溃或误判（guard 异常归约为「不满足」）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/domain/state_machine.dart';

/// 造一个 guard：只在信号存在且满足条件时为真。
///
/// 注意 `signals['knee']` 是 `double?` —— 缺键或为 null 时返回 false，
/// 这正是真实场景里 guard 的常见写法。
Guard kneeBelow(double threshold) =>
    (s) => (s['knee'] ?? double.infinity) < threshold;

Guard kneeAbove(double threshold) =>
    (s) => (s['knee'] ?? double.negativeInfinity) > threshold;

/// 深蹲式的四状态链，供多个用例复用。
StateMachine squatMachine({
  int minDwellFrames = 0,
  int voteWindow = 1,
  int voteRequired = 1,
}) =>
    StateMachine(
      initialState: 'STANDING',
      transitions: [
        Transition(
          src: 'STANDING',
          dst: 'DESCENT',
          guard: kneeBelow(170),
          label: 'standing->descent',
        ),
        Transition(
          src: 'DESCENT',
          dst: 'BOTTOM',
          guard: kneeBelow(135),
          label: 'descent->bottom',
        ),
        Transition(
          src: 'BOTTOM',
          dst: 'ASCENT',
          guard: kneeAbove(143),
          label: 'bottom->ascent',
        ),
        Transition(
          src: 'ASCENT',
          dst: 'STANDING',
          guard: kneeAbove(172),
          label: 'ascent->standing',
        ),
      ],
      minDwellFrames: minDwellFrames,
      voteWindow: voteWindow,
      voteRequired: voteRequired,
    );

void main() {
  group('基本转移', () {
    test('条件满足时转移，并带回两端状态', () {
      final m = squatMachine();
      final u = m.update({'knee': 160.0}, 0);
      expect(u.changed, isTrue);
      expect(u.state, 'DESCENT');
      expect(u.previousState, 'STANDING');
      expect(u.entered, 'DESCENT');
      expect(u.left, 'STANDING');
    });

    test('条件不满足时保持原状态', () {
      final m = squatMachine();
      final u = m.update({'knee': 178.0}, 0);
      expect(u.changed, isFalse);
      expect(u.state, 'STANDING');
      expect(u.entered, isNull);
      expect(u.left, isNull);
    });

    test('四状态链能一路走完并回到站立', () {
      final m = squatMachine();
      expect(m.update({'knee': 160.0}, 0).state, 'DESCENT');
      expect(m.update({'knee': 120.0}, 33).state, 'BOTTOM');
      expect(m.update({'knee': 150.0}, 66).state, 'ASCENT');
      expect(m.update({'knee': 178.0}, 99).state, 'STANDING');
    });
  });

  group('坏数据不得让状态机崩溃或误判', () {
    test('缺键判为不满足，不抛异常', () {
      final m = squatMachine();
      expect(() => m.update(const {}, 0), returnsNormally);
      expect(m.update(const {}, 0).changed, isFalse);
    });

    test('值为 null 判为不满足', () {
      final m = squatMachine();
      expect(m.update({'knee': null}, 0).changed, isFalse);
    });

    test('guard 对 null 做算术语算时判为不满足（这是最常见的坏数据情形）', () {
      // guard 的自然写法：不做判空直接比较。信号缺键时 s['knee'] 是 null，
      // 运算抛 TypeError —— **在 Dart 里它是 Error 而不是 Exception**。
      // 只捕获 Exception 的实现会在这里崩掉整个循环。
      final m = StateMachine(
        initialState: 'A',
        transitions: [
          Transition(
            src: 'A',
            dst: 'B',
            guard: (s) => s['knee']! < 100,
            label: 'null-misuse',
          ),
          Transition(src: 'A', dst: 'C', guard: (_) => false, label: 'never'),
        ],
      );
      expect(() => m.update(const {}, 0), returnsNormally);
      expect(m.update(const {}, 0).changed, isFalse);
      expect(m.state, 'A');
    });

    test('guard 抛 Exception 时同样判为不满足', () {
      final m = StateMachine(
        initialState: 'A',
        transitions: [
          Transition(
            src: 'A',
            dst: 'B',
            guard: (_) => throw const FormatException('guard 里有 bug'),
            label: 'boom',
          ),
        ],
      );
      expect(() => m.update(const {}, 0), returnsNormally);
      for (var i = 0; i < 3; i++) {
        expect(m.update(const {}, i * 33).changed, isFalse);
      }
      // 状态机「纹丝不动」，而这正是健康检查要暴露的情形
      expect(m.state, 'A');
      expect(m.guardHealth()['boom'], isFalse);
    });

    test('健康检查能指出「从未通过」的候选', () {
      final m = squatMachine();
      m.update({'knee': 160.0}, 0); // 只有第一条会过
      final health = m.guardHealth();
      expect(health['standing->descent'], isTrue);
      expect(health['descent->bottom'], isFalse);
      expect(health['bottom->ascent'], isFalse);
    });

    test('时间戳回退、重复、跳跃都不影响状态推进', () {
      final clean = squatMachine();
      final messy = squatMachine();
      const knees = [178.0, 160.0, 120.0, 150.0, 178.0];
      const messyStamps = [0, -500, 100, 100, 999999];

      for (var i = 0; i < knees.length; i++) {
        final a = clean.update({'knee': knees[i]}, i * 33);
        final b = messy.update({'knee': knees[i]}, messyStamps[i]);
        expect(a.state, equals(b.state), reason: '第 $i 帧状态不一致');
      }
    });
  });

  group('最短停留', () {
    test('转移后若干帧内不得再次转移', () {
      // 上一条边一提交，下一条边的条件立刻满足 —— 没有停留门槛的话会一路冲到底
      final m = squatMachine(minDwellFrames: 3);
      expect(m.update({'knee': 120.0}, 0).state, 'DESCENT'); // 提交，计时归零

      // 之后 2 帧虽然 guard 满足（120 < 135），也不该转移
      expect(m.update({'knee': 120.0}, 33).state, 'DESCENT');
      expect(m.update({'knee': 120.0}, 66).state, 'DESCENT');
      // 第 3 帧解锁
      expect(m.update({'knee': 120.0}, 99).state, 'BOTTOM');
    });

    test('停留只锁提交，不锁计票', () {
      // 锁定期间真票照常入窗：解锁那一刻窗口里已经攒够票，立即可转
      final m = squatMachine(minDwellFrames: 2, voteWindow: 3, voteRequired: 3);
      // 前 3 帧攒满 DESCENT 的票
      m.update({'knee': 160.0}, 0);
      m.update({'knee': 160.0}, 33);
      expect(m.update({'knee': 160.0}, 66).state, 'DESCENT'); // 提交
      // 提交帧清零，此刻 BOTTOM 的窗口是空的；等它攒满
      expect(m.update({'knee': 120.0}, 99).state, 'DESCENT');
      expect(m.update({'knee': 120.0}, 132).state, 'DESCENT');
      expect(m.update({'knee': 120.0}, 165).state, 'BOTTOM');
    });

    test('初始状态不受停留限制', () {
      // 初始状态没有被「进入」过，不该被门槛挡住
      final m = squatMachine(minDwellFrames: 5, voteWindow: 1, voteRequired: 1);
      expect(m.update({'knee': 160.0}, 0).state, 'DESCENT');
    });
  });

  group('N-of-M 投票', () {
    test('窗口攒满之前不转移（冷启动需要 M 帧证据）', () {
      final m = squatMachine(voteWindow: 5, voteRequired: 4);
      for (var i = 0; i < 4; i++) {
        expect(m.update({'knee': 160.0}, i * 33).changed, isFalse);
      }
      // 第 5 帧窗口才满
      expect(m.update({'knee': 160.0}, 4 * 33).changed, isTrue);
    });

    test('窗口内真票不足时不转移', () {
      final m = squatMachine(voteWindow: 5, voteRequired: 4);
      // 5 帧里只有 3 帧满足
      const knees = [160.0, 178.0, 160.0, 178.0, 160.0];
      for (var i = 0; i < knees.length; i++) {
        expect(m.update({'knee': knees[i]}, i * 33).changed, isFalse);
      }
      expect(m.state, 'STANDING');
    });

    test('单帧尖刺不足以触发转移', () {
      final m = squatMachine(voteWindow: 5, voteRequired: 4);
      // 5 帧里只有 1 帧是尖刺
      const knees = [178.0, 178.0, 120.0, 178.0, 178.0];
      for (var i = 0; i < knees.length; i++) {
        expect(m.update({'knee': knees[i]}, i * 33).changed, isFalse);
      }
      expect(m.state, 'STANDING');
    });

    test('投票窗口为 1 时等价于关闭投票', () {
      final m = squatMachine(voteWindow: 1, voteRequired: 1);
      expect(m.update({'knee': 160.0}, 0).changed, isTrue);
    });

    test('转移后旧票作废 —— 回到原状态不会用过期证据瞬移', () {
      final m = squatMachine(minDwellFrames: 0, voteWindow: 3, voteRequired: 3);

      // **每次转移都要重新攒满 3 票** —— 转移提交时全部窗口被清空，
      // 所以每换一个状态都得给足 3 帧，而不是 1 帧。
      var ts = 0;
      void feed(double knee, int frames) {
        for (var i = 0; i < frames; i++) {
          m.update({'knee': knee}, ts);
          ts += 33;
        }
      }

      feed(160.0, 3);
      expect(m.state, 'DESCENT');
      feed(120.0, 3);
      expect(m.state, 'BOTTOM');
      feed(150.0, 3);
      expect(m.state, 'ASCENT');
      feed(178.0, 3);
      expect(m.state, 'STANDING');

      // 回到 STANDING 后紧接着给一帧「满足 STANDING->DESCENT」的信号。
      // 若旧票没作废，这里会被上一轮的票立刻推回 DESCENT —— 那就是瞬移。
      expect(
        m.update({'knee': 160.0}, ts).changed,
        isFalse,
        reason: '回到站立后第一帧就被旧票推进了 DESCENT',
      );
    });
  });

  group('多候选的确定性', () {
    test('同帧多个候选满足时取列表靠前者', () {
      final m = StateMachine(
        initialState: 'A',
        transitions: [
          Transition(src: 'A', dst: 'FIRST', guard: (_) => true, label: 'first'),
          Transition(src: 'A', dst: 'SECOND', guard: (_) => true, label: 'second'),
        ],
        minDwellFrames: 0,
        voteWindow: 1,
        voteRequired: 1,
      );
      expect(m.update(const {}, 0).state, 'FIRST');
    });

    test('顺序即优先级，交换顺序结果也交换', () {
      final m = StateMachine(
        initialState: 'A',
        transitions: [
          Transition(src: 'A', dst: 'SECOND', guard: (_) => true, label: 'second'),
          Transition(src: 'A', dst: 'FIRST', guard: (_) => true, label: 'first'),
        ],
        minDwellFrames: 0,
        voteWindow: 1,
        voteRequired: 1,
      );
      expect(m.update(const {}, 0).state, 'SECOND');
    });
  });

  group('reset 等价于全新实例', () {
    test('reset 后逐帧结果与新建实例一致', () {
      final fresh = squatMachine(minDwellFrames: 2, voteWindow: 3, voteRequired: 3);
      final used = squatMachine(minDwellFrames: 2, voteWindow: 3, voteRequired: 3);

      const knees = [178.0, 160.0, 160.0, 160.0, 120.0, 120.0];
      for (var i = 0; i < knees.length; i++) {
        used.update({'knee': knees[i]}, i * 33);
      }
      used.reset();

      for (var i = 0; i < knees.length; i++) {
        final a = fresh.update({'knee': knees[i]}, i * 33);
        final b = used.update({'knee': knees[i]}, i * 33);
        expect(b.state, equals(a.state), reason: '第 $i 帧不一致 —— reset 没清干净');
      }
    });

    test('reset 清掉停留计时', () {
      final m = squatMachine(minDwellFrames: 3);
      m.update({'knee': 160.0}, 0); // 提交，计时归零
      m.reset();
      // 若计时没清，下面这帧会被挡住
      expect(m.update({'knee': 160.0}, 33).changed, isTrue);
    });

    test('reset 到指定状态', () {
      final m = squatMachine();
      m.update({'knee': 160.0}, 0);
      m.reset(target: 'BOTTOM');
      expect(m.state, 'BOTTOM');
    });

    test('reset 到未知状态抛异常，且不改动当前状态', () {
      final m = squatMachine();
      expect(() => m.reset(target: 'NOPE'), throwsA(isA<StateMachineException>()));
      expect(m.state, 'STANDING');
    });
  });

  group('构造期校验', () {
    test('转移列表为空时拒绝', () {
      expect(
        () => StateMachine(initialState: 'A', transitions: const []),
        throwsA(isA<StateMachineException>()),
      );
    });

    test('初始状态不在图内时拒绝', () {
      expect(
        () => StateMachine(
          initialState: 'NOWHERE',
          transitions: [Transition(src: 'A', dst: 'B', guard: (_) => true)],
        ),
        throwsA(isA<StateMachineException>()),
      );
    });

    test('自环被拒绝', () {
      expect(
        () => StateMachine(
          initialState: 'A',
          transitions: [Transition(src: 'A', dst: 'A', guard: (_) => true)],
        ),
        throwsA(isA<StateMachineException>()),
      );
    });

    test('voteRequired 大于 voteWindow 时拒绝', () {
      expect(
        () => StateMachine(
          initialState: 'A',
          transitions: [Transition(src: 'A', dst: 'B', guard: (_) => true)],
          voteWindow: 3,
          voteRequired: 5,
        ),
        throwsA(isA<StateMachineException>()),
      );
    });

    test('负数帧数与零窗口被拒绝', () {
      expect(
        () => StateMachine(
          initialState: 'A',
          transitions: [Transition(src: 'A', dst: 'B', guard: (_) => true)],
          minDwellFrames: -1,
        ),
        throwsA(isA<StateMachineException>()),
      );
      expect(
        () => StateMachine(
          initialState: 'A',
          transitions: [Transition(src: 'A', dst: 'B', guard: (_) => true)],
          voteWindow: 0,
        ),
        throwsA(isA<StateMachineException>()),
      );
    });
  });

  group('仿真：刻意抖动的深蹲序列', () {
    // 与真实深蹲定义一致的六条边 —— **必须含「假动作」回退边**。
    // 少了它，站立段在 170 边界的抖动根本没有边可走，对照实验就证明不了任何事
    // （曾经那条测试就是这么"通过"得毫无意义）。
    StateMachine squatWithFallback({
      required int minDwellFrames,
      required int voteWindow,
      required int voteRequired,
    }) =>
        StateMachine(
          initialState: 'STANDING',
          transitions: [
            Transition(
              src: 'STANDING',
              dst: 'DESCENT',
              guard: kneeBelow(170),
              label: 'standing->descent',
            ),
            Transition(
              src: 'DESCENT',
              dst: 'BOTTOM',
              guard: kneeBelow(135),
              label: 'descent->bottom',
            ),
            Transition(
              src: 'DESCENT',
              dst: 'STANDING',
              guard: kneeAbove(172),
              label: 'descent->standing(假动作)',
            ),
            Transition(
              src: 'BOTTOM',
              dst: 'ASCENT',
              guard: kneeAbove(143),
              label: 'bottom->ascent',
            ),
            Transition(
              src: 'ASCENT',
              dst: 'STANDING',
              guard: kneeAbove(172),
              label: 'ascent->standing',
            ),
            Transition(
              src: 'ASCENT',
              dst: 'DESCENT',
              guard: kneeBelow(135),
              label: 'ascent->descent(回蹲)',
            ),
          ],
          minDwellFrames: minDwellFrames,
          voteWindow: voteWindow,
          voteRequired: voteRequired,
        );

    /// 一段恶劣的膝角序列。
    ///
    /// **抖动必须同时跨越两个阈值**（下降线 170 与回升线 172），否则证明不了防抖有用：
    /// 只在 169/171 之间抖的话，两者都低于 172，**滞回一条机制就挡住了**，
    /// 对照组也就干净如常。这一点是踩过才知道的 —— 曾经那条对照实验就是这么
    /// "优雅地通过"，但什么都没验证。
    ///
    /// 同理，底部抖动要跨 135（DESCENT→BOTTOM 的线）。
    ///
    /// 尾部给足 6 帧 >172 —— 回到站立需要 4-of-5 的票，帧数不够就回不去，
    /// 那是序列的问题而不是防抖的问题。
    const jitteryKnees = <double>[
      // 站立段：在滞回带【两侧】反复跳（166 低于 170、176 高于 172）
      166, 176, 166, 176, 166, 176, 166, 176, 166, 176,
      // 真正下降
      160, 150, 140, 136,
      // 底部：在 135 两侧反复跳
      134, 136, 134, 136, 134, 136, 134, 136,
      // 到底（连续 3 帧，配合上一段凑满 4-of-5）
      120, 118, 116,
      // 起身
      130, 145, 155, 165,
      // 回到站立并稳定
      175, 178, 178, 178, 178, 178,
    ];

    List<String> runAndCollect(StateMachine machine) {
      final visited = <String>[machine.state];
      for (var i = 0; i < jitteryKnees.length; i++) {
        final u = machine.update({'knee': jitteryKnees[i]}, i * 33);
        if (u.changed) visited.add(u.state);
      }
      return visited;
    }

    test('防抖开启时一路只向前走，不因抖动往返', () {
      final visited = runAndCollect(
        squatWithFallback(minDwellFrames: 3, voteWindow: 5, voteRequired: 4),
      );
      expect(
        visited,
        equals(['STANDING', 'DESCENT', 'BOTTOM', 'ASCENT', 'STANDING']),
        reason: '抖动造成了额外的状态往返：$visited',
      );
    });

    test('关掉防抖后同一序列会被抖乱（证明抖动本身足够恶劣）', () {
      final visited = runAndCollect(
        squatWithFallback(minDwellFrames: 0, voteWindow: 1, voteRequired: 1),
      );
      // 干净走完一次只需 4 次转移；被抖乱后会明显更多
      expect(
        visited.length - 1,
        greaterThan(4),
        reason: '对照组没被抖乱，说明序列不够恶劣，上面那条测试也就证明不了什么：$visited',
      );
      // 而且会出现「回到站立又立刻下去」这类往返
      final standingCount = visited.where((s) => s == 'STANDING').length;
      expect(standingCount, greaterThan(2), reason: '对照组应出现多次回到站立：$visited');
    });
  });
}
