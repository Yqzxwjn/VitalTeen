///Phase 0 真机帧率探针（一次性验证工具）
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/camera_position_check.dart';
import '../domain/landmarks.dart';
import '../domain/pose.dart';
import '../platform/pose_camera_pipeline.dart';
import '../ui/skeleton_overlay.dart';

const double _visibilityThreshold = visibilityThreshold;

const List<L> _footPoints = [
  L.leftHeel,
  L.rightHeel,
  L.leftFootIndex,
  L.rightFootIndex,
];

String _shortError(String message) {
  final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 70 ? oneLine : '${oneLine.substring(0, 70)}…';
}

bool _allFootPointsVisible(PoseFrame frame, double threshold) {
  for (final point in _footPoints) {
    if (frame.visibility(point) < threshold) return false;
  }
  return true;
}

const int _minSample = 30;

void main() {
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VitalTeen Phase 0 · 帧率探针',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const _ProbePage(),
      );
}

class _ProbePage extends StatefulWidget {
  const _ProbePage();
  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  final Stopwatch _clock = Stopwatch();
  final PoseCameraPipeline _pipeline = PoseCameraPipeline();
  int _footPointsFrames = 0;
  int _lastLogMs = 0;
  bool _showSkeleton = true;
  bool _showPosition = false;
  final CameraPositionMonitor _position = CameraPositionMonitor();
  bool? _mirrorOverride;
  static const int _stressDurationMs = 5 * 60 * 1000;
  int? _stressStartMs;
  bool _alarmFired = false;
  Timer? _ticker;
  final ValueNotifier<String> _countdown = ValueNotifier<String>('未开始');
  static const MethodChannel _alarmChannel = MethodChannel('vitalteen/probe');

  @override
  void initState() {
    super.initState();
    _clock.start();
    _pipeline.pose.addListener(_onPose);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_pipeline.start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pipeline.pose.removeListener(_onPose);
    unawaited(_pipeline.dispose());
    _countdown.dispose();
    _clock.stop();
    super.dispose();
  }

  void _onPose() {
    final frame = _pipeline.pose.value;
    if (_showPosition) _position.add(frame);
    if (frame == null) return;
    if (_allFootPointsVisible(frame, _visibilityThreshold)) {
      _footPointsFrames++;
    }
  }

  void _tick() {
    _logIfDue();
    _updateCountdown();
  }

  void _updateCountdown() {
    final start = _stressStartMs;
    if (start == null) {
      _countdown.value = '未开始';
      return;
    }
    final left = _stressDurationMs - (_clock.elapsedMilliseconds - start);
    if (left > 0) {
      final d = Duration(milliseconds: left);
      _countdown.value =
          '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
      return;
    }
    _countdown.value = '完成';
    if (_alarmFired) return;
    _alarmFired = true;
    debugPrint('[probe] 5 分钟压测到点，响提示音');
    _playAlarm();
  }

  Future<void> _playAlarm({int seconds = 10}) async {
    try {
      await _alarmChannel.invokeMethod<void>('alarm', {'seconds': seconds});
    } on MissingPluginException {
      debugPrint('[probe] 提示音通道不可用：平台侧未注册');
    } on PlatformException catch (error) {
      debugPrint('[probe] 提示音失败：${error.code} ${error.message}');
    }
  }

  void _toggleStress() {
    if (_stressStartMs != null) {
      setState(() {
        _stressStartMs = null;
        _alarmFired = false;
      });
      _countdown.value = '未开始';
      return;
    }
    _resetCounters();
    setState(() {
      _stressStartMs = _clock.elapsedMilliseconds;
      _alarmFired = false;
    });
    _countdown.value = '5:00';
    debugPrint('[probe] 5 分钟压测开始');
  }

  Future<void> _switchLens(CameraLensDirection lens) async {
    _resetCounters();
    _mirrorOverride = null;
    await _pipeline.switchLens(lens);
    if (mounted) setState(() {});
  }

  Future<void> _switchPreset(ResolutionPreset preset) async {
    _resetCounters();
    await _pipeline.switchPreset(preset);
    if (mounted) setState(() {});
  }

  void _resetCounters() {
    _pipeline.resetStats();
    setState(() {
      _lastLogMs = 0;
      _footPointsFrames = 0;
    });
  }

  String get _lensTag {
    final lens = _pipeline.activeCamera?.lens;
    return lens == CameraLensDirection.front
        ? 'front'
        : lens == CameraLensDirection.back
            ? 'back'
            : 'ext';
  }

  String get _skelTag {
    if (!_showSkeleton) return 'off';
    return _mirrorOverride ?? _mirror ? 'on+mirror' : 'on';
  }
  bool get _mirror =>
      _mirrorOverride ?? _pipeline.activeCamera?.mirrorPreview ?? true;

  String get _lensLabel {
    final lens = _pipeline.activeCamera?.lens;
    return lens == CameraLensDirection.front
        ? '前置 · 正视机位'
        : lens == CameraLensDirection.back
            ? '后置 · 架在侧面则为侧视机位'
            : '外接';
  }

  String _positionTag() {
    if (!_showPosition) return '';
    final report = _position.report;
    final r = report.lateralRatio;
    final body = report.bodyHeightRatio;
    return ' r=${r == null ? '?' : r.toStringAsFixed(3)}'
        ' body=${body == null ? '?' : body.toStringAsFixed(3)}'
        ' view=${report.view?.name ?? '?'}'
        '${report.viewStable ? '' : '(unstable)'}'
        ' block=${report.blocking ? 'Y' : 'N'}'
        '${report.primaryIssue == null ? '' : ' why=${report.primaryIssue!.code.name}'}';
  }

  void _logIfDue() {
    final now = _clock.elapsedMilliseconds;
    if (now - _lastLogMs < 1000) return;
    _lastLogMs = now;
    final stats = _pipeline.snapshot();
    debugPrint(
      '[probe] t=${(now / 1000).toStringAsFixed(0)}s '
      'lens=$_lensTag/${_pipeline.activeCamera?.description.sensorOrientation ?? '?'} '
      'skel=$_skelTag '
      'infer=${stats.inferenceFps.toStringAsFixed(1)}fps '
      'cam=${stats.cameraFps.toStringAsFixed(1)}fps '
      'infer_ms=${stats.meanInferenceMs.toStringAsFixed(0)} '
      'drop=${(stats.dropRate * 100).toStringAsFixed(0)}% '
      'det=${(stats.hitRate * 100).toStringAsFixed(0)}% '
      'vis=${stats.meanVisible.toStringAsFixed(1)} '
      'fmt=${stats.observedRawFormat ?? '?'}/${stats.observedPlaneCount ?? '?'} '
      'badfmt=${stats.formatFailures} err=${stats.errorCount} '
      'feet=${stats.hitPoses < _minSample ? 'n/a' : '${_footPointsFrames * 100 ~/ stats.hitPoses}%'}'
      '${_positionTag()}'
      '${stats.lastError == null ? '' : ' err0=${_shortError(stats.lastError!)}'}',
    );
    _pipeline.trimWindow();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phase 0 · 推理帧率探针'),
        actions: [
          IconButton(
            tooltip: '试听提示音',
            onPressed: () => _playAlarm(seconds: 3),
            icon: const Icon(Icons.volume_up),
          ),
          IconButton(
            tooltip: _stressStartMs == null ? '开始 5 分钟压测' : '停止压测',
            onPressed: _toggleStress,
            icon: Icon(
              _stressStartMs == null ? Icons.timer_outlined : Icons.stop_circle,
            ),
          ),
          IconButton(
            tooltip: '重置统计',
            onPressed: _resetCounters,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!kReleaseMode)
            Container(
              width: double.infinity,
              color: Colors.red.shade700,
              padding: const EdgeInsets.all(8),
              child: const Text(
                '当前是 debug 构建，下面的数字没有参考价值。\n'
                '请用 flutter run --release 重新运行。',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            flex: 3,
            child: _preview(),
          ),
          Expanded(
            flex: 5,
            child: ValueListenableBuilder<PipelineStatus>(
              valueListenable: _pipeline.status,
              builder: (context, status, _) => _pipeline.activeCamera == null
                  ? _statusPanel(status)
                  : SingleChildScrollView(child: _readouts()),
            ),
          ),
          _presetBar(),
        ],
      ),
    );
  }

  Widget _preview() {
    final controller = _pipeline.activeCamera?.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(
      controller,
      child: _showSkeleton
          ? CustomPaint(
              painter: SkeletonPainter(
                _pipeline.pose,
                mirror: _mirror,
                visibilityThreshold: _visibilityThreshold,
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _statusPanel(PipelineStatus status) {
    if (status.isFatal) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red.shade700),
              const SizedBox(height: 12),
              Text(
                status.message ?? '相机启动失败',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (status.detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  status.detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              if (status.retryMayHelp)
                FilledButton(
                  onPressed: () => unawaited(_pipeline.retry()),
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
      );
    }
    return Center(child: Text(status.message ?? '正在启动相机…'));
  }

  Widget _readouts() {
    final stats = _pipeline.snapshot();
    final inferFps = stats.inferenceFps;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _big(
            '推理帧率',
            '${inferFps.toStringAsFixed(1)} fps',
            inferFps >= 15 ? Colors.green.shade700 : Colors.orange.shade800,
            note: '验收线 15 fps —— 这是决策要看的那一个数字',
          ),
          ValueListenableBuilder<String>(
            valueListenable: _countdown,
            builder: (context, value, _) => _row('压测剩余', value),
          ),
          const SizedBox(height: 12),
          _row('取帧率（相机上限）', '${stats.cameraFps.toStringAsFixed(1)} fps'),
          _row('单次推理耗时', '${stats.meanInferenceMs.toStringAsFixed(0)} ms'),
          _row('丢帧率', '${(stats.dropRate * 100).toStringAsFixed(0)} %'),
          _row(
            '检出到人的比例',
            stats.inferences < _minSample
                ? '—（样本不足：${stats.hitPoses}/${stats.inferences}）'
                : '${(stats.hitRate * 100).toStringAsFixed(0)} %',
          ),
          _row(
            '平均可见关键点',
            stats.inferences < _minSample
                ? '—（样本不足：${stats.inferences}/$_minSample）'
                : stats.meanVisible.toStringAsFixed(1),
          ),
          _row(
            '四个脚部点齐全的比例',
            stats.hitPoses < _minSample
                ? '—（样本不足：$_footPointsFrames/${stats.hitPoses}）'
                : '${_footPointsFrames * 100 ~/ stats.hitPoses} %（$_footPointsFrames/${stats.hitPoses}）',
          ),
          const SizedBox(height: 8),
          _row(
            '流启动到首帧结果',
            stats.firstDetectionMs == null ? '—' : '${stats.firstDetectionMs} ms',
          ),
          _row('分辨率', _pipeline.preset.name),
          _row('摄像头', _lensLabel),
          _row(
            '传感器朝向',
            _pipeline.activeCamera == null
                ? '—'
                : '${_pipeline.activeCamera!.description.sensorOrientation}°',
          ),
          _row(
            '请求的格式组',
            _pipeline.activeCamera?.controller.imageFormatGroup?.name ?? '—',
          ),
          _row(
            '实测的图像格式',
            stats.observedRawFormat == null
                ? '—'
                : 'raw=${stats.observedRawFormat} / ${stats.observedPlaneCount} 个平面',
          ),
          _row('累计推理 / 累计取帧', '${stats.inferences} / ${stats.framesSeen}'),
          if (_showPosition) ..._positionRows(),
          if (stats.formatFailures > 0) _row('帧格式不受支持', '${stats.formatFailures} 次'),
          if (stats.errorCount > 0) _row('推理异常', '${stats.errorCount} 次'),
          if (stats.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '最后一次异常：${stats.lastError}',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _positionRows() {
    final report = _position.report;
    final r = report.lateralRatio;
    final body = report.bodyHeightRatio;
    return [
      const Divider(height: 20),
      _row(
        '侧向比 r（0.62 正视 / 0.30 侧视）',
        r == null ? '—' : r.toStringAsFixed(3),
      ),
      _row('身高占画面', body == null ? '—' : '${(body * 100).toStringAsFixed(1)} %'),
      _row(
        '判出的机位',
        report.view == null
            ? '判断中（${report.sampleCount} 帧）'
            : '${report.view!.name}${report.viewStable ? '' : ' · 不稳'}',
      ),
      _row('能不能开始', report.canStart ? '可以' : '不行'),
      for (final issue in report.issues)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${issue.blocking ? '✕' : '·'} ${issue.message}',
            style: TextStyle(
              fontSize: 12,
              color: issue.blocking
                  ? Colors.red.shade700
                  : Colors.blueGrey.shade600,
            ),
          ),
        ),
    ];
  }
  Widget _presetBar() => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final lens in const [
                    CameraLensDirection.front,
                    CameraLensDirection.back,
                  ])
                    ChoiceChip(
                      label: Text(
                        lens == CameraLensDirection.front ? '前置' : '后置',
                      ),
                      selected: _pipeline.lens == lens,
                      onSelected: (selected) {
                        if (selected && _pipeline.lens != lens) {
                          unawaited(_switchLens(lens));
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final preset in const [
                    ResolutionPreset.low,
                    ResolutionPreset.medium,
                    ResolutionPreset.high,
                  ])
                    ChoiceChip(
                      label: Text(preset.name),
                      selected: _pipeline.preset == preset,
                      onSelected: (selected) {
                        if (selected && _pipeline.preset != preset) {
                          unawaited(_switchPreset(preset));
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('骨架'),
                    selected: _showSkeleton,
                    onSelected: (selected) =>
                        setState(() => _showSkeleton = selected),
                  ),
                  FilterChip(
                    label: const Text('镜像'),
                    selected: _mirror,
                    onSelected: _showSkeleton
                        ? (selected) => setState(() => _mirrorOverride = selected)
                        : null,
                  ),
                  FilterChip(
                    label: const Text('机位读数'),
                    selected: _showPosition,
                    onSelected: (selected) => setState(() {
                      _showPosition = selected;
                      _position.reset();
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
  Widget _big(String label, String value, Color color, {String? note}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54)),
          Text(
            value,
            style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: color),
          ),
          if (note != null)
            Text(note, style: const TextStyle(fontSize: 11, color: Colors.black45)),
        ],
      );
  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54)),
            Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
