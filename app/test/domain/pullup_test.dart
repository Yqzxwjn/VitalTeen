/// 引体向上动作定义测试。
///
/// 与 `domain/tests/test_pullup.py` 的断言**逐条对应**：合成几何相同、阈值相同、
/// 结论相同。语言之间出现分歧时 `check_all.py` 不会报警 —— 唯一的发现方式就是
/// 两侧各有一份说同一件事的测试。
///
/// 这里钉住五类结论，每一类都是「不做就会**静默**出错」的：
///
/// 1. **分段信号是肘角，判定信号是肘角 + 嘴高差 + 躯干倾角 —— 三者互不干扰。**
///    合成帧的三个自变量是各自独立造的（各有一个几何支点），所以能造出
///    「拉到位但身体在荡」「不荡但没回到直臂」这类交叉用例。谁把它们耦合起来，
///    一条规则的命中就会跟着另一条的自变量变。
/// 2. **「算不算一次」与「做得好不好」是两条线。** 没到过 `TOP` 的那些根本不进
///    计数（走 `discardedReps`），而下颌过杠那条管的是进来的那些 —— 两者合成
///    一条，用户就分不清「这一次没算」与「这一次算了但可以更好」。
/// 3. **下颌过杠那条切在顶点段（`Phase.apex`），而这件事只有在「读不到」时才
///    看得出差别。** 下面有一条专门造「拉到顶之后脸就被上臂挡住」的断言，
///    并且用**同一批帧 + 把窗口换回整段的对照定义**证明那份「不报」真的来自
///    窗口。这条规则是本动作唯一一条会因为遮挡而改变结论的。
/// 4. **`PULLUP_NOT_DEAD_HANG` 的阈值必须高于分段线。** 低于的话「整段最大值
///    越界」恒假（封存条件就要求最大值超过分段线），规则永远不触发、也不报错。
///    下面有一条把这件事量出来的断言。
/// 5. **三条判定都不挂本人基线。** 肘角是关节夹角、嘴高差已用躯干长归一、
///    躯干倾角是绝对偏角，再乘一个基线只会引入噪声；而挂错的表现是阈值整体
///    挪位、判错率变，不报错。
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
import 'package:vitalteen_app/domain/exercises/pullup.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/pose.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/state_machine.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

import '../support/synthetic_pullup.dart';

/// 站立基线。**引体向上三条判定一条都不用它**（全是绝对量），但它仍然要采 ——
/// 那是 `Calibrator` 的门槛，也是「开始之前先站好」那一步的产物，
/// 与其余动作共用同一套流程。
const Calibration _standingCalibration = Calibration(
  kneeAngle: 175.0,
  trunkLean: 0,
  heelRiseRatio: 0.0,
  frames: 15,
);

/// 内联阈值表。三条判定的取值只为本测试服务，见文件头。
///
/// 取值刻意离合成帧的取值远一点，免得断在阈值同侧的边界上：
/// 悬垂 175° 对阈 170°、到顶嘴高差 −0.15 对阈 −0.10、倾角 0 对阈 20°。
///
/// **注意 `pullup.chin_over_dy_max` 是一个负数** —— 下颌过杠的判据是「嘴高于
/// 手腕」，在这个带符号的特征上是负值。所以本文件里不能断言「阈值一律为正」，
/// 只能断言「非零、有限」。
Threshold _threshold(
  String key,
  double value,
  String featureCode, {
  String unit = 'ratio',
}) =>
    Threshold(
      key: key,
      actionCode: pullupActionCode,
      featureCode: featureCode,
      value: value,
      unit: unit,
      sourceType: SourceType.literature,
      version: 'test',
    );

ThresholdTable _localTable() => ThresholdTable(
      [
        _threshold('pullup.dead_hang_min_elbow', 170.0, 'elbow_angle_L',
            unit: 'deg'),
        _threshold('pullup.chin_over_dy_max', -0.10, 'mouth_wrist_dy'),
        _threshold('pullup.swing_max_lean_deg', 20.0, 'trunk_lean',
            unit: 'deg'),
      ],
      version: 'test',
    );

/// 与产品一致：引体向上走 45° 主链路（`productCameraView`）。
TrackingConfig _config() =>
    const TrackingConfig(cameraView: CameraView.oblique45, maxRepFrames: 180);

ActionRunner _runner({ThresholdTable? thresholds, ActionDefinition? definition}) =>
    ActionRunner(
      definition ?? buildPullup(_standingCalibration, config: _config()),
      thresholds: thresholds ?? _localTable(),
      calibration: _standingCalibration,
    );

/// 把「下颌未过杠」那条规则的窗口从顶点段换成整段，**其余一字不动**。
///
/// 用来做**对照**：同一批帧、同一条规则，只有窗口不同。结论不同就证明那处窗口
/// 真的在起作用 —— 而不是「不报」这件事碰巧由别的原因（比如压根没计数）造成。
ActionDefinition _chinRuleOnWholeRep() {
  final base = buildPullup(_standingCalibration, config: _config());
  return ActionDefinition(
    code: base.code,
    nameZh: base.nameZh,
    cameraView: base.cameraView,
    config: base.config,
    states: base.states,
    restingState: base.restingState,
    bottomState: base.bottomState,
    transitions: base.transitions,
    rules: [
      for (final rule in base.rules)
        if (rule.code == 'PULLUP_CHIN_NOT_OVER')
          Rule(
            code: rule.code,
            nameZh: rule.nameZh,
            metric: rule.metric,
            thresholdKey: rule.thresholdKey,
            badSide: rule.badSide,
            // ← 唯一改动。
            phase: Phase.all,
            useAbs: rule.useAbs,
            reduce: rule.reduce,
            minViolatingFrames: rule.minViolatingFrames,
            severitySpan: rule.severitySpan,
          )
        else
          rule,
    ],
    stateToPhase: base.stateToPhase,
    thresholdOffsets: base.thresholdOffsets,
    lossRecovery: base.lossRecovery,
  );
}

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

/// 产品机位下读一帧的特征值。
///
/// 三个自变量用的特征（`elbow_angle_*` / `mouth_wrist_dy` / `trunk_lean`）
/// 在 45° 下都**没有机位门控**，所以这个读取器与 runner 内部用的那个一致。
const FeatureExtractor _productView =
    FeatureExtractor(cameraView: CameraView.oblique45);

double? _feature(PoseFrame frame, String code) =>
    _productView.extract(frame).get(code);

/// 造一次「拉到顶那一刻起，脸就被上臂挡住」的引体向上。
///
/// 嘴点在**顶点段与它之后的整段下放**上不可见，上拉段与悬垂段正常可见。
/// 顶点段的嘴高差由 [topMouthWristDy] 给 —— 传一个**该被判违规**的值，
/// 用来看规则到底判不判。
///
/// **为什么连下放段一起挡住**：状态机换相要经过投票窗口，确认会滞后几帧，
/// 所以顶点相位窗口的**尾巴上有几帧其实是下放**（见下面那条测试的注释）。
/// 只挡顶点段的话，那几帧照样会被读到 —— 这条用例要验的是「整段读不到就不判」。
List<PoseFrame> _repWithMouthHiddenFromTheTop({
  required double topMouthWristDy,
}) =>
    pullupFromSegments([
      pullupHang,
      pullupMid,
      pullupMouthHidden(PullupSegment(
        elbowDeg: pullupTopElbowDeg,
        mouthWristDy: topMouthWristDy,
      )),
      pullupMouthHidden(pullupMid),
      pullupHang,
    ]);

void main() {
  group('构造期校验', () {
    test('分段线顺序被违反时当场炸，而不是悄悄多一条边', () {
      // 这两条线全是可调的工程参数。调乱之后状态机不会报错，只会多一条
      // 「一进新状态就成立」的边 —— 那种故障的表现是「计数偶尔不对」，
      // 离病因非常远。把两条线的含义写反（顶部线跑到悬垂线上面）是最容易
      // 犯的一种：看起来只是两个数字换了位置。
      expect(
        () => buildPullup(
          _standingCalibration,
          config: const TrackingConfig(
            cameraView: CameraView.oblique45,
            pullupHangDeg: 120.0,
            pullupTopDeg: 150.0,
          ),
        ),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('默认机位是 45°，三个自变量在 45° 下都读得出来', () {
      final definition = buildPullup(_standingCalibration);
      expect(definition.cameraView, CameraView.oblique45);

      // 判据用的特征在主链路机位下必须可用 —— 判掉一个就等于少一条规则，
      // 而规则不可用时不命中、也不报错。
      const oblique = FeatureExtractor(cameraView: CameraView.oblique45);
      final frame = pullupPose(timestampMs: 0);
      for (final code in [
        'elbow_angle_L',
        'mouth_wrist_dy',
        'trunk_lean',
      ]) {
        expect(oblique.extract(frame).get(code), isNotNull, reason: code);
      }
    });

    test('三条判定都用绝对阈值 —— 一个基线偏移都不挂', () {
      // 挂错的表现是阈值整体挪位、判错率变，而它不报错。肘角是关节夹角、
      // 嘴高差已用躯干长归一、躯干倾角是绝对偏角，三者都与体型、站姿习惯
      // 无关，所以偏移表必须为空。
      final definition = buildPullup(_standingCalibration, config: _config());
      expect(
        definition.thresholdOffsets,
        isEmpty,
        reason: '三条判定的阈值都是绝对的，一个偏移都不该有',
      );
    });
  });

  group('合成姿态的数值', () {
    test('肘角、嘴高差、躯干倾角三个量都是精确造出来的', () {
      // 判定测试要断的是「越没越过阈值」，所以自变量必须算得准。
      // 俯卧撑那边髋偏离只有近似（分母跟着动），这一份三个量都是精确的，
      // 差异来自支点的选法：引体向上的腕点钉在杠上不动。
      for (final deg in [
        pullupHangElbowDeg,
        pullupMidElbowDeg,
        pullupTopElbowDeg,
      ]) {
        final frame = pullupPose(timestampMs: 0, elbowDeg: deg);
        expect(_feature(frame, 'elbow_angle_L'), closeTo(deg, 1e-9),
            reason: '肘角应当逐位等于传入值');
        // 两侧都造得出来，分段用的均值才等于它。
        expect(_feature(frame, 'elbow_angle_R'), closeTo(deg, 1e-9));
      }

      for (final dy in [pullupHangMouthDy, pullupMidMouthDy, pullupTopMouthDy]) {
        final frame = pullupPose(timestampMs: 0, mouthWristDy: dy);
        expect(_feature(frame, 'mouth_wrist_dy'), closeTo(dy, 1e-9),
            reason: '嘴高差应当逐位等于传入值');
      }

      for (final lean in [0.0, 12.0, -20.0]) {
        final frame = pullupPose(timestampMs: 0, trunkLeanDeg: lean);
        expect(_feature(frame, 'trunk_lean'), closeTo(lean, 1e-6),
            reason: '躯干倾角应当逐位等于传入值');
      }
    });

    test('嘴高差带符号：悬垂为正、到顶为负', () {
      // **不能取绝对值。** 取绝对值会把「挂在杠下」与「拉过头」压成同一个数，
      // 于是「下颌未过杠」这条规则会同时指向两种方向相反的姿势 ——
      // 而它给的纠正建议只有一句。这条断言就是那个符号约定的守门人。
      expect(pullupHangMouthDy, greaterThan(0));
      expect(pullupTopMouthDy, lessThan(0));

      final hanging = pullupPose(timestampMs: 0);
      final atTop = pullupPose(
        timestampMs: 0,
        elbowDeg: pullupTopElbowDeg,
        mouthWristDy: pullupTopMouthDy,
      );
      expect(_feature(hanging, 'mouth_wrist_dy')!, greaterThan(0));
      expect(_feature(atTop, 'mouth_wrist_dy')!, lessThan(0));
    });

    test('三个自变量互不干扰', () {
      // 造出「拉到位但身体在荡」与「不荡但拉到顶」两个交叉姿态：
      // 改一个自变量不该动到另一个的读数。耦合起来的话，一条规则的命中
      // 会跟着另一条的自变量变，而屏幕上只表现为「这两条老是乱报」。
      final leanOnly = pullupPose(timestampMs: 0, trunkLeanDeg: 25.0);
      expect(_feature(leanOnly, 'elbow_angle_L'), closeTo(pullupHangElbowDeg, 1e-9));
      expect(_feature(leanOnly, 'mouth_wrist_dy'), closeTo(pullupHangMouthDy, 1e-9));

      final topOnly = pullupPose(
        timestampMs: 0,
        elbowDeg: pullupTopElbowDeg,
        mouthWristDy: pullupTopMouthDy,
      );
      expect(_feature(topOnly, 'trunk_lean'), closeTo(0.0, 1e-6));
    });
  });

  group('分段', () {
    test('标准一次计 1', () {
      final runner = _runner();
      _feed(runner, pullupRepFrames(startTimestampMs: 0));

      expect(runner.repCount, 1, reason: '丢弃了 ${runner.discardedReps}');
      expect(runner.discardedReps, 0);
      expect(runner.currentState, PullupStates.hang);
    });

    test('没拉到顶就落回来：计 0、弃 1', () {
      // 「引体向上」这个动作的判定对象就是「拉到顶再落回直臂悬垂」。只弯到
      // 130°（够不着 `pullupTopDeg` 90°）的那一次**不算一次**，而它也不是
      // 无声无息地消失 —— `discardedReps` 记账，界面解释为「有 N 次没计入」。
      //
      // 这也正是下颌过杠那条规则不去管的事：把没到顶的那些也算进来，
      // 用户会被告知一个他并没有做的动作有问题。
      final runner = _runner();
      _feed(
        runner,
        pullupFromSegments(
          [
            pullupHang,
            pullupMid,
            pullupHang,
          ],
          startTimestampMs: 0,
        ),
      );

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 1);
      expect(runner.currentState, PullupStates.hang, reason: '要回到悬垂等下一次');
    });

    test('守卫的上下界', () {
      // 上面那条计数测试一旦变绿，就可能是因为「压根没离开 HANG」——
      // 那样它证明的是别的东西。这里直接对守卫求值。
      final definition = buildPullup(_standingCalibration, config: _config());

      bool at(String src, String dst, double elbow) =>
          _guardOf(definition, src, dst)({'elbow_angle_L': elbow});

      expect(at(PullupStates.hang, PullupStates.pulling, pullupHangElbowDeg),
          isFalse);
      expect(at(PullupStates.hang, PullupStates.pulling, pullupMidElbowDeg),
          isTrue);
      expect(at(PullupStates.hang, PullupStates.pulling, pullupTopElbowDeg),
          isTrue);

      expect(at(PullupStates.pulling, PullupStates.top, pullupMidElbowDeg),
          isFalse);
      expect(at(PullupStates.pulling, PullupStates.top, pullupTopElbowDeg),
          isTrue);

      // 开局与封存落到 HANG 用的是**同一条线**：HANG 只有一个含义。
      expect(
        _guardOf(definition, PullupStates.lowering, PullupStates.hang),
        same(_guardOf(definition, PullupStates.pulling, PullupStates.hang)),
      );

      // 而滞回带保证「刚进 TOP」的那一帧不会被同一条线立刻推出去。
      expect(at(PullupStates.top, PullupStates.lowering, 91.0), isFalse);
      expect(at(PullupStates.top, PullupStates.lowering, 99.0), isTrue);
    });

    test('回拉不卡死：下放到一半又拉上去，仍然落得回来', () {
      // 守卫看不见时间，没有 `LOWERING → PULLING` 这条边的话，
      // 「放到一半又来劲了」会停在 LOWERING 直到帧上限 —— 既不计数也不丢弃，
      // 只是每一帧都显示着一个错的状态词。
      final runner = _runner();
      _feed(
        runner,
        pullupFromSegments(
          [
            pullupHang,
            pullupMid,
            pullupTop,
            pullupMid, // 下放到一半
            pullupTop, // 又拉回去
            pullupMid,
            pullupHang, // 终于落回 → 封存
          ],
          startTimestampMs: 0,
        ),
      );

      expect(runner.repCount, 1, reason: '回拉之后仍然要落得回来');
      expect(runner.currentState, PullupStates.hang);
    });

    test('挂在杠上不动：既不计数也不丢弃', () {
      final runner = _runner();
      _feed(runner, pullupHangFrames(count: 60));

      expect(runner.repCount, 0);
      expect(runner.discardedReps, 0, reason: '挂着不动不该被记账成一次丢弃');
      expect(runner.currentState, PullupStates.hang);
    });

    test('HANG 不产出相位，TOP 产出的是 apex', () {
      // `RepWindow.select` 在相位缺失时**静默**返回整段。HANG 不映射相位是
      // 刻意的（rep 缓冲从离开悬垂那一帧开始，悬垂段天然不在已封存的 rep 里），
      // 但 TOP 必须映射到 `Phase.apex` —— 下颌过杠那条规则切的就是它，
      // **漏映射的后果是它悄悄跑在整个 rep 上**，而那是另一条测试在钉的事。
      final definition = buildPullup(_standingCalibration, config: _config());

      final runner = _runner();
      _feed(runner, pullupRepFrames(startTimestampMs: 0));
      final window = runner.windows.single;

      expect(
        window.phaseBounds.keys.toSet(),
        {Phase.descent, Phase.apex, Phase.ascent},
        reason: 'HANG 不该有相位；三个非悬垂状态各一个',
      );
      for (final phase in [Phase.descent, Phase.apex, Phase.ascent]) {
        final bounds = window.phaseBounds[phase]!;
        expect(bounds.end - bounds.start + 1, lessThan(window.frames.length),
            reason: '相位退化成了整段');
      }

      // 而 apex 确实是「最高那一段」：它的帧索引落在 descent 之后、ascent 之前。
      expect(
        window.phaseBounds[Phase.apex]!.start,
        greaterThan(window.phaseBounds[Phase.descent]!.end - 1),
      );

      // 反面：三条规则里恰好只有下颌过杠那条切窗口。
      expect(
        definition.rules
            .where((r) => r.phase != Phase.all)
            .map((r) => r.code)
            .toList(),
        ['PULLUP_CHIN_NOT_OVER'],
        reason: '别把另外两条顺手也切进某个相位 —— 它们问的是整次动作的极值',
      );
    });
  });

  group('三条规则', () {
    test('未回到直臂悬垂：只命中手臂一直弯着的那一次', () {
      // 落回来时肘角停在 168°：**低于绝对阈值 170°、高于分段线 165°** ——
      // 于是这一次被正常计数，然后被这条规则指出「没伸直」。
      // 停在 160°（够不着分段线）的话这一次会被 `bottomState` 挡在外面、
      // 整段丢弃，这条规则根本没机会求值。
      final soft = _runner();
      _feed(soft, pullupRepFrames(startTimestampMs: 0, hangElbowDeg: 168.0));
      expect(soft.repCount, 1, reason: '过了 pullupHangDeg（165°），算一次');
      expect(_statOf(soft.finishSet(), 'PULLUP_NOT_DEAD_HANG'), isNotNull);

      final straight = _runner();
      _feed(straight, pullupRepFrames(startTimestampMs: 0));
      expect(
        _statOf(straight.finishSet(), 'PULLUP_NOT_DEAD_HANG'),
        isNull,
        reason: '回到直臂悬垂不该被判未伸直 —— 否则这条规则是「永远命中」',
      );
    });

    test('阈值若定在分段线之下，这条规则恒不触发', () {
      // **这是一条「把注释里的推理量出来」的测试**，不是在验产品行为。
      // 封存条件是「肘角回到分段线 165° 以上」，所以每一个被计数的 rep 的
      // 整段最大值都必然 > 165°。阈值定在 160° 时「最大值越界」恒假 ——
      // 规则永远不触发，**而且不报错**。所以资产表里那条线只能取在 165° 之上。
      final trapped = _runner(
        thresholds: ThresholdTable(
          [
            _threshold('pullup.dead_hang_min_elbow', 160.0, 'elbow_angle_L',
                unit: 'deg'),
            _threshold('pullup.chin_over_dy_max', -0.10, 'mouth_wrist_dy'),
            _threshold('pullup.swing_max_lean_deg', 20.0, 'trunk_lean',
                unit: 'deg'),
          ],
          version: 'test',
        ),
      );
      _feed(trapped, pullupRepFrames(startTimestampMs: 0, hangElbowDeg: 168.0));
      expect(trapped.repCount, 1);
      expect(
        _statOf(trapped.finishSet(), 'PULLUP_NOT_DEAD_HANG'),
        isNull,
        reason: '168° 的整段最大值已经越过了 160° 这条线 —— 它本来就是坏的',
      );
    });

    test('下颌未过杠：只命中拉起来但嘴没高过杠的那一次', () {
      // 到顶时嘴还停在杠下（高差 +0.05 > 阈值 −0.10）：这一次**算数**
      // （肘角到了 `pullupTopDeg`），只是高度不够。
      final short = _runner();
      _feed(
        short,
        pullupRepFrames(startTimestampMs: 0, topMouthWristDy: 0.05),
      );
      expect(short.repCount, 1, reason: '到了顶就算一次 —— 判定的是「算数的那次好不好」');
      expect(_statOf(short.finishSet(), 'PULLUP_CHIN_NOT_OVER'), isNotNull);

      final over = _runner();
      _feed(over, pullupRepFrames(startTimestampMs: 0));
      expect(
        _statOf(over.finishSet(), 'PULLUP_CHIN_NOT_OVER'),
        isNull,
        reason: '下颌过杠不该被判未过杠',
      );
    });

    test('拉到顶之后脸被挡住时，这条规则不触发（切窗口的意义）', () {
      // **本文件里最值钱的一条。** 同一个「嘴还停在杠下」的姿态，
      // 唯一的差别是顶点段的嘴点看不见。切在 `Phase.apex` 上时那一段
      // 一个可用值都没有 → 规则不触发；跑在整段上时，上拉段那个看得见的
      // 读数会被 `reduce: min` 取成「这一次里最高的一帧」，于是
      // **脸被上臂挡住、其实拉得很到位的人会被判成没拉上去**。
      //
      // 代价是这条判定会因为遮挡而**静默地不生效** —— 那是有意选的：
      // 少判一次是提示，误报一次是告诉用户他做错了。
      final frames = _repWithMouthHiddenFromTheTop(topMouthWristDy: 0.05);

      final hidden = _runner();
      _feed(hidden, frames);
      expect(hidden.repCount, 1, reason: '肘角照样到了顶 —— 计数不受遮挡影响');
      expect(
        _statOf(hidden.finishSet(), 'PULLUP_CHIN_NOT_OVER'),
        isNull,
        reason: '顶点段的嘴读不到，应当「不知道」而不是「没过杠」',
      );

      // **对照：同一批帧、同一条规则，只把窗口换回整段 —— 必须命中。**
      // 这一半是决定性的：它证明上一条的「不报」真的来自窗口，
      // 而不是来自别的原因（计数没发生、阈值根本没被查到之类）。
      final whole = _runner(definition: _chinRuleOnWholeRep());
      _feed(whole, frames);
      expect(whole.repCount, 1);
      expect(
        _statOf(whole.finishSet(), 'PULLUP_CHIN_NOT_OVER'),
        isNotNull,
        reason: '窗口换成整段之后，上拉段那个读数就会被取到 —— 这正是要防的误报',
      );

      // 第三个对照组：同一个姿态、嘴看得见 → 也必须命中。
      // 否则「嘴挡住时规则安静」可能是因为这条规则压根不工作。
      final visible = _runner();
      _feed(visible, pullupRepFrames(startTimestampMs: 0, topMouthWristDy: 0.05));
      expect(_statOf(visible.finishSet(), 'PULLUP_CHIN_NOT_OVER'), isNotNull);
    });

    test('身体摆动借力：只命中荡起来的那一次，且不看方向', () {
      // 符号取决于人面朝画面哪一侧，不是体育含义，所以 `useAbs` ——
      // 前后两个方向的摆动都要判命中。
      for (final lean in [25.0, -25.0]) {
        final swinging = _runner();
        _feed(
          swinging,
          pullupRepFrames(startTimestampMs: 0, trunkLeanDeg: lean),
        );
        expect(swinging.repCount, 1);
        expect(
          _statOf(swinging.finishSet(), 'PULLUP_SWING'),
          isNotNull,
          reason: '倾角 $lean° 应当被判成摆动',
        );
      }

      final steady = _runner();
      _feed(steady, pullupRepFrames(startTimestampMs: 0));
      expect(_statOf(steady.finishSet(), 'PULLUP_SWING'), isNull);
    });

    test('三条规则互不顶替：一次标准动作一条都不命中', () {
      // 三条规则各自都有自己的用例，但**同时**干净的这一次是另一回事：
      // 谁的方向或窗口写错一点点，很可能在单条用例里看不出来、在这里露出来。
      final runner = _runner();
      _feed(runner, pullupRepFrames(startTimestampMs: 0));
      expect(runner.repCount, 1);

      final summary = runner.finishSet();
      expect(summary.faultStats, isEmpty);
    });
  });

  group('阈值表的三个键', () {
    test('规则引用的键与内联表对得上，且非零、有限', () {
      final definition = buildPullup(_standingCalibration, config: _config());
      final table = _localTable();
      for (final rule in definition.rules) {
        final value = table.get(rule.thresholdKey).value;
        // **不能断言 isPositive**：下颌过杠那条的阈值就是负数
        //（见 `_threshold` 的注释）。
        expect(value.isFinite && value != 0, isTrue,
            reason: '${rule.code} 的阈值取到了 0 或非有限值');
      }
    });

    test('下颌过杠的阈值是个负数', () {
      // 那个量的符号约定（嘴高于腕 = 负）一旦被谁改成「取绝对值再判」，
      // 正负号就会失去意义、两条方向相反的姿势被压成同一个数。
      // 阈值的正负是那个约定的守门人。
      final definition = buildPullup(_standingCalibration, config: _config());
      final table = _localTable();
      final key = definition.rules
          .firstWhere((r) => r.code == 'PULLUP_CHIN_NOT_OVER')
          .thresholdKey;
      expect(table.get(key).value, lessThan(0));
    });
  });

  group('真实阈值表', () {
    // 上面那些用例用的是内联表：键名与资产表一致、数值不必一致 —— 于是「资产表里
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

    test('引体向上引用的每一个阈值键都真实存在', () {
      for (final rule in buildPullup(_standingCalibration).rules) {
        expect(
          () => table.get(rule.thresholdKey),
          returnsNormally,
          reason: '规则 ${rule.code} 引用了不存在的阈值键 ${rule.thresholdKey}',
        );
      }
    });

    test('用真实资产表构造 FaultPresenter 与 FormScorer 都不抛', () {
      final definition = buildPullup(_standingCalibration);
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

    test('三条权重都被读到，且有限、为正', () {
      // 走 `scoreRep` 而不是直接查表：这样才能证明 `_weights[code]!` 那一步
      // 真的取到了值 —— 键名双前缀（`pullup.fault_weight.pullup_swing`）这类
      // 拼写错误，直接查表时是查「我拼的那个名字」，永远自洽。
      final definition = buildPullup(_standingCalibration);
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
          table.get('pullup.form_score_rating_breakpoints').severityBreakpoints;
      expect(breakpoints, hasLength(FormRating.values.length - 1));
      for (var i = 1; i < breakpoints.length; i++) {
        expect(breakpoints[i], greaterThan(breakpoints[i - 1]));
      }
    });

    test('随包发出的表全是 pending_review，所以这一组分数必然带「暂定」标', () {
      // 断言的是**机制**：核定之后 `provisional` 应当自己变成 false，
      // 不需要有人记得回来改这条测试。
      final definition = buildPullup(_standingCalibration);
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
      _feed(runner, pullupRepFrames(startTimestampMs: 0));
      final score = scorer.scoreSet(runner.finishSet());
      expect(score, isNotNull);
      expect(score!.provisional, isTrue);
    });
  });
}
