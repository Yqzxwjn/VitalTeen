/// 分析面板的表单与状态测试。
///
/// 与 `squat_widgets_test.dart` 那条「只验渲染、不验交互」的分工不同：**这里的
/// 交互就是它存在的意义**。表单拦不拦、拦下来说什么、按下去之后把什么交给了
/// 谁 —— 这几件事没有别的地方在管，而它们的失败方式是「生成了一个请求」或
/// 「生成了一个服务端会拒收的请求」，两种都不会在应用里报错。
///
/// 具体盯住的是契约那几条硬约束：年龄 5–25、年级与组别 1–20 字符。它们写在
/// `shared/contracts/decision_request.schema.json` 里，而**客户端不做这一层校验
/// 的代价不在本地发生** —— 是发上去之后一个 400，那时离填表的人已经很远了。
///
/// 另一半盯住的是**四种结局各自说的话**：成了、服务端没成、本机缺件、
/// 这一组导不出。它们对用户的意义互不相同（重试 / 重装 / 重做一组），
/// 合成一句「分析失败」就把下一步弄丢了。
///
/// 报告正文长什么样不在这里测 —— 那是 `test/app/decision_report_test.dart`
/// 的事，这里用手搭的一份 [DecisionReport] 就够，只验它被摆上了界面。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/analysis.dart';
import 'package:vitalteen_app/app/decision_report.dart';
import 'package:vitalteen_app/app/decision_request.dart';
import 'package:vitalteen_app/app/decision_submission.dart';
import 'package:vitalteen_app/app/plan_catalog.dart';
import 'package:vitalteen_app/app/profile.dart';
import 'package:vitalteen_app/ui/analysis_panel.dart';

/// 一个记下「谁被问过什么」的假会话层。
class _Spy {
  final List<(Sex, int, String, String)> calls = [];
  DecisionRequest? result;

  DecisionRequest? call(Sex sex, int age, String grade, String standardGroup) {
    calls.add((sex, age, grade, standardGroup));
    return result;
  }
}

/// 一个记下「发出去的到底是什么」的假提交层。
class _Runner {
  final List<(DecisionRequest, DecisionEndpoint)> calls = [];

  /// 下一次要返回什么。`null` 表示挂住不返回（用来测「分析中」）。
  AnalysisResult? next;
  Completer<void>? blocked;

  Future<AnalysisResult> call(DecisionRequest request, DecisionEndpoint endpoint) async {
    calls.add((request, endpoint));
    final gate = blocked;
    if (gate != null) await gate.future;
    return next!;
  }
}

const PoseQuality _quality = PoseQuality(
  meanVisibility: 0.9,
  coverageOkRatio: 0.9,
  fpsMean: 30,
  gapMaxMs: 33,
  viewConfidence: 0.9,
);

DecisionRequest _request() => const DecisionRequest(
      requestId: 'local-1',
      context: DecisionContext(
        sex: Sex.female,
        age: 16,
        grade: '高一',
        standardGroup: '高中女子',
        actionCode: 'SQUAT',
        cameraView: 'oblique45',
      ),
      poseQuality: _quality,
      set: SetIn(
        repCount: 10,
        validRepCount: 10,
        tempoMeanMs: 1200,
        romMeanDeg: null,
        symmetryIndexMean: null,
        faultStats: [],
      ),
      reps: [],
      candidates: [],
      thresholdsVersion: 'test',
    );

/// 手搭的一份报告。**内容不是这里要验的东西** —— 只要各段都在，
/// 能确认「报告被摆上了界面」就够了。
///
/// 各段的取舍照抄 `buildDecisionReport` 的口径（弃权不给分、clean 不给问题），
/// 否则测的是一份真实运行中不会出现的报告 —— 那比不测更糟。
DecisionReport _report({
  ReportKind kind = ReportKind.scored,
  String? headline = '这一组做了 10 个，有一处可以改。',
  bool draft = false,
  ReportOrigin origin = ReportOrigin.server,
}) {
  final abstain = kind == ReportKind.abstain;
  final clean = kind == ReportKind.clean;
  final withFindings = !abstain && !clean;

  return DecisionReport(
    kind: kind,
    headline: headline,
    headlineSource:
        headline == null ? HeadlineSource.unavailable : HeadlineSource.serverTemplate,
    headlineIsDraft: draft,
    primary: withFindings
        ? const ReportPrimary(
            code: 'KNEE_VALGUS',
            title: '膝内扣倾向',
            severityLabel: '中度',
            repsLabel: '第 3 次',
          )
        : null,
    serviceScore: withFindings
        ? const ReportScore(formScore: 82, rating: '良', provisional: true)
        : null,
    faults: withFindings
        ? const [
            ReportFault(
              code: 'KNEE_VALGUS',
              title: '膝内扣倾向',
              severityLabel: '中度',
              repsLabel: '第 3 次',
              evidenceLine: '第 3 次 · 膝内移 0.2（参考值 0.15）',
            ),
          ]
        : const [],
    gates: withFindings
        ? const [ReportGate(code: 'KNEE_VALGUS', title: '膝内扣倾向', ok: false)]
        : const [],
    plans: abstain
        ? const []
        : const [
            ReportPlan(
              CorrectionPlan(
                planId: 'p1',
                nameZh: '箱式蹲（椅式蹲）',
                goal: '练臀中肌',
                instructions: ['坐到椅子边', '起身时膝盖对准脚尖'],
                keyCues: ['慢一点'],
                equipment: [],
                contraindications: ['膝痛时不要做'],
                status: 'draft',
                dosageText: '2 组 × 8 次',
                dosageRatified: false,
                targetFaultCodes: ['KNEE_VALGUS'],
                difficulty: 1,
                ageMin: 12,
                ageMax: 18,
              ),
            ),
          ],
    selectionReason: abstain ? '' : '针对膝内扣',
    doseNote: abstain ? '' : '动作要领：慢一点',
    disclosures: [
      const Disclosure(
        kind: DisclosureKind.notNationalStandard,
        text: '本报告只看动作做得准不准，不是国标体测成绩。',
      ),
      // 真报告里的来源声明由 `buildDecisionReport` 生成，措辞与它一起在
      // `decision_report_test.dart` 里测。这里只放一句**可辨认的替身**，
      // 验的是「声明区确实会把它渲染出来」—— 措辞不归这个文件管。
      if (origin.isDevice)
        const Disclosure(
          kind: DisclosureKind.decidedOnDevice,
          text: '来源声明替身',
        ),
    ],
    abstainReason: abstain ? '有效帧不足' : null,
    // 顶部那行来源标记从它取词。真报告里这两个字段由 `buildDecisionReport`
    // 一起给（那里有断言挡着，见 `decision_report_test.dart`）。
    fallbackCause: origin.isDevice ? DeviceFallbackCause.unreachable : null,
    tech: ReportTech(
      requestId: 'local-1',
      modelVersion: 'rule-only',
      thresholdsVersion: 'v1',
      localThresholdsVersion: 'v1',
      latencyMs: 4,
      origin: origin,
    ),
  );
}

AnalysisReported _reported({
  ReportKind kind = ReportKind.scored,
  String? headline = '这一组做了 10 个，有一处可以改。',
  bool draft = false,
  ReportOrigin origin = ReportOrigin.server,
}) =>
    AnalysisReported(
      report: _report(kind: kind, headline: headline, draft: draft, origin: origin),
      rawJson: '{"status":"ok"}',
      elapsed: const Duration(milliseconds: 1300),
      origin: origin,
      fallbackCause:
          origin.isDevice ? DeviceFallbackCause.unreachable : null,
    );

/// 把面板挂起来。**外面套一层滚动**，与 `squat_page.dart` 里的用法一致 ——
/// 展开后表单加报告超过一屏，面板要求父级可滚动（见 `AnalysisPanel` 的文档）。
Future<void> _show(WidgetTester tester, AnalysisPanel panel) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: panel),
        ),
      ),
    );

/// 点之前先滚到它跟前。
///
/// **不这么做的话，落在屏幕外的那些点击会被静默丢掉** —— `tap` 只打印一句
/// 警告就返回，于是断言失败在「怎么没反应」上，而真正的原因在坐标里。
/// 这个面板尤其容易踩：报做完之后按钮和「原始数据」都在一屏之外。
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 展开面板。
///
/// 用副标题而不是标题来定位：标题「分析这一组」与主按钮**是同一句话**
/// （计划里就这么定的：面板叫什么，按钮就叫什么），展开之后 `find.text`
/// 会同时命中两个。
Future<void> _expand(WidgetTester tester) =>
    _tap(tester, find.text('发给决策服务，出一份中文报告'));

/// 展开「原始数据」。
Future<void> _expandRaw(WidgetTester tester) => _tap(tester, find.text('原始数据'));

/// 展开「服务设置」。
Future<void> _expandSettings(WidgetTester tester) => _tap(tester, find.text('服务设置'));

/// 改服务地址。
Future<void> _enterAddress(WidgetTester tester, String value) async {
  await tester.enterText(find.widgetWithText(TextField, '服务地址'), value);
  await tester.pumpAndSettle();
}

/// 填一份完整的表单。
Future<void> _fill(
  WidgetTester tester, {
  String age = '16',
  String grade = '高一',
  String group = '高中女子',
  bool female = true,
}) async {
  if (female) {
    await tester.tap(find.text('女'));
    await tester.pump();
  }
  await tester.enterText(find.widgetWithText(TextFormField, '年龄'), age);
  await tester.enterText(find.widgetWithText(TextFormField, '年级'), grade);
  await tester.enterText(find.widgetWithText(TextFormField, '国标组别'), group);
  await tester.pump();
}

Future<void> _tapAnalyze(WidgetTester tester) =>
    _tap(tester, find.widgetWithText(FilledButton, '分析这一组'));

/// 点「重试」。它在失败块里，通常在一屏之外。
Future<void> _tapRetry(WidgetTester tester) =>
    _tap(tester, find.widgetWithText(FilledButton, '重试'));

/// 装一个面板，默认地址指向局域网而不是回环 —— 于是 USB 转发那句提示不出现，
/// 少一段噪声。需要验那句提示的用例自己传 `initialEndpoint`。
Future<void> _mount(
  WidgetTester tester, {
  required _Spy build,
  required _Runner run,
  DecisionEndpoint? endpoint,
  Profile? profile,
}) =>
    _show(
      tester,
      AnalysisPanel(
        build: build.call,
        analyze: run.call,
        initialEndpoint:
            endpoint ?? const DecisionEndpoint(baseUrl: 'http://10.0.0.5:8080'),
        profile: profile,
      ),
    );

/// 一份已存档案。数值刻意**与 [_fill] 的默认值全都不同** ——
/// 一样的话，「预填了」和「没预填、用户自己填的」两种情形在断言上分不开。
Profile _profile({int daysAgo = 3}) => Profile(
      sex: Sex.female,
      age: 15,
      grade: '初三',
      standardGroup: '初中女子',
      heightCm: 160,
      weightKg: 50,
      updatedAt: DateTime.now().subtract(Duration(days: daysAgo)),
    );

void main() {
  group('我的资料预填', () {
    testWidgets('四个框都预填，并写出处与日期', (tester) async {
      // 「记住」这件事当年是被否掉过的，理由是**一个上次留下的年龄看起来像是
      // 「已经确认过」**（`analysis_panel.dart` 的类注释）。这条理由没有消失，
      // 所以预填必须连着出处一起给：用户看得见这个值是哪来的、什么时候填的，
      // 才谈得上判断该不该信它。
      final profile = _profile(daysAgo: 3);
      await _mount(
        tester,
        build: _Spy()..result = _request(),
        run: _Runner()..next = _reported(),
        profile: profile,
      );
      await _expand(tester);

      expect(find.text('15'), findsOneWidget);
      expect(find.text('初三'), findsOneWidget);
      expect(find.text('初中女子'), findsOneWidget);
      expect(find.textContaining('已按「我的资料」填好'), findsOneWidget);
      expect(
        find.textContaining(formatProfileDate(profile.updatedAt)),
        findsOneWidget,
      );
      // 出处之外还要说清楚改动的去向 —— 不说的话，用户改完年龄做完分析，
      // 下次进来发现又变回去了，那看起来像一个 bug，而它其实是设计。
      expect(find.textContaining('不会写回档案'), findsOneWidget);
    });

    testWidgets('没有档案时不说「已按我的资料填好」', (tester) async {
      // 没有档案却说按档案填好了，是一句纯粹的假话。
      await _mount(
        tester,
        build: _Spy()..result = _request(),
        run: _Runner()..next = _reported(),
      );
      await _expand(tester);

      expect(find.textContaining('我的资料'), findsNothing);
      expect(find.textContaining('没有你的档案'), findsOneWidget);
    });

    testWidgets('改过的值按改过的发，而不是按档案发', (tester) async {
      // 这条拦的是「提交路径回头读 `widget.profile`」。那样写的话，
      // 用户在框里把 15 改成 20，发出去的仍然是 15 —— 而他明明看着 20。
      // **性别也一起换**：`_sex` 是另一个字段、另一条路。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(),
        profile: _profile(),
      );
      await _expand(tester);

      await tester.tap(find.text('男'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextFormField, '年龄'), '20');
      await tester.pump();
      await _tapAnalyze(tester);

      expect(spy.calls, [(Sex.male, 20, '初三', '初中女子')]);
    });

    testWidgets('资料填于一年多前：有一句提醒，但不替用户改年龄', (tester) async {
      await _mount(
        tester,
        build: _Spy()..result = _request(),
        run: _Runner()..next = _reported(),
        profile: _profile(daysAgo: 400),
      );
      await _expand(tester);

      // 与首页那张卡片**同一句事实**（`profileStaleFact`），只有后半句不同 ——
      // 那边整张卡可点，这边不可点。
      expect(find.textContaining('一年多前'), findsOneWidget);
      // 提示里必须还是用户填的那个年龄。自动加一岁是替用户编数据。
      expect(find.text('15'), findsOneWidget);
    });

    testWidgets('在这里改动不碰存储 —— 唯一的写入者是资料页', (tester) async {
      // 这条拦的是「分析之后顺手把表单值存回去」这种体贴。
      // 一旦那样写，用户在面板上为了试一个值把年龄改成 20，
      // 档案就被永久改掉了，而他从没按过「保存」。
      final touched = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('vitalteen/profile'),
        (call) async {
          touched.add(call.method);
          return null;
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(
            const MethodChannel('vitalteen/profile'),
            null,
          ));

      await _mount(
        tester,
        build: _Spy()..result = _request(),
        run: _Runner()..next = _reported(),
        profile: _profile(),
      );
      await _expand(tester);
      await tester.enterText(find.widgetWithText(TextFormField, '年龄'), '20');
      await tester.pump();
      await _tapAnalyze(tester);

      expect(touched, isEmpty);
    });
  });

  group('表单', () {
    testWidgets('填全了才把四项交给会话层', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(spy.calls, [(Sex.female, 16, '高一', '高中女子')]);
    });

    testWidgets('性别默认是男，但选过的会带过去', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester, female: false);
      await _tapAnalyze(tester);

      expect(spy.calls.single.$1, Sex.male);
    });

    testWidgets('年龄不在 5–25 就不发出去 —— 契约的下界在这里拦住', (tester) async {
      final spy = _Spy()..result = _request();
      final run = _Runner()..next = _reported();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);

      for (final age in ['4', '26']) {
        await _fill(tester, age: age);
        await _tapAnalyze(tester);
        expect(spy.calls, isEmpty, reason: '年龄 $age 不该被交出去');
        expect(run.calls, isEmpty, reason: '年龄 $age 不该发出去');
        expect(find.text('年龄要在 5 到 25 之间'), findsOneWidget);
      }

      // 边界上要放行 —— 5 与 25 都是契约允许的。
      for (final age in ['5', '25']) {
        await _fill(tester, age: age);
        await _tapAnalyze(tester);
        expect(spy.calls, hasLength(1), reason: '年龄 $age 是契约允许的');
        spy.calls.clear();
      }
    });

    testWidgets('空着就不发出去，并说明缺哪一项', (tester) async {
      final spy = _Spy()..result = _request();
      final run = _Runner()..next = _reported();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester, grade: '');
      await _tapAnalyze(tester);

      expect(run.calls, isEmpty);
      expect(find.text('请填年级'), findsOneWidget);
    });

    testWidgets('年级与组别超长被截断，不会生成一个服务端拒收的请求', (tester) async {
      // 契约限定 1–20 字符。**截断而不是校验**：超长只可能是误触或粘贴，
      // 弹一条「不能超过 20 个字」让人回去删，不如根本不让他输进去。
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester, group: '高中女子' * 10);
      await _tapAnalyze(tester);

      final group = spy.calls.single.$4;
      expect(group.characters.length, 20);
    });

    testWidgets('会话层说导不出来时，解释原因而不是留白', (tester) async {
      // 「按了没反应」是最糟的一种失败：用户刚做完一组，会以为是自己填错了。
      final spy = _Spy()..result = null;
      final run = _Runner()..next = _reported();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(spy.calls, hasLength(1));
      expect(run.calls, isEmpty, reason: '没有请求就不该发');
      expect(find.textContaining('没有可用于判定的帧'), findsOneWidget);
    });

    testWidgets('每次点「分析这一组」都重新问一次会话层，不缓存上一份', (tester) async {
      // 用户改了性别再点一次，拿到的必须是新的那一份 —— 缓存会让第二次点击
      // 显示第一次的结果，而屏幕上完全看不出区别。
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _tapAnalyze(tester);

      expect(spy.calls, hasLength(2));
    });
  });

  group('地址', () {
    testWidgets('地址不合法时不发请求，并把话说在按钮旁边', (tester) async {
      // 「http://」这种输入连不上是必然的，等连接失败后报「网络错误」是误导。
      // 而且服务设置是折起来的 —— 只在里面红一行，用户看到的是「按了没反应」。
      final spy = _Spy()..result = _request();
      final run = _Runner()..next = _reported();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _expandSettings(tester);
      await _enterAddress(tester, '192.168.1.7:8080');
      await _tapAnalyze(tester);

      expect(run.calls, isEmpty);
      // 输入框里一次、按钮旁边一次 —— 两处都在。
      expect(
        find.text('地址要以 http:// 或 https:// 开头'),
        findsNWidgets(2),
      );
    });

    testWidgets('地址栏里改了地址，发出去的就是改过的那个', (tester) async {
      final spy = _Spy()..result = _request();
      final run = _Runner()..next = _reported();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _expandSettings(tester);
      await _enterAddress(tester, 'http://192.168.1.7:9000/');
      await _tapAnalyze(tester);

      expect(run.calls.single.$2.normalizedBaseUrl, 'http://192.168.1.7:9000');
    });

    testWidgets('回环地址上提示 adb reverse', (tester) async {
      // 这是演示时**唯一一处不做就一定连不上**的手工操作。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(),
        endpoint: const DecisionEndpoint(baseUrl: 'http://127.0.0.1:8080'),
      );
      await _expand(tester);
      await _expandSettings(tester);

      expect(find.textContaining('adb reverse'), findsOneWidget);
    });

    testWidgets('填了局域网地址就不再说 adb reverse', (tester) async {
      // 那句话只对回环成立。局域网地址上还挂着它，会把人指向一步
      // 根本不需要的操作。
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _expandSettings(tester);

      expect(find.textContaining('adb reverse'), findsNothing);
    });
  });

  group('结局', () {
    testWidgets('成功时把报告摆上来', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.text('这一组做了 10 个，有一处可以改。'), findsOneWidget);
      expect(find.text('膝内扣倾向'), findsWidgets);
      expect(find.text('服务端参考分'), findsOneWidget);
      expect(find.text('箱式蹲（椅式蹲）'), findsOneWidget);
      // 禁忌必须在，而且不接受折叠。
      expect(find.text('膝痛时不要做'), findsOneWidget);
      expect(find.textContaining('不是国标体测成绩'), findsOneWidget);
    });

    testWidgets('文案还是草稿时明说', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(draft: true),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.text('这句话的文案还在评审中。'), findsOneWidget);
    });

    testWidgets('弃权不给错误色，也不写「失败」', (tester) async {
      // 弃权是服务端在说「这组数据不足以支撑判断」—— 那是它的诚实，
      // 不是用户的错，也不该被读成一个错误。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()
          ..next = _reported(
            // 弃权的那句话是端侧写死的（服务端不给 message），
            // 见 `decision_report.dart::_headline`。
            kind: ReportKind.abstain,
            headline: abstainHeadline,
          ),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.text(abstainHeadline), findsOneWidget);
      expect(find.textContaining('有效帧不足'), findsOneWidget);
      expect(find.text(abstainAdvice), findsOneWidget);
      // 弃权时不摆分数与建议 —— 那些是「有结论」时才有的东西。
      expect(find.text('服务端参考分'), findsNothing);
      expect(find.textContaining('失败'), findsNothing);
    });

    testWidgets('总述渲染不出来时不留白', (tester) async {
      // 留白是最坏的处理：读的人会以为报告本来就这么短。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()
          ..next = _reported(kind: ReportKind.clean, headline: null),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.textContaining('这一段总述没能显示出来'), findsOneWidget);
    });

    testWidgets('服务端没成：说清发生了什么、下一步、以及数据还在', (tester) async {
      // 失败之后用户的第一反应是「我是不是得再做一组」。
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = const AnalysisFailed(
          DecisionFailure(
            kind: DecisionFailureKind.unreachable,
            detail: 'SocketException: Connection refused',
          ),
        );
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.text('连不上决策服务'), findsOneWidget);
      expect(find.textContaining('adb reverse'), findsWidgets);
      expect(find.textContaining('数据还在手机上'), findsOneWidget);
      expect(find.textContaining('Connection refused'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    });

    testWidgets('重试重发同一份，不重新问会话层', (tester) async {
      // 服务端无状态，重发同一份是安全的；而重做一组动作不是 ——
      // 用户会为了看一眼刚才那份结论再做二十个深蹲。
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = const AnalysisFailed(
          DecisionFailure(kind: DecisionFailureKind.unreachable),
        );
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      run.next = _reported();
      await _tapRetry(tester);

      expect(spy.calls, hasLength(1), reason: '重试不该再问一次会话层');
      expect(run.calls, hasLength(2));
      expect(run.calls[0].$1, same(run.calls[1].$1), reason: '必须是同一份请求');
      expect(find.text('服务端参考分'), findsOneWidget);
    });

    testWidgets('重试用的是改过之后的地址', (tester) async {
      // 现场最常见的一种修法就是「地址写错了，改一下再点」——
      // 重发要是还发到旧地址，改地址这个动作就是白做的。
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = const AnalysisFailed(
          DecisionFailure(kind: DecisionFailureKind.wrongEndpoint),
        );
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      await _expandSettings(tester);
      await _enterAddress(tester, 'http://127.0.0.1:8080');
      await _tapRetry(tester);

      expect(run.calls, hasLength(2));
      expect(run.calls[1].$2.normalizedBaseUrl, 'http://127.0.0.1:8080');
    });

    testWidgets('本机缺件：说的是重装，不是再点一次', (tester) async {
      // 这两种该做的事正好相反。合成一句「分析失败」就把下一步弄丢了。
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = const AnalysisBlocked(
          message: '本机的文案表或方案库读不出来，这份报告算不出来。',
          advice: '重装一次应用。',
        );
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.textContaining('读不出来'), findsOneWidget);
      expect(find.textContaining('重装'), findsOneWidget);
      // 这一种重试没有意义，不给重试按钮。
      expect(find.widgetWithText(FilledButton, '重试'), findsNothing);
    });

    testWidgets('分析中不重复提交', (tester) async {
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = _reported()
        ..blocked = Completer<void>();
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);

      await tester.tap(find.widgetWithText(FilledButton, '分析这一组'));
      await tester.pump();

      expect(find.text('正在分析…'), findsOneWidget);
      // 按钮已经禁用了，再点一次也发不出去第二份。
      await tester.tap(find.widgetWithText(FilledButton, '正在分析…'));
      await tester.pump();
      expect(run.calls, hasLength(1));

      run.blocked!.complete();
      await tester.pumpAndSettle();
      expect(find.text('服务端参考分'), findsOneWidget);
    });
  });

  group('原始数据', () {
    testWidgets('点过之后请求 JSON 就在，且是这一份的', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      expect(find.text('原始数据'), findsNothing);
      await _tapAnalyze(tester);
      await _expandRaw(tester);

      expect(find.text('发出去的请求'), findsOneWidget);
      expect(find.textContaining('"request_id": "local-1"'), findsOneWidget);
      expect(find.textContaining('"action_code": "SQUAT"'), findsOneWidget);
      // 响应那一份只在成功之后才有。
      expect(find.text('服务端返回的响应'), findsOneWidget);
    });

    testWidgets('失败时请求 JSON 照样看得到 —— Phase 1 的验收物不能丢', (tester) async {
      final spy = _Spy()..result = _request();
      final run = _Runner()
        ..next = const AnalysisFailed(
          DecisionFailure(kind: DecisionFailureKind.unreachable),
        );
      await _mount(tester, build: spy, run: run);
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _expandRaw(tester);

      expect(find.textContaining('"request_id": "local-1"'), findsOneWidget);
      expect(find.text('服务端返回的响应'), findsNothing);
    });

    testWidgets('复制把同一份 JSON 放进剪贴板', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _expandRaw(tester);
      await _tap(tester, find.text('复制').first);

      expect(copied, hasLength(1));
      // 复制的必须是**显示的那一份**：两处各自序列化一次，迟早会出现
      // 「屏幕上看着对、复制出来是旧的」。
      expect(copied.single, contains('"request_id": "local-1"'));
      expect(copied.single, contains('"schema_version": "1.0"'));
    });

    testWidgets('成功时顺手报出端侧实测的往返', (tester) async {
      // 响应里那个 latency_ms 只算服务端内部。现场要判「是服务慢还是网慢」
      // 只能看端侧实测这一个 —— 而这两种的处置完全不同。
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _expandRaw(tester);

      expect(find.textContaining('端侧实测往返 1.3 秒'), findsOneWidget);
      expect(find.textContaining('服务端自报 4 毫秒'), findsOneWidget);
    });

    testWidgets('本机算的那一份不冒充「服务端返回的响应」', (tester) async {
      // 这一格正是用来核对来源真伪的 —— 把在本机生成的响应标成
      // 「服务端返回的」是假话，而假话比空白更糟。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _expandRaw(tester);

      expect(find.text('本机生成的响应'), findsOneWidget);
      expect(find.text('服务端返回的响应'), findsNothing);
    });

    testWidgets('本机算的时候耗时那句话不引用服务端自报的那个数', (tester) async {
      // `latency_ms` 在本机来源时是**占位的 0**，不是测量结果 ——
      // 摆出来当数字看就是假数字。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      await _expandRaw(tester);

      expect(find.textContaining('本机判定用了'), findsOneWidget);
      expect(find.textContaining('没有网络往返'), findsOneWidget);
      expect(find.textContaining('服务端自报'), findsNothing);
      expect(find.textContaining('端侧实测往返'), findsNothing);
    });
  });

  group('本机算的报告', () {
    testWidgets('参考分那个标签换成「本机判定参考分」', (tester) async {
      // 保留「服务端」三个字是为了与组末那个端侧即时参考分形成对照；
      // 本机算的时候那份对照的参照物换成了本机判定，标签也得跟着换。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.text('本机判定参考分'), findsOneWidget);
      expect(find.text('服务端参考分'), findsNothing);
    });

    testWidgets('来源声明出现在报告里，而不是折叠区里', (tester) async {
      // 来源不明的报告等于没有来源 —— 这段话在折叠区里就等于没有。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);
      // **刻意不展开「原始数据」** —— 它是唯一一个折叠区。
      expect(find.textContaining('来源声明替身'), findsOneWidget);
    });

    testWidgets('服务端算的报告里没有那条声明', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.textContaining('来源声明替身'), findsNothing);
    });

    testWidgets('顶部先说来源，且排在总述上面', (tester) async {
      // 声明区在报告末尾：读的人要先读完成绩和建议才知道这份报告是本机算的。
      // 所以顶部必须另有一行 —— 而它「在总述上面」这件事只能靠坐标验，
      // 光断言文字存在的话，把它挪到最底下测试照样绿。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      final notice = find.textContaining('本机判定 ·');
      expect(notice, findsOneWidget);
      expect(
        tester.getTopLeft(notice).dy,
        lessThan(tester.getTopLeft(find.textContaining('这一组做了 10 个')).dy),
      );
    });

    testWidgets('顶部那行说得出是哪一种没连上', (tester) async {
      // 「连不上」和「超时」对读报告的人是两件事（现场有没有网 / 电脑开着没有），
      // 笼统写「本机算的」等于把这条信息丢了。
      final spy = _Spy()..result = _request();
      await _mount(
        tester,
        build: spy,
        run: _Runner()..next = _reported(origin: ReportOrigin.device),
      );
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.textContaining('当时连不上决策服务'), findsOneWidget);
    });

    testWidgets('服务端算的报告顶部没有那行', (tester) async {
      final spy = _Spy()..result = _request();
      await _mount(tester, build: spy, run: _Runner()..next = _reported());
      await _expand(tester);
      await _fill(tester);
      await _tapAnalyze(tester);

      expect(find.textContaining('本机判定 ·'), findsNothing);
    });
  });
}
