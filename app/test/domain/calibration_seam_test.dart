/// 标定接缝的守卫测试（Python 侧对应 `domain/tests/test_calibration_seam.py`）。
///
/// **这一组的对象不是某个动作，而是一次共享组件的改动。** 标定要求的基线量从写死的
/// 四个特征，变成了「随动作而变、默认仍是原来那三个」。深蹲与立定跳远不传新参数，
/// 所以它们**应当**一个字节都没变 —— 但「应当」不算数：这类改动的失败模式全是
/// **静默**的（标定恒不完成、屏幕无报错、永远进不了计数），跑一遍测试看着全绿
/// 恰恰是它最像的样子。
///
/// 所以这里逐条列出「深蹲的行为会在什么情况下变」，每条配一条断言：
///
/// | 会让深蹲变的行为 | 表现 | 下面哪条守卫 |
/// |---|---|---|
/// | 默认基线集与今天那三个不逐值相等 | 标定恒不完成，屏幕无报错 | `默认基线集` |
/// | 可用性门槛不按 `required` 收 | 深蹲在要 `legSpread` 的路径上卡死 | `拿不到的量` |
/// | 缺基线时静默取 0 而不是抛 | 躯干前倾/脚跟离地的阈值线挪位 | `缺席即抛` |
/// | spec 的基线集在自己的机位下采不到 | 标定恒不完成，屏幕无报错 | `每个已注册的动作` |
///
/// **这张表本身就是交付物**：不是「我改得很小心」，而是列清楚它在什么情况下会坏、
/// 以及坏的时候谁会响。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/domain/exercises/base.dart';
import 'package:vitalteen_app/domain/features.dart';

import '../support/synthetic_squat.dart';

/// 历史上那三个基线量。**写死在这里是刻意的** ——
/// 从 `BaselineKey.defaultRequired` 取的话，这条断言就成了自己跟自己比。
const Set<BaselineKey> _historicalThree = {
  BaselineKey.kneeAngle,
  BaselineKey.trunkLean,
  BaselineKey.heelRiseRatio,
};

FeatureExtractor _extractor(CameraView view) =>
    FeatureExtractor(cameraView: view);

void main() {
  group('默认基线集', () {
    test('Calibrator 不传 required 时，采的恰好是今天那三个', () {
      // **要的是「恰好」，不是「至少」**：多一个（比如顺手把 legSpread 加进默认）
      // 会让深蹲在侧视下永远采不到分腿比，feed 恒返回 null —— 标定条卡在 0，
      // 屏幕上没有任何错误。少一个则会让脚跟离地那条规则的阈值线整段挪位。
      //
      // 用 setEquals 而不是 `==`：Dart 的 Set 没有值相等语义，
      // `{a, b} == {a, b}` 恒为 false，写成 `==` 这条断言会**永远红**，
      // 然后被人当成噪音删掉。
      expect(
        setEquals(Calibrator().required, _historicalThree),
        isTrue,
        reason: '默认基线集变成 ${Calibrator().required.map((k) => k.name)} 了',
      );
    });

    test('深蹲与立定跳远都走默认集 —— 它们一个字节都没被改', () {
      // 深蹲与立定跳远都靠 `heelRiseRatio`（脚跟离地那条规则），
      // 都跑 45° 斜机位，所以默认集对它们正好合用。哪天有人给它们显式传一个
      // 别的集合，这条会红。
      //
      // **这里是逐个列举，不是遍历 `kActionSpecs`。** 开合跳刻意不用默认集，
      // 遍历的话「它也走默认集」会被当成正常 —— 而这个文件存在的理由正是
      // 拒绝那种「所有动作都一样」的默认。它那一条在下面单独钉。
      for (final spec in [squatSpec, sljSpec]) {
        expect(
          setEquals(spec.calibrationBaselines, Calibrator().required),
          isTrue,
          reason: '${spec.code} 的基线集与默认集不一致：'
              '${spec.calibrationBaselines.map((k) => k.name)}',
        );
      }
    });

    test('开合跳的基线集恰好是「膝角 / 躯干倾角 / 分腿比」', () {
      // **要的是「恰好」。** 多一个（顺手把 `heelRiseRatio` 留下）就够让它
      // 在正视机位下恒采不满 —— `heel_rise_ratio_L` 声明
      // `[sagittal, oblique45]`，正视下是 `view_mismatch`，
      // 而 `Calibrator.feed` 会因此整帧丢弃、永远返回 null。
      // 表现是标定条卡在 0、屏幕上没有任何错误。
      expect(
        setEquals(jjSpec.calibrationBaselines, {
          BaselineKey.kneeAngle,
          BaselineKey.trunkLean,
          BaselineKey.legSpread,
        }),
        isTrue,
        reason: '开合跳的基线集变成 '
            '${jjSpec.calibrationBaselines.map((k) => k.name)} 了',
      );
      expect(
        jjSpec.calibrationBaselines.contains(BaselineKey.heelRiseRatio),
        isFalse,
        reason: '正视机位下脚跟抬升比恒不可用，带上它标定就再也走不完',
      );
    });

    test('不传 required 采出来的数与今天逐值相同，且没采的量为 null', () {
      final extractor = _extractor(CameraView.sagittal);
      final calibrator = Calibrator(minFrames: 10);
      Calibration? result;
      for (var i = 0; i < 10; i++) {
        result =
            calibrator.feed(extractor.extract(squatPose(standDeg, timestampMs: i * 33)));
      }

      expect(result, isNotNull);
      expect(result!.frames, 10);
      expect(result.kneeAngle, closeTo(standDeg, 1.0));
      expect(result.trunkLean, closeTo(0.0, 1.0));
      expect(result.heelRiseRatio, closeTo(0.0, 1e-3));
      // **没采的量是 null，不是 0。** 0 是一个会参与 `stand ± …` 计算的数，
      // null 不是 ——「不知道」和「是零」在个体化阈值里是两回事。
      expect(result.legSpread, isNull);
    });
  });

  group('拿不到的量', () {
    test('要采的量在自己机位下拿不到时：标定不完成，也**不报错**', () {
      // 这是这一整节要修的坏法的**最小复现**。正面机位下 `heel_rise_ratio_L`
      // 恒不可用，而标定器原先硬性要求它 —— 于是标定条卡在 0，
      // 屏幕上没有任何错误，用户只会以为这个功能坏了。
      //
      // 这里换成「侧视下要分腿比」来复现同一个形状：`leg_spread_ratio`
      // 在侧视下拿不到（声明的是 `views: [frontal]`）。断言的是**行为**，
      // 不是某个特征存不存在 —— 所以这条测试在特征加进来之前之后都成立。
      final extractor = _extractor(CameraView.sagittal);
      final calibrator = Calibrator(
        required: {
          BaselineKey.kneeAngle,
          BaselineKey.trunkLean,
          BaselineKey.legSpread,
        },
        minFrames: 3,
      );

      for (var i = 0; i < 30; i++) {
        expect(
          calibrator.feed(extractor.extract(squatPose(standDeg, timestampMs: i * 33))),
          isNull,
          reason: '第 $i 帧：分腿比拿不到，这一帧应当整帧丢弃',
        );
      }
      expect(calibrator.isReady, isFalse);
      // 注意这里**没有**「抛异常」的断言：不抛才是对的行为（一帧坏不等于会话坏），
      // 也正因为不抛，这个 bug 才那么难查。
    });

    test('同一台标定器把 legSpread 去掉就采得满 —— 差别确实来自那一个量', () {
      // 上一条要是因为「侧视帧本来就采不满」而绿，它就什么都没证明。
      // 这一条把唯一不同的那个变量拿掉，必须立刻变成绿 —— 两条合起来才说明
      // 上一条拦的是 legSpread 而不是别的东西。
      final extractor = _extractor(CameraView.sagittal);
      final calibrator = Calibrator(minFrames: 3);
      Calibration? result;
      for (var i = 0; i < 3; i++) {
        result =
            calibrator.feed(extractor.extract(squatPose(standDeg, timestampMs: i * 33)));
      }
      expect(result, isNotNull);
      expect(calibrator.isReady, isTrue);
    });
  });

  group('缺席即抛', () {
    const noHeel = Calibration(
      kneeAngle: 175,
      trunkLean: 0,
      heelRiseRatio: null,
      frames: 15,
    );

    test('基线量为 null 时 of 抛异常，不返回 0', () {
      // 取 0 会把深蹲 `EXCESSIVE_TRUNK_LEAN` / `HEEL_RISE` 的阈值从
      // 「基线 + 阈值增量」悄悄变成「阈值增量本身」—— 一条针对本人的线，
      // 变成一条针对某个不存在的人的线，而屏幕上一切照常。
      expect(
        () => BaselineKey.heelRiseRatio.of(noHeel),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('BaselineOffset 顺着往上抛，自己不兜底', () {
      // `BaselineOffset.resolve` 只调 `of`，异常自然上抛。哪天有人在它里面
      // 加了「缺失取 0」的兜底，这条会红 —— 而那个兜底正是最像「健壮性改动」
      // 的那种坏改动。
      expect(
        () => const BaselineOffset(BaselineKey.heelRiseRatio, 1.0).resolve(noHeel),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('采集到的基线一个都不缺时照常返回', () {
      // 上两条要是因为「of 对什么都抛」而绿，就什么都没证明。
      const full = Calibration(
        kneeAngle: 175,
        trunkLean: 4,
        heelRiseRatio: 0.02,
        legSpread: 0.6,
        frames: 15,
      );
      expect(BaselineKey.kneeAngle.of(full), 175);
      expect(BaselineKey.trunkLean.of(full), 4);
      expect(BaselineKey.heelRiseRatio.of(full), 0.02);
      expect(BaselineKey.legSpread.of(full), 0.6);
    });
  });

  group('每个已注册的动作', () {
    test('它的基线集在自己的机位下都采得到', () {
      // **这是「机位写错了」的哨兵。** 基线量与机位是绑死的：能采到哪些量
      // 完全由机位决定。哪天有人把某个动作的 `cameraView` 改成一个采不到它
      // 基线集的机位（比如把开合跳写成 45°），标定就会恒不完成、屏幕无报错。
      //
      // 断言的是**行为**（喂真帧，标定走不走得完），不是任何一张表 ——
      // 这样它对「机位」与「基线集」两边各自的改动都敏感。
      for (final spec in kActionSpecs) {
        final extractor = _extractor(spec.cameraView);
        final calibrator = Calibrator(
          required: spec.calibrationBaselines,
          minFrames: 5,
        );
        for (var i = 0; i < 5; i++) {
          calibrator.feed(extractor.extract(squatPose(standDeg, timestampMs: i * 33)));
        }
        expect(
          calibrator.isReady,
          isTrue,
          reason: '${spec.code} 在 ${spec.cameraView.name} 机位下标定采不满：'
              '它的基线集里有一个量在这个机位下拿不到',
        );
      }
    });
  });

  group('每个已注册的动作', () {
    test('标定结果里读得回它声明要采的每一个量', () {
      // **专抓「采了，但没往结果里放」。** `Calibrator.feed` 是按 `required`
      // 逐量累加样本的，而结果 `Calibration` 是**手写**的一项一项拼出来的
      // （它比 `required` 多两个总是要的 `kneeAngle` / `trunkLean`，其余每一项
      // 都是可空）。漏拼一项的表现极隐蔽：标定照样走完、`isReady` 为真、
      // 屏幕上一切正常，而**读那一项的人**在别处抛 ——
      // `buildRope` 里的 `calibration.footHeight ?? throw`，抛点在
      // `_buildRunner` 里，也就是用户做完一组、标定刚结束的那一刻。一组白做。
      //
      // 2026-10-05 就是这样漏掉 `footHeight` 的：`_collectBaseline` 里有它、
      // 上面的「都采得到」那条也绿（它只问 `isReady`）。**采到 ≠ 放进去。**
      for (final spec in kActionSpecs) {
        final extractor = _extractor(spec.cameraView);
        final calibrator = Calibrator(
          required: spec.calibrationBaselines,
          minFrames: 5,
        );
        for (var i = 0; i < 5; i++) {
          calibrator.feed(
            extractor.extract(squatPose(standDeg, timestampMs: i * 33)),
          );
        }
        final calibration = calibrator.calibration;
        expect(calibration, isNotNull, reason: '${spec.code} 标定没走完');

        for (final key in spec.calibrationBaselines) {
          expect(
            () => key.of(calibration!),
            returnsNormally,
            reason: '${spec.code} 声明要采 ${key.name}，'
                '但标定结果里没有这个量 —— 拼 `Calibration` 时漏了一项',
          );
        }
      }
    });
  });

  group('required 的构造期校验', () {
    test('漏掉每个动作都要的量时就地抛出，不等到用的时候', () {
      expect(
        () => Calibrator(required: {BaselineKey.heelRiseRatio}),
        throwsA(isA<ExerciseException>()),
      );
    });

    test('合法的集合照常构造', () {
      expect(
        Calibrator(required: {
          BaselineKey.kneeAngle,
          BaselineKey.trunkLean,
          BaselineKey.legSpread,
        }).required.length,
        3,
      );
    });
  });
}
