//TODO 还没接进管线，现在用的还是原始角度
library;

import 'dart:math' as math;

import 'pose.dart';

const double _dtFallbackSeconds = 1e-3;

class MedianFilter {
  MedianFilter({this.window = 3}) {
    if (window < 1) {
      throw ArgumentError('window 必须 >= 1');
    }
    if (window.isEven) {
      throw ArgumentError('window 必须为奇数，否则中位数需插值，意义不明');
    }
  }
  final int window;
  final List<double> _buffer = [];

  double call(double value) {
    _buffer.add(value);
    if (_buffer.length > window) {
      _buffer.removeAt(0);
    }
    final ordered = List<double>.from(_buffer)..sort();
    return ordered[ordered.length ~/ 2];
  }
  void reset() => _buffer.clear();
}

class OneEuroFilter {
  OneEuroFilter({
    this.minCutoff = 1.0,
    this.beta = 0.02,
    this.dCutoff = 1.0,
  }) {
    if (minCutoff <= 0 || dCutoff <= 0) {
      throw ArgumentError('截止频率必须为正');
    }
    if (beta < 0) {
      throw ArgumentError('beta 不能为负');
    }
  }
  final double minCutoff;
  final double beta;
  final double dCutoff;
  double _xPrev = 0.0;
  double _dxPrev = 0.0;
  bool _initialised = false;

  static double _alpha(double cutoff, double dt) {
    final tau = 1.0 / (2.0 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  double call(double x, double dt) {
    final step = dt <= 0 ? _dtFallbackSeconds : dt;
    if (!_initialised) {
      _xPrev = x;
      _dxPrev = 0.0;
      _initialised = true;
      return x;
    }
    final dx = (x - _xPrev) / step;
    final aD = _alpha(dCutoff, step);
    final dxHat = aD * dx + (1.0 - aD) * _dxPrev;
    final cutoff = minCutoff + beta * dxHat.abs();
    final a = _alpha(cutoff, step);
    final xHat = a * x + (1.0 - a) * _xPrev;
    _xPrev = xHat;
    _dxPrev = dxHat;
    return xHat;
  }

  void reset() {
    _xPrev = 0.0;
    _dxPrev = 0.0;
    _initialised = false;
  }
}

class LandmarkSmoother {
  LandmarkSmoother({
    this.medianWindow = 3,
    this.minCutoff = 1.0,
    this.beta = 0.02,
    this.dCutoff = 1.0,
  });
  final int medianWindow;
  final double minCutoff;
  final double beta;
  final double dCutoff;

  final Map<String, MedianFilter> _medians = {};
  final Map<String, OneEuroFilter> _euros = {};
  int? _lastTimestampMs;

  List<Landmark> _smoothFrame(
    List<Landmark> landmarks,
    String tag,
    double dt,
  ) {
    final out = <Landmark>[];
    for (var i = 0; i < landmarks.length; i++) {
      final lm = landmarks[i];
      final smoothed = <String, double>{};
      for (final axis in const ['x', 'y', 'z']) {
        final key = '$tag:$i:$axis';
        final raw = switch (axis) {
          'x' => lm.x,
          'y' => lm.y,
          _ => lm.z,
        };
        final median = _medians.putIfAbsent(
          key,
          () => MedianFilter(window: medianWindow),
        );
        final euro = _euros.putIfAbsent(
          key,
          () => OneEuroFilter(
            minCutoff: minCutoff,
            beta: beta,
            dCutoff: dCutoff,
          ),
        );
        smoothed[axis] = euro(median(raw), dt);
      }
      out.add(Landmark(
        x: smoothed['x']!,
        y: smoothed['y']!,
        z: smoothed['z']!,
        visibility: lm.visibility,
      ));
    }
    return out;
  }

  PoseFrame call(PoseFrame frame) {
    final dt = _lastTimestampMs == null
        ? _dtFallbackSeconds
        : math.max((frame.timestampMs - _lastTimestampMs!) / 1000.0,
            _dtFallbackSeconds);
    _lastTimestampMs = frame.timestampMs;
    final world = frame.worldLandmarks;
    return PoseFrame(
      landmarks: _smoothFrame(frame.landmarks, 'n', dt),
      worldLandmarks:
          world == null ? null : _smoothFrame(world, 'w', dt),
      frameWidth: frame.frameWidth,
      frameHeight: frame.frameHeight,
      timestampMs: frame.timestampMs,
    );
  }

  void reset() {
    _medians.clear();
    _euros.clear();
    _lastTimestampMs = null;
  }
}
