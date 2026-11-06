//自己画的简笔人形，按关键帧循环
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'preview_poses.dart';
import 'theme.dart';

class _Rig {
  const _Rig._();
  static const double headR = 0.062;
  static const double neck = 0.055;
  static const double torso = 0.30;
  static const double upperArm = 0.17;
  static const double foreArm = 0.155;
  static const double thigh = 0.235;
  static const double shin = 0.235;
  static const double foot = 0.07;
  static const double shoulderHalf = 0.075;
  static const double hipHalf = 0.055;
}

const double _groundY = 0;

const double _standingHipHeight = _Rig.thigh + _Rig.shin;

class _Skeleton {
  const _Skeleton(this.points, this.groundOffset);
  final Map<String, Offset> points;
  final double groundOffset;
}

class _ForwardKinematics {
  const _ForwardKinematics(this.pose, this.view);
  final PreviewPose pose;
  final PreviewView view;
  static const Offset _down = Offset(0, 1);

  static Offset _rot(Offset v, double deg) {
    final r = deg * math.pi / 180;
    final c = math.cos(r);
    final s = math.sin(r);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  Offset _limbDir(double angle, {required bool left}) {
    final sign = view == PreviewView.front ? (left ? -1.0 : 1.0) : -1.0;
    return _rot(_down, sign * angle);
  }

  _Skeleton solve() {
    final frontal = view == PreviewView.front;
    final points = <String, Offset>{};
    const hip = Offset(0, 0);
    final trunkDir = frontal
        ? const Offset(0, -1)
        : _rot(const Offset(0, -1), pose.trunk);
    final neckBase = hip + trunkDir * _Rig.torso;
    final headCentre = neckBase + trunkDir * (_Rig.neck + _Rig.headR);
    points['hip'] = hip;
    points['head'] = headCentre;
    points['headTop'] = headCentre + trunkDir * _Rig.headR;
    points['hipRootL'] = frontal ? hip + const Offset(_Rig.hipHalf, 0) : hip;
    points['hipRootR'] = frontal ? hip + const Offset(-_Rig.hipHalf, 0) : hip;
    for (final left in [true, false]) {
      final tag = left ? 'L' : 'R';
      final shoulderAnchor = frontal
          ? neckBase + Offset(left ? _Rig.shoulderHalf : -_Rig.shoulderHalf, 0)
          : neckBase;
      points['shoulder$tag'] = shoulderAnchor;
      final upperArmDir =
          _limbDir(left ? pose.shoulder : pose.shoulderRight, left: left);
      final elbow =
          shoulderAnchor + upperArmDir * _Rig.upperArm;
      final elbowAngle = left ? pose.elbow : pose.elbowRight;
      final foreArmDir = frontal
          ? _rot(upperArmDir, left ? -elbowAngle : elbowAngle)
          : _rot(upperArmDir, -elbowAngle);
      final wrist = elbow + foreArmDir * _Rig.foreArm;
      points['elbow$tag'] = elbow;
      points['wrist$tag'] = wrist;
      final hipAngle = frontal
          ? (left ? pose.spread : pose.spreadRight)
          : (left ? pose.hip : pose.hipRight);
      final thighDir = _limbDir(hipAngle, left: left);
      final knee = points['hipRoot$tag']! + thighDir * _Rig.thigh;
      final shinDir = frontal
          ? thighDir
          : _rot(thighDir, left ? pose.knee : pose.kneeRight);
      final ankle = knee + shinDir * _Rig.shin;
      final footDir =
          frontal ? _rot(shinDir, left ? -90 : 90) : _rot(shinDir, -90);
      final toe = ankle + footDir * _Rig.foot;
      points['knee$tag'] = knee;
      points['ankle$tag'] = ankle;
      points['toe$tag'] = toe;
    }
    final lowest = points.values
        .map((p) => p.dy)
        .reduce((a, b) => a > b ? a : b);
    return _Skeleton(points, _groundY - lowest);
  }
}

Map<String, Offset> _solved(
  PreviewPose pose,
  PreviewView view,
  double lift,
  double drift,
) {
  final skeleton = _ForwardKinematics(pose, view).solve();
  final dy =
      lift > 0 ? -(_standingHipHeight + lift) : skeleton.groundOffset;
  return {
    for (final entry in skeleton.points.entries)
      entry.key: entry.value + Offset(drift, dy),
  };
}

Map<String, Offset> previewPoints(PreviewFrame frame, PreviewView view) =>
    _solved(frame.pose, view, frame.lift, frame.drift);

Rect previewBox(List<PreviewFrame> frames, PreviewView view) {
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;

  for (final frame in frames) {
    for (final p in previewPoints(frame, view).values) {
      if (p.dx < left) left = p.dx;
      if (p.dx > right) right = p.dx;
      if (p.dy < top) top = p.dy;
      if (p.dy > bottom) bottom = p.dy;
    }
  }

  if (frames.any((f) => f.lift == 0)) {
    if (_groundY > bottom) bottom = _groundY;
  }
  const pad = 0.12;
  return Rect.fromLTRB(left - pad, top - pad, right + pad, bottom + pad);
}

double previewBarY(List<PreviewFrame> frames, PreviewView view) {
  var top = double.infinity;
  for (final frame in frames) {
    final points = previewPoints(frame, view);
    for (final tag in ['wristL', 'wristR']) {
      top = math.min(top, points[tag]!.dy);
    }
  }
  return top;
}

class StickFigurePainter extends CustomPainter {
  const StickFigurePainter({
    required this.pose,
    required this.view,
    required this.lift,
    required this.drift,
    required this.box,
    required this.color,
    required this.groundColor,
    this.showGround = true,
    this.barY,
  });
  final PreviewPose pose;
  final PreviewView view;
  final double lift;
  final double drift;
  final Rect box;
  final Color color;
  final Color groundColor;
  final bool showGround;
  final double? barY;

  @override
  void paint(Canvas canvas, Size size) {
    final scale =
        math.min(size.width / box.width, size.height / box.height);
    final originX = (size.width - box.width * scale) / 2 - box.left * scale;
    final originY = (size.height - box.height * scale) / 2 - box.top * scale;
    Offset at(Offset p) => Offset(
          originX + p.dx * scale,
          originY + p.dy * scale,
        );
    final line = Paint()
      ..color = groundColor
      ..strokeWidth = math.max(1, scale * 0.006);
    if (showGround) {
      canvas.drawLine(
        at(Offset(box.left, _groundY)),
        at(Offset(box.right, _groundY)),
        line,
      );
    }
    if (barY != null) {
      canvas.drawLine(
        at(Offset(box.left, barY!)),
        at(Offset(box.right, barY!)),
        line..strokeWidth = math.max(1.5, scale * 0.012),
      );
    }
    final points = _solved(pose, view, lift, drift);
    Offset p(String name) => at(points[name]!);
    final width = math.max(2.0, scale * 0.032);
    final far = Paint()
      ..color = color.withValues(alpha: 0.38)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final near = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final tag in ['R', 'L']) {
      final paint = tag == 'R' ? far : near;
      canvas.drawLine(p('shoulder$tag'), p('elbow$tag'), paint);
      canvas.drawLine(p('elbow$tag'), p('wrist$tag'), paint);
    }
    if (view == PreviewView.front) {
      canvas.drawLine(p('hipRootL'), p('shoulderL'), near);
      canvas.drawLine(p('hipRootR'), p('shoulderR'), near);
      canvas.drawLine(p('shoulderL'), p('shoulderR'), near);
      canvas.drawLine(p('hipRootL'), p('hipRootR'), near);
    } else {
      canvas.drawLine(p('hip'), p('shoulderL'), near);
      canvas.drawLine(p('hip'), p('shoulderR'), near);
    }
    for (final tag in ['R', 'L']) {
      final paint = tag == 'R' ? far : near;
      canvas.drawLine(p('hipRoot$tag'), p('knee$tag'), paint);
      canvas.drawLine(p('knee$tag'), p('ankle$tag'), paint);
      canvas.drawLine(p('ankle$tag'), p('toe$tag'), paint);
    }
    final head = p('head');
    canvas.drawCircle(
      head,
      _Rig.headR * scale,
      Paint()..color = color.withValues(alpha: 0.22),
    );
    canvas.drawCircle(
      head,
      _Rig.headR * scale,
      Paint()
        ..color = color
        ..strokeWidth = math.max(1.5, width * 0.5)
        ..style = PaintingStyle.stroke,
    );
  }
  @override
  bool shouldRepaint(StickFigurePainter old) =>
      old.pose != pose ||
      old.view != view ||
      old.lift != lift ||
      old.drift != drift ||
      old.box != box ||
      old.barY != barY ||
      old.color != color;
}

class StickFigureThumbnail extends StatelessWidget {
  const StickFigureThumbnail({
    super.key,
    required this.code,
    required this.color,
  });
  final String code;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final frame = previewThumbnail(code);
    if (frame == null) return const SizedBox.shrink();
    final view = previewViewFor(code);
    return CustomPaint(
      size: Size.infinite,
      painter: StickFigurePainter(
        pose: frame.pose,
        view: view,
        lift: frame.lift,
        drift: frame.drift,
        box: previewBox([frame], view),
        color: color,
        groundColor: color,
        showGround: false,
      ),
    );
  }
}

PreviewPose lerpPreviewPose(PreviewPose a, PreviewPose b, double t) =>
    PreviewPose(
      trunk: _mix(a.trunk, b.trunk, t),
      hip: _mix(a.hip, b.hip, t),
      knee: _mix(a.knee, b.knee, t),
      spread: _mix(a.spread, b.spread, t),
      shoulder: _mix(a.shoulder, b.shoulder, t),
      elbow: _mix(a.elbow, b.elbow, t),
      hipR: _mix(a.hipRight, b.hipRight, t),
      kneeR: _mix(a.kneeRight, b.kneeRight, t),
      spreadR: _mix(a.spreadRight, b.spreadRight, t),
      shoulderR: _mix(a.shoulderRight, b.shoulderRight, t),
      elbowR: _mix(a.elbowRight, b.elbowRight, t),
    );

double _mix(double a, double b, double t) => a + (b - a) * t;

class ExercisePreview extends StatefulWidget {
  const ExercisePreview({
    super.key,
    required this.code,
    this.aspectRatio = 1.5,
  });
  final String code;
  final double aspectRatio;
  @override
  State<ExercisePreview> createState() => _ExercisePreviewState();
}

class _ExercisePreviewState extends State<ExercisePreview>
    with SingleTickerProviderStateMixin {
  static const Duration _hold = Duration(milliseconds: 900);
  static const Duration _tween = Duration(milliseconds: 420);
  late final List<PreviewFrame> _frames =
      kPreviewFrames[widget.code] ?? const [];
  late final Duration _cycle = Duration(
    microseconds: math.max(
      1000,
      _frames.length * (_hold + _tween).inMicroseconds,
    ),
  );
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _cycle,
  )..repeat();
  late final Rect _box = previewBox(_frames, _view);
  late final bool _showGround = _frames.any((f) => f.lift == 0);
  late final double? _barY =
      widget.code == 'PULLUP' ? previewBarY(_frames, _view) : null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_frames.isEmpty) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Text(
            '这个动作还没有预览',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: widget.aspectRatio,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _painterAt(_controller.value),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => _label(theme, _frameIndexAt(_controller.value)),
        ),
      ],
    );
  }

  StickFigurePainter _painterAt(double t) {
    final (index, target, mix) = _decode(t);
    return StickFigurePainter(
      pose: lerpPreviewPose(_frames[index].pose, target.pose, mix),
      view: _view,
      lift: _frames[index].lift + (target.lift - _frames[index].lift) * mix,
      drift: _frames[index].drift + (target.drift - _frames[index].drift) * mix,
      box: _box,
      showGround: _showGround,
      barY: _barY,
      color: vitalBlue,
      groundColor:
          Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
    );
  }

  PreviewView get _view => previewViewFor(widget.code);

  (int, PreviewFrame, double) _decode(double t) {
    final span = (_hold + _tween).inMicroseconds / _cycle.inMicroseconds;
    final slot = (t / span).floor() % _frames.length;
    final within = (t - slot * span) * _cycle.inMicroseconds;
    final hold = _hold.inMicroseconds;
    if (within <= hold) return (slot, _frames[slot], 0);
    final raw = (within - hold) / _tween.inMicroseconds;
    return (slot, _frames[(slot + 1) % _frames.length], _ease(raw));
  }

  double _ease(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  int _frameIndexAt(double t) {
    final (slot, _, mix) = _decode(t);
    return mix >= 0.5 ? (slot + 1) % _frames.length : slot;
  }

  Widget _label(ThemeData theme, int index) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Container(
        key: ValueKey(index),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: vitalBlue.withValues(alpha: 0.06),
          border: Border.all(color: vitalBlue.withValues(alpha: 0.25)),
        ),
        child: Text(
          _frames[index].label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: vitalBlue,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
