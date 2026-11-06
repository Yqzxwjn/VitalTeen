//几何算子，含负零修正
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

class PixelPoint {
  const PixelPoint(this.x, this.y);
  final double x;
  final double y;
  Offset toOffset() => Offset(x, y);
  @override
  String toString() => 'PixelPoint($x, $y)';
  @override
  bool operator ==(Object other) =>
      other is PixelPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}

class DegenerateGeometryException implements Exception {
  const DegenerateGeometryException(this.message);
  final String message;
  @override
  String toString() => 'DegenerateGeometryException: $message';
}

const double _eps = 1e-9;

(double, double) _sub(PixelPoint a, PixelPoint b) => (a.x - b.x, a.y - b.y);

double _norm((double, double) v) => math.sqrt(v.$1 * v.$1 + v.$2 * v.$2);

double _normalizeSignedDegrees(double deg) {
  if (deg <= -180.0) return deg + 360.0;
  return deg + 0.0;
}

double distance(PixelPoint a, PixelPoint b) => _norm(_sub(a, b));

double angle3(PixelPoint a, PixelPoint b, PixelPoint c) {
  final ba = _sub(a, b);
  final bc = _sub(c, b);
  final nba = _norm(ba);
  final nbc = _norm(bc);
  if (nba < _eps || nbc < _eps) {
    throw const DegenerateGeometryException('angle3 的向量长度为 0，角度无定义');
  }
  final cos = ((ba.$1 * bc.$1 + ba.$2 * bc.$2) / (nba * nbc)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180.0 / math.pi;
}

double tiltFromVertical(PixelPoint a, PixelPoint b) {
  final v = _sub(b, a);
  if (_norm(v) < _eps) {
    throw const DegenerateGeometryException('tiltFromVertical 的线段长度为 0');
  }
  return _normalizeSignedDegrees(
    math.atan2(v.$1, -v.$2) * 180.0 / math.pi,
  );
}

double tiltFromHorizontal(PixelPoint a, PixelPoint b) {
  final v = _sub(b, a);
  if (_norm(v) < _eps) {
    throw const DegenerateGeometryException('tiltFromHorizontal 的线段长度为 0');
  }
  return _normalizeSignedDegrees(
    math.atan2(-v.$2, v.$1) * 180.0 / math.pi,
  );
}

double distRatio(PixelPoint p, PixelPoint q, PixelPoint refA, PixelPoint refB) {
  final refLen = distance(refA, refB);
  if (refLen < _eps) {
    throw const DegenerateGeometryException('distRatio 的参考线段长度为 0');
  }
  return distance(p, q) / refLen;
}

double symmetryIndex(double left, double right) {
  final total = left + right;
  if (total.abs() < _eps) {
    throw const DegenerateGeometryException('symmetryIndex 的左右之和为 0');
  }
  return 2.0 * (left - right).abs() / total.abs();
}

PixelPoint midpoint(PixelPoint a, PixelPoint b) =>
    PixelPoint((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);

double signedOffset(PixelPoint p, PixelPoint a, PixelPoint b) {
  final ab = _sub(b, a);
  final length = _norm(ab);
  if (length < _eps) {
    throw const DegenerateGeometryException('signedOffset 的基线长度为 0');
  }
  final ap = (p.x - a.x, p.y - a.y);
  final cross = ab.$1 * ap.$2 - ab.$2 * ap.$1;
  return cross / length;
}

double angularVelocityDegPerSec(double prevDeg, double currDeg, double dtMs) {
  if (dtMs <= 0) {
    throw const DegenerateGeometryException('angularVelocityDegPerSec 的 dtMs 必须为正');
  }
  return (currDeg - prevDeg) / (dtMs / 1000.0);
}
