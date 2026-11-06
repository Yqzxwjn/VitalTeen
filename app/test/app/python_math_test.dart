/// Python 舍入规则的复刻测试。
///
/// **这里的每个期望值都是从真 Python 跑出来的，不是手算的。** 手算会犯的错
/// 恰恰是这个文件要防的错 —— 人脑默认「.5 就进位」，而 Python 是进位到偶数。
///
/// 所以分两组：一组钉住**行为**（Python 的答案），一组钉住**差异**
/// （Dart 原生写法给出的不同答案）。第二组看着像废话，其实不是：
/// 它把「这件事有坑」写成可执行的文档 —— 谁要是把 [pyFixed2] 换成
/// `toStringAsFixed`，第一组会红；谁要是以为两者等价而删掉这个文件，
/// 第二组会告诉后来的人为什么不能。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/python_math.dart';

void main() {
  group('pyRound：Python 的 round(x)', () {
    test('并列时进位到偶数，而不是远离零', () {
      // 四个一圈，正负各一对：有的向下、有的向上 —— 只看单向的实现会漏一半。
      expect(pyRound(12.5), 12);
      expect(pyRound(13.5), 14);
      expect(pyRound(-0.5), 0);
      expect(pyRound(-1.5), -2);
      expect(pyRound(-2.5), -2);
    });

    test('不并列时就是普通的四舍五入', () {
      expect(pyRound(0.4), 0);
      expect(pyRound(0.6), 1);
      expect(pyRound(-0.4), 0);
      expect(pyRound(-0.6), -1);
    });

    test('对精确的二进制值仍然按「精确值」判定', () {
      // 0.125 在二进制里恰好是 0.125，所以 ×100 恰好是 12.5 —— 真并列。
      // 换成 0.1 + 0.2 那种就不是了，这里刻意不用那种值：
      // 拿一个「看起来该并列、其实是 12.500000000000002」的数当用例，
      // 测出来的是浮点误差，不是舍入规则。
      expect(pyRound(0.125 * 100), 12);
      expect(pyRound(0.375 * 100), 38);
    });

    test('分数就是服务端那条式子', () {
      // severity_score=round(severity * 100)，端侧要给出同一个整数。
      expect(pyRound(0.0 * 100), 0);
      expect(pyRound(1.0 * 100), 100);
      expect(pyRound(0.345 * 100), 34); // 34.5 → 34（偶数）
    });

    test('非有限值抛，而不是返回一个假数字', () {
      // Python 在这里抛 OverflowError / ValueError。返回 0 更糟：
      // 它会带着一个看起来正常的分数一路走进报告。
      expect(() => pyRound(double.nan), throwsArgumentError);
      expect(() => pyRound(double.infinity), throwsArgumentError);
      expect(() => pyRound(double.negativeInfinity), throwsArgumentError);
    });
  });

  group('pyRoundTo：Python 的 round(x, n)', () {
    test('并列时进位到偶数', () {
      // 0.03125 与 0.09375 都是精确的二进制值，×10⁴ 后恰好落在 .5 上，
      // 且一个向下、一个向上。
      expect(pyRoundTo(0.03125, 4), 0.0312);
      expect(pyRoundTo(0.09375, 4), 0.0938);
    });

    test('confidence 那条式子', () {
      // confidence=round(min(mean_visibility, coverage_ok_ratio), 4)
      expect(pyRoundTo(0.90625, 4), 0.9062);
      expect(pyRoundTo(0.5, 4), 0.5);
      expect(pyRoundTo(0.123456, 4), 0.1235);
    });

    test('负的小数位数是显式拒绝，不是猜一种语义', () {
      expect(() => pyRoundTo(1234.5, -1), throwsArgumentError);
    });
  });

  group('pyFixed2：Python 的 f"{x:.2f}"', () {
    test('并列时进位到偶数', () {
      // 这两个是**弃权理由里真正会出现**的值：可见性 0.125 时，
      // Python 说「0.12」，Dart 原生写法会说「0.13」。
      expect(pyFixed2(0.125), '0.12');
      expect(pyFixed2(0.375), '0.38');
    });

    test('不并列时四舍五入，并补足两位', () {
      expect(pyFixed2(0.90625), '0.91');
      expect(pyFixed2(0.5), '0.50');
      expect(pyFixed2(0.004), '0.00');
      expect(pyFixed2(1.0), '1.00');
      expect(pyFixed2(0.0), '0.00');
    });

    test('负的零照 Python 的样子渲染成 -0.00', () {
      // f'{-0.004:.2f}' 在 Python 里是 '-0.00' —— 不是 '0.00'。
      // 数值上等价，字符串上不等价，而这个字符串会直接进弃权理由那句话。
      expect(pyFixed2(-0.004), '-0.00');
      expect(pyFixed2(-0.005), '-0.01');
    });
  });

  group('与 Dart 原生的差异（这组是文档，不是断言同义反复）', () {
    test('round 在并列处就走岔了', () {
      expect((12.5).round(), 13, reason: 'Dart：远离零');
      expect(pyRound(12.5), 12, reason: 'Python：进位到偶数');
      expect((12.5).round(), isNot(pyRound(12.5)));
    });

    test('toStringAsFixed 也一样', () {
      expect(0.125.toStringAsFixed(2), '0.13');
      expect(pyFixed2(0.125), '0.12');
      expect(0.125.toStringAsFixed(2), isNot(pyFixed2(0.125)));
    });
  });
}
