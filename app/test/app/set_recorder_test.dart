/// 记录器「什么时候记一条」的行为测试。
///
/// 这段逻辑只有两种坏法，而**两种都不会报错**：
///
/// - **记多了**：`finished` 相位会持续到用户按下「再来一组」，而快照是 10 Hz
///   喂进来的 —— 不挡掉同一个相位的重复投喂，站着不动的用户会在历史里留下
///   几百条一模一样的记录，而且**看不出来是哪一次坏掉的**。
/// - **记少了**：把判定挂在按钮上（而不是相位上），十秒无动作自动收工的那次
///   就永远记不下来 —— 而那恰好是最常见的一次结束。
///
/// 两者都得靠这里把「喂了几次快照 → 回调了几次」逐条比对才看得见。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/app/form_score.dart';
import 'package:vitalteen_app/app/session_record.dart';
import 'package:vitalteen_app/app/set_recorder.dart';
import 'package:vitalteen_app/app/squat_session.dart';
import 'package:vitalteen_app/domain/rules.dart';

/// 一份只填了必要字段的会话快照。
///
/// 形状照 `voice_coach_test.dart` 那份 —— 两份测的都是「读快照、做一件事」的
/// 对象，造快照的方式没有理由不一样。**只有这三个字段与记录有关**
///（[phase]、[summary]、[setScore]），其余一律给初值。
SessionView _view({
  SessionPhase phase = SessionPhase.position,
  int repCount = 0,
  SetSummary? summary,
  FormScore? setScore,
}) =>
    SessionView(
      phase: phase,
      position: PositionReport.empty(),
      calibrationFrames: 0,
      calibrationTarget: 15,
      repCount: repCount,
      discardedReps: 0,
      machineState: 'STANDING',
      kneeAngle: null,
      holdMs: 0,
      repDurationsMs: const [],
      lastRep: null,
      lastRepScore: null,
      summary: summary,
      setScore: setScore,
      interrupted: false,
      sawFrame: true,
    );

SetSummary _summary(int repCount, {List<FaultStat> faultStats = const []}) =>
    SetSummary(repCount: repCount, faultStats: faultStats);

/// 一条组级故障统计。
///
/// `scorable` 默认 **false** —— 那不是随手选的默认值，是**现在真机上唯一会发生
/// 的情况**：阈值表 69 条全是 `pending_review`，没有一条能扣分。记录器要是只存
/// 可扣分的那些，历史里就一条故障都不会有，而体态页会永远说「数据还不够」。
FaultStat _fault(String code, int count, {bool scorable = false}) => FaultStat(
      code: code,
      nameZh: code,
      scorable: scorable,
      count: count,
      rate: count / 12,
      repIndices: const [],
      worstDelta: 1.0,
    );

FormScore _score(int score, {bool provisional = false}) => FormScore(
      score: score,
      rating: FormRating.fair,
      provisional: provisional,
      penalty: (100 - score) / 100,
      terms: const [],
    );

/// 一个把收到的东西记下来的假接收方。
class _Sink {
  final List<SessionRecord> records = [];

  void call(SessionRecord record) => records.add(record);
}

/// 一套现成的「记录器 + 假接收方」，并把注入的时钟钉死。
({SetRecorder recorder, _Sink sink}) _harness({
  String actionCode = 'SQUAT',
  DateTime? now,
}) {
  final spec = specForCode(actionCode)!;
  final sink = _Sink();
  final fixed = now ?? DateTime(2026, 10, 5, 14, 30);
  return (
    recorder: SetRecorder(spec: spec, onRecord: sink.call, now: () => fixed),
    sink: sink,
  );
}

void main() {
  test('练完一组：记一条，时间取的是注入的那个钟', () {
    // **时间必须是注入的。** 会话层只持帧时间戳（从 0 开始的相机时钟），
    // 历史要的是「几月几号练的」—— 那个数只在这里取得到。
    // 用 `DateTime.now()` 的话这条断言没法写，而「记录的时间戳是哪来的」
    // 恰恰是这个类里唯一一个不能靠肉眼复查的地方。
    final fixed = DateTime(2026, 10, 5, 14, 30);
    final h = _harness(now: fixed);

    h.recorder.onView(_view(phase: SessionPhase.counting, repCount: 12));
    h.recorder.onView(_view(
      phase: SessionPhase.finished,
      repCount: 12,
      summary: _summary(12),
      setScore: _score(85),
    ));

    expect(h.sink.records.length, 1);
    final record = h.sink.records.single;
    expect(record.finishedAt, fixed);
    expect(record.repCount, 12);
    expect(record.score, 85);
    expect(record.actionCode, 'SQUAT');
    expect(record.provisional, isFalse);
  });

  test('动作码、动作名、计时制都取自 spec 本身', () {
    // 三者都从 [ActionSpec] 取，而不是从别处拼 —— 于是它们不可能与屏幕上
    // 正在练的那个动作对不上。平板支撑那一条顺带钉住「段」这个量词的数据来源。
    final squat = _harness();
    squat.recorder.onView(
        _view(phase: SessionPhase.finished, summary: _summary(9)));
    expect(squat.sink.records.single.actionNameZh,
        specForCode('SQUAT')!.nameZh);
    expect(squat.sink.records.single.isTimed, isFalse);

    final plank = _harness(actionCode: 'PLANK');
    plank.recorder.onView(
        _view(phase: SessionPhase.finished, summary: _summary(4)));
    expect(plank.sink.records.single.actionCode, 'PLANK');
    expect(plank.sink.records.single.actionNameZh,
        specForCode('PLANK')!.nameZh);
    expect(plank.sink.records.single.isTimed, isTrue,
        reason: '丢了它，界面会把「4 段」说成「4 个」');
  });

  test('同一个相位喂十次，只记一次', () {
    // 快照是 10 Hz 喂进来的，而 `finished` 会一直持续到用户按「再来一组」——
    // 那可能是几十秒。不挡重复投喂，历史里会出现几百条一模一样的记录。
    final h = _harness();
    final finished = _view(
      phase: SessionPhase.finished,
      summary: _summary(12),
      setScore: _score(85),
    );

    for (var i = 0; i < 10; i++) {
      h.recorder.onView(finished);
    }
    expect(h.sink.records.length, 1);
  });

  test('「再来一组」之后再练完，记第二条', () {
    // 一组接一组地练是正常的用法，而记录器**每次跨进 `finished` 都要记**。
    // 只在第一次跨进时记（比如拿一个 `bool` 当闸门）会让第二次以后全部丢失。
    final h = _harness();

    h.recorder.onView(_view(phase: SessionPhase.finished, summary: _summary(12)));
    // 回到站位自检，再走一遍。
    h.recorder.onView(_view(phase: SessionPhase.position));
    h.recorder.onView(_view(phase: SessionPhase.counting, repCount: 5));
    h.recorder.onView(_view(phase: SessionPhase.finished, summary: _summary(5)));

    expect(h.sink.records.length, 2);
    expect(h.sink.records.map((r) => r.repCount).toList(), [12, 5]);
  });

  test('组里的故障统计整份记下来 —— 包括不能扣分的那些', () {
    // 体态页整个功能就建在这一条上：过去每组出现过哪些问题，是唯一能
    // 跨时间看的东西。丢在这里，历史里就只剩一个分数，什么也分析不出来。
    //
    // **`scorable: false` 的那条必须也在**：阈值表 69 条全未核定，
    // `scorable` 现在恒为 false，只存可扣分的等于一条都不存。
    final h = _harness();

    h.recorder.onView(_view(
      phase: SessionPhase.finished,
      summary: _summary(12, faultStats: [
        _fault('EXCESSIVE_TRUNK_LEAN', 7),
        _fault('ASYMMETRY', 2),
        _fault('INSUFFICIENT_DEPTH', 1, scorable: true),
      ]),
      setScore: _score(85),
    ));

    expect(h.sink.records.single.faultCounts, {
      'EXCESSIVE_TRUNK_LEAN': 7,
      'ASYMMETRY': 2,
      'INSUFFICIENT_DEPTH': 1,
    });
  });

  test('这一组很干净：记空表，不是 null', () {
    // **空表与 null 是两件事**（见 `session_record.dart` 文件头）：空表是
    // 「采集到了、这组没问题」，null 是「那一版没采集过」。体态页拿前者当分母，
    // 后者直接不算 —— 折平之后，一批「不知道」会被当成「很干净」。
    final h = _harness();

    h.recorder.onView(_view(
      phase: SessionPhase.finished,
      summary: _summary(12),
      setScore: _score(92),
    ));

    final recorded = h.sink.records.single.faultCounts;
    expect(recorded, isNotNull, reason: '干净组也不能是 null');
    expect(recorded, isEmpty);
  });

  test('一个都没数到：不记', () {    // 点进练习页又立刻退出来、或者相机一个人都没看见就自动收工，
    // 都会走到这条路上。记下来会在历史里留下一堆「0 个」，而它们对齐的是
    // 用户的自我评价（「我明明练了三天，怎么历史里全是 0」）—— 比不记更糟。
    final h = _harness();

    h.recorder.onView(_view(phase: SessionPhase.counting, repCount: 0));
    h.recorder.onView(_view(phase: SessionPhase.finished, summary: _summary(0)));

    expect(h.sink.records, isEmpty);
  });

  test('快照里连汇总都没有：不记', () {
    // `SessionView.summary` 可以是 null —— 一次都没数到时连 `SetSummary`
    // 都不存在（见 `form_score.dart` 里 `scoreSet` 的签名）。
    final h = _harness();
    h.recorder.onView(_view(phase: SessionPhase.finished));
    expect(h.sink.records, isEmpty);
  });

  test('没数到的那些次不记，但数到的那些照记', () {
    // `repCount` 是**数到的**个数，被丢弃的那些不在其中（丢弃数走
    // `SessionView.discardedReps`）。用户做了 12 个、丢了 3 个，历史里该是 9。
    final h = _harness();
    h.recorder.onView(_view(phase: SessionPhase.finished, summary: _summary(9)));
    expect(h.sink.records.single.repCount, 9);
  });

  test('一次都没打上分：分数是 null，暂定标志也是 false', () {
    // **不是 0 分。** 0 是一次真实的低分（每一项都扣满了），而「一个 rep 都
    // 没打上分」是**没有分**（见 `form_score.dart` 的 `scoreSet`）。
    // 写成 0 会让用户的平均分被一次没数到的练习拉下去。
    final h = _harness();
    h.recorder.onView(_view(
      phase: SessionPhase.finished,
      summary: _summary(6),
      setScore: null,
    ));

    expect(h.sink.records.single.score, isNull);
    // `provisional` 为 true 而分数为 null 会造出一个「暂定的、但没有分数」的
    // 记录，而那种东西在界面上无从显示。
    expect(h.sink.records.single.provisional, isFalse);
  });

  test('暂定分要标出来', () {
    // 一个光秃秃的「72」看起来像正式结论，而它可能只是照着还没核定的阈值
    // 算出来的。
    final h = _harness();
    h.recorder.onView(_view(
      phase: SessionPhase.finished,
      summary: _summary(6),
      setScore: _score(72, provisional: true),
    ));

    expect(h.sink.records.single.score, 72);
    expect(h.sink.records.single.provisional, isTrue);
  });

  test('还在数的时候不记', () {
    // 只有跨进 `finished` 那一下才算练完。`counting` 期间 rep 在涨，
    // 那时候记下来的是一条半截记录。
    final h = _harness();
    h.recorder.onView(_view(phase: SessionPhase.position));
    h.recorder.onView(_view(phase: SessionPhase.calibrating));
    h.recorder.onView(_view(phase: SessionPhase.counting, repCount: 12));
    expect(h.sink.records, isEmpty);
  });

  test('第一次喂进来就是 finished：也记', () {
    // 真机上到不了这条路（记录器与会话是同一个 `State` 在 `initState` 里
    // 一起建的，会话必然从 `position` 开始），但真到了要往「多记一条」那边倒：
    // 少记的那条用户发现不了，只会觉得这个应用有时候不记事。
    final h = _harness();
    h.recorder.onView(_view(phase: SessionPhase.finished, summary: _summary(3)));
    expect(h.sink.records.length, 1);
  });
}
