/// 问候语时段的测试。
///
/// **这一组测的全是边界。** 五档划分的中间值（比如 9 点说「早上好」）写错了
/// 一眼就能看出来，没人会那么写；会写错的是 10:59 与 11:00 这种地方 ——
/// 把 `<` 写成 `<=`、或者某一档的上下界各差一小时，在开发机上打开应用
/// 多半看不出来，除非恰好那一分钟去试。
///
/// 所以这里逐个小时都过一遍（一天 24 次），而不是挑几个代表值。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/greeting.dart';

/// 本地时间某一天的 [hour] 点整。
///
/// 用 `DateTime(...)` 构造而不是 `DateTime.utc(...)`：`greetingFor` 会
/// `toLocal()`，喂 UTC 进去的话，测试的结果会跟着跑测试那台机器的时区变 ——
/// 在 CI 上（多半是 UTC）恰好是对的，在开发机上不是。
DateTime _at(int hour) => DateTime(2026, 10, 5, hour);

void main() {
  group('五个时段', () {
    test('逐小时看一遍，一天里每一刻都有话可说', () {
      const expected = {
        0: '夜深了',
        1: '夜深了',
        2: '夜深了',
        3: '夜深了',
        4: '夜深了',
        5: '早上好',
        6: '早上好',
        7: '早上好',
        8: '早上好',
        9: '早上好',
        10: '早上好',
        11: '中午好',
        12: '中午好',
        13: '中午好',
        14: '下午好',
        15: '下午好',
        16: '下午好',
        17: '下午好',
        18: '晚上好',
        19: '晚上好',
        20: '晚上好',
        21: '晚上好',
        22: '晚上好',
        23: '夜深了',
      };

      expected.forEach((hour, word) {
        expect(greetingFor(_at(hour)), word, reason: '$hour 点');
      });
      // 24 个都在表里 —— 漏掉一个小时的话上面那个循环不会说话。
      expect(expected, hasLength(24));
    });

    test('边界就在整点上：10:59 还是早上，11:00 已经是中午', () {
      expect(greetingFor(DateTime(2026, 10, 5, 10, 59)), '早上好');
      expect(greetingFor(DateTime(2026, 10, 5, 11, 0)), '中午好');
    });

    test('23 点与 0 点说的是同一句 —— 跨零点不该换一句话', () {
      // 23:59 与 00:01 只差两分钟，中间没有发生任何事。
      expect(greetingFor(DateTime(2026, 10, 5, 23, 59)), '夜深了');
      expect(greetingFor(DateTime(2026, 10, 6, 0, 1)), '夜深了');
    });

    test('每一句都落在首页横幅的黑名单之外', () {
      // 横幅在整张动作清单上面，而端到端测试会用裸 `find.text('开始')`
      // 去点东西（`squat_widgets_test.dart`）。问候语里带一个「开始」，
      // 那些 tap 会一次找到两个然后失败，失败信息却指向别处。
      for (var hour = 0; hour < 24; hour++) {
        final word = greetingFor(_at(hour));
        for (final banned in const ['开始', '深蹲', '本组报告', '取消', '保存']) {
          expect(word.contains(banned), isFalse,
              reason: '$hour 点说的是「$word」，里面有「$banned」');
        }
      }
    });
  });
}
