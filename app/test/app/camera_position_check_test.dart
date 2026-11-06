/// 站姿与机位自检测试。
///
/// **这里钉的头一条是「人正对镜头时必须被拦住」。** 那不是一个体验问题：
/// 正视画面里髋、膝、踝几乎共线于图像平面，蹲到底投影出来的膝角仍接近 180°，
/// 状态机永远不离开 `STANDING` —— count 恒为 0，而且不抛异常、不置 `null`、
/// 不出现在任何错误日志里。用户蹲了二十个、屏幕上是个 0，没有任何线索。
///
/// 所以这条判据在真机上失效的代价，比其他所有判据加起来都大。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalteen_app/app/action_spec.dart'
    show jjFrontalAdvice, jjRequiredLandmarks, squatFrontalAdvice;
import 'package:vitalteen_app/app/camera_position_check.dart';
import 'package:vitalteen_app/domain/features.dart';
import 'package:vitalteen_app/domain/landmarks.dart';
import 'package:vitalteen_app/domain/pose.dart';

import '../support/synthetic_pu.dart';

const int _side = 1000;

/// 造一帧站姿。
///
/// 几何是刻意摆成「侧向比可控」的：肩与髋各自水平张开 `lateralRatio × 躯干长`，
/// 而躯干长就是 `hipY - shoulderY`。于是
/// `r = (肩距 + 髋距) / (2 × 躯干长)` 恰好等于传入的 [lateralRatio]，
/// 读测试的人不必反推三角关系。
///
/// 默认值给的是**一帧 45° 斜机位的正常画面**：身高占画面 71%，
/// 四周都有留白，所有必需点可见。每条用例只改它要测的那一项。
PoseFrame bodyFrame({
  double lateralRatio = 0.51,
  double headY = 0.10,
  double shoulderY = 0.20,
  double hipY = 0.30,
  double kneeY = 0.55,
  double ankleY = 0.80,
  double shiftX = 0.0,
  Map<L, double>? invisible,
}) {
  final span = lateralRatio * (hipY - shoulderY);
  final half = span / 2;
  final centre = 0.5 + shiftX;

  (double, double) pair(double y, {double extra = 0}) =>
      (centre - half - extra, y);

  return poseFrameFromPoints(
    frameWidth: _side,
    frameHeight: _side,
    points: {
      L.nose: (centre, headY),
      L.leftEye: (centre - 0.01, headY - 0.01),
      L.rightEye: (centre + 0.01, headY - 0.01),
      L.leftEar: (centre - 0.02, headY),
      L.rightEar: (centre + 0.02, headY),
      L.leftShoulder: pair(shoulderY),
      L.rightShoulder: (centre + half, shoulderY),
      L.leftHip: pair(hipY),
      L.rightHip: (centre + half, hipY),
      L.leftKnee: pair(kneeY),
      L.rightKnee: (centre + half, kneeY),
      L.leftAnkle: pair(ankleY),
      L.rightAnkle: (centre + half, ankleY),
      L.leftHeel: pair(ankleY + 0.01, extra: 0.02),
      L.rightHeel: (centre + half + 0.02, ankleY + 0.01),
      L.leftFootIndex: pair(ankleY + 0.01, extra: -0.02),
      L.rightFootIndex: (centre + half - 0.02, ankleY + 0.01),
    },
    // 其余的点（手肘、手腕、嘴…）堆到头顶上方一点，可见、互不重合，
    // 免得某个几何算子因为「两点重合」被判退化。
    fill: (centre, headY - 0.04),
    visibilityOverrides: invisible,
  );
}

/// 喂 [count] 帧同样的姿态。
void feed(CameraPositionMonitor monitor, PoseFrame frame, [int count = 1]) {
  for (var i = 0; i < count; i++) {
    monitor.add(frame);
  }
}

/// 喂够让机位结论稳定的帧数（默认 15 帧，多给几帧留余量）。
void feedStable(CameraPositionMonitor monitor, PoseFrame frame) =>
    feed(monitor, frame, 20);

bool has(CameraPositionMonitor m, PositionIssueCode code) =>
    m.report.issues.any((i) => i.code == code);

void main() {
  group('机位判别', () {
    test('45° 斜机位放行，且没有拦住的项', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.51));

      expect(monitor.report.view, CameraView.oblique45);
      expect(monitor.report.blocking, isFalse);
      expect(monitor.report.canStart, isTrue);
    });

    test('正对镜头被拦住，并说明「计数会一直是 0」', () {
      // 这是本文件存在的首要理由：正视下膝角投影几乎不变，
      // 状态机永远停在 STANDING，而**不报任何错**。
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.72));

      expect(monitor.report.view, CameraView.frontal);
      expect(has(monitor, PositionIssueCode.facingFront), isTrue);
      expect(monitor.report.blocking, isTrue);
      expect(monitor.report.canStart, isFalse);
      // 文案要说清后果，否则用户只会觉得「凭什么不让我开始」。
      expect(
        monitor.report.issues
            .firstWhere((i) => i.code == PositionIssueCode.facingFront)
            .message,
        contains('0'),
      );
    });

    test('完全侧对镜头只提示、不拦 —— 它仍然数得出来', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.10));

      expect(monitor.report.view, CameraView.sagittal);
      expect(has(monitor, PositionIssueCode.facingSide), isTrue);
      expect(monitor.report.blocking, isFalse);
    });

    test('样本不足时不拿机位拦人，只说还在判断', () {
      final monitor = CameraPositionMonitor();
      feed(monitor, bodyFrame(lateralRatio: 0.72), 5); // 稳定需要 15 帧

      expect(monitor.report.view, isNull);
      expect(monitor.report.viewStable, isFalse);
      expect(has(monitor, PositionIssueCode.viewUnstable), isTrue);
      expect(monitor.report.blocking, isFalse);
    });

    test('单帧飘走不改变结论 —— 取中位数而不是均值', () {
      // ML Kit 在遮挡恢复的瞬间会甩出一帧离谱的坐标。均值会被它拽走，
      // 中位数不会。这正是「偶尔错一次」和「一直错」的区别。
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.51));
      monitor.add(bodyFrame(lateralRatio: 0.05));

      expect(monitor.report.view, CameraView.oblique45);
      expect(monitor.report.blocking, isFalse);
    });

    test('分类门槛落在 0.62 / 0.30 上（都是闭区间下界）', () {
      // 把 stableFrames 压到 1，好让单帧就能读出结论 —— 这里测的是分类边界，
      // 不是稳定性，而稳定性另有专门的用例。
      CameraView? classify(double ratio) => (CameraPositionMonitor(stableFrames: 1)
            ..add(bodyFrame(lateralRatio: ratio)))
          .report
          .view;

      expect(classify(0.72), CameraView.frontal);
      expect(classify(0.62), CameraView.frontal, reason: '下界闭合，0.62 算正视');
      expect(classify(0.61), CameraView.oblique45);
      expect(classify(0.30), CameraView.oblique45, reason: '下界闭合，0.30 算斜向');
      expect(classify(0.29), CameraView.sagittal);
    });

    test('远近不改变机位判别 —— 两个判据必须互不干扰', () {
      // 侧向比的分子分母都是像素距离，人走近走远时它们等比缩放。
      // 若哪天有人把分母换成画面尺寸（一个不随人缩放的量），
      // 这条会立刻红：那时「离得远」会被误判成「侧对镜头」。
      double ratioAt(double height) {
        const head = 0.08;
        final scale = height / 0.72;
        final frame = bodyFrame(
          headY: head,
          shoulderY: head + 0.10 * scale,
          hipY: head + 0.20 * scale,
          kneeY: head + 0.45 * scale,
          ankleY: head + 0.70 * scale,
        );
        return (CameraPositionMonitor()..add(frame)).report.lateralRatio!;
      }

      expect(ratioAt(0.50), closeTo(ratioAt(0.72), 1e-6));
      expect(ratioAt(0.90), closeTo(ratioAt(0.72), 1e-6));
    });

    test('肩膀髋部看不见时不判机位 —— 不许拿外推坐标凑一个结论', () {
      // 2026-10-04 真机截图抓到的：人正对着镜头、肩膀根本不在画面里，
      // 而 `torsoLength()` / `pixelSpan()` 都不检查可见性，ML Kit 对出画的点
      // 照样给外推坐标 —— 于是算出一个落在 45° 区间里的假比值，
      // 清单上「站成 45°」那一行是绿色对勾。
      //
      // 这一条比「判错」更坏：判错会被别的行挡住，而它让人照着一个凭空的
      // 结论站好，然后做出零个计数。
      final monitor = CameraPositionMonitor();
      feedStable(
        monitor,
        bodyFrame(
          lateralRatio: 0.51,
          invisible: {
            L.leftShoulder: 0.1,
            L.rightShoulder: 0.1,
            L.leftHip: 0.1,
            L.rightHip: 0.1,
          },
        ),
      );

      expect(monitor.report.view, isNull);
      expect(monitor.report.lateralRatio, isNull);
      expect(has(monitor, PositionIssueCode.viewUnstable), isTrue);
      // 说「量不出角度」时要指向那条真正要改的提示，而不是让人站着不动。
      expect(
        monitor.report.issues
            .firstWhere((i) => i.code == PositionIssueCode.viewUnstable)
            .message,
        contains('上身'),
      );
      expect(has(monitor, PositionIssueCode.missingTorso), isTrue);
      expect(monitor.report.canStart, isFalse);
    });

    test('人退出画面后旧结论会过期，不会一直绿着', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.51));
      expect(monitor.report.view, CameraView.oblique45);

      // 再喂满一整个窗口的「量不出躯干」。旧样本必须逐帧退出，
      // 而不是因为「没有再写进去」就原地冻结。
      feed(
        monitor,
        bodyFrame(
          lateralRatio: 0.51,
          invisible: {
            L.leftShoulder: 0.1,
            L.rightShoulder: 0.1,
            L.leftHip: 0.1,
            L.rightHip: 0.1,
          },
        ),
        30,
      );

      expect(monitor.report.view, isNull);
      expect(monitor.report.lateralRatio, isNull);
    });
  });

  group('必需点缺失', () {
    test('左脚不可见会被拦住 —— 脚跟离地判定依赖它', () {
      final monitor = CameraPositionMonitor();
      feedStable(
        monitor,
        bodyFrame(invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1}),
      );

      expect(has(monitor, PositionIssueCode.missingLeftFoot), isTrue);
      expect(monitor.report.blocking, isTrue);
    });

    test('膝盖不可见按「腿」报，而不是笼统地说「身体」', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(invisible: {L.rightKnee: 0.1}));

      expect(has(monitor, PositionIssueCode.missingLegs), isTrue);
      expect(has(monitor, PositionIssueCode.missingTorso), isFalse);
    });

    test('肩膀不可见按「躯干」报', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(invisible: {L.leftShoulder: 0.1}));

      expect(has(monitor, PositionIssueCode.missingTorso), isTrue);
    });

    test('偶尔掉一帧不拦 —— 门禁神经质的代价是用户学会无视它', () {
      final monitor = CameraPositionMonitor();
      feed(monitor, bodyFrame(), 20);
      monitor.add(bodyFrame(invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1}));
      feed(monitor, bodyFrame(), 5);

      expect(has(monitor, PositionIssueCode.missingLeftFoot), isFalse);
      expect(monitor.report.blocking, isFalse);
    });

    test('持续缺失超过窗口一半就拦', () {
      final monitor = CameraPositionMonitor();
      feed(monitor, bodyFrame(), 10);
      feed(
        monitor,
        bodyFrame(invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1}),
        20,
      );

      expect(has(monitor, PositionIssueCode.missingLeftFoot), isTrue);
    });

    test('跑得久了不会变得更难发现问题（累计计数的那个坑）', () {
      // 曾经把缺失计数写成累计的，配上「超过样本数一半」的判据，
      // 结果跑得越久门槛越高 —— 方向正好反了。这一条钉住它不再回来。
      final monitor = CameraPositionMonitor();
      for (var i = 0; i < 30; i++) {
        feed(monitor, bodyFrame(), 10);
        feed(
          monitor,
          bodyFrame(invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1}),
          20,
        );
        expect(
          has(monitor, PositionIssueCode.missingLeftFoot),
          isTrue,
          reason: '第 ${i + 1} 轮就该发现问题，而不是越跑越钝',
        );
      }
    });

    test('头部没入镜只提示，不拦 —— 没有任何深蹲特征依赖头部', () {
      final monitor = CameraPositionMonitor();
      feedStable(
        monitor,
        bodyFrame(invisible: {
          L.nose: 0.1,
          L.leftEye: 0.1,
          L.rightEye: 0.1,
          L.leftEar: 0.1,
          L.rightEar: 0.1,
        }),
      );

      expect(has(monitor, PositionIssueCode.headNotVisible), isTrue);
      expect(
        monitor.report.issues
            .firstWhere((i) => i.code == PositionIssueCode.headNotVisible)
            .blocking,
        isFalse,
      );
      expect(monitor.report.blocking, isFalse);
    });
  });

  group('距离与出画', () {
    PoseFrame atHeight(double height) {
      // 头顶固定在 0.08，脚按身高往下推。
      const head = 0.08;
      final scale = height / 0.72; // 默认那帧的身高是 0.71~0.72
      return bodyFrame(
        headY: head,
        shoulderY: head + 0.10 * 1.0 * scale,
        hipY: head + 0.20 * scale,
        kneeY: head + 0.45 * scale,
        ankleY: head + 0.70 * scale,
      );
    }

    test('离得太远被拦住', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, atHeight(0.40));

      expect(has(monitor, PositionIssueCode.tooFar), isTrue);
      expect(monitor.report.blocking, isTrue);
    });

    test('离得太近被拦住', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, atHeight(0.98));

      expect(has(monitor, PositionIssueCode.tooClose), isTrue);
      expect(monitor.report.bodyHeightRatio, greaterThan(0.95));
      expect(monitor.report.blocking, isTrue);
    });

    test('归一化画幅里「太近」和「出画」必然同时发生，这不是缺陷', () {
      // 记一笔免得后人当 bug 修：画面是满幅的，身高超过 95% 时脚必然越过
      // 下边缘 —— 两个判据在物理上就不可分。分开报是为了让文案能对症
      //（「后退一些」比「身体被裁掉了」更直接），而不是因为它们是两件事。
      final monitor = CameraPositionMonitor();
      feedStable(monitor, atHeight(0.98));

      expect(has(monitor, PositionIssueCode.tooClose), isTrue);
      expect(has(monitor, PositionIssueCode.cropped), isTrue);
    });

    test('正常距离两项都不报', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, atHeight(0.72));

      expect(has(monitor, PositionIssueCode.tooFar), isFalse);
      expect(has(monitor, PositionIssueCode.tooClose), isFalse);
      expect(monitor.report.bodyHeightRatio, closeTo(0.72, 0.05));
    });

    test('身体贴到画面右边被判定为出画', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(shiftX: 0.5));

      expect(has(monitor, PositionIssueCode.cropped), isTrue);
      expect(monitor.report.blocking, isTrue);
    });
  });

  group('窗口管理', () {
    test('人离开画面就清空，不留上一轮的结论', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.72));
      expect(monitor.report.view, CameraView.frontal);

      monitor.add(null);

      expect(monitor.report.sampleCount, 0);
      expect(monitor.report.view, isNull);
      expect(monitor.report.canStart, isFalse);
    });

    test('窗口只保留最近 windowSize 帧', () {
      final monitor = CameraPositionMonitor(windowSize: 10);
      feed(monitor, bodyFrame(), 50);

      expect(monitor.report.sampleCount, 10);
    });

    test('reset 之后一切归零', () {
      final monitor = CameraPositionMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.72));
      monitor.reset();

      expect(monitor.report.sampleCount, 0);
      expect(monitor.report.view, isNull);
      expect(monitor.report.issues, isEmpty);
    });
  });

  group('门禁按动作而变（开合跳）', () {
    // 开合跳的机位要求与深蹲、立定跳远**正好相反**：它必须是正面。
    // 这一组测的是「同一个门禁组件能不能同时服务两种相反的要求」。
    //
    // **每一条都同时断言两边。** 只断言开合跳那一侧的话，
    // 「深蹲的行为一个字节都没变」就成了一句没有人验过的话 ——
    // 而那正是这一轮动共享组件时唯一可能的翻车方式：
    // 加了参数却把默认值顺手改掉，深蹲那侧静默地换了一套判据。
    CameraPositionMonitor jjMonitor() => CameraPositionMonitor(
          requiresFrontal: true,
          blockingAdvice: jjFrontalAdvice,
          advisoryAdvice: null,
          requiredLandmarks: jjRequiredLandmarks,
        );

    test('正视：开合跳放行，深蹲被拦 —— 极性真的反了', () {
      final frame = bodyFrame(lateralRatio: 0.72);

      final jj = jjMonitor();
      feedStable(jj, frame);
      final squat = CameraPositionMonitor();
      feedStable(squat, frame);

      expect(jj.report.view, CameraView.frontal);
      expect(jj.report.blocking, isFalse);
      expect(jj.report.canStart, isTrue);

      expect(squat.report.blocking, isTrue);
      expect(has(squat, PositionIssueCode.facingFront), isTrue);
    });

    test('45° 与完全侧对都拦 —— 不是「只有侧对才拦」', () {
      // 开合跳要判的两个量都是额状面的，45° 下它们判为机位不匹配、
      // 直接不可用 —— 那是**同一种失效**，只是轻一点。
      // 写成「等于侧视才拦」的话，45° 会一路放行到标定完，
      // 然后在计数阶段做出一个恒为 0 的数字。
      for (final ratio in [0.51, 0.10]) {
        final monitor = jjMonitor();
        feedStable(monitor, bodyFrame(lateralRatio: ratio));

        expect(monitor.report.view, isNot(CameraView.frontal));
        expect(
          has(monitor, PositionIssueCode.notFacingFront),
          isTrue,
          reason: '横向比 $ratio 也该被拦住',
        );
        expect(monitor.report.canStart, isFalse);
      }
    });

    test('拦人时说的是开合跳自己的话，不是深蹲那句', () {
      // 这一条抓的是「只翻比较、不动文案」那种改法：
      // 结构上全部正确，而开合跳用户会看到「请侧身 45°」——
      // 正好是叫他做一个会让这个动作失效的动作。
      final monitor = jjMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.51));

      final message = monitor.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.notFacingFront)
          .message;
      expect(message, jjFrontalAdvice);
      expect(message, isNot(squatFrontalAdvice));
      expect(
        message,
        isNot(contains('请侧身')),
        reason: '开合跳的文案里不该出现「请侧身」',
      );
    });

    test('左脚出画不拦开合跳 —— 它不判脚跟离地', () {
      final frame = bodyFrame(
        lateralRatio: 0.72,
        invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1},
      );

      final jj = jjMonitor();
      feedStable(jj, frame);

      expect(
        has(jj, PositionIssueCode.missingLeftFoot),
        isFalse,
        reason: '左脚跟不在开合跳的必需点里',
      );
      expect(jj.report.blocking, isFalse);
      expect(jj.report.canStart, isTrue);
    });

    test('同一帧，深蹲照样为左脚出画拦人（上一条的对照）', () {
      // 两份断言必须成对存在。只写开合跳那一侧的话，
      // 「左脚本就没人拦」这个改坏了的版本也能通过。
      final monitor = CameraPositionMonitor();
      feedStable(
        monitor,
        bodyFrame(
          lateralRatio: 0.51,
          invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1},
        ),
      );

      expect(has(monitor, PositionIssueCode.missingLeftFoot), isTrue);
      expect(monitor.report.blocking, isTrue);
    });

    test('必需点名单覆盖开合跳全部判定的依赖（名单不许手写）', () {
      // 这条把「名单是从特征定义推出来的」变成可执行的：哪天给开合跳
      // 加一条用新关键点的判定、却没往名单里补那个点，门禁会放行一局
      // 算不出那条判定的动作，且不报任何错。
      //
      // 只查这三条 —— 标定用的 `knee_angle_*` / `trunk_lean` 是它们的子集，
      // 不必重复一遍。
      for (final code in const [
        'leg_spread_ratio',
        'shoulder_angle_min',
        'frontal_knee_angle_max',
      ]) {
        final spec = featureSpecsByCode[code]!;
        for (final landmark in spec.requires) {
          expect(
            jjRequiredLandmarks,
            contains(landmark),
            reason: '$code 依赖 $landmark，名单里却没有它',
          );
        }
      }
    });

    test('肘出画不拦 —— 缺失判据只认那三组，这是今天的边界', () {
      // **这不是「应该如此」，是「今天如此」，写下来免得下一个人假设它拦。**
      //
      // `_recordMissing` 按 `requiredLandmarks` 全量记账，但**报告那一小段
      // 只认深蹲那三组**（躯干 / 腿 / 左脚），所以名单里超出这三组的点
      // （开合跳的双肘）今天不会产生任何一条 blocking。
      // 兜住它的是决策层：`pose_quality.coverage_ok_ratio` 按**同一份名单**
      // 算覆盖率（见 `PoseQualityTracker.requiredLandmarks`），
      // 肘长看不见时那一局的覆盖率会掉下去。
      //
      // 哪天门禁学会报通用缺失点，这条会红 —— 那时把它改成断言拦住，
      // 而不是删掉它。
      final monitor = jjMonitor();
      feedStable(
        monitor,
        bodyFrame(lateralRatio: 0.72, invisible: {L.rightElbow: 0.1}),
      );

      expect(jjRequiredLandmarks, contains(L.rightElbow), reason: '名单里是有它的');
      expect(monitor.report.blocking, isFalse);
      expect(monitor.report.canStart, isTrue);
    });

    test('站对了就不说话 —— 开合跳没有提示级的站位偏差', () {
      // 中间没有第三种结论：要么站对、要么拦住。
      // 若哪天有人给开合跳塞了一句 `advisoryAdvice`，正视时就会凭空多一条提示，
      // 而门禁的提示是「照着改」的意思 —— 一条站对了才出现的提示只会让人乱动。
      final monitor = jjMonitor();
      feedStable(monitor, bodyFrame(lateralRatio: 0.72));

      expect(monitor.report.issues, isEmpty);
      expect(monitor.report.viewStable, isTrue);
    });
  });

  group('结论的排序与可读性', () {
    test('拦住的问题排在提示前面', () {
      final monitor = CameraPositionMonitor();
      // 正对镜头（拦）+ 头部没入镜（提示），两个同时存在。
      feedStable(
        monitor,
        bodyFrame(
          lateralRatio: 0.72,
          invisible: {
            L.nose: 0.1,
            L.leftEye: 0.1,
            L.rightEye: 0.1,
            L.leftEar: 0.1,
            L.rightEar: 0.1,
          },
        ),
      );

      final report = monitor.report;
      expect(report.issues.length, greaterThanOrEqualTo(2));
      expect(report.primaryIssue!.blocking, isTrue);
      expect(report.primaryIssue!.code, PositionIssueCode.facingFront);
      expect(report.blockingIssues.length, 1);
    });

    test('每条文案都说「怎么改」，不只是「哪里不对」', () {
      final monitor = CameraPositionMonitor();
      feedStable(
        monitor,
        bodyFrame(
          lateralRatio: 0.72,
          invisible: {L.leftHeel: 0.1, L.leftFootIndex: 0.1},
        ),
      );

      for (final issue in monitor.report.issues) {
        expect(
          issue.message.length,
          greaterThan(8),
          reason: '${issue.code} 的文案太短，大概只说了「哪里不对」',
        );
      }
    });
  });

  group('表观尺寸与方向无关（横屏的回归网）', () {
    // 门禁判「离得远不远」量的是**身体包围盒在画面上占的最大边长**。
    //
    // 这一组盯的是它的两条性质，缺一条横屏上都会出事：
    //
    // 1. **站着的人取到的是身高。** 竖屏的既有两个动作（深蹲、立定跳远）
    //    靠这一条保持逐字不变。
    // 2. **横躺着的人取到的是宽度。** 这正是旧实现里 `isLyingDown` 那个开关
    //    当初想解决的问题 —— 现在判据自己会挑长轴，调用方不必声明姿势
    //   （也做不到：门禁这一层拿不到「用户现在是什么姿势」）。
    //
    // 第二条对横屏是**必需**的：横屏的转正图是宽 > 高，只按高度占比的话，
    // 横躺着的人会偏小、站着的人会偏大，两种误报都指向一个并不存在的距离问题。

    test('站着的人：取的是身高，不是宽度', () {
      // 阈值卡在两者之间（宽度约 9%，身高约 71%）。实现若改成取宽度，
      // 这个人会被判成「离得远」—— 那会是竖屏既有动作的回归。
      final monitor = CameraPositionMonitor(tooFarBelow: 0.30);
      feedStable(monitor, bodyFrame());

      expect(has(monitor, PositionIssueCode.tooFar), isFalse);
      expect(monitor.report.canStart, isTrue);
    });

    test('站着的人：阈值抬到身高之上就报，且说的是「身高」', () {
      final monitor = CameraPositionMonitor(tooFarBelow: 0.80);
      feedStable(monitor, bodyFrame());

      final issue = monitor.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.tooFar);
      expect(issue.blocking, isTrue);
      expect(issue.message, contains('身高'));
    });

    test('横躺着的人：默认就取到宽度，调用方不必声明姿势', () {
      // 旧实现（默认只取身高）在这里会误报「离得有点远（身高只占画面 10%）」，
      // 那正是 `isLyingDown` 那个开关当初存在的全部理由。
      final monitor = CameraPositionMonitor();
      feedStable(monitor, puPose(timestampMs: 0));

      expect(
        monitor.report.bodyHeightRatio,
        lessThan(0.45),
        reason: '趴着时纵向跨度就是身体的厚度 —— 这条前提要成立才有意义',
      );
      expect(has(monitor, PositionIssueCode.tooFar), isFalse);
      expect(monitor.report.canStart, isTrue);
    });

    test('判据仍然开着，只是换了那个数 —— 真的退远了照样拦', () {
      // 「换了跨度」与「关掉这条判据」在标准姿势下**结论相同**，上面那条分不开。
      // 把阈值抬到那个跨度之上，判据就该响 —— 这正是它没被关掉的证据。
      final monitor = CameraPositionMonitor(tooFarBelow: 0.80);
      feedStable(monitor, puPose(timestampMs: 0));

      final issue = monitor.report.issues
          .firstWhere((i) => i.code == PositionIssueCode.tooFar);
      expect(issue.blocking, isTrue);
      expect(
        issue.message,
        isNot(contains('身高')),
        reason: '横躺着的人没有「身高」可量 —— 照抄那句话会把人引去按站着的样子找问题',
      );
      expect(issue.message, contains('身体'));
    });
  });
}
