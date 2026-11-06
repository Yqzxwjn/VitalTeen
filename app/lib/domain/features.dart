//特征提取：一帧姿态 → 一组带元信息的量
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'landmarks.dart';
import 'pose.dart';

enum CameraView {
  frontal,
  sagittal,
  oblique45,
}

class FeatureValue {
  const FeatureValue({
    required this.code,
    required this.value,
    required this.unit,
    required this.coordSpace,
    this.invalidReason,
  });
  const FeatureValue.unavailable({
    required this.code,
    required this.unit,
    required this.coordSpace,
    required String reason,
  })  : value = null,
        invalidReason = reason;
  final String code;
  final double? value;
  final String unit;
  final String coordSpace;
  final String? invalidReason;
  bool get valid => value != null;
  @override
  String toString() =>
      'FeatureValue($code, ${value ?? "null"} $unit${valid ? "" : " [$invalidReason]"})';
}

class FrameFeatures {
  const FrameFeatures({required this.timestampMs, required this.values});
  final int timestampMs;
  final Map<String, FeatureValue> values;
  double? get(String code) => values[code]?.value;
  bool isValid(String code) => values[code]?.valid ?? false;
  Map<String, double?> asSignals() =>
      values.map((code, fv) => MapEntry(code, fv.value));
}

class FeatureSpec {
  const FeatureSpec({
    required this.code,
    required this.unit,
    required this.coordSpace,
    required this.requires,
    required this.compute,
    this.views = const [],
  });
  final String code;
  final String unit;
  final String coordSpace;
  final List<L> requires;
  final double Function(PoseFrame frame) compute;
  final List<CameraView> views;
}

const double _eps = 1e-9;

double Function(PoseFrame) _jointAngleFn(L a, L vertex, L c) =>
    (f) => angle3(f.pixel(a), f.pixel(vertex), f.pixel(c));

double Function(PoseFrame) _tiltHorizontalFn(L a, L b) =>
    (f) => tiltFromHorizontal(f.pixel(a), f.pixel(b));

double Function(PoseFrame) _heelRiseFn(L heel, L toe) => (f) {
      final pH = f.pixel(heel);
      final pT = f.pixel(toe);
      final footLen = distance(pH, pT);
      if (footLen < _eps) {
        throw const DegenerateGeometryException('足长为 0，无法归一');
      }
      return (pT.y - pH.y) / footLen;
    };

double Function(PoseFrame) _frontalKneeAngleFn(L hip, L knee, L ankle) => (f) {
      final pH = f.pixel(hip);
      final pK = f.pixel(knee);
      final pA = f.pixel(ankle);
      final v1 = (pK.x - pH.x, pK.y - pH.y);
      final v2 = (pA.x - pK.x, pA.y - pK.y);
      final n1 = math.sqrt(v1.$1 * v1.$1 + v1.$2 * v1.$2);
      final n2 = math.sqrt(v2.$1 * v2.$1 + v2.$2 * v2.$2);
      if (n1 < _eps || n2 < _eps) {
        throw const DegenerateGeometryException('额状面膝角的向量长度为 0');
      }
      final cos =
          ((v1.$1 * v2.$1 + v1.$2 * v2.$2) / (n1 * n2)).clamp(-1.0, 1.0);
      return math.acos(cos) * 180.0 / math.pi;
    };

double Function(PoseFrame) _frontalKneeOffsetFn(L hip, L knee, L ankle) =>
    (f) {
      final kneeLen = f.pixelSpan(hip, knee);
      if (kneeLen < _eps) {
        throw const DegenerateGeometryException('大腿长为 0，无法归一');
      }
      return signedOffset(f.pixel(knee), f.pixel(hip), f.pixel(ankle)) /
          kneeLen;
    };

double _trunkLeanFn(PoseFrame f) => tiltFromVertical(
      f.pixelMid(L.leftHip, L.rightHip),
      f.pixelMid(L.leftShoulder, L.rightShoulder),
    );

double _bodyLineFn(PoseFrame f) => angle3(
      f.pixelMid(L.leftShoulder, L.rightShoulder),
      f.pixelMid(L.leftHip, L.rightHip),
      f.pixelMid(L.leftAnkle, L.rightAnkle),
    );

double _shoulderHeightFn(PoseFrame f) {
  final pShoulder = f.pixelMid(L.leftShoulder, L.rightShoulder);
  final pAnkle = f.pixelMid(L.leftAnkle, L.rightAnkle);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  return (pAnkle.y - pShoulder.y) / torso;
}

double _footHeightFn(PoseFrame f) {
  final toe = f.pixelMid(L.leftFootIndex, L.rightFootIndex);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  return (f.frameHeight - toe.y) / torso;
}

double _footGapFn(PoseFrame f) {
  final left = f.pixel(L.leftFootIndex);
  final right = f.pixel(L.rightFootIndex);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  return (left.y - right.y).abs() / torso;
}

double _mouthWristDyFn(PoseFrame f) {
  final mouth = f.pixelMid(L.mouthLeft, L.mouthRight);
  final wrist = f.pixelMid(L.leftWrist, L.rightWrist);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  return (mouth.y - wrist.y) / torso;
}

double _hipHeightFn(PoseFrame f) {
  final pHip = f.pixelMid(L.leftHip, L.rightHip);
  final pKnee = f.pixelMid(L.leftKnee, L.rightKnee);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  return (pKnee.y - pHip.y) / torso;
}

double _pelvisOffsetFn(PoseFrame f) {
  final pHip = f.pixelMid(L.leftHip, L.rightHip);
  final pAnkle = f.pixelMid(L.leftAnkle, L.rightAnkle);
  final width = f.shoulderWidth();
  if (width < _eps) {
    throw const DegenerateGeometryException('肩宽为 0，无法归一');
  }
  return (pHip.x - pAnkle.x) / width;
}

double _kneeSymmetryFn(PoseFrame f) => symmetryIndex(
      angle3(f.pixel(L.leftHip), f.pixel(L.leftKnee), f.pixel(L.leftAnkle)),
      angle3(f.pixel(L.rightHip), f.pixel(L.rightKnee), f.pixel(L.rightAnkle)),
    );

double _frontalKneeMaxFn(PoseFrame f) {
  final angles = <double>[];
  const pairs = [
    (L.leftHip, L.leftKnee, L.leftAnkle),
    (L.rightHip, L.rightKnee, L.rightAnkle),
  ];
  for (final (hip, knee, ankle) in pairs) {
    try {
      angles.add(_frontalKneeAngleFn(hip, knee, ankle)(f));
    } on DegenerateGeometryException {
      continue;
    }
  }
  if (angles.isEmpty) {
    throw const DegenerateGeometryException('两侧额状面膝角均不可计算');
  }
  return angles.reduce(math.max);
}

const Map<String, Map<String, L>> _sides = {
  'L': {
    'hip': L.leftHip,
    'knee': L.leftKnee,
    'ankle': L.leftAnkle,
    'heel': L.leftHeel,
    'toe': L.leftFootIndex,
    'shoulder': L.leftShoulder,
    'elbow': L.leftElbow,
    'wrist': L.leftWrist,
  },
  'R': {
    'hip': L.rightHip,
    'knee': L.rightKnee,
    'ankle': L.rightAnkle,
    'heel': L.rightHeel,
    'toe': L.rightFootIndex,
    'shoulder': L.rightShoulder,
    'elbow': L.rightElbow,
    'wrist': L.rightWrist,
  },
};

List<FeatureSpec> _sideSpecs() {
  final out = <FeatureSpec>[];
  for (final entry in _sides.entries) {
    final side = entry.key;
    final p = entry.value;
    out.addAll([
      FeatureSpec(
        code: 'knee_angle_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['hip']!, p['knee']!, p['ankle']!],
        compute: _jointAngleFn(p['hip']!, p['knee']!, p['ankle']!),
      ),
      FeatureSpec(
        code: 'hip_angle_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['shoulder']!, p['hip']!, p['knee']!],
        compute: _jointAngleFn(p['shoulder']!, p['hip']!, p['knee']!),
      ),
      FeatureSpec(
        code: 'elbow_angle_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['shoulder']!, p['elbow']!, p['wrist']!],
        compute: _jointAngleFn(p['shoulder']!, p['elbow']!, p['wrist']!),
      ),
      FeatureSpec(
        code: 'shoulder_angle_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['hip']!, p['shoulder']!, p['elbow']!],
        compute: _jointAngleFn(p['hip']!, p['shoulder']!, p['elbow']!),
      ),
      FeatureSpec(
        code: 'thigh_tilt_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['hip']!, p['knee']!],
        compute: _tiltHorizontalFn(p['hip']!, p['knee']!),
      ),
      FeatureSpec(
        code: 'frontal_knee_angle_$side',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [p['hip']!, p['knee']!, p['ankle']!],
        compute: _frontalKneeAngleFn(p['hip']!, p['knee']!, p['ankle']!),
        views: const [CameraView.frontal],
      ),
      FeatureSpec(
        code: 'frontal_knee_offset_$side',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [p['hip']!, p['knee']!, p['ankle']!],
        compute: _frontalKneeOffsetFn(p['hip']!, p['knee']!, p['ankle']!),
        views: const [CameraView.frontal],
      ),
      FeatureSpec(
        code: 'heel_rise_ratio_$side',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [p['heel']!, p['toe']!, p['ankle']!],
        compute: _heelRiseFn(p['heel']!, p['toe']!),
        views: const [CameraView.sagittal, CameraView.oblique45],
      ),
    ]);
  }
  return out;
}

List<FeatureSpec> _buildSpecs() => [
      ..._sideSpecs(),
      const FeatureSpec(
        code: 'trunk_lean',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: upperTorso,
        compute: _trunkLeanFn,
      ),
      const FeatureSpec(
        code: 'body_line_angle',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [
          ...upperTorso,
          L.leftAnkle,
          L.rightAnkle,
        ],
        compute: _bodyLineFn,
        views: [CameraView.sagittal, CameraView.oblique45],
      ),
      const FeatureSpec(
        code: 'hip_height_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [...upperTorso, L.leftKnee, L.rightKnee],
        compute: _hipHeightFn,
      ),
      const FeatureSpec(
        code: 'pelvis_offset_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [...lowerChain, L.leftShoulder, L.rightShoulder],
        compute: _pelvisOffsetFn,
        views: [CameraView.frontal],
      ),
      const FeatureSpec(
        code: 'knee_symmetry',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: lowerChain,
        compute: _kneeSymmetryFn,
      ),
      const FeatureSpec(
        code: 'frontal_knee_angle_max',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [
          L.leftHip,
          L.rightHip,
          L.leftKnee,
          L.rightKnee,
          L.leftAnkle,
          L.rightAnkle,
        ],
        compute: _frontalKneeMaxFn,
        views: [CameraView.frontal],
      ),
      FeatureSpec(
        code: 'torso_length_px',
        unit: 'px',
        coordSpace: 'pixel',
        requires: upperTorso,
        compute: (f) => f.torsoLength(),
      ),
      const FeatureSpec(
        code: 'shoulder_width_px',
        unit: 'px',
        coordSpace: 'pixel',
        requires: [L.leftShoulder, L.rightShoulder],
        compute: _shoulderWidthFn,
      ),
      const FeatureSpec(
        code: 'leg_spread_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [L.leftAnkle, L.rightAnkle, L.leftShoulder, L.rightShoulder],
        compute: _legSpreadFn,
        views: [CameraView.frontal],
      ),
      const FeatureSpec(
        code: 'shoulder_angle_min',
        unit: 'deg',
        coordSpace: 'pixel',
        requires: [
          L.leftHip,
          L.rightHip,
          L.leftShoulder,
          L.rightShoulder,
          L.leftElbow,
          L.rightElbow,
        ],
        compute: _shoulderAngleMinFn,
      ),
      const FeatureSpec(
        code: 'body_line_offset_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [
          L.leftShoulder,
          L.rightShoulder,
          L.leftHip,
          L.rightHip,
          L.leftAnkle,
          L.rightAnkle,
        ],
        compute: _bodyLineOffsetFn,
        views: [CameraView.sagittal, CameraView.oblique45],
      ),
      const FeatureSpec(
        code: 'shoulder_height_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [
          L.leftShoulder,
          L.rightShoulder,
          L.leftHip,
          L.rightHip,
          L.leftAnkle,
          L.rightAnkle,
        ],
        compute: _shoulderHeightFn,
        views: [CameraView.sagittal, CameraView.oblique45],
      ),
      const FeatureSpec(
        code: 'foot_height_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [
          ...upperTorso,
          L.leftFootIndex,
          L.rightFootIndex,
        ],
        compute: _footHeightFn,
        views: [CameraView.sagittal, CameraView.oblique45],
      ),
      const FeatureSpec(
        code: 'foot_gap_ratio',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [
          ...upperTorso,
          L.leftFootIndex,
          L.rightFootIndex,
        ],
        compute: _footGapFn,
        views: [CameraView.sagittal, CameraView.oblique45],
      ),
      const FeatureSpec(
        code: 'mouth_wrist_dy',
        unit: 'ratio',
        coordSpace: 'dimensionless',
        requires: [
          ...upperTorso,
          L.mouthLeft,
          L.mouthRight,
          L.leftWrist,
          L.rightWrist,
        ],
        compute: _mouthWristDyFn,
      ),
    ];

double _shoulderWidthFn(PoseFrame f) => f.shoulderWidth();

double _legSpreadFn(PoseFrame f) {
  final width = f.shoulderWidth();
  if (width < _eps) {
    throw const DegenerateGeometryException('肩宽为 0，无法归一');
  }
  return (f.pixel(L.leftAnkle).x - f.pixel(L.rightAnkle).x).abs() / width;
}

double _shoulderAngleMinFn(PoseFrame f) {
  final left = angle3(
    f.pixel(L.leftHip),
    f.pixel(L.leftShoulder),
    f.pixel(L.leftElbow),
  );
  final right = angle3(
    f.pixel(L.rightHip),
    f.pixel(L.rightShoulder),
    f.pixel(L.rightElbow),
  );
  return math.min(left, right);
}

double _bodyLineOffsetFn(PoseFrame f) {
  final shoulder = f.pixelMid(L.leftShoulder, L.rightShoulder);
  final hip = f.pixelMid(L.leftHip, L.rightHip);
  final ankle = f.pixelMid(L.leftAnkle, L.rightAnkle);
  final torso = f.torsoLength();
  if (torso < _eps) {
    throw const DegenerateGeometryException('躯干长为 0，无法归一');
  }
  final ux = ankle.x - shoulder.x;
  final uy = ankle.y - shoulder.y;
  final len2 = ux * ux + uy * uy;
  if (len2 < _eps) {
    throw const DegenerateGeometryException('肩-踝连线的长度为 0，偏离无定义');
  }
  var t = ((hip.x - shoulder.x) * ux + (hip.y - shoulder.y) * uy) / len2;
  if (t < 0.0) {
    t = 0.0;
  } else if (t > 1.0) {
    t = 1.0;
  }
  return (hip.y - (shoulder.y + t * uy)) / torso;
}

final List<FeatureSpec> featureSpecs = _buildSpecs();

final Map<String, FeatureSpec> featureSpecsByCode = {
  for (final spec in featureSpecs) spec.code: spec,
};

class FeatureExtractor {
  const FeatureExtractor({
    this.visibilityThreshold = 0.5,
    this.cameraView = CameraView.frontal,
  });
  final double visibilityThreshold;
  final CameraView cameraView;

  FrameFeatures extract(PoseFrame frame) {
    final values = <String, FeatureValue>{};
    for (final spec in featureSpecs) {
      values[spec.code] = _one(spec, frame);
    }
    return FrameFeatures(timestampMs: frame.timestampMs, values: values);
  }

  FeatureValue _one(FeatureSpec spec, PoseFrame frame) {
    if (spec.views.isNotEmpty && !spec.views.contains(cameraView)) {
      return FeatureValue.unavailable(
        code: spec.code,
        unit: spec.unit,
        coordSpace: spec.coordSpace,
        reason: 'view_mismatch',
      );
    }
    if (!frame.allVisible(spec.requires, visibilityThreshold)) {
      return FeatureValue.unavailable(
        code: spec.code,
        unit: spec.unit,
        coordSpace: spec.coordSpace,
        reason: 'low_visibility',
      );
    }
    try {
      return FeatureValue(
        code: spec.code,
        value: spec.compute(frame),
        unit: spec.unit,
        coordSpace: spec.coordSpace,
      );
    } on DegenerateGeometryException {
      return FeatureValue.unavailable(
        code: spec.code,
        unit: spec.unit,
        coordSpace: spec.coordSpace,
        reason: 'degenerate',
      );
    }
  }
}
