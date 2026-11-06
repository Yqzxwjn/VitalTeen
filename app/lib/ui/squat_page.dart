///练习页：相机体与报告体整页换
library;

import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../app/action_spec.dart';
import '../app/analysis.dart';
import '../app/decision_report.dart';
import '../app/decision_request.dart';
import '../app/decision_submission.dart';
import '../app/local_decision.dart';
import '../app/message_catalog.dart';
import '../app/plan_catalog.dart';
import '../app/profile.dart';
import '../app/rule_settings.dart';
import '../app/session_record.dart';
import '../app/set_recorder.dart';
import '../app/squat_session.dart';
import '../app/thresholds_loader.dart';
import '../app/voice_coach.dart';
import '../platform/decide_client.dart';
import '../platform/history_store.dart';
import '../platform/keep_screen_on.dart';
import '../platform/pose_camera_pipeline.dart';
import '../platform/speech.dart';
import 'analysis_panel.dart';
import 'bottom_surface.dart';
import 'counting_hud.dart';
import 'landscape_gate.dart';
import 'position_checklist.dart';
import 'set_report_view.dart';
import 'rep_feedback_card.dart';
import 'skeleton_overlay.dart';
import 'theme.dart';

class SquatPage extends StatefulWidget {
  const SquatPage({
    super.key,
    required this.onExit,
    this.profile,
    this.spec = squatSpec,
    this.onReportShown,
  });
  @visibleForTesting
  static const Key panelKey = ValueKey('squat-panel');
  final ActionSpec spec;
  final VoidCallback onExit;
  final Profile? profile;
  final ValueChanged<bool>? onReportShown;
  @override
  State<SquatPage> createState() => _SquatPageState();
}

sealed class _Loaded {
  const _Loaded();
}

class _Loading extends _Loaded {
  const _Loading();
}

class _Failed extends _Loaded {
  const _Failed(this.message);
  final String message;
}

class _Ready extends _Loaded {
  const _Ready(this.session);
  final SquatSession session;
}

class _SquatPageState extends State<SquatPage> {
  static const int autoStartSeconds = 3;
  final PoseCameraPipeline _pipeline = PoseCameraPipeline();
  final DecideClient _decideClient = DecideClient();
  Future<MessageCatalog>? _messages;
  Future<PlanCatalog>? _plans;
  Future<RuleSettings>? _ruleSettings;
  _Loaded _loaded = const _Loading();
  bool _screenOn = false;
  Timer? _autoStartTimer;
  int _autoStartIn = 0;
  late final VoiceCoach _voice = VoiceCoach(
    speak: _say,
    framingHint: widget.spec.framingHint,
    discardedReason: widget.spec.discardedReason,
    isTimed: widget.spec.isTimed,
  );
  late final SetRecorder _recorder = SetRecorder(
    spec: widget.spec,
    onRecord: _saveRecord,
  );
  bool _muted = false;
  bool _voiceUnavailable = false;
  bool _cameraParked = false;
  SessionPhase? _lastPhase;
  bool _landscapeAcknowledged = true;
  bool _panelCollapsed = false;

  @override
  void initState() {
    super.initState();
    _landscapeAcknowledged = !widget.spec.requiresLandscape;
    _pipeline.pose.addListener(_onPose);
    _pipeline.status.addListener(_onStatus);
    _boot();
  }

  @override
  void dispose() {
    _autoStartTimer?.cancel();
    _pipeline.pose.removeListener(_onPose);
    _pipeline.status.removeListener(_onStatus);
    _pipeline.dispose();
    _decideClient.close();
    final loaded = _loaded;
    if (loaded is _Ready) loaded.session.dispose();
    if (_screenOn) setKeepScreenOn(false);
    stopSpeaking();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final table = await loadThresholds();
      if (!mounted) return;
      final session = SquatSession(thresholds: table, spec: widget.spec);
      session.view.addListener(_onSessionView);
      setState(() => _loaded = _Ready(session));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loaded = _Failed('$error'));
      return;
    }
    await _pipeline.start();
  }

  void _onPose() {
    final loaded = _loaded;
    if (loaded is! _Ready) return;
    loaded.session.feed(_pipeline.pose.value);
  }

  void _onSessionView() {
    final loaded = _loaded;
    if (loaded is! _Ready) return;
    final view = loaded.session.view.value;
    _syncScreenOn(view);
    _updateAutoStart(view);
    _voice.onView(view);
    _syncCameraForPhase(view);
    _recorder.onView(view);
    if (view.phase != _lastPhase) {
      _lastPhase = view.phase;
      if (view.phase == SessionPhase.position) _panelCollapsed = false;
      setState(() {});
      widget.onReportShown?.call(view.phase == SessionPhase.finished);
    }
  }

  void _syncCameraForPhase(SessionView view) {
    final park = view.phase == SessionPhase.finished;
    if (park == _cameraParked) return;
    _cameraParked = park;
    unawaited(park ? _pipeline.stop() : _pipeline.start());
  }

  void _saveRecord(SessionRecord record) {
    unawaited(_persistRecord(record));
  }

  Future<void> _persistRecord(SessionRecord record) async {
    if (await appendSessionRecord(record)) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这一组没能存到这台设备上，历史记录里不会出现。')),
    );
  }

  void _say(String text) {
    if (_muted) return;
    unawaited(_speakNow(text));
  }

  Future<void> _speakNow(String text) async {
    final accepted = await speak(text);
    if (accepted || _voiceUnavailable || !mounted) return;
    _voiceUnavailable = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这台设备的语音引擎说不出中文，本局只能看屏幕。')),
    );
  }

  void _toggleVoice() {
    setState(() => _muted = !_muted);
    if (_muted) unawaited(stopSpeaking());
  }

  void _onStatus() {
    if (_pipeline.status.value.isRunning) return;
    final loaded = _loaded;
    if (loaded is _Ready) loaded.session.feed(null);
  }

  void _updateAutoStart(SessionView view) {
    // 引导没确认就拦住倒计时，别让这一组在引导背后开始
    if (!_landscapeAcknowledged) {
      _cancelAutoStart();
      return;
    }
    if (view.phase != SessionPhase.position || !view.canBeginCalibration) {
      _cancelAutoStart();
      return;
    }
    if (_autoStartTimer != null) return;
    _autoStartIn = autoStartSeconds;
    _voice.onCountdown(_autoStartIn);
    _autoStartTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _autoStartIn--;
      if (_autoStartIn > 0) {
        _voice.onCountdown(_autoStartIn);
        setState(() {});
        return;
      }
      _cancelAutoStart();
      _beginCalibration();
    });
    setState(() {});
  }

  void _cancelAutoStart() {
    if (_autoStartTimer == null) return;
    _autoStartTimer!.cancel();
    _autoStartTimer = null;
    _autoStartIn = 0;
    if (mounted) setState(() {});
  }

  void _beginCalibration() {
    final loaded = _loaded;
    if (loaded is! _Ready) return;
    loaded.session.beginCalibration();
    _onSessionView();
  }

  void _syncScreenOn(SessionView view) {
    final want = view.phase == SessionPhase.calibrating ||
        view.phase == SessionPhase.counting;
    if (want == _screenOn) return;
    _screenOn = want;
    setKeepScreenOn(want);
  }

  bool get _showingReport {
    final loaded = _loaded;
    return loaded is _Ready &&
        loaded.session.view.value.phase == SessionPhase.finished;
  }

  @override
  Widget build(BuildContext context) {
    return _showingReport ? _report() : _camera();
  }

  Widget _report() {
    final session = (_loaded as _Ready).session;
    final view = session.view.value;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回动作列表',
          onPressed: widget.onExit,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('本组报告'),
        actions: [
          IconButton(
            tooltip: _muted ? '打开语音' : '关掉语音',
            onPressed: _toggleVoice,
            icon: Icon(
              _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: SetReportView(
          view: view,
          requestBuilder: _requestBuilder(session),
          analyze: (request, endpoint) => _analyze(session, request, endpoint),
          onAnotherSet: session.startNewSet,
          onRecalibrate: session.reset,
          profile: widget.profile,
          discardedReason: widget.spec.discardedReason,
          isTimed: widget.spec.isTimed,
        ),
      ),
    );
  }

  Widget _camera() {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回动作列表',
          onPressed: widget.onExit,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(widget.spec.nameZh),
        actions: [
          IconButton(
            tooltip: _muted ? '打开语音' : '关掉语音',
            onPressed: _toggleVoice,
            icon: Icon(
              _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
            ),
          ),
          ValueListenableBuilder<PipelineStatus>(
            valueListenable: _pipeline.status,
            builder: (context, status, _) => IconButton(
              tooltip: '切换前后摄像头',
              onPressed: status.isRunning ? _switchLens : null,
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
          ),
        ],
      ),
      body: switch (_loaded) {
        _Loading() => const Center(child: CircularProgressIndicator()),
        _Failed(:final message) => _errorPanel(message),
        _Ready(:final session) => _body(session),
      },
    );
  }

  Future<void> _switchLens() async {
    final next = _pipeline.lens == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    await _pipeline.switchLens(next);
  }

  Widget _body(SquatSession session) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _preview(),
        const IgnorePointer(child: _Scrim()),
        ValueListenableBuilder<SessionView>(
          valueListenable: session.view,
          builder: (context, view, _) => _overlay(session, view),
        ),
        if (!_landscapeAcknowledged)
          LandscapeGuide(onAcknowledge: _acknowledgeLandscape),
      ],
    );
  }

  void _acknowledgeLandscape() {
    setState(() => _landscapeAcknowledged = true);
  }

  Widget _overlay(SquatSession session, SessionView view) {
    final panel = _panel(session, view);
    if (MediaQuery.orientationOf(context) == Orientation.landscape) {
      final width = (MediaQuery.sizeOf(context).width * 0.38)
          .clamp(300.0, 420.0)
          .toDouble();
      final collapsed = _panelCollapsed && view.phase == SessionPhase.position;
      return Row(
        crossAxisAlignment:
            collapsed ? CrossAxisAlignment.end : CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          SizedBox(width: width, child: panel),
        ],
      );
    }
    return Column(
      children: [
        const Spacer(),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.52,
          ),
          child: panel,
        ),
      ],
    );
  }

  Widget _preview() {
    return ValueListenableBuilder<PipelineStatus>(
      valueListenable: _pipeline.status,
      builder: (context, status, _) {
        final active = _pipeline.activeCamera;
        final controller = active?.controller;
        if (controller == null || !controller.value.isInitialized) {
          return _pipelinePlaceholder(status);
        }
        final preview = CameraPreview(
          controller,
          child: CustomPaint(
            painter: SkeletonPainter(
              _pipeline.pose,
              mirror: active!.mirrorPreview,
              visibilityThreshold: 0.5,
            ),
          ),
        );
        // 相机给的是 16:9，横屏屏幕是 20:9；照 AspectRatio 铺会在左右各留 240px 黑边。
        // 横屏改成铺满（裁掉上下多出来的那条），判定用的是整帧，裁的只是显示。
        final size = controller.value.previewSize;
        if (size == null ||
            MediaQuery.orientationOf(context) != Orientation.landscape) {
          return preview;
        }
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: preview,
            ),
          ),
        );
      },
    );
  }

  Widget _pipelinePlaceholder(PipelineStatus status) {
    if (!status.isFatal) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined,
                size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 8),
            Text(
              status.message ?? '相机启动失败',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (status.retryMayHelp) ...[
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _pipeline.retry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _panel(SquatSession session, SessionView view) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.orientationOf(context) == Orientation.landscape;
    final collapsed = _panelCollapsed && view.phase == SessionPhase.position;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (wide)
              const Spacer()
            else
              Expanded(
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            if (view.phase == SessionPhase.position)
              TextButton.icon(
                onPressed: () =>
                    setState(() => _panelCollapsed = !_panelCollapsed),
                icon: Icon(
                  collapsed ? Icons.unfold_more : Icons.unfold_less,
                  size: 18,
                ),
                label: Text(collapsed ? '站位自检' : '收起'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        if (!collapsed)
          Flexible(
            child: SingleChildScrollView(child: _panelBody(session, view)),
          ),
        const SizedBox(height: 8),
        _actions(session, view),
      ],
    );

    if (wide) {
      final insets = MediaQuery.paddingOf(context);
      if (collapsed) {
        return Container(
          key: SquatPage.panelKey,
          margin: EdgeInsets.fromLTRB(0, 0, 12 + insets.right, 12 + insets.bottom),
          decoration: BoxDecoration(
            color: vitalOverlay,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: body,
        );
      }
      return Container(
        key: SquatPage.panelKey,
        margin: EdgeInsets.only(top: insets.top + kToolbarHeight),
        decoration: BoxDecoration(
          color: vitalOverlay,
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(20),
          ),
          border: Border(
            left: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16 + insets.right, 12 + insets.bottom),
        child: body,
      );
    }

    return BottomSurface(
      key: SquatPage.panelKey,
      decoration: BoxDecoration(
        color: vitalOverlay,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: body,
    );
  }

  Widget _panelBody(SquatSession session, SessionView view) {
    switch (view.phase) {
      case SessionPhase.position:
        return ValueListenableBuilder<PipelineStatus>(
          valueListenable: _pipeline.status,
          builder: (context, status, _) => PositionChecklist(
            report: view.position,
            sawFrame: view.sawFrame,
            cameraRunning: status.isRunning,
            framingHint: widget.spec.framingHint,
          ),
        );
      case SessionPhase.calibrating:
        return _calibratingPanel(view);
      case SessionPhase.counting:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            CountingHud(
              view: view,
              stateLabels: widget.spec.hudStateLabels,
              discardedReason: widget.spec.discardedReason,
              isTimed: widget.spec.isTimed,
            ),
            if (widget.spec.framingHint != null && view.repCount == 0) ...[
              const SizedBox(height: 8),
              Text(
                widget.spec.framingHint!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            if (view.lastRep != null)
              RepFeedbackCard(
                feedback: view.lastRep!,
                score: view.lastRepScore,
              ),
            const SizedBox(height: 12),
            Text(
              '站直不动 ${session.autoFinishRestMs ~/ 1000} 秒，本组会自动结束。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
            if (view.lastRepScore?.provisional ?? false) ...[
              const SizedBox(height: 4),
              Text(
                '分数只是参考：判定所依据的阈值与权重都还没经体育专业核定。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ],
          ],
        );
      case SessionPhase.finished:
        return const SizedBox.shrink();
    }
  }

  Widget _calibratingPanel(SessionView view) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('站直，别动', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '正在记录你的站立姿势。手臂自然下垂，两只脚都别挪。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: view.calibrationProgress),
      ],
    );
  }

  Future<AnalysisResult> _analyze(
    SquatSession session,
    DecisionRequest request,
    DecisionEndpoint endpoint,
  ) async {
    final MessageCatalog messages;
    final PlanCatalog plans;
    try {
      messages = await (_messages ??= loadMessageCatalog());
      plans = await (_plans ??= loadPlanCatalog());
    } on Object catch (error) {
      return AnalysisBlocked(
        message: '本机的文案表或方案库读不出来，这份报告算不出来。',
        advice: '重装一次应用。若仍然如此，把这一行报给开发者：$error',
      );
    }
    final outcome = await _decideClient.send(endpoint, request);
    if (outcome is DecisionSuccess) {
      return AnalysisReported(
        report: buildDecisionReport(
          response: outcome.response,
          request: request,
          messages: messages,
          planCatalog: plans,
          thresholds: session.thresholds,
          origin: ReportOrigin.server,
          local: session.localFaults,
        ),
        rawJson: outcome.rawJson,
        elapsed: outcome.elapsed,
        origin: ReportOrigin.server,
      );
    }
    final failure = outcome as DecisionFailure;
    final cause = DeviceFallbackCause.from(failure.kind);
    if (cause == null) {
      return AnalysisFailed(failure);
    }
    return _analyzeOnDevice(
      session: session,
      request: request,
      messages: messages,
      plans: plans,
      cause: cause,
    );
  }

  Future<AnalysisResult> _analyzeOnDevice({
    required SquatSession session,
    required DecisionRequest request,
    required MessageCatalog messages,
    required PlanCatalog plans,
    required DeviceFallbackCause cause,
  }) async {
    final RuleSettings settings;
    try {
      settings = await (_ruleSettings ??= loadRuleSettings());
    } on Object catch (error) {
      return AnalysisBlocked(
        message: '连不上决策服务，本机又读不出判定参数，这一组算不出报告。',
        advice: '重装一次应用；也可以先把电脑上的服务起起来。'
            '若仍然如此，把这一行报给开发者：$error',
      );
    }
    final started = Stopwatch()..start();
    final response = decideLocally(
      request: request,
      planCatalog: plans,
      settings: settings,
      faultName: session.localFaults?.faultName ?? (_) => null,
      availableEquipment: const [],
    );
    started.stop();
    return AnalysisReported(
      report: buildDecisionReport(
        response: response,
        request: request,
        messages: messages,
        planCatalog: plans,
        thresholds: session.thresholds,
        origin: ReportOrigin.device,
        fallbackCause: cause,
        local: session.localFaults,
      ),
      rawJson: const JsonEncoder.withIndent('  ').convert(response.toJson()),
      elapsed: started.elapsed,
      origin: ReportOrigin.device,
      fallbackCause: cause,
    );
  }
  RequestBuilder _requestBuilder(SquatSession session) =>
      (sex, age, grade, group) => session.buildRequest(
            requestId: 'local-${DateTime.now().millisecondsSinceEpoch}',
            sex: sex,
            age: age,
            grade: grade,
            standardGroup: group,
          );

  Widget _actions(SquatSession session, SessionView view) {
    switch (view.phase) {
      case SessionPhase.position:
        final counting = _autoStartIn > 0;
        return FilledButton(
          onPressed: view.canBeginCalibration
              ? () {
                  _cancelAutoStart();
                  session.beginCalibration();
                }
              : null,
          child: Text(
            switch ((counting, view.canBeginCalibration)) {
              (true, _) => '$_autoStartIn 秒后自动开始（点一下立即开始）',
              (_, true) => '立即开始',
              _ => '先按清单调整站位',
            },
          ),
        );
      case SessionPhase.calibrating:
        return const FilledButton(onPressed: null, child: Text('正在记录…'));
      case SessionPhase.counting:
        return FilledButton.tonal(
          onPressed: session.finishSet,
          child: const Text('结束本组'),
        );
      case SessionPhase.finished:
        return const SizedBox.shrink();
    }
  }

  Widget _errorPanel(String message) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rule_folder_outlined,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            const Text(
              '阈值表读不出来，这一局没法开始',
              style: TextStyle(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC080C10),
            Color(0x33080C10),
            Color(0x00080C10),
            Color(0x00080C10),
            Color(0x99080C10),
          ],
          stops: [0.0, 0.16, 0.30, 0.62, 1.0],
        ),
      ),
    );
  }
}
