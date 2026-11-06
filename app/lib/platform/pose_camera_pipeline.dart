///相机管线，全应用唯一开相机的地方
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../domain/pose.dart';
import 'camera_frame_conversion.dart';
import 'mlkit_pose_mapper.dart';
import 'video_rotation.dart';

const int _windowMs = 3000;

const double visibilityThreshold = 0.5;

enum PipelinePhase {
  idle,
  starting,
  running,
  suspended,
  fatal,
}

enum PipelineFailure {
  permissionDenied,
  noCamera,
  cameraInit,
  unsupportedRotation,
  landmarkMismatch,
  unknown,
}

@immutable
class PipelineStatus {
  const PipelineStatus({
    required this.phase,
    this.failure,
    this.message,
    this.detail,
  });
  const PipelineStatus.idle() : this(phase: PipelinePhase.idle);
  const PipelineStatus.starting() : this(phase: PipelinePhase.starting);
  const PipelineStatus.running() : this(phase: PipelinePhase.running);
  const PipelineStatus.suspended()
      : this(
          phase: PipelinePhase.suspended,
          message: '应用切到后台，相机已释放。回到前台会自动恢复。',
        );
  const PipelineStatus.failed(
    PipelineFailure failure,
    String message, {
    String? detail,
  }) : this(
          phase: PipelinePhase.fatal,
          failure: failure,
          message: message,
          detail: detail,
        );
  final PipelinePhase phase;
  final PipelineFailure? failure;
  final String? message;
  final String? detail;
  bool get isFatal => phase == PipelinePhase.fatal;
  bool get isRunning => phase == PipelinePhase.running;
  bool get retryMayHelp =>
      isFatal && failure != PipelineFailure.permissionDenied;
}

@immutable
class ActiveCamera {
  const ActiveCamera({
    required this.controller,
    required this.description,
    required this.mirrorPreview,
  });
  final CameraController controller;
  final CameraDescription description;
  final bool mirrorPreview;
  CameraLensDirection get lens => description.lensDirection;
}

@immutable
class PipelineStats {
  const PipelineStats({
    required this.framesSeen,
    required this.framesDropped,
    required this.inferences,
    required this.hitPoses,
    required this.formatFailures,
    required this.errorCount,
    required this.visibleSum,
    required this.inferenceFps,
    required this.cameraFps,
    required this.meanInferenceMs,
    this.lastError,
    this.observedRawFormat,
    this.observedPlaneCount,
    this.firstDetectionMs,
  });
  final int framesSeen;
  final int framesDropped;
  final int inferences;
  final int hitPoses;
  final int formatFailures;
  final int errorCount;
  final int visibleSum;
  final double inferenceFps;
  final double cameraFps;
  final double meanInferenceMs;
  final String? lastError;
  final int? observedRawFormat;
  final int? observedPlaneCount;
  final int? firstDetectionMs;
  double get dropRate => framesSeen == 0 ? 0 : framesDropped / framesSeen;
  double get hitRate => inferences == 0 ? 0 : hitPoses / inferences;
  double get meanVisible =>
      inferences == 0 ? 0 : visibleSum / inferences;
}

class PoseCameraPipeline {
  PoseCameraPipeline({
    ResolutionPreset preset = ResolutionPreset.medium,
    CameraLensDirection lens = CameraLensDirection.front,
  }) {
    _preset = preset;
    _lens = lens;
    _clock.start();
  }
  final ValueNotifier<PoseFrame?> pose = ValueNotifier<PoseFrame?>(null);
  final ValueNotifier<PipelineStatus> status =
      ValueNotifier<PipelineStatus>(const PipelineStatus.idle());
  final Stopwatch _clock = Stopwatch();
  CameraController? _controller;
  PoseDetector? _detector;
  InputImageRotation? _rotation;
  ActiveCamera? _active;
  int? _sensorOrientation;
  bool _isFrontFacing = false;
  DeviceOrientation? _lastDeviceOrientation;
  late CameraLensDirection _lens;
  late ResolutionPreset _preset;
  int _generation = 0;
  bool _busy = false;
  bool _disposed = false;
  bool _suspended = false;
  bool _observerRegistered = false;
  late final _PipelineLifecycleObserver _lifecycle =
      _PipelineLifecycleObserver(this);
  final List<int> _frameTimes = [];
  final List<int> _inferEnds = [];
  final List<int> _inferCosts = [];
  int _framesSeen = 0;
  int _framesDropped = 0;
  int _inferences = 0;
  int _hitPoses = 0;
  int _visibleSum = 0;
  int _formatFailures = 0;
  int _errorCount = 0;
  String? _lastError;
  int? _observedRawFormat;
  int? _observedPlaneCount;
  int? _streamStartedMs;
  int? _firstDetectionMs;
  ActiveCamera? get activeCamera => _active;
  ResolutionPreset get preset => _preset;
  CameraLensDirection get lens => _active?.lens ?? _lens;
  @visibleForTesting
  bool get isBusy => _busy;

  Future<void> start() async {
    if (_disposed) return;
    _generation++;
    final generation = _generation;
    _registerObserver();
    _suspended = false;
    status.value = const PipelineStatus.starting();
    try {
      final cameras = await availableCameras();
      if (_superseded(generation)) return;
      if (cameras.isEmpty) {
        _fail(PipelineFailure.noCamera, '这台设备没有可用相机');
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == _lens,
        orElse: () => cameras.first,
      );
      final problems = landmarkAlignmentProblems();
      if (problems.isNotEmpty) {
        _fail(
          PipelineFailure.landmarkMismatch,
          '姿态模型的 33 个关键点与本项目定义不对齐，所有角度都会算错。',
          detail: problems.join('\n'),
        );
        return;
      }
      final controller = CameraController(
        camera,
        _preset,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      if (_superseded(generation)) {
        await _safeDispose(controller);
        return;
      }
      final sensor = camera.sensorOrientation;
      if (InputImageRotationValue.fromRawValue(sensor) == null) {
        await _safeDispose(controller);
        _fail(
          PipelineFailure.unsupportedRotation,
          '无法识别的相机朝向（$sensor°），图像转正会算错。',
        );
        return;
      }
      final isFront = camera.lensDirection == CameraLensDirection.front;
      final deviceOrientation = controller.value.deviceOrientation;
      final rotation = InputImageRotationValue.fromRawValue(
        mlkitRotationDegrees(
          deviceOrientation: deviceOrientation,
          sensorOrientation: sensor,
          isFrontFacing: isFront,
        ),
      )!;
      final detector = PoseDetector(
        options: PoseDetectorOptions(
          model: PoseDetectionModel.base,
          mode: PoseDetectionMode.stream,
        ),
      );
      _controller = controller;
      _detector = detector;
      _rotation = rotation;
      _sensorOrientation = sensor;
      _isFrontFacing = isFront;
      _lastDeviceOrientation = deviceOrientation;
      _lens = camera.lensDirection;
      _active = ActiveCamera(
        controller: controller,
        description: camera,
        mirrorPreview: camera.lensDirection == CameraLensDirection.front,
      );
      _streamStartedMs = _clock.elapsedMilliseconds;
      await controller.startImageStream((image) => _onFrame(image, generation));
      if (_superseded(generation)) return;
      status.value = const PipelineStatus.running();
    } on CameraException catch (error) {
      await _teardown();
      if (_superseded(generation)) return;
      _failFromCameraException(error);
    } catch (error) {
      await _teardown();
      if (_superseded(generation)) return;
      _fail(PipelineFailure.unknown, '相机启动失败。', detail: '$error');
    }
  }

  Future<void> stop() async {
    _generation++;
    await _teardown();
    if (_disposed) return;
    status.value = const PipelineStatus.idle();
  }

  Future<void> switchLens(CameraLensDirection lens) async {
    if (_lens == lens && _active?.lens == lens) return;
    _lens = lens;
    await _restart();
  }

  Future<void> switchPreset(ResolutionPreset preset) async {
    if (_preset == preset) return;
    _preset = preset;
    await _restart();
  }
  Future<void> retry() => _restart();

  Future<void> _restart() async {
    _generation++;
    await _teardown();
    if (_disposed) return;
    await start();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _unregisterObserver();
    await _teardown();
    pose.dispose();
    status.dispose();
    _clock.stop();
  }

  Future<void> _teardown() async {
    final controller = _controller;
    final detector = _detector;
    _controller = null;
    _detector = null;
    _rotation = null;
    _sensorOrientation = null;
    _lastDeviceOrientation = null;
    _active = null;
    try {
      if (controller != null) {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
        await controller.dispose();
      }
    } catch (_) {
    }
    await detector?.close();
    _observedRawFormat = null;
    _observedPlaneCount = null;
    _busy = false;
  }

  Future<void> _safeDispose(CameraController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
    }
  }
  bool _superseded(int generation) => _disposed || generation != _generation;

  void _fail(PipelineFailure failure, String message, {String? detail}) {
    status.value = PipelineStatus.failed(failure, message, detail: detail);
  }

  void _failFromCameraException(CameraException error) {
    if (error.code.contains('CameraAccessDenied')) {
      _fail(
        PipelineFailure.permissionDenied,
        '相机权限被拒绝。\n请到「系统设置 → 应用 → 健知行绎 → 权限」里打开相机权限，'
            '再回到这里重试。',
        detail: '${error.code}: ${error.description}',
      );
      return;
    }
    _fail(
      PipelineFailure.cameraInit,
      '相机初始化失败（${error.code}）。',
      detail: error.description,
    );
  }

  void _registerObserver() {
    if (_observerRegistered) return;
    WidgetsBinding.instance.addObserver(_lifecycle);
    _observerRegistered = true;
  }

  void _unregisterObserver() {
    if (!_observerRegistered) return;
    WidgetsBinding.instance.removeObserver(_lifecycle);
    _observerRegistered = false;
  }

  void _onLifecycle(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_suspend());
      case AppLifecycleState.resumed:
        unawaited(_resume());
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _suspend() async {
    if (_suspended || _disposed) return;
    final busy = _active != null || status.value.phase == PipelinePhase.starting;
    if (!busy) return;
    _suspended = true;
    _generation++;
    await _teardown();
    if (_disposed || !_suspended) return;
    status.value = const PipelineStatus.suspended();
  }

  Future<void> _resume() async {
    if (!_suspended) return;
    _suspended = false;
    await start();
  }

  void _refreshRotation() {
    final controller = _controller;
    final sensor = _sensorOrientation;
    if (controller == null || sensor == null) return;
    final orientation = controller.value.deviceOrientation;
    if (orientation == _lastDeviceOrientation) return;
    _lastDeviceOrientation = orientation;
    final degrees = mlkitRotationDegrees(
      deviceOrientation: orientation,
      sensorOrientation: sensor,
      isFrontFacing: _isFrontFacing,
    );
    final rotation = InputImageRotationValue.fromRawValue(degrees);
    if (rotation != null) _rotation = rotation;
  }

  void _onFrame(CameraImage image, int generation) {
    if (_superseded(generation)) return;
    _refreshRotation();
    final now = _clock.elapsedMilliseconds;
    _framesSeen++;
    _frameTimes.add(now);
    if (_observedRawFormat == null) {
      final raw = image.format.raw;
      _observedRawFormat = raw is int ? raw : -1;
      _observedPlaneCount = image.planes.length;
    }
    if (_busy) {
      _framesDropped++;
      return;
    }
    _busy = true;
    _run(image, generation).whenComplete(() {
      if (generation == _generation) _busy = false;
    });
  }

  Future<void> _run(CameraImage image, int generation) async {
    final detector = _detector;
    final rotation = _rotation;
    if (detector == null || rotation == null) return;
    final started = _clock.elapsedMilliseconds;
    try {
      final input = buildInputImage(
        width: image.width,
        height: image.height,
        planes: image.planes.map((p) => p.bytes).toList(growable: false),
        bytesPerRow: image.planes.first.bytesPerRow,
        rotation: rotation,
        rawFormat: image.format.raw,
      );
      if (input == null) {
        _formatFailures++;
        return;
      }
      final poses = await detector.processImage(input);
      final ended = _clock.elapsedMilliseconds;
      if (_superseded(generation)) return;
      _inferences++;
      _inferEnds.add(ended);
      _inferCosts.add(ended - started);
      final frame = poses.isEmpty
          ? null
          : poseFrameFromMlKit(
              poses.first,
              imageWidth: image.width,
              imageHeight: image.height,
              rotation: rotation,
              timestampMs: ended,
            );
      if (frame != null) {
        _hitPoses++;
        _visibleSum += frame.landmarks
            .where((l) => l.visibility >= visibilityThreshold)
            .length;
      }
      pose.value = frame;
      _firstDetectionMs ??= ended - (_streamStartedMs ?? ended);
    } catch (error) {
      if (_superseded(generation)) return;
      _errorCount++;
      _lastError = '$error';
      pose.value = null;
      if (_errorCount <= 3) {
        debugPrint('[pipeline] 推理异常 #$_errorCount：$error');
      }
    }
  }

  PipelineStats snapshot() {
    final now = _clock.elapsedMilliseconds;
    int countWithin(List<int> times) =>
        times.where((t) => t >= now - _windowMs).length;
    final meanCost = _inferCosts.isEmpty
        ? 0.0
        : _inferCosts.reduce((a, b) => a + b) / _inferCosts.length;
    return PipelineStats(
      framesSeen: _framesSeen,
      framesDropped: _framesDropped,
      inferences: _inferences,
      hitPoses: _hitPoses,
      formatFailures: _formatFailures,
      errorCount: _errorCount,
      visibleSum: _visibleSum,
      inferenceFps: countWithin(_inferEnds) * 1000.0 / _windowMs,
      cameraFps: countWithin(_frameTimes) * 1000.0 / _windowMs,
      meanInferenceMs: meanCost,
      lastError: _lastError,
      observedRawFormat: _observedRawFormat,
      observedPlaneCount: _observedPlaneCount,
      firstDetectionMs: _firstDetectionMs,
    );
  }

  void resetStats() {
    _framesSeen = 0;
    _framesDropped = 0;
    _inferences = 0;
    _hitPoses = 0;
    _visibleSum = 0;
    _formatFailures = 0;
    _errorCount = 0;
    _lastError = null;
    _firstDetectionMs = null;
    _observedRawFormat = null;
    _observedPlaneCount = null;
    _frameTimes.clear();
    _inferEnds.clear();
    _inferCosts.clear();
  }

  void trimWindow() {
    final now = _clock.elapsedMilliseconds;
    _frameTimes.retainWhere((t) => t >= now - _windowMs);
    _inferEnds.retainWhere((t) => t >= now - _windowMs);
    if (_inferCosts.length > 240) {
      _inferCosts.removeRange(0, _inferCosts.length - 240);
    }
  }
}

class _PipelineLifecycleObserver with WidgetsBindingObserver {
  _PipelineLifecycleObserver(this._pipeline);
  final PoseCameraPipeline _pipeline;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _pipeline._onLifecycle(state);
}
