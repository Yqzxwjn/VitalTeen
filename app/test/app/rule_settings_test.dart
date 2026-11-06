/// 规则参数装载的测试。
///
/// **这个文件的重点是「缺字段就抛」。** 这些数字决定断网时本机算出的分数与评级，
/// 而一份缺字段的参数如果退回默认值，产物不是崩溃 —— 是**一份看起来正常、
/// 其实评级全错的报告**。所以端侧一个默认值都不留。
///
/// 另一半是校验：约束与 `DecisionSettings.__post_init__` 逐条对应。服务端那份
/// 拦的是「有人改坏了代码」，这一份拦的是「改动没同步过来」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/rule_settings.dart';

const String _path = 'assets/decision/rule_settings.json';
const String _sharedPath = '../shared/decision/rule_settings.json';

/// 一份字段齐全的参数，供改单个字段的用例打底。
///
/// [replace] 里每项写成 `旧|新`，按顺序替换 —— 有些约束（比如两个权重之和）
/// 要同时动两处才说得清楚。
String _rawWith({List<String> replace = const []}) {
  var text = '''
{
  "min_mean_visibility": 0.5,
  "min_coverage_ratio": 0.6,
  "max_plans": 3,
  "severity_level_breakpoints": [0.34, 0.67],
  "score_worst_weight": 0.6,
  "score_mean_weight": 0.4,
  "rating_cutoffs": [90, 80, 70, 60],
  "rating_labels": ["优", "良", "中", "及格", "需改进"],
  "fallback_model_version": "rule-only"
}
''';
  for (final pair in replace) {
    final parts = pair.split('|');
    if (parts.length != 2 || !text.contains(parts[0])) {
      // 夹具自己写错时当场炸：静默不替换会让「本该抛的用例」变成
      // 「什么都没测，还绿了」。
      throw ArgumentError('替换项无效：$pair');
    }
    text = text.replaceFirst(parts[0], parts[1]);
  }
  return text;
}

RuleSettings _parse([String? raw]) =>
    parseRuleSettingsAsset(path: _path, raw: raw ?? _rawWith());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('挑文件', () {
    test('目录里只有一份时选它', () {
      expect(selectRuleSettingsAsset([_path]), _path);
    });

    test('目录为空时抛，且异常类型是规则参数自己的', () {
      expect(
        () => selectRuleSettingsAsset(['AssetManifest.bin']),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            allOf(contains('assets/decision/'), contains('pubspec.yaml')),
          ),
        ),
      );
    });

    test('找到两份时抛，并把两份都列出来', () {
      expect(
        () => selectRuleSettingsAsset([
          'assets/decision/rule_settings.json',
          'assets/decision/rule_settings_old.json',
        ]),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            allOf(contains('2 份'), contains('rule_settings.json')),
          ),
        ),
      );
    });
  });

  group('解析', () {
    test('读得出每一个字段', () {
      final settings = _parse();
      expect(settings.minMeanVisibility, 0.5);
      expect(settings.minCoverageRatio, 0.6);
      expect(settings.maxPlans, 3);
      expect(settings.severityLevelBreakpoints.low, 0.34);
      expect(settings.severityLevelBreakpoints.high, 0.67);
      expect(settings.scoreWorstWeight, 0.6);
      expect(settings.scoreMeanWeight, 0.4);
      expect(settings.ratingCutoffs, [90, 80, 70, 60]);
      expect(settings.ratingLabels, ['优', '良', '中', '及格', '需改进']);
      expect(settings.fallbackModelVersion, 'rule-only');
    });

    test('缺字段就抛，绝不退回默认值', () {
      // 这是本文件存在的理由。退回默认值的话，服务端把 max_plans 从 3 改成 2
      // 而端侧资产没更新 —— 两边会给出不同数量的方案，且没有任何东西报错。
      expect(
        () => _parse(_rawWith(replace: ['"max_plans": 3,|'])),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith(_path), contains('max_plans')),
          ),
        ),
      );
    });

    test('坏 JSON 的报错带文件名', () {
      expect(
        () => _parse('{ 这不是 json'),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });

    test('类型不对时报错，而不是硬塞', () {
      expect(
        () => _parse(_rawWith(replace: ['"max_plans": 3|"max_plans": "3"'])),
        throwsA(isA<RuleSettingsException>()),
      );
    });

    test('切点不是恰好两个时报错', () {
      expect(
        () => _parse(_rawWith(replace: ['[0.34, 0.67]|[0.34]'])),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            contains('两个'),
          ),
        ),
      );
    });
  });

  group('校验（与 DecisionSettings.__post_init__ 对应）', () {
    test('切点必须严格递增且落在 (0,1)', () {
      for (final bad in ['[0.67, 0.34]', '[0.34, 0.34]', '[0.0, 0.67]', '[0.34, 1.0]']) {
        expect(
          () => _parse(_rawWith(replace: ['[0.34, 0.67]|$bad'])),
          throwsA(isA<RuleSettingsException>()),
          reason: '$bad 应该被拒绝',
        );
      }
    });

    test('评级词必须比切点多一个', () {
      // 少一个的后果是最后一档没有词，多一个则是有一档永远取不到 ——
      // 两种都不会崩，只会让某个分数段的人拿到错的评级。
      expect(
        () => _parse(_rawWith(
          replace: ['["优", "良", "中", "及格", "需改进"]|["优", "良", "中", "及格"]'],
        )),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            contains('多一个'),
          ),
        ),
      );
    });

    test('切点必须严格递减', () {
      expect(
        () => _parse(_rawWith(replace: ['[90, 80, 70, 60]|[90, 80, 80, 60]'])),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            contains('递减'),
          ),
        ),
      );
    });

    test('评分权重之和必须落在 (0,1]', () {
      // 和为 0 意味着「扣分为零」—— 再严重的动作也拿 100 分、评「优」。
      expect(
        () => _parse(_rawWith(replace: [
          '"score_worst_weight": 0.6|"score_worst_weight": 0.0',
          '"score_mean_weight": 0.4|"score_mean_weight": 0.0',
        ])),
        throwsA(isA<RuleSettingsException>()),
      );
      // 和超过 1 则是**过度扣分**：两条都犯了的时候分数可以掉到负数区，
      // max(0,...) 一夹，表现成「动不动就 0 分」。
      expect(
        () => _parse(_rawWith(replace: ['"score_mean_weight": 0.4|"score_mean_weight": 0.5'])),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            contains('权重'),
          ),
        ),
      );
    });

    test('max_plans 为负是错的，为 0 是对的', () {
      // 0 的含义是「禁用推荐」，是一个合法配置（服务端有对应的测试）。
      // 把它一并拒掉，会让「先关掉推荐」这个选项在端侧变得不可用。
      expect(
        () => _parse(_rawWith(replace: ['"max_plans": 3|"max_plans": -1'])),
        throwsA(isA<RuleSettingsException>()),
      );
      expect(_parse(_rawWith(replace: ['"max_plans": 3|"max_plans": 0'])).maxPlans, 0);
    });

    test('校验失败的消息带文件名', () {
      // 调试的人手上可能有十几份 json，只说「切点不对」等于没说。
      expect(
        () => _parse(_rawWith(replace: ['[90, 80, 70, 60]|[60, 70, 80, 90]'])),
        throwsA(
          isA<RuleSettingsException>().having(
            (e) => e.message,
            'message',
            startsWith(_path),
          ),
        ),
      );
    });
  });

  group('取评级与档位', () {
    test('ratingOf 走阶梯', () {
      final settings = _parse();
      expect(settings.ratingOf(100), '优');
      expect(settings.ratingOf(90), '优');
      expect(settings.ratingOf(89), '良');
      expect(settings.ratingOf(80), '良');
      expect(settings.ratingOf(70), '中');
      expect(settings.ratingOf(60), '及格');
      expect(settings.ratingOf(59), '需改进');
      expect(settings.ratingOf(0), '需改进');
    });

    test('levelOf 走切点，未知档位算 1', () {
      final settings = _parse();
      expect(settings.levelOf(null), 1, reason: '没有偏离数据时算最轻，不是最重');
      expect(settings.levelOf(0.0), 1);
      expect(settings.levelOf(0.339), 1);
      expect(settings.levelOf(0.34), 2, reason: '切点是闭下界');
      expect(settings.levelOf(0.669), 2);
      expect(settings.levelOf(0.67), 3);
      expect(settings.levelOf(1.0), 3);
    });
  });

  group('真读随包发布的那份', () {
    test('能从资源里读出来', () async {
      final settings = await loadRuleSettings();
      expect(settings.maxPlans, 3);
      expect(settings.fallbackModelVersion, 'rule-only');
      expect(settings.ratingLabels.first, '优');
    });

    test('与 shared/ 下那份逐字段同源', () async {
      // sync_assets.py 是单向同步，但「同步过」这件事只有真比对才知道。
      // 两份漂移不会报错，只会让同一个动作在手机断网时得出不同结论。
      final loaded = await loadRuleSettings();
      final onDisk = _parse(File(_sharedPath).readAsStringSync());

      expect(loaded.minMeanVisibility, onDisk.minMeanVisibility);
      expect(loaded.minCoverageRatio, onDisk.minCoverageRatio);
      expect(loaded.maxPlans, onDisk.maxPlans);
      expect(loaded.severityLevelBreakpoints.low, onDisk.severityLevelBreakpoints.low);
      expect(loaded.severityLevelBreakpoints.high, onDisk.severityLevelBreakpoints.high);
      expect(loaded.scoreWorstWeight, onDisk.scoreWorstWeight);
      expect(loaded.scoreMeanWeight, onDisk.scoreMeanWeight);
      expect(loaded.ratingCutoffs, onDisk.ratingCutoffs);
      expect(loaded.ratingLabels, onDisk.ratingLabels);
      expect(loaded.fallbackModelVersion, onDisk.fallbackModelVersion);
    });

    test('导出的键与服务端的 DecisionSettings 对得上', () async {
      // severity_labels 是刻意不导出的：那是喂给决策模型的档位词，
      // 本机永远走规则兜底，只用得到 1/2/3 这三个数字档位。
      // 反过来，多出来的键说明有人手工编辑了导出物。
      final decoded =
          jsonDecode(File(_sharedPath).readAsStringSync()) as Map<String, dynamic>;
      expect(decoded.keys.toSet()..remove('_comment'), {
        'min_mean_visibility',
        'min_coverage_ratio',
        'max_plans',
        'severity_level_breakpoints',
        'score_worst_weight',
        'score_mean_weight',
        'rating_cutoffs',
        'rating_labels',
        'fallback_model_version',
      });
    });
  });
}
