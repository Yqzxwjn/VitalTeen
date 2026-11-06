///站位门禁，看三件事：机位对不对、人进没进画面、离得合不合适
library;

import 'dart:math' as math;

import '../domain/features.dart';
import '../domain/landmarks.dart';
import '../domain/pose.dart';
import 'action_spec.dart' show squatFrontalAdvice, squatSagittalAdvice;

const List<L> defaultRequiredLandmarks = [
  ...upperTorso,
  ...lowerChain,
  L.leftHeel,
  L.leftFootIndex,
];

const List<L> _headLandmarks = [
  L.nose,
  L.leftEye,
  L.rightEye,
  L.leftEar,
  L.rightEar,
];

enum PositionIssueCode {
  missingTorso,
  missingLegs,
  missingLeftFoot,
  missingFeet,
  headNotVisible,
  tooFar,
  tooClose,
  cropped,
  facingFront,
  notFacingFront,
  facingSide,
  viewUnstable,
}

class PositionIssue {
  const PositionIssue(this.code, this.message, {this.blocking = true});
  final PositionIssueCode code;
  final String message;
  final bool blocking;
}

class PositionReport {
  const PositionReport({
    required this.view,
    required this.viewStable,
    required this.issues,
    this.lateralRatio,
    this.bodyHeightRatio,
    this.sampleCount = 0,
  });
  const PositionReport.empty()
      : view = null,
        viewStable = false,
        issues = const [],
        lateralRatio = null,
        bodyHeightRatio = null,
        sampleCount = 0;
  final CameraView? view;
  final bool viewStable;
  final List<PositionIssue> issues;
  final double? lateralRatio;
  final double? bodyHeightRatio;
  final int sampleCount;
  bool get blocking => issues.any((i) => i.blocking);
  bool get canStart => !blocking && sampleCount > 0;
  PositionIssue? get primaryIssue => issues.isEmpty ? null : issues.first;
  List<PositionIssue> get blockingIssues =>
      issues.where((i) => i.blocking).toList(growable: false);
}

class CameraPositionMonitor {
  CameraPositionMonitor({
    this.windowSize = 30,
    this.stableFrames = 15,
    this.visibilityThreshold = 0.5,
    this.margin = 0.03,
    this.tooFarBelow = 0.45,
    this.tooCloseAbove = 0.95,
    this.frontalRatio = 0.62,
    this.sagittalRatio = 0.30,
    this.requiresFrontal = false,
    this.blockingAdvice = squatFrontalAdvice,
    this.advisoryAdvice = squatSagittalAdvice,
    this.requiredLandmarks = defaultRequiredLandmarks,
  });
  final int windowSize;
  final int stableFrames;
  final double visibilityThreshold;
  final double margin;
  final double tooFarBelow;
  final double tooCloseAbove;
  final bool requiresFrontal;
  final String blockingAdvice;
  final String? advisoryAdvice;
  final List<L> requiredLandmarks;
  final double frontalRatio;
  final double sagittalRatio;
  final List<double> _lateralRatios = [];
  final List<double> _bodyHeights = [];
  final List<double> _bboxLefts = [];
  final List<double> _bboxTops = [];
  final List<double> _bboxRights = [];
  final List<double> _bboxBottoms = [];
  final List<_Observation> _observations = [];
  CameraView? _candidate;
  int _candidateStreak = 0;
  CameraView? _stableView;

  void reset() {
    _lateralRatios.clear();
    _bodyHeights.clear();
    _bboxLefts.clear();
    _bboxTops.clear();
    _bboxRights.clear();
    _bboxBottoms.clear();
    _observations.clear();
    _candidate = null;
    _candidateStreak = 0;
    _stableView = null;
  }

  void add(PoseFrame? frame) {
    if (frame == null) {
      reset();
      return;
    }
    _recordMissing(frame);
    _recordGeometry(frame);
    _updateViewStability();
  }

  void _recordMissing(PoseFrame frame) {
    final missing = <L>[];
    for (final landmark in requiredLandmarks) {
      if (frame.visibility(landmark) < visibilityThreshold) {
        missing.add(landmark);
      }
    }
    final headVisible = _headLandmarks.any(
      (l) => frame.visibility(l) >= visibilityThreshold,
    );
    _observations.add(_Observation(missing, headVisible));
    if (_observations.length > windowSize) _observations.removeAt(0);
  }

  void _recordGeometry(PoseFrame frame) {
    final torso = frame.torsoLength();
    final torsoVisible = upperTorso.every(
      (l) => frame.visibility(l) >= visibilityThreshold,
    );
    if (torso > 1 && torsoVisible) {
      final shoulderSpan = frame.pixelSpan(L.leftShoulder, L.rightShoulder);
      final hipSpan = frame.pixelSpan(L.leftHip, L.rightHip);
      _push(_lateralRatios, (shoulderSpan + hipSpan) / (2 * torso));
    } else if (_lateralRatios.isNotEmpty) {
      _lateralRatios.removeAt(0);
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final landmark in L.values) {
      if (frame.visibility(landmark) < visibilityThreshold) continue;
      final point = frame.pixel(landmark);
      minX = math.min(minX, point.x);
      minY = math.min(minY, point.y);
      maxX = math.max(maxX, point.x);
      maxY = math.max(maxY, point.y);
    }
    if (minX == double.infinity) return;
    final width = frame.frameWidth.toDouble();
    final height = frame.frameHeight.toDouble();
    if (width <= 0 || height <= 0) return;
    _push(_bboxLefts, minX / width);
    _push(_bboxTops, minY / height);
    _push(_bboxRights, maxX / width);
    _push(_bboxBottoms, maxY / height);
    _push(_bodyHeights, (maxY - minY) / height);
  }

  void _push(List<double> buffer, double value) {
    buffer.add(value);
    if (buffer.length > windowSize) buffer.removeAt(0);
  }

  void _updateViewStability() {
    final ratio = _median(_lateralRatios);
    if (ratio == null) {
      _candidate = null;
      _candidateStreak = 0;
      _stableView = null;
      return;
    }
    final classified = _classify(ratio);
    if (classified == _candidate) {
      _candidateStreak++;
    } else {
      _candidate = classified;
      _candidateStreak = 1;
    }
    _stableView =
        _candidateStreak >= stableFrames ? _candidate : null;
  }

  CameraView? _classify(double ratio) {
    if (ratio >= frontalRatio) return CameraView.frontal;
    if (ratio >= sagittalRatio) return CameraView.oblique45;
    return CameraView.sagittal;
  }

  PositionReport get report {
    final frames = _observations.length;
    if (frames == 0) return const PositionReport.empty();
    final issues = <PositionIssue>[];
    final ratio = _median(_lateralRatios);
    final bodyHeight = _median(_bodyHeights);
    final half = frames / 2;
    int missCount(L landmark) => _observations
        .where((o) => o.missing.contains(landmark))
        .length;
    bool mostlyMissing(Iterable<L> group) =>
        group.any((l) => missCount(l) > half);
    if (mostlyMissing(upperTorso)) {
      issues.add(const PositionIssue(
        PositionIssueCode.missingTorso,
        '肩膀或髋部没有完整入镜。请后退半步，让上半身整个进画面。',
      ));
    }
    if (mostlyMissing(lowerChain)) {
      issues.add(const PositionIssue(
        PositionIssueCode.missingLegs,
        '膝盖或脚踝没有完整入镜。请后退半步，让双腿整个进画面。',
      ));
    }
    if (requiredLandmarks.contains(L.leftHeel) &&
        mostlyMissing(const [L.leftHeel, L.leftFootIndex])) {
      issues.add(const PositionIssue(
        PositionIssueCode.missingLeftFoot,
        '左脚没有完整入镜，脚跟离地判定做不了。请后退半步，或换个角度让左脚也进画面。',
      ));
    }
    if (!requiredLandmarks.contains(L.leftHeel) &&
        requiredLandmarks.contains(L.leftFootIndex) &&
        mostlyMissing(const [L.leftFootIndex, L.rightFootIndex])) {
      issues.add(const PositionIssue(
        PositionIssueCode.missingFeet,
        '脚尖没有完整入镜，判断你有没有离地就做不了，这一组会一次都数不上。'
        '请后退半步，让两只脚都整个进画面。',
      ));
    }
    final headSeen = _observations.where((o) => o.headVisible).length;
    if (headSeen <= half) {
      issues.add(const PositionIssue(
        PositionIssueCode.headNotVisible,
        '头部没进画面，可能是离得太近。',
        blocking: false,
      ));
    }
    final left = _median(_bboxLefts);
    final top = _median(_bboxTops);
    final right = _median(_bboxRights);
    final bottom = _median(_bboxBottoms);
    // 取两个跨度里大的那个：与画面方向无关
    double? apparentSize;
    var what = '身高';
    if (bodyHeight != null && left != null && right != null) {
      final width = right - left;
      if (width > bodyHeight) {
        apparentSize = width;
        what = '身体';
      } else {
        apparentSize = bodyHeight;
      }
    }
    if (apparentSize != null) {
      if (apparentSize < tooFarBelow) {
        issues.add(PositionIssue(
          PositionIssueCode.tooFar,
          '离得有点远（$what只占画面 ${(apparentSize * 100).round()}%）。'
          '请靠近一些，或把手机放低一点。',
        ));
      } else if (apparentSize > tooCloseAbove) {
        issues.add(PositionIssue(
          PositionIssueCode.tooClose,
          '离得太近（$what占了画面 ${(apparentSize * 100).round()}%）。请后退一些。',
        ));
      }
    }
    if (bodyHeight != null &&
        left != null &&
        top != null &&
        right != null &&
        bottom != null) {
      if (left < margin ||
          top < margin ||
          right > 1 - margin ||
          bottom > 1 - margin) {
        issues.add(const PositionIssue(
          PositionIssueCode.cropped,
          '身体贴到画面边上了，有一部分被裁掉。请后退半步，让整个人落在画面中间。',
        ));
      }
    }
    final stable = _stableView;
    if (mostlyMissing(upperTorso)) {
      issues.add(const PositionIssue(
        PositionIssueCode.viewUnstable,
        '肩膀和髋部不在画面里，量不出站位角度。请先按上面那条把整个上身放进来。',
        blocking: false,
      ));
    } else if (stable == null) {
      issues.add(const PositionIssue(
        PositionIssueCode.viewUnstable,
        '正在判断你的站位，请保持不动一两秒。',
        blocking: false,
      ));
    } else if (requiresFrontal) {
      if (stable != CameraView.frontal) {
        issues.add(PositionIssue(
          PositionIssueCode.notFacingFront,
          blockingAdvice,
        ));
      }
    } else if (stable == CameraView.frontal) {
      issues.add(PositionIssue(PositionIssueCode.facingFront, blockingAdvice));
    } else if (stable == CameraView.sagittal) {
      final advice = advisoryAdvice;
      if (advice != null) {
        issues.add(PositionIssue(
          PositionIssueCode.facingSide,
          advice,
          blocking: false,
        ));
      }
    }
    issues.sort((a, b) => (a.blocking == b.blocking) ? 0 : (a.blocking ? -1 : 1));
    return PositionReport(
      view: _stableView,
      viewStable: _stableView != null,
      issues: issues,
      lateralRatio: ratio,
      bodyHeightRatio: bodyHeight,
      sampleCount: frames,
    );
  }
}

class _Observation {
  const _Observation(this.missing, this.headVisible);
  final List<L> missing;
  final bool headVisible;
}

double? _median(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = List<double>.of(values)..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}
