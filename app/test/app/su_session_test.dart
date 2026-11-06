/// 仰卧起坐在**会话层**的接线测试。
///
/// 领域层那组（`test/domain/su_test.dart`）验的是「动作定义本身对不对」。
/// 这一组验的是**另一件事**：动作定义接进产品管线之后还对不对。两者之间隔着
/// 一整层 `ActionSpec`，而那一层里每一处接错的失败方式都是静默的：
///
/// - **阈值/权重没接到真实资产表** —— `FaultPresenter` 与 `FormScorer` 都在
///   构造期解析全部键、缺失即抛，而构造点在 `_buildRunner` 里，也就是
///   **用户做完一组、标定刚结束的那一刻**。一组白做。
/// - **站位方向接反** —— 仰卧起坐要侧身（45° 下 `shoulder_height_ratio` 与
///   `body_line_offset_ratio` 才可用）。接反的话正视的人能进去，而那三条判定里
///   **两条静默消失** —— 用户做完一整组，报告里只字不提肩没贴垫、髋顶起来了。
/// - **必需点名单照抄了深蹲的** —— 名单里有没有脚跟，决定躺下去之后左脚出画
///   会不会被拦住，也决定拦他的理由是不是「脚跟离地判定做不了」。
/// - **[ActionSpec.framingHint] 给错了姿势** —— 仰卧起坐**不能坐着开始**，
///   理由见下面那个「已知缺陷」组。
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

import '../support/synthetic_su.dart';

/// 随包发出的阈值表。与 `test/domain/su_test.dart` 的「真实阈值表」组同款。
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

/// 会话里的这个人占画幅多大。
///
/// **不取默认的 1.0。** 合成帧默认那个人躺下只占 45.1%，而门禁 `tooFarBelow`
/// 是 0.45 —— 过是过了，只过 0.1%。会话层的测试要的是一个站得住的人，
/// 不是「卡着门槛过」的人：那样一条测试会因为合成了几个像素而红，
/// 而红的原因与它要验的东西毫无关系。
///
/// 1.5 是「手机放得合适」的那一档：躺下占 67.7%，四周都留着边（不出画）。
const double _scale = 1.5;

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

/// 走到「计数中」的会话，附带投喂器。**收尾时人已经躺在垫上。**
///
/// **用躺着的帧标定**，不是坐着的 —— 见「已知缺陷」那一组：
/// 坐姿在门禁的距离判据下会被拦人，而相机页的自动倒计时以「门禁放行」为条件。
/// 这里如果照深蹲那样用「站着的帧」，测的就不是产品真走得通的那条路。
///
/// 标定走完之后**再喂一段躺着的帧**，不是凑数：标定结束时状态机还在
/// `SEATED`，它要走到 `LYING` 得穿过 `LOWERING`。那段路没走完就喂「坐起来」，
/// 机器会把一次没到过底部的起身记进 `discardedReps` —— 而真实用户躺下之后
/// 本来也有这一下，测试要测的是「安顿好之后做动作」，不是「边躺边做」。
(SquatSession, _Driver) _countingSession() {
  final session = SquatSession(thresholds: _realTable(), spec: suSpec);
  addTearDown(session.dispose);
  final driver = _Driver(session);

  driver.feed(suLyingFrames(count: 20, scale: _scale));
  expect(session.beginCalibration(), isTrue, reason: '门禁应当放行');
  driver.feed(suLyingFrames(count: 20, startTimestampMs: driver.clock, scale: _scale));
  expect(session.view.value.phase, SessionPhase.counting);
  driver.feed(suLyingFrames(count: 20, startTimestampMs: driver.clock, scale: _scale));
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

/// 造一批「门禁读成正视」的帧。
///
/// 侧视下 `lateralRatio` 是 0.05，放大那条 0.01 的横向缝 **13 倍**就刚过
/// `frontalRatio`（0.62）。取「刚过线」而不是放大到 20 倍：20 倍会让这个人
/// 同时贴上画面右缘，多出一条出画提示，把「拦住你的是机位」这件事说糊。
///
/// **这不是一个物理上站得住的「正视仰卧起坐」** —— 它只对「门禁给出什么结论」
/// 这一件事有意义，见 `synthetic_su.dart` 里 `sideGapScale` 的注释。
List<PoseFrame> _facingFrontFrames({int count = 30, double gapScale = 13.0}) => [
      for (var i = 0; i < count; i++)
        suPose(timestampMs: i * 33, sideGapScale: gapScale, scale: _scale),
    ];

void main() {
  group('真实资产表 · 整条会话', () {
    test('从自检走到本组结束都不抛，且出得了分', () {
      final session = SquatSession(thresholds: _realTable(), spec: suSpec);
      addTearDown(session.dispose);
      final driver = _Driver(session);

      driver.feed(suLyingFrames(count: 20, scale: _scale));
      expect(session.view.value.canBeginCalibration, isTrue, reason: '门禁应当放行');
      expect(session.beginCalibration(), isTrue);

      driver.feed(
        suLyingFrames(count: 20, startTimestampMs: driver.clock, scale: _scale),
      );
      expect(
        session.view.value.phase,
        SessionPhase.counting,
        reason: '基线攒够之后应当自动进计数。仰卧起坐只采框架强制要求的两项'
            '（`BaselineKey.alwaysRequired`），所以这一步同时证明'
            '「只采两项也能标定完」',
      );

      // 先让他躺稳（见 `_countingSession` 的注释），再做动作。
      driver.feed(
        suLyingFrames(count: 20, startTimestampMs: driver.clock, scale: _scale),
      );
      driver.feed(suRepFrames(startTimestampMs: driver.clock, scale: _scale));
      session.finishSet();

      final view = session.view.value;
      expect(view.phase, SessionPhase.finished);
      expect(
        view.repCount,
        2,
        reason: '人是从躺姿开始的，所以 `suRepFrames` 那一段里**第一次起身**'
            '也是一次完整动作（`LYING → RISING → SEATED`，底部到过、封存得住），'
            '第二次才是躺回去又坐起来。少一多一都说明分段线或状态环被动过。',
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

    test('标准一次在真实阈值下一条错误都不命中', () {
      // 领域层那条同样的断言用的是内联表。这一条问的是**随包的数值**会不会
      // 把标准动作误判 —— 内联表的数值只为本测试服务，管不着这件事。
      //
      // 这一条对仰卧起坐格外要紧：「坐起线」是 `situpSeatRatio`（0.75），
      // 而躺着与坐着的特征读数（约 0.05 与 0.90）隔得很开，看似余量很大，
      // 但那三条判定**每条都只在某一侧生效**，谁把方向弄反都会在这里露出来。
      final (session, driver) = _countingSession();

      driver.feed(suRepFrames(startTimestampMs: driver.clock, scale: _scale));
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
    test('45° 斜前方放行，躺姿也放行', () {
      // 主链路机位。仰卧起坐与深蹲、立定跳远、俯卧撑同向：**要侧身**。
      for (final scale in [1.0, _scale]) {
        final report = _monitorFor(
          suSpec,
          suLyingFrames(count: 30, scale: scale),
        ).report;
        expect(report.view, CameraView.sagittal, reason: '这条前提要成立才有意义');
        expect(report.blocking, isFalse);
        expect(report.canStart, isTrue);
      }

      // 45° 那一档（门禁读成 `oblique45`）也放行 —— 而且**一条提示都不给**：
      // `advisoryAdvice` 刻意留了 `null`，仰卧起坐没有「提示级」那一档
      //（理由写在 `suSpec` 上）。这条断言就是那句话的可执行版本。
      final oblique = _monitorFor(
        suSpec,
        [for (var i = 0; i < 30; i++) suPose(timestampMs: i * 33, sideGapScale: 8.0, scale: _scale)],
      ).report;
      expect(oblique.view, CameraView.oblique45, reason: '这条前提要成立才有意义');
      expect(oblique.canStart, isTrue);
      expect(oblique.issues, isEmpty, reason: '站对了就不该有提示');
    });

    test('正视拦住仰卧起坐 —— 三条判定在那样的站位下少两条', () {
      // `shoulder_height_ratio` 与 `body_line_offset_ratio` 都声明
      // `[sagittal, oblique45]`。正视下身体的长边就是镜头方向本身，
      // 两个 y 方向的差都读不出来，而**特征不可用时规则不命中、也不报错**
      // —— 肩没贴垫与顶髋借力会一起消失，报告里只字不提。
      final report = _monitorFor(suSpec, _facingFrontFrames()).report;

      expect(report.view, CameraView.frontal, reason: '这条前提要成立才有意义');
      expect(report.blocking, isTrue);
      expect(report.canStart, isFalse);
    });

    test('拦人时说的是仰卧起坐自己的话，不是深蹲、开合跳或俯卧撑那一句', () {
      final report = _monitorFor(suSpec, _facingFrontFrames()).report;

      final issue = report.issues.firstWhere(
        (i) => i.code == PositionIssueCode.facingFront,
      );
      expect(issue.message, suSpec.blockingAdvice);
      expect(
        issue.message,
        isNot(squatFrontalAdvice),
        reason: '深蹲那句解释的是「膝盖的弯曲看不出来」—— 仰卧起坐不是这么失效的',
      );
      expect(issue.message, isNot(jjFrontalAdvice));
      expect(issue.message, isNot(puSpec.blockingAdvice));
    });

    test('左脚出画不拦仰卧起坐 —— 它三条判定都不碰脚跟', () {
      // 名单里没有 `leftHeel` / `leftFootIndex`：仰卧起坐三条判定一条都不碰它们，
      // 标定也不采（`suSpec.calibrationBaselines` 只有两项）。带上它们的后果是
      // 躺下之后左脚一出画就被拦住，拦他的理由说的是「脚跟离地判定做不了」——
      // 一件这个动作根本不做的事。
      expect(suSpec.requiredLandmarks, isNot(contains(L.leftHeel)));
      expect(suSpec.requiredLandmarks, isNot(contains(L.leftFootIndex)));

      final frames = [
        for (var i = 0; i < 30; i++)
          suPose(
            timestampMs: i * 33,
            scale: _scale,
            visibilityOverrides: const {
              L.leftHeel: 0.0,
              L.leftFootIndex: 0.0,
            },
          ),
      ];

      final su = _monitorFor(suSpec, frames);
      // 这一条**只断言「没有那条提示」，不断言 `canStart`**：脚跟脚尖一去掉，
      // 包围盒右缘就短了一截，会同时触发那条未标定的距离判据 —— 那是另一件事，
      // 混进来说不清楚，它自己有一条记账断言（见下一组）。
      expect(
        su.report.issues.map((i) => i.code),
        isNot(contains(PositionIssueCode.missingLeftFoot)),
      );

      // 对照组：同一批帧喂给深蹲，必须照样为左脚出画拦人 ——
      // 少了它，这条测试在「那条判据整个失效」时也会绿。
      final squat = _monitorFor(squatSpec, frames);
      expect(
        squat.report.issues.map((i) => i.code),
        contains(PositionIssueCode.missingLeftFoot),
      );
    });

    test('起始提示说的是「先躺下」，不是深蹲那句话', () {
      // 这一句三处都用（自检清单、计数屏、开跳前的语音，见 `ActionSpec.framingHint`），
      // 而它说的是**这个动作唯一走得通的起始姿势**：坐姿在距离判据下过不去。
      // 所以它必须是仰卧起坐自己的话 —— 立定跳远那句说的「往前跳的那一米」
      // 在这里指着一件不存在的事。
      expect(suSpec.framingHint, isNotNull);
      expect(suSpec.framingHint, contains('仰卧'));
      expect(suSpec.framingHint, isNot(sljSpec.framingHint));
    });
  });

  group('已知缺陷的记账', () {
    // 这一组**不是在验代码对不对，是在给一个缺陷记账**。
    //
    // 门禁判「离得远不远」的量是**身体包围盒占画幅的最大边长**
    //（`camera_position_check.dart`：两个跨度各自按画幅对应边长归一之后取 max）。
    // 它的两个阈值是按**直立的人**标定的 —— `tooFarBelow`（0.45）对站着的人成立，
    // 而仰卧起坐的起始姿势偏偏是坐着：同一个人、同一部手机，躺着占画幅多少、
    // 坐着占多少，差着一倍。少于 0.45 就**拦人**，而相机页的自动倒计时以
    // 「门禁放行」为条件：过不去就永远不进标定。
    //
    // 现在的办法是**绕开**它（`framingHint` 让用户躺着开始），不是修好它 ——
    // 要给坐姿定一个真数，得先有真机数据。
    //
    // **2026-10-06 判据改过一次（原来按姿势分叉、现在一律取 max），结论没变。**
    // 那次改动是为横屏：转正图宽大于高，只按高度占比会把站着的人判远、把横躺着
    // 的人判近。**坐姿不在这件事的受益面里** —— 坐着的身体高仍大于宽，于是 max
    // 取到的还是高，读数与改前逐位相同（下面那句「身高只占画面 26%」就是证据：
    // 词是「身高」，说明胜出的是高那一维）。
    //
    // 所以这条断言对那次改动**不敏感**，它已经不能当「有人动了距离判据」的哨兵了；
    // 那个哨兵现在在 `camera_position_check_test.dart` 里那一组。它留在这里只钉
    // 「坐姿过不去、躺姿过得去」这一个事实。
    //
    // 反过来说，哪天这条红了：说明坐姿已经能过，`suSpec.framingHint` 里
    // 「先仰卧躺下」那半句就该跟着重新考虑（它现在承担的是「唯一走得通的起始
    // 姿势」，不只是建议）。

    test('坐姿会被距离判据拦下 —— 躺着才过得去', () {
      final seated = _monitorFor(
        suSpec,
        suSeatedFrames(count: 30, scale: _scale),
      ).report;
      final lying = _monitorFor(
        suSpec,
        suLyingFrames(count: 30, scale: _scale),
      ).report;

      expect(
        seated.issues.map((i) => i.code),
        contains(PositionIssueCode.tooFar),
        reason: '坐姿被拦是**当前**的行为，不是设计。见本组开头。',
      );
      expect(seated.canStart, isFalse);
      expect(
        lying.canStart,
        isTrue,
        reason: '躺姿过得去 —— `framingHint` 让用户躺着开始，靠的就是这一条',
      );

      // **门槛与两个读数写在这里，免得下一个人以为「调一调 `scale` 就能让坐姿
      // 也过」。** 同一个人、同一个机位，两个姿势占画幅的比例差着一倍多 ——
      // 因为躺着的身体长轴横着、坐着的竖着。数字是合成帧上量的（正方形画幅）：
      // 默认 `scale` 1.0 下**躺 45.1% / 坐 26.2%**；本组用的 `_scale` 1.5 下
      // **躺 67.7% / 坐 39%** —— 坐姿那一档放大了一半还是够不着 45% 这条线。
      //
      // 这里不自己再量一遍包围盒：那等于把生产代码里那段（只统计可见点、
      // 按各自画幅边长归一）抄一份，抄本漂了没人知道。要看的只是**结论**。
      expect(
        seated.issues
            .firstWhere((i) => i.code == PositionIssueCode.tooFar)
            .message,
        contains('离得有点远'),
      );
    });
  });
}
