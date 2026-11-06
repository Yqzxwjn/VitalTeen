/// 动作预览的测试。
///
/// 这一组里最值钱的是**相位词那条**：预览上那一拍叫什么，和相机页 HUD 上
/// 那一拍叫什么，必须是同一个词。它们是两个人写的、在两个文件里、服务于
/// 两个屏幕，而用户看到的是同一个人在同一件事上被告知两次。
/// 词一旦漂开（预览说「蹬伸」、HUD 说「起跳」），用户会以为自己看漏了一拍。
///
/// 另一条管的是**覆盖**：清单里的九个动作在这张表里都得有姿势。
/// 少一个不会崩 —— `ExercisePreview` 会画一句「这个动作还没有预览」——
/// 但那正是要拦的：一个空框在预览页里看起来像是加载失败。
///
/// 第三条管的是**趴着、坐着那几个动作站在哪儿**。「踩在地上的动作」那一组
/// 盯的是一类只能靠看才发现的错：人形按「最低点贴地」摆，所以只要有一处
/// 不该着地的地方垂到脚下面，**整个人就被抬离地面**。仰卧起坐和坐位体前屈
/// 都栽在这上头，而它们在本文件里一条断言都不会红 —— 数值全是对的，
/// 错在那些数值**合起来**画出来的东西。这条测试就是把「用眼睛看出来」
/// 换成一条断言。见 `工具`：`tool/preview_sheet.dart`。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitalteen_app/app/action_spec.dart';
import 'package:vitalteen_app/ui/exercise_catalog.dart';
import 'package:vitalteen_app/ui/exercise_preview.dart';
import 'package:vitalteen_app/ui/preview_poses.dart';
import 'package:vitalteen_app/ui/theme.dart';

Future<void> _mount(WidgetTester tester, String code) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildVitalTeenTheme(),
    home: Scaffold(body: ExercisePreview(code: code)),
  ));
}

/// 点 [p] 到直线 [a]–[b] 的垂直距离（人形单位）。
double _distanceToLine(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final ap = p - a;
  return (ab.dx * ap.dy - ab.dy * ap.dx).abs() / ab.distance;
}

void main() {
  group('姿势表', () {
    test('清单里的每个动作都有姿势，一个不多一个不少', () {
      final catalogue = [for (final e in allExercises()) e.code]..sort();
      final poses = kPreviewFrames.keys.toList()..sort();

      expect(poses, catalogue,
          reason: '两边对不上：清单里有动作没有预览，或者预览里挂着一个'
              '清单里已经没有的码');
    });

    test('每个动作至少两拍 —— 一帧的「动画」不是动画', () {
      for (final entry in kPreviewFrames.entries) {
        expect(entry.value.length, greaterThanOrEqualTo(2),
            reason: entry.key);
      }
    });

    test('每一拍都有相位词', () {
      for (final entry in kPreviewFrames.entries) {
        for (final frame in entry.value) {
          expect(frame.label, isNotEmpty, reason: entry.key);
        }
      }
    });

    test('每个已注册的动作，相位词与相机页 HUD 逐字一致、顺序也一致', () {
      // 顺序也管：HUD 上那四个词是按状态链的顺序排的，预览的拍子也必须按
      // 同一个顺序演，否则用户看到的是一条倒着放的链。
      //
      // 键取的是 `action_spec.dart` 里的表，**不是抄一份字面量** ——
      // 抄一份的话，改了 HUD 的词这条测试照样绿，而它本该红。
      //
      // **遍历 `kActionSpecs` 而不是逐个列举**：加第四个动作时忘掉这里，
      // 这条测试不会红 —— 所以下面就着 `kPreviewFrames` 的键再核一次
      // 「每个有独立词表的动作都被这条比过」，把「忘了加」变成可执行的。
      for (final spec in kActionSpecs) {
        expect(
          [for (final f in kPreviewFrames[spec.code] ?? const []) f.label],
          spec.hudStateLabels.values.toList(),
          reason: '${spec.code} 的预览相位词与 HUD 词表对不上',
        );
      }
    });

    test('没开放的动作也照样有一整套姿势', () {
      // 它们的 tagline 早就在首页上写着「这个动作会看什么」
      //（`exercise_catalog.dart`），预览是那句话的图像版。
      for (final entry in allExercises()) {
        if (entry.isLive) continue;
        expect(kPreviewFrames[entry.code], isNotNull, reason: entry.code);
      }
    });
  });

  group('画面框', () {
    test('竖直方向不越界 —— 头顶和脚底都要在框里', () {
      // 框写死过一次，代价是立定跳远那一跳被切掉半个身子、引体向上的手
      // 出了框。这条测试盯的就是「框是按姿势算的」。
      for (final entry in kPreviewFrames.entries) {
        final view =
            entry.key == 'JJ' ? PreviewView.front : PreviewView.side;
        final box = previewBox(entry.value, view);

        for (final frame in entry.value) {
          for (final point in previewPoints(frame, view).values) {
            expect(box.contains(point), isTrue,
                reason: '${entry.key} 的 ${frame.label} 有点落在框外：$point');
          }
        }
      }
    });

    test('踩在地上的动作，地面线在框里', () {
      // 地面线是「离地多少」的唯一参照。它掉到框外的话，腾空那一拍就
      // 看不出在腾空 —— 画面里只剩一个悬着的、没有参照的人。
      final frames = kPreviewFrames['SLJ']!;
      final box = previewBox(frames, PreviewView.side);
      expect(box.top, lessThanOrEqualTo(0.0));
      expect(box.bottom, greaterThanOrEqualTo(0.0));
    });
  });

  group('踩在地上的动作', () {
    test('撑着人的是脚 —— 比脚还低的部位会把人整个抬起来', () {
      // 人形是按「最低的那个点贴地」摆的（`_ForwardKinematics.solve`），
      // 所以**任何一处垂得比脚还低，整个身体都会被抬离地面**。
      // 仰卧起坐和坐位体前屈都栽在这上面：手臂垂到地面线以下，手当上了那个
      //「最低点」，于是躺着的人**臀离地 0.185**、坐着的人**离地 0.105**，
      // 两屏画面上都是一个人浮在半空。**这个错在数值上完全看不出来**，
      // 是渲染出来才看见的 —— 数值全是对的，错在它们**合起来**画出的东西。
      //
      // 容差 0.02 是**量出来的**，不是估的：这几个动作的正确姿势解出来
      // 恰好是 **0.000**（脚趾就是全图最低点，因为那些角度本来就是照
      //「手／肘和脚趾同时落在地面线上」解出来的），所以下界可以压得很低；
      // 而离得最近的那个真错是 0.105，还差五倍。
      //
      // 这条测试的形状是「脚必须承重」，所以它只对**脚踩地**的动作成立。
      // 以后真加了一个以别的部位承重的姿势（比如坐姿举腿的坐骨），
      // 该做的是给它另开一组，**不是把这个数往上抬** ——
      // 抬到 0.11 以上这条测试就再也拦不住任何东西了。
      for (final entry in kPreviewFrames.entries) {
        final view = entry.key == 'JJ' ? PreviewView.front : PreviewView.side;
        for (final frame in entry.value) {
          if (frame.lift != 0) continue; // 腾空的一拍本来就不落地
          final points = previewPoints(frame, view);

          // `dy` 朝下，所以取 `max` 就是「最低的那个点」。
          // 差要是**最低点减脚**：脚高出最低点多少。反过来写的话恒为负，
          // 这条断言就成了永远通过的空壳 —— 它刚写出来时就是这样。
          final lowest = points.values.map((p) => p.dy).reduce(math.max);
          final foot = ['ankleL', 'ankleR', 'toeL', 'toeR']
              .map((name) => points[name]!.dy)
              .reduce(math.max);

          expect(lowest - foot, lessThan(0.02),
              reason: '${entry.key} 的 ${frame.label}：'
                  '脚离最低点还差 ${(lowest - foot).toStringAsFixed(3)}，'
                  '撑着人的不是脚');
        }
      }
    });

    test('俯卧撑的身体是一条线', () {
      // 「身体成一条线」既是这项运动的判定标准，也是它最容易一笔画错的地方：
      // `hip` 和 `trunk` 只要不是严格的相反数，差多少角度就在髋上折多少。
      // 早先写的是 `trunk: 88, hip: -61`，差出来的 27° 落在髋上 ——
      // 画出来是「下犬式」：髋顶在最上面、躯干横着、腿斜着往下插。
      //
      // 这里量的是**髋到「肩—膝」这条线的垂直距离**，不是去比对数值 ——
      // 比对数值只能证明这两个数相等，证明不了画出来是一条线。
      //
      // 平板支撑没算进来：它要在肘和脚趾**同时**着地的前提下解出髋角，
      // 解得 0.023 的偏摆（见那张表里的注释），比这里的门槛还宽。
      for (final frame in kPreviewFrames['PU']!) {
        final p = previewPoints(frame, PreviewView.side);
        final sag = _distanceToLine(p['hip']!, p['shoulderL']!, p['kneeL']!);
        expect(sag, lessThan(0.01),
            reason: '${frame.label}：髋离「肩—膝」那条线 ${sag.toStringAsFixed(3)}，'
                '身体从髋上折了');
      }
    });
  });

  group('正视的动作', () {
    test('左右两侧关于中轴严格镜像', () {
      // 正视里左右是同一个人形的两半，**必须互为镜像**，否则画出来的是个歪人。
      // 这条断言是有来历的：写它的时候代码正是错的 —— 正视分支里只有脚的朝向
      // 翻了号，屈膝与屈肘没翻，于是 `spread: 26, knee: 20` 那一拍左踝落在
      // +0.182、右踝落在 −0.327，差着一倍；腿上看着像罗圈，根上却是同一个符号
      // 用在了两半上。
      //
      // 判据是「x 相反、y 相同」，**不是「左右数值相等」** —— 相等只说明两边
      // 套了同一个值，而那恰好就是错的写法。镜像律本身是一条恒等式：
      // `_rot(mirror(v), -θ) == mirror(_rot(v, θ))`。
      const pairs = [
        'shoulder',
        'elbow',
        'wrist',
        'hipRoot',
        'knee',
        'ankle',
        'toe',
      ];
      for (final frame in kPreviewFrames['JJ']!) {
        final p = previewPoints(frame, PreviewView.front);
        for (final name in pairs) {
          final l = p['${name}L']!;
          final r = p['${name}R']!;
          expect(l.dx, closeTo(-r.dx, 1e-9),
              reason: '${frame.label} 的 $name：左 ${l.dx}、右 ${r.dx}，'
                  'x 不是相反数');
          expect(l.dy, closeTo(r.dy, 1e-9),
              reason: '${frame.label} 的 $name：左右高度差 ${l.dy - r.dy}');
        }
      }
    });

    test('人的左侧画在画面右边 —— 正对镜头时他的左就是你的右', () {
      // `_limbDir` 的符号与 `hipRoot*` / `shoulder*` 两个锚点必须取同一个约定。
      // 取反的话腿会从胯的**另一边**长出去，在根部分叉成一个大叉 ——
      // 侧视里两胯重合所以看不出来，正视里一眼就是错的。
      final p = previewPoints(kPreviewFrames['JJ']!.first, PreviewView.front);
      expect(p['hipRootL']!.dx, greaterThan(0), reason: '左胯应该在画面右半边');
      expect(p['shoulderL']!.dx, greaterThan(0), reason: '左肩应该在画面右半边');
      expect(p['ankleL']!.dx, greaterThan(p['ankleR']!.dx));
    });

    test('屈肘在正视下也镜像 —— 开合跳都是直臂，这条是为下一个正视动作准备的', () {
      // 开合跳四拍的 `elbow` 全是 0，所以上面那条镜像断言**碰不到**屈肘这个
      // 分支（把代码撤回原样它照样绿）。单独造一帧屈臂钉住它：正视下左臂的
      // 附加转角取负、右臂取正，照搬侧视那一个符号的话两条前臂会朝同一边拐。
      const frame = PreviewFrame(
        pose: PreviewPose(shoulder: 150, spread: 10, elbow: 30),
        label: '举臂屈肘',
      );
      final p = previewPoints(frame, PreviewView.front);
      final l = p['wristL']!;
      final r = p['wristR']!;
      expect(l.dx, closeTo(-r.dx, 1e-9), reason: '左腕 ${l.dx}、右腕 ${r.dx}');
      expect(l.dy, closeTo(r.dy, 1e-9));
    });

    test('脚朝外撇，两脚不指向同一边', () {
      // 侧视里两脚都朝前（也是唯一一边），正视照搬的话两只脚会一起指向屏幕
      // 右侧 —— 正面站着的人不可能这样。
      final p = previewPoints(kPreviewFrames['JJ']!.first, PreviewView.front);
      expect(p['toeL']!.dx - p['ankleL']!.dx, greaterThan(0), reason: '左脚该朝右外');
      expect(p['toeR']!.dx - p['ankleR']!.dx, lessThan(0), reason: '右脚该朝左外');
    });
  });

  group('动画本身', () {
    testWidgets('会动：相位词随着拍子往前走', (tester) async {
      await _mount(tester, 'SQUAT');
      expect(find.text('站立'), findsOneWidget);

      // 一拍停 900ms、走 420ms。跳过一整拍多一些，词必须换。
      // **不能用 `pumpAndSettle`** —— 这个动画是 `repeat()` 的，永远 settle 不了。
      await tester.pump(const Duration(milliseconds: 1400));
      // 再来一帧，而且要等够 `AnimatedSwitcher` 那 220ms：换词是交叉淡入淡出，
      // 旧的那个 `Text` 在过渡结束前**还在树上**。少了这一下，「站立」和「下蹲」
      // 会同时被找到 —— 那条断言测的就成了「动画走没走」以外的东西。
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('站立'), findsNothing,
          reason: '过了整整一拍还停在「站立」，说明动画根本没走');
      expect(find.text('下蹲'), findsOneWidget);
    });

    testWidgets('未知动作码画一句说明，不画别的动作', (tester) async {
      // 画一个默认动作会让人以为他看的就是自己点的那个 ——
      // 这正是 `preview_poses.dart` 里那句「谁也不驱动谁」要防的事。
      await _mount(tester, '没有这个码');
      expect(find.text('这个动作还没有预览'), findsOneWidget);
    });

    testWidgets('九个动作都画得出来，没有一个落到兜底分支上', (tester) async {
      for (final entry in allExercises()) {
        await _mount(tester, entry.code);
        expect(find.text('这个动作还没有预览'), findsNothing,
            reason: '${entry.nameZh} 没有预览');
      }
    });
  });
}
