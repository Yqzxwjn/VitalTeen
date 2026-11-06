//TODO 有个动作还差一条判据没做，要新加一个特征
library;

import '../domain/exercises/base.dart';
import '../domain/exercises/jj.dart';
import '../domain/exercises/plank.dart';
import '../domain/exercises/pu.dart';
import '../domain/exercises/pullup.dart';
import '../domain/exercises/rope.dart';
import '../domain/exercises/sit_reach.dart';
import '../domain/exercises/situp.dart';
import '../domain/exercises/slj.dart';
import '../domain/exercises/squat.dart';
import '../domain/features.dart';
import '../domain/landmarks.dart';

const CameraView productCameraView = CameraView.oblique45;

const Map<String, String> squatHudStateLabels = {
  SquatStates.standing: '站立',
  SquatStates.descent: '下蹲',
  SquatStates.bottom: '最低点',
  SquatStates.ascent: '起身',
};

const Map<String, String> sljHudStateLabels = {
  SljStates.standing: '站立',
  SljStates.prep: '预蹲',
  SljStates.launch: '蹬伸',
  SljStates.flight: '腾空',
  SljStates.land: '落地缓冲',
};

const Map<String, String> jjHudStateLabels = {
  JjStates.closed: '并腿站立',
  JjStates.opening: '起跳',
  JjStates.open: '分腿展臂',
  JjStates.closing: '落地合拢',
};

const Map<String, String> puHudStateLabels = {
  PuStates.top: '支撑',
  PuStates.down: '下放',
  PuStates.bottom: '最低点',
  PuStates.up: '撑起',
};

const Map<String, String> suHudStateLabels = {
  SitupStates.lying: '仰卧',
  SitupStates.rising: '起身',
  SitupStates.seated: '坐起',
  SitupStates.lowering: '躺回',
};

typedef ActionBuilder = ActionDefinition Function(
  Calibration calibration, {
  CameraView cameraView,
});

class ActionSpec {
  const ActionSpec({
    required this.code,
    required this.nameZh,
    required this.cameraView,
    required ActionBuilder build,
    required this.hudStateLabels,
    required this.discardedReason,
    required this.blockingAdvice,
    this.advisoryAdvice,
    this.requiresFrontal = false,
    this.isTimed = false,
    this.requiresLandscape = false,
    this.requiredLandmarks,
    this.calibrationBaselines = BaselineKey.defaultRequired,
    this.framingHint,
  })
      // ignore: prefer_initializing_formals
      : _build = build;
  final String code;
  final String nameZh;
  final CameraView cameraView;
  final ActionBuilder _build;
  final Map<String, String> hudStateLabels;
  final String discardedReason;
  final String blockingAdvice;
  final String? advisoryAdvice;
  final bool requiresFrontal;
  final bool isTimed;
  final bool requiresLandscape;
  final List<L>? requiredLandmarks;
  final Set<BaselineKey> calibrationBaselines;
  final String? framingHint;
  ActionDefinition build(Calibration calibration) =>
      _build(calibration, cameraView: cameraView);
}

const String squatFrontalAdvice =
    '请侧身 45° —— 正对镜头时膝盖的弯曲在画面上看不出来，计数会一直是 0。';
const String squatSagittalAdvice =
    '完全侧对镜头也能计数，但膝内扣判定会不可用。稍微转回来一点更好。';
const String squatDiscardedReason = '幅度不够或太快';

const ActionSpec squatSpec = ActionSpec(
  code: squatActionCode,
  nameZh: squatActionNameZh,
  cameraView: productCameraView,
  build: buildSquat,
  hudStateLabels: squatHudStateLabels,
  discardedReason: squatDiscardedReason,
  blockingAdvice: squatFrontalAdvice,
  advisoryAdvice: squatSagittalAdvice,
);

const ActionSpec sljSpec = ActionSpec(
  code: sljActionCode,
  nameZh: sljActionNameZh,
  cameraView: productCameraView,
  build: buildSlj,
  hudStateLabels: sljHudStateLabels,
  discardedReason: '没跳到落地缓冲，或动作被打断',
  blockingAdvice: '请侧身 45° —— 正对镜头时蹬伸在画面上看不出多少，很可能一次都数不着。',
  advisoryAdvice: '完全侧对镜头也能计数，但「双脚是不是同时起跳」判定会不可用。稍微转回来一点更好。',
  requiresLandscape: true,
  framingHint: '别站在画面正中：往前跳的那一米也要留在画面里，站到偏后一些。',
);

const String jjFrontalAdvice =
    '请正对镜头站好 —— 侧着身子时双腿张开的幅度在画面上量不出来，计数会一直是 0。';

const List<L> jjRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftElbow,
  L.rightElbow,
];

const ActionSpec jjSpec = ActionSpec(
  code: jjActionCode,
  nameZh: jjActionNameZh,
  cameraView: CameraView.frontal,
  build: buildJj,
  hudStateLabels: jjHudStateLabels,
  discardedReason: '腿没张开到位，或中途人出画',
  blockingAdvice: jjFrontalAdvice,
  requiresFrontal: true,
  requiredLandmarks: jjRequiredLandmarks,
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
    BaselineKey.legSpread,
  },
);

const List<L> puRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftElbow,
  L.rightElbow,
  L.leftWrist,
  L.rightWrist,
];

const ActionSpec puSpec = ActionSpec(
  code: puActionCode,
  nameZh: puActionNameZh,
  cameraView: productCameraView,
  build: buildPushUp,
  hudStateLabels: puHudStateLabels,
  discardedReason: '没下到底，或中途人出画',
  blockingAdvice: '请侧身 45° —— 正对镜头时身体有没有塌腰或撅臀量不出来，两条判定会不可用。',
  advisoryAdvice: '完全侧对镜头也能计数，但远侧手臂容易被身体挡住，深度判定会时断时续。稍微转回来一点更好。',
  requiresLandscape: true,
  requiredLandmarks: puRequiredLandmarks,
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  },
);

const List<L> suRequiredLandmarks = [...upperTorso, ...lowerChain];

const ActionSpec suSpec = ActionSpec(
  code: situpActionCode,
  nameZh: situpActionNameZh,
  cameraView: productCameraView,
  build: buildSitUp,
  hudStateLabels: suHudStateLabels,
  discardedReason: '没躺回垫上，或中途人出画',
  blockingAdvice: '请侧身 45° —— 正对镜头时肩比踝高了多少、身体有没有成一条线都量不出来，三条判定里两条会不可用。',
  requiresLandscape: true,
  requiredLandmarks: suRequiredLandmarks,
  framingHint: '先仰卧躺到垫上，让整个身体横着落在画面里 —— 坐起来头顶会往上走，上方留一点余量。',
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  },
);

const Map<String, String> ropeHudStateLabels = {
  RopeStates.ground: '双脚着地',
  RopeStates.air: '腾空',
  RopeStates.cushion: '落地缓冲',
};

const List<L> ropeRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftFootIndex,
  L.rightFootIndex,
];

const ActionSpec ropeSpec = ActionSpec(
  code: ropeActionCode,
  nameZh: ropeActionNameZh,
  cameraView: productCameraView,
  build: buildRope,
  hudStateLabels: ropeHudStateLabels,
  discardedReason: '没跳到腾空，或落地后没站回来',
  blockingAdvice: '请侧身 45° —— 正对镜头时就看不出你脚离没离地，计数会一直是 0。',
  advisoryAdvice: '完全侧对镜头也能计数，但两只脚在画面上会叠在一起，远侧那只常被挡住，「单脚跳」判定会时断时续。稍微转回来一点更好。',
  requiredLandmarks: ropeRequiredLandmarks,
  framingHint: '把手机架稳别动 —— 跳绳要靠画面下缘判断你有没有离地，手机一动这条线就跟着动。标定时先站定在地面上。',
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
    BaselineKey.footHeight,
  },
);

const Map<String, String> pullupHudStateLabels = {
  PullupStates.hang: '直臂悬垂',
  PullupStates.pulling: '上拉',
  PullupStates.top: '顶部',
  PullupStates.lowering: '下放',
};

const List<L> pullupRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftElbow,
  L.rightElbow,
  L.leftWrist,
  L.rightWrist,
  L.mouthLeft,
  L.mouthRight,
];

const ActionSpec pullupSpec = ActionSpec(
  code: pullupActionCode,
  nameZh: pullupActionNameZh,
  cameraView: productCameraView,
  build: buildPullup,
  hudStateLabels: pullupHudStateLabels,
  discardedReason: '没拉到顶，或中途人出画',
  blockingAdvice: '请侧身 45° —— 正对镜头时身体前后摆动在画面上几乎看不出来，摆动借力那条判定会一直不响。',
  advisoryAdvice: '完全侧对镜头也能计数，但远侧手臂容易被身体挡住，手臂伸直的判定会时断时续。稍微转回来一点更好。',
  framingHint: '把手机架到能同时看见横杆和双脚 —— 手看不见就一次都数不上，脚看不见标定过不去。',
  requiredLandmarks: pullupRequiredLandmarks,
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  },
);

const Map<String, String> plankHudStateLabels = {
  PlankStates.holdOk: '撑住',
  PlankStates.holdBreak: '没在撑',
};

const List<L> plankRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftElbow,
  L.rightElbow,
  L.leftWrist,
  L.rightWrist,
];

const ActionSpec plankSpec = ActionSpec(
  code: plankActionCode,
  nameZh: plankActionNameZh,
  cameraView: productCameraView,
  build: buildPlank,
  hudStateLabels: plankHudStateLabels,
  discardedReason: '撑得太久，超过了几分钟',
  blockingAdvice: '请侧身 45° —— 正对镜头时身体有没有放平、成不成一条线都量不出来，计数会一直是 0。',
  advisoryAdvice: '完全侧对镜头也能计数，但远侧手臂容易被身体挡住，肘角偏离判定会时断时续。稍微转回来一点更好。',
  isTimed: true,
  requiresLandscape: true,
  requiredLandmarks: plankRequiredLandmarks,
  framingHint: '先站着把标定走完，再撑下去 —— 撑住时整个人是横的，头和脚都要留在画面里。',
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  },
);

const Map<String, String> sitReachHudStateLabels = {
  SitReachStates.upright: '坐直',
  SitReachStates.reaching: '前伸',
  SitReachStates.holding: '保持',
  SitReachStates.returning: '坐回',
};

const List<L> srtRequiredLandmarks = [...upperTorso, ...lowerChain];

const ActionSpec srtSpec = ActionSpec(
  code: sitReachActionCode,
  nameZh: sitReachActionNameZh,
  cameraView: productCameraView,
  build: buildSitReach,
  hudStateLabels: sitReachHudStateLabels,
  discardedReason: '没伸到底，或中途人出画',
  blockingAdvice: '请侧身 45° —— 正对镜头时上身折了多少读不出来，计数会一直是 0。',
  requiresLandscape: true,
  requiredLandmarks: srtRequiredLandmarks,
  framingHint: '坐到垫上、两腿前伸，让整个身体横着落在画面里 —— 手往前够的时候脚不要出画，头顶也留一点余量。',
  calibrationBaselines: {
    BaselineKey.kneeAngle,
    BaselineKey.trunkLean,
  },
);

const List<ActionSpec> kActionSpecs = [
  squatSpec,
  sljSpec,
  jjSpec,
  puSpec,
  suSpec,
  ropeSpec,
  pullupSpec,
  plankSpec,
  srtSpec,
];

ActionSpec? specForCode(String code) {
  for (final spec in kActionSpecs) {
    if (spec.code == code) return spec;
  }
  return null;
}

String repUnitText(bool isTimed) => isTimed ? '段' : '个';
