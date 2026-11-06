///本组的 pose_quality 五项
library;

import '../domain/landmarks.dart';
import '../domain/pose.dart';
import 'camera_position_check.dart' show defaultRequiredLandmarks;
import 'decision_request.dart';

class PoseQualityTracker {
  PoseQualityTracker({
    this.visibilityThreshold = 0.5,
    this.requiredLandmarks = defaultRequiredLandmarks,
  });
  final List<L> requiredLandmarks;
  final double visibilityThreshold;
  int _frames = 0;
  double _visibilitySum = 0;
  int _coverageOkFrames = 0;
  int _viewStableFrames = 0;
  int _timedFrames = 0;
  int? _firstMs;
  int? _lastMs;
  int _gapMaxMs = 0;

  void add(PoseFrame frame, {required bool viewStable}) {
    _frames++;
    _visibilitySum += _meanVisibility(frame);
    if (_hasAllRequired(frame)) _coverageOkFrames++;
    if (viewStable) _viewStableFrames++;
    final ts = frame.timestampMs;
    if (ts <= 0) return;
    final first = _firstMs;
    if (first == null) {
      _firstMs = ts;
    } else {
      final gap = ts - _lastMs!;
      if (gap > _gapMaxMs) _gapMaxMs = gap;
    }
    _lastMs = ts;
    _timedFrames++;
  }

  void reset() {
    _frames = 0;
    _visibilitySum = 0;
    _coverageOkFrames = 0;
    _viewStableFrames = 0;
    _timedFrames = 0;
    _firstMs = null;
    _lastMs = null;
    _gapMaxMs = 0;
  }

  PoseQuality? get quality {
    final first = _firstMs;
    final last = _lastMs;
    if (_frames < 2 || _timedFrames < 2 || first == null || last == null) {
      return null;
    }
    final elapsedMs = last - first;
    if (elapsedMs <= 0) return null;
    return PoseQuality(
      meanVisibility: _visibilitySum / _frames,
      coverageOkRatio: _coverageOkFrames / _frames,
      fpsMean: (_timedFrames - 1) * 1000.0 / elapsedMs,
      gapMaxMs: _gapMaxMs,
      viewConfidence: _viewStableFrames / _frames,
    );
  }

  static double _meanVisibility(PoseFrame frame) {
    var sum = 0.0;
    for (final landmark in frame.landmarks) {
      sum += landmark.visibility;
    }
    return frame.landmarks.isEmpty ? 0.0 : sum / frame.landmarks.length;
  }

  bool _hasAllRequired(PoseFrame frame) {
    for (final L landmark in requiredLandmarks) {
      if (frame.visibility(landmark) < visibilityThreshold) return false;
    }
    return true;
  }
}
