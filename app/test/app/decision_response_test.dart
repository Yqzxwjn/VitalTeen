/// 决策响应模型的解析测试。
///
/// **这个文件守的是一条分界线：结构错误要拦，取值越界不拦。**
///
/// - 缺字段、类型不对 → 抛，且消息里带字段路径。**绝不渲染半个响应**：
///   「有几条问题没读出来」的报告比「读不出来」更危险，因为读的人不会怀疑它。
/// - 取值越界（`severity_level` 是 7、`form_score` 是 120）→ 不抛。
///   那是服务端该修的事，但不该让用户整份报告都看不到。
/// - **`status` 是唯一一个「取值也必须拦」的字段** —— 它决定整份响应的读法，
///   把 `abstain` 当成 `ok` 读会产出一份完全错误的报告。
///
/// 与 Python 的逐字段一致性在 `decision_response_conformance_test.dart`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/decision_response.dart';

/// 一份最小的合法响应：只有必填项。各用例在它上面改一处。
Map<String, dynamic> _minimal({String status = 'ok'}) => {
      'request_id': 'r-1',
      'status': status,
      'faults': <dynamic>[],
      'gates': <String, dynamic>{},
      'meta': {
        'decision_model_version': 'rule-only',
        'thresholds_version': 'v1',
        'latency_ms': 12,
        'shuffled': false,
      },
    };

/// 在 [_minimal] 上深改一处，省得每个用例抄一整份。
Map<String, dynamic> _with(Map<String, dynamic> patch) {
  final base = _minimal();
  base.addAll(patch);
  return base;
}

void main() {
  group('必填与结构', () {
    test('最小响应能解析，可选字段都是 null', () {
      final response = DecisionResponse.fromJson(_minimal());
      expect(response.requestId, 'r-1');
      expect(response.status, DecisionStatus.ok);
      expect(response.faults, isEmpty);
      expect(response.gates, isEmpty);
      expect(response.scores, isNull);
      expect(response.choice, isNull);
      expect(response.message, isNull);
      expect(response.primaryFault, isNull);
      expect(response.abstainReason, isNull);
    });

    test('缺必填字段时抛，消息里带字段路径', () {
      final json = _minimal()..remove('request_id');
      expect(
        () => DecisionResponse.fromJson(json),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            contains('response.request_id'),
          ),
        ),
      );
    });

    test('嵌套字段的路径一直指到下标', () {
      // 「缺字段」这四个字对调试毫无帮助；`response.faults[1].evidence.reps`
      // 能直接定位到是哪一条。
      final json = _with({
        'faults': [
          {
            'code': 'INSUFFICIENT_DEPTH',
            'name': '下蹲深度不足',
            'severity_level': 2,
            'severity_score': 49,
            'confidence': 0.9,
            'evidence': {
              'reps': [2, '第二次'],
            },
          },
        ],
      });
      expect(
        () => DecisionResponse.fromJson(json),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            contains('response.faults[0].evidence.reps[1]'),
          ),
        ),
      );
    });

    test('未知字段一律忽略', () {
      // 服务端加字段不该让老版本 App 崩掉。
      final json = _minimal()
        ..['service_version'] = '2.0'
        ..['future_block'] = {'anything': [1, 2, 3]};
      expect(DecisionResponse.fromJson(json).requestId, 'r-1');
    });

    test('meta 缺失时抛', () {
      final json = _minimal()..remove('meta');
      expect(() => DecisionResponse.fromJson(json), throwsA(isA<DecisionResponseException>()));
    });
  });

  group('status 是唯一一个取值也拦的字段', () {
    test('认识的两个值都能解析', () {
      expect(DecisionResponse.fromJson(_minimal()).status, DecisionStatus.ok);
      expect(
        DecisionResponse.fromJson(_with({'status': 'abstain', 'abstain_reason': '画面质量不足'}))
            .status,
        DecisionStatus.abstain,
      );
    });

    test('不认识的值抛，而不是按 ok 猜着读', () {
      expect(
        () => DecisionResponse.fromJson(_with({'status': 'degraded'})),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            allOf(contains('degraded'), contains('abstain')),
          ),
        ),
      );
    });
  });

  group('弃权', () {
    test('弃权必须说明原因', () {
      // 契约要求如此，而一条没有理由的弃权在界面上会变成一句
      // 「这组数据还不够评价」的判断题 —— 用户无从知道该重拍还是重做。
      expect(
        () => DecisionResponse.fromJson(_with({'status': 'abstain'})),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            contains('abstain_reason'),
          ),
        ),
      );
    });

    test('弃权时没有分数 —— 不是 0 分', () {
      final response = DecisionResponse.fromJson(
        _with({
          'status': 'abstain',
          'abstain_reason': '关键点可见性过低（0.20）',
          'scores': null,
        }),
      );
      expect(response.scores, isNull);
    });
  });

  group('取值越界不拦', () {
    test('severity_level 是 7 也照样读得出来', () {
      // 界面会把它渲染成「未知档」。一个越界的档位是服务端的问题，
      // 但不该让用户整份报告都看不到 —— 而这条错误之外的每一条都是好的。
      final response = DecisionResponse.fromJson(
        _with({
          'faults': [
            {
              'code': 'KNEE_VALGUS',
              'name': '膝内扣',
              'severity_level': 7,
              'severity_score': 130,
              'confidence': 1.4,
              'evidence': {'reps': [1]},
            },
          ],
        }),
      );
      expect(response.faults.single.severityLevel, 7);
      expect(response.faults.single.severityScore, 130);
    });

    test('整数写成 2.0 也认，但 0.9 不认', () {
      // JSON 里一个整数可能是 2.0。但静默 `toInt()` 会把 0.9 变成 0，
      // 而 0 是有含义的值（「一次都没出现过」）。
      final ok = _with({
        'faults': [
          {
            'code': 'C',
            'name': 'N',
            'severity_level': 2.0,
            'severity_score': 49.0,
            'confidence': 0.9,
            'evidence': {'reps': <dynamic>[]},
          },
        ],
      });
      expect(DecisionResponse.fromJson(ok).faults.single.severityLevel, 2);

      final bad = _with({
        'faults': [
          {
            'code': 'C',
            'name': 'N',
            'severity_level': 2.5,
            'severity_score': 49,
            'confidence': 0.9,
            'evidence': {'reps': <dynamic>[]},
          },
        ],
      });
      expect(() => DecisionResponse.fromJson(bad), throwsA(isA<DecisionResponseException>()));
    });

    test('evidence 的 metric 恒为 null，不猜一个数', () {
      // 服务端没有「用户看到的那一行数字」。要显示「左膝角 119.6°（参考值 100°）」
      // 得回本地那份请求里按码 join（见 decision_report.dart）。
      final response = DecisionResponse.fromJson(
        _with({
          'faults': [
            {
              'code': 'C',
              'name': 'N',
              'severity_level': 1,
              'severity_score': 10,
              'confidence': 0.5,
              'evidence': {'reps': [2], 'metric': null, 'mean_deviation': null},
            },
          ],
        }),
      );
      expect(response.faults.single.evidence.metric, isNull);
      expect(response.faults.single.evidence.reps, [2]);
    });

    test('evidence 整块缺失时退化成空，不抛', () {
      final response = DecisionResponse.fromJson(
        _with({
          'faults': [
            {
              'code': 'C',
              'name': 'N',
              'severity_level': 1,
              'severity_score': 10,
              'confidence': 0.5,
            },
          ],
        }),
      );
      expect(response.faults.single.evidence.reps, isEmpty);
    });
  });

  group('口径声明', () {
    test('decision_model_version 是 rule-only 就算规则兜底', () {
      expect(DecisionResponse.fromJson(_minimal()).meta.isRuleOnly, isTrue);
    });

    test('调了模型（shuffled 为 true）就不算', () {
      final json = _minimal();
      (json['meta'] as Map<String, dynamic>)['decision_model_version'] = 'laya-multilingual';
      (json['meta'] as Map<String, dynamic>)['shuffled'] = true;
      expect(DecisionResponse.fromJson(json).meta.isRuleOnly, isFalse);
    });

    test('版本号不认识但 shuffled 不是 true，仍按规则兜底披露', () {
      // 双条件兜底：`shuffled` 缺失或为 false 时，无论模型版本写着什么，
      // 都按「没过模型」披露。宁可可披露而实际过了模型（顶多多一句说明），
      // 也不能反过来 —— 那会让一份纯规则的结论看起来像模型判断的。
      final json = _minimal();
      (json['meta'] as Map<String, dynamic>)['decision_model_version'] = '将来才有的版本';
      // shuffled 本就缺省为 false
      expect(DecisionResponse.fromJson(json).meta.isRuleOnly, isTrue);
    });
  });

  group('文案与方案', () {
    test('message 只有模板 ID 与参数，没有正文', () {
      final response = DecisionResponse.fromJson(
        _with({
          'message': {
            'template_id': 'msg_squat_clean_teen_v1',
            'params': {'total': 10, 'valid': 8},
          },
        }),
      );
      expect(response.message!.templateId, 'msg_squat_clean_teen_v1');
      expect(response.message!.params, {'total': 10, 'valid': 8});
    });

    test('params 里的字符串 / 整数 / 小数都收，别的类型抛', () {
      expect(
        DecisionResponse.fromJson(
          _with({
            'message': {
              'template_id': 't',
              'params': {'a': 'x', 'b': 1, 'c': 1.5},
            },
          }),
        ).message!.params,
        {'a': 'x', 'b': 1, 'c': 1.5},
      );

      expect(
        () => DecisionResponse.fromJson(
          _with({
            'message': {
              'template_id': 't',
              'params': {
                'a': [1, 2],
              },
            },
          }),
        ),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            contains('response.message.params.a'),
          ),
        ),
      );
    });

    test('choice 只带 plan_id，正文留给端侧查', () {
      final response = DecisionResponse.fromJson(
        _with({
          'choice': {
            'selected_plan_ids': ['COR_BOX_SQUAT', 'COR_TEMPO_SQUAT'],
            'selection_reason': '以覆盖面为优先',
            'dose_note': '本建议由规则引擎按覆盖面排序产出；剂量待**核定**。',
          },
        }),
      );
      expect(response.choice!.selectedPlanIds, ['COR_BOX_SQUAT', 'COR_TEMPO_SQUAT']);
      expect(response.choice!.doseNote, contains('**核定**'));
    });

    test('selection_reason / dose_note 缺失时退化成空串', () {
      final response = DecisionResponse.fromJson(
        _with({
          'choice': {
            'selected_plan_ids': <dynamic>[],
          },
        }),
      );
      expect(response.choice!.selectionReason, '');
      expect(response.choice!.doseNote, '');
    });

    test('gate 的值必须是布尔', () {
      expect(
        () => DecisionResponse.fromJson(_with({'gates': {'KNEE_VALGUS_ok': 'false'}})),
        throwsA(
          isA<DecisionResponseException>().having(
            (e) => e.message,
            'message',
            contains('response.gates.KNEE_VALGUS_ok'),
          ),
        ),
      );
    });
  });

  group('decode', () {
    test('坏 JSON 抛的是本层的异常，不是 FormatException', () {
      expect(() => DecisionResponse.decode('{ 不是 json'), throwsA(isA<DecisionResponseException>()));
    });

    test('顶层不是对象时抛', () {
      expect(() => DecisionResponse.decode('[1, 2]'), throwsA(isA<DecisionResponseException>()));
    });

    test('能读一段真 JSON 文本', () {
      expect(DecisionResponse.decode('{"request_id":"r","status":"ok",'
          '"faults":[],"gates":{},"meta":{"decision_model_version":"rule-only",'
          '"thresholds_version":"v","latency_ms":0,"shuffled":false}}').requestId, 'r');
    });
  });

  group('Markdown 剥离', () {
    test('去掉星号，保留正文', () {
      // 服务端的文案字段是纯文本字段，却带 `**动作要领**`。别的消费方
      // 可能正靠那两个星号做排版，所以剥在端侧。
      expect(stripMarkdownEmphasis('**动作要领**：慢下慢起'), '动作要领：慢下慢起');
    });

    test('没有星号时原样返回', () {
      expect(stripMarkdownEmphasis('普通一句话'), '普通一句话');
    });
  });
}
