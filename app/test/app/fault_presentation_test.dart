/// 措辞层的测试。
///
/// **这里最要紧的一条是「每个故障码都有中文名」，而且是机械校验的。**
/// 理由：漏一个不会报错，只会让界面上出现 `heel_rise_ratio_L` 这样的字样 ——
/// 而它出现在一个给青少年看的反馈里，和在日志里出现是两件事。
/// `_featureLabels` 是手写的，手写的东西必然漂移，所以用规则表反过来查它。
///
/// 阈值一律读**真实的那份 asset**，不用测试里编的数。分档切点是体育口径的
/// 结论、带着出处（见 `assets/thresholds/`），编一个数来测等于在测自己。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/fault_presentation.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/exercises/sit_reach.dart';
import 'package:vitalteen_app/domain/exercises/squat.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/rules.dart';
import 'package:vitalteen_app/domain/thresholds.dart';

/// 一份形状正常但不参与判定的基线 —— 本文件测的是措辞，基线值取什么都不影响。
const Calibration _calibration = Calibration(
  kneeAngle: 178.0,
  trunkLean: 3.0,
  heelRiseRatio: 0.02,
  frames: 45,
);

ThresholdTable _loadTable() {
  final file = File('assets/thresholds/thr_2026-10_v1.json');
  return ThresholdTable.fromJson(
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  );
}

ActionDefinition _squat() =>
    buildSquat(_calibration, cameraView: CameraView.oblique45);

/// 造一条故障。[feature] 默认取规则自己声明的 `metric` —— 这正是引擎的做法
/// （`rules.dart` 里 `Deviation(feature: rule.metric)`），照抄它才不会测出
/// 一个引擎永远不会走到的路径。
Fault faultOf(
  Rule rule, {
  required double measured,
  double? threshold,
  double? severity01,
  double confidence = 0.5,
  bool scorable = false,
  String? feature,
}) =>
    Fault(
      code: rule.code,
      nameZh: rule.nameZh,
      scorable: scorable,
      confidence: confidence,
      evidenceTimestamps: const [],
      deviation: Deviation(
        feature: feature ?? rule.metric,
        measured: measured,
        threshold: threshold ?? 0.0,
        deltaSigned: measured - (threshold ?? 0.0),
        severity01: severity01,
      ),
    );

void main() {
  final table = _loadTable();
  final definition = _squat();
  final presenter = FaultPresenter(definition: definition, thresholds: table);

  group('覆盖性（机械校验，不靠人盯）', () {
    test('每条规则的特征都有中文名，界面上不会漏出特征码', () {
      for (final rule in definition.rules) {
        final view = presenter
            .present(1, [faultOf(rule, measured: 123.0, threshold: 100.0)])
            .faults
            .single;

        expect(
          view.detail,
          isNot(contains(rule.metric)),
          reason: '规则 ${rule.code} 的特征 ${rule.metric} 没有中文名，'
              '界面上会把特征码原样显示出来。请补 _featureLabels。',
        );
      }
    });

    test('阈值键查不到时构造就抛，而不是少显示一点', () {
      // 降级的表现是「单位没了、分档没了」—— 一句话少了个单位，没人会发现。
      // 而查不到只有两种原因：键写错了，或阈值表没同步过来。两种都是 bug。
      expect(
        () => FaultPresenter(
          definition: definition,
          thresholds: ThresholdTable(const [], version: 'empty'),
        ),
        throwsA(isA<ThresholdException>()),
      );
    });

    test('没有中文名时会漏出特征码本身 —— 证明上一条不是空断言', () {
      // 机械校验最怕的是「怎么写都不会红」。这里把兜底路径正面走一遍：
      // 兜底确实会输出特征码，所以上面那条 `isNot(contains(metric))`
      // 真的有分辨力，而不是恒真。
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final view = presenter
          .present(1, [
            faultOf(rule, measured: 118.0, feature: 'brand_new_feature'),
          ])
          .faults
          .single;

      expect(view.detail, contains('brand_new_feature'));
    });

    test('深蹲的五个故障码都在，不多不少', () {
      // 数量本身不重要，重要的是**加规则的人会看到这条红**，
      // 从而被迫想一遍「新的那条该怎么措辞」。
      expect(
        definition.rules.map((r) => r.code).toSet(),
        {
          'INSUFFICIENT_DEPTH',
          'KNEE_VALGUS',
          'EXCESSIVE_TRUNK_LEAN',
          'HEEL_RISE',
          'ASYMMETRY',
        },
      );
    });
  });

  group('措辞', () {
    test('膝内扣被降调成「倾向」—— 阈值表要求的', () {
      final rule = definition.rules.firstWhere((r) => r.code == 'KNEE_VALGUS');
      final view = presenter
          .present(1, [faultOf(rule, measured: 20.0, threshold: 8.0)])
          .faults
          .single;

      expect(view.title, '膝内扣倾向');
      expect(view.title, isNot('膝内扣'));
    });

    test('其余四条不做降调 —— 它们是能直接描述的机械事实', () {
      for (final rule in definition.rules) {
        if (rule.code == 'KNEE_VALGUS') continue;
        final view = presenter
            .present(1, [faultOf(rule, measured: 20.0, threshold: 8.0)])
            .faults
            .single;

        expect(view.title, rule.nameZh);
      }
    });

    test('每句话都带数字 —— 只说「深度不足」等于什么都没说', () {
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final view = presenter
          .present(1, [faultOf(rule, measured: 118.0, threshold: 95.0)])
          .faults
          .single;

      expect(view.detail, contains('118'));
      expect(view.detail, contains('95'));
      expect(view.detail, contains('左膝角'));
      expect(view.detail, contains('°'), reason: 'deg 单位要渲染成度数符号');
    });
  });

  group('未核定阈值的标注', () {
    test('不可评分的故障带「待核定 · 仅提示」', () {
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final view = presenter
          .present(1, [faultOf(rule, measured: 118.0, threshold: 95.0)])
          .faults
          .single;

      expect(view.scorable, isFalse);
      expect(view.notice, '待核定 · 仅提示');
    });

    test('已核定的故障不带角标', () {
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final view = presenter
          .present(1, [
            faultOf(rule, measured: 118.0, threshold: 95.0, scorable: true),
          ])
          .faults
          .single;

      expect(view.scorable, isTrue);
      expect(view.notice, isNull);
    });

    test('现实情况：当前阈值表整表待核定，所以每一条都是「仅提示」', () {
      // 这条不是断言现状永远如此，而是**把现状写成断言**：
      // 阈值一旦核定，这条会红，而红的人正是该去更新界面文案的人。
      final views = presenter
          .present(1, [
            for (final rule in definition.rules)
              faultOf(
                rule,
                measured: rule.badSide == Direction.above ? 1e3 : -1e3,
              ),
          ])
          .faults;

      expect(views, isNotEmpty);
      expect(views.every((v) => !v.scorable), isTrue);
      expect(table.pendingReview().length, table.length);
    });
  });

  group('分档', () {
    test('膝内扣只出「需关注 / 明显」两级，切点取阈值表的 13°', () {
      final rule = definition.rules.firstWhere((r) => r.code == 'KNEE_VALGUS');

      String labelAt(double measured) => presenter
          .present(1, [faultOf(rule, measured: measured, threshold: 8.0)])
          .faults
          .single
          .severityLabel;

      expect(table.get('squat.knee_valgus_angle_notice').severityBreakpoints,
          [13.0], reason: '切点变了的话，下面的边界断言要跟着改');
      expect(labelAt(9.0), '需关注');
      expect(labelAt(13.0), '需关注', reason: '刚好等于切点不算越过（严格大于）');
      expect(labelAt(13.1), '明显');
      expect(labelAt(25.0), '明显');
    });

    test('切点落在越界方向上才用，否则退回 severity01', () {
      // 躯干前倾：阈值 15°，切点 10°。**10 在 15 的里面**，任何越界都必然
      // 已经越过 10，两档会退化成只有一档。这时必须退回 severity01，
      // 而不是照输出「需关注」—— 那会把一个满严重度的动作说成「关注一下」。
      final rule =
          definition.rules.firstWhere((r) => r.code == 'EXCESSIVE_TRUNK_LEAN');
      final threshold = table.get(rule.thresholdKey);
      expect(threshold.value, 15.0);
      expect(threshold.severityBreakpoints, [10.0]);

      final high = presenter
          .present(1, [
            faultOf(rule, measured: 30.0, threshold: 15.0, severity01: 1.0),
          ])
          .faults
          .single;

      expect(high.severityLabel, '明显', reason: '满严重度不能说成「需关注」');
    });

    test('severity01 的区间措辞', () {
      final rule = definition.rules.firstWhere((r) => r.code == 'HEEL_RISE');
      // HEEL_RISE 的切点 0.08 < 阈值 0.15，同样不走分档表，
      // 正好拿来单独测 severity01 的三段。
      String labelAt(double? s) => presenter
          .present(1, [
            faultOf(rule, measured: 0.3, threshold: 0.15, severity01: s),
          ])
          .faults
          .single
          .severityLabel;

      expect(labelAt(0.10), '轻微');
      expect(labelAt(0.50), '中等');
      expect(labelAt(0.90), '明显');
      expect(labelAt(null), '已记录', reason: '不归一不是零严重度，别写成「轻微」');
    });

    test('深度不足：105° 切点把「差一点」和「差很多」分开', () {
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');

      String labelAt(double measured) => presenter
          .present(1, [faultOf(rule, measured: measured, threshold: 95.0)])
          .faults
          .single
          .severityLabel;

      expect(table.get(rule.thresholdKey).severityBreakpoints, [105.0]);
      expect(labelAt(100.0), '需关注');
      expect(labelAt(105.0), '需关注');
      expect(labelAt(120.0), '明显');
    });
  });

  group('排序', () {
    Rule ruleOf(String code) =>
        definition.rules.firstWhere((r) => r.code == code);

    test('严重度降序', () {
      final view = presenter.present(1, [
        faultOf(ruleOf('HEEL_RISE'), measured: 0.2, threshold: 0.15,
            severity01: 0.2),
        faultOf(ruleOf('INSUFFICIENT_DEPTH'), measured: 120.0, threshold: 95.0,
            severity01: 0.9),
      ]);

      expect(
        view.faults.map((f) => f.code),
        ['INSUFFICIENT_DEPTH', 'HEEL_RISE'],
      );
    });

    test('没有严重度的排最后，而不是当零处理', () {
      final view = presenter.present(1, [
        faultOf(ruleOf('INSUFFICIENT_DEPTH'), measured: 120.0, threshold: 95.0),
        faultOf(ruleOf('HEEL_RISE'), measured: 0.2, threshold: 0.15,
            severity01: 0.05),
      ]);

      expect(view.faults.first.code, 'HEEL_RISE');
      expect(view.faults.last.code, 'INSUFFICIENT_DEPTH');
    });

    test('严重度并列时看置信度，再并列才看故障码', () {
      final view = presenter.present(1, [
        // 三条 severity01 全为 null：置信度决定前两条，码序决定后两条。
        faultOf(ruleOf('INSUFFICIENT_DEPTH'), measured: 120.0, threshold: 95.0,
            confidence: 0.4),
        faultOf(ruleOf('HEEL_RISE'), measured: 0.2, threshold: 0.15,
            confidence: 0.9),
        faultOf(ruleOf('ASYMMETRY'), measured: 0.2, threshold: 0.1,
            confidence: 0.4),
      ]);

      expect(
        view.faults.map((f) => f.code),
        ['HEEL_RISE', 'ASYMMETRY', 'INSUFFICIENT_DEPTH'],
      );
    });

    test('排序不改动传进来的那份列表', () {
      // 引擎产出的 List<Fault> 组级汇总还要用。就地排序会悄悄改掉调用方
      // 手上的顺序 —— 不报错，只让别处的输出在某天变得和今天不一样。
      final input = [
        faultOf(ruleOf('HEEL_RISE'), measured: 0.2, threshold: 0.15,
            severity01: 0.1),
        faultOf(ruleOf('INSUFFICIENT_DEPTH'), measured: 120.0, threshold: 95.0,
            severity01: 0.9),
      ];
      final before = input.map((f) => f.code).toList();

      presenter.present(1, input);

      expect(input.map((f) => f.code).toList(), before);
    });
  });

  group('标题', () {
    test('没有故障时不说「0 处问题」', () {
      final view = presenter.present(3, const []);

      expect(view.clean, isTrue);
      expect(view.faults, isEmpty);
      expect(view.headline, contains('第 3 个'));
      expect(view.headline, contains('不错'));
    });

    test('只有一条时把话说全', () {
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final view = presenter
          .present(2, [faultOf(rule, measured: 120.0, threshold: 95.0)]);

      expect(view.headline, contains('下蹲深度不足'));
      expect(view.headline, contains('明显'));
    });

    test('多条时只报数量，细节留给卡片', () {
      final rule = definition.rules.firstWhere((r) => r.code == 'HEEL_RISE');
      final view = presenter.present(4, [
        faultOf(rule, measured: 0.2, threshold: 0.15, severity01: 0.5),
        faultOf(definition.rules.firstWhere((r) => r.code == 'ASYMMETRY'),
            measured: 0.3, threshold: 0.1, severity01: 0.5),
      ]);

      expect(view.headline, contains('2 处'));
    });
  });

  group('报告层的本地入口', () {
    test('逐次卡片与报告用的是同一个渲染函数', () {
      // 两处各写一遍，早晚会出现「卡片说 118°、报告说 118.0°」——
      // 同一个数两种写法，读的人会以为是两次测量。
      final rule =
          definition.rules.firstWhere((r) => r.code == 'INSUFFICIENT_DEPTH');
      final fault = faultOf(rule, measured: 119.6, threshold: 100.0);

      final fromPresenter = presenter.evidenceLine(
        code: rule.code,
        feature: fault.deviation.feature,
        measured: fault.deviation.measured,
        threshold: fault.deviation.threshold,
      );

      expect(fromPresenter, presenter.present(1, [fault]).faults.single.detail);
    });

    test('名字查得到，且不在这里降调', () {
      // 降调由调用方决定：这一层给的是「这个码本来叫什么」，
      // 先降一遍会让原始名没有第二个地方能查到。
      expect(presenter.faultName('KNEE_VALGUS'), '膝内扣');
      expect(faultTitle('KNEE_VALGUS', presenter.faultName('KNEE_VALGUS')!),
          '膝内扣倾向');
    });

    test('查不到的错误码返回 null —— 不显示一个没有单位的数', () {
      expect(presenter.faultName('将来才有的码'), isNull);
      expect(
        presenter.evidenceLine(
          code: '将来才有的码',
          feature: 'knee_angle_L',
          measured: 119.6,
          threshold: 100.0,
        ),
        isNull,
      );
    });

    test('特征名有中文，查不到时退化成特征码本身', () {
      expect(featureLabel('knee_angle_L'), '左膝角');
      // 难看，但能被搜索到；「未知」什么都查不出来。
      expect(featureLabel('some_future_feature'), 'some_future_feature');
    });

    test('三位数不留小数，角度带度数符号', () {
      expect(formatMeasurement(119.6, 'deg'), '120°');
      expect(formatMeasurement(95.4, 'deg'), '95.4°');
      // 非角度只加度数符号之外的写法照旧。
      expect(formatMeasurement(0.2, 'ratio'), '0.2');
    });

    test('比值只保留一位小数 —— 这是逐次卡片一直以来的写法', () {
      // **一个已知的粗糙处**：脚跟抬起比 0.18 与阈值 0.15 都显示成一位小数后
      // 是「0.2（参考值 0.15）」，看不出「刚过线」。改它要动已经验收过的
      // 逐次卡片，本轮不动。这条钉住现状，免得有人以为报告里的 0.2 是算错了。
      expect(formatMeasurement(0.18, 'ratio'), '0.2');
    });
  });

  group('量名：报出来的那个数叫什么', () {
    // 上面所有用例都在深蹲上，而深蹲五条规则报的都是「特征在窗口上的一个
    // 代表值」（最低的膝角、最大的偏移），按特征名念是对的。
    //
    // **坐位体前屈的弹振那条不是。** 它的归约是掉头次数，报出来的
    // 是一个无量纲的次数 —— 按特征名念会变成「左髋角 5（参考值 3）」，
    // 一个没有人能读懂的角度。
    final srt = buildSitReach(_calibration, cameraView: CameraView.oblique45);
    final srtPresenter = FaultPresenter(definition: srt, thresholds: table);

    Rule srtRuleOf(String code) =>
        srt.rules.firstWhere((r) => r.code == code);

    test('判据挂在归约上，不给某一条规则开特例', () {
      // 换个动作、换个特征名，只要归约还是掉头次数，量名就该是对的。
      final ballistic = srtRuleOf('SRT_BALLISTIC');
      expect(ballistic.reduce, Reduce.reversals);
      expect(ballistic.metric, 'hip_angle_L', reason: '特征本身还是髋角');
      expect(measureLabel(ballistic), '掉头次数');

      // 反过来：靠量的比较得出结论的规则一律不给覆盖，量名就是特征名。
      expect(measureLabel(srtRuleOf('SRT_KNEE_BENT')), isNull);
      for (final rule in definition.rules) {
        expect(measureLabel(rule), isNull, reason: rule.code);
      }
    });

    test('弹振那条的详情说「掉头次数」，不说「左髋角」', () {
      final rule = srtRuleOf('SRT_BALLISTIC');
      final view = srtPresenter
          .present(1, [faultOf(rule, measured: 5.0, threshold: 3.0)])
          .faults
          .single;

      expect(view.detail, contains('掉头次数'));
      expect(view.detail, contains('5'), reason: '次数也要显示出来');
      expect(
        view.detail,
        isNot(contains('左髋角')),
        reason: '按特征名念会把次数说成一个角度',
      );
      // 单位照旧从阈值表来（这一条是 `count`，所以没有度数符号）。
      expect(view.detail, isNot(contains('°')));
    });

    test('同一份动作里的另一条照旧按特征名念', () {
      // 覆盖是**逐条**的，不是「这个动作特殊」。写成整份定义一起覆盖的话，
      // 屈膝那一条会被念成「掉头次数」，而它明明是个角度。
      final view = srtPresenter
          .present(1, [faultOf(srtRuleOf('SRT_KNEE_BENT'), measured: 140.0,
              threshold: 150.0)])
          .faults
          .single;

      expect(view.detail, contains('左膝角'));
      expect(view.detail, isNot(contains('掉头次数')));
    });
  });
}
