//组末分析面板：表单、主按钮、五态
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/analysis.dart';
import '../app/decision_request.dart';
import '../app/decision_submission.dart';
import '../app/profile.dart';
import 'analysis_report.dart';

typedef RequestBuilder = DecisionRequest? Function(
  Sex sex,
  int age,
  String grade,
  String standardGroup,
);

typedef AnalysisRunner = Future<AnalysisResult> Function(
  DecisionRequest request,
  DecisionEndpoint endpoint,
);

class AnalysisPanel extends StatefulWidget {
  const AnalysisPanel({
    super.key,
    required this.build,
    required this.analyze,
    this.initialEndpoint,
    this.profile,
  });
  final RequestBuilder build;
  final AnalysisRunner analyze;
  final DecisionEndpoint? initialEndpoint;
  final Profile? profile;
  @override
  State<AnalysisPanel> createState() => _AnalysisPanelState();
}

class _AnalysisPanelState extends State<AnalysisPanel> {
  final _formKey = GlobalKey<FormState>();
  final _ageController = TextEditingController();
  final _gradeController = TextEditingController();
  final _groupController = TextEditingController();
  late final TextEditingController _baseController;
  late final TextEditingController _keyController;
  late Sex _sex = widget.profile?.sex ?? Sex.male;
  DecisionRequest? _request;
  bool _noData = false;
  bool _sending = false;
  String? _addressError;
  bool _settingsOpen = false;
  late bool _loopback;
  AnalysisResult? _result;

  @override
  void initState() {
    super.initState();
    final endpoint = widget.initialEndpoint ?? DecisionEndpoint.fromEnvironment();
    _baseController = TextEditingController(text: endpoint.baseUrl);
    _keyController = TextEditingController(text: endpoint.apiKey ?? '');
    _loopback = endpoint.isLoopback;
    final profile = widget.profile;
    if (profile == null) return;
    _ageController.text = '${profile.age}';
    _gradeController.text = profile.grade;
    _groupController.text = profile.standardGroup;
  }

  void _onAddressChanged(String value) {
    setState(() {
      _addressError = null;
      _loopback = DecisionEndpoint(baseUrl: value).isLoopback;
    });
  }

  @override
  void dispose() {
    _ageController.dispose();
    _gradeController.dispose();
    _groupController.dispose();
    _baseController.dispose();
    _keyController.dispose();
    super.dispose();
  }
  DecisionEndpoint get _endpoint => DecisionEndpoint(
        baseUrl: _baseController.text.trim(),
        apiKey: _keyController.text.trim().isEmpty ? null : _keyController.text.trim(),
      );

  Future<void> _analyze({required bool rebuild}) async {
    if (_sending) return;
    final addressError = DecisionEndpoint.validationError(_baseController.text);
    setState(() {
      _addressError = addressError;
      if (addressError != null) _settingsOpen = true;
    });
    if (addressError != null) return;
    if (rebuild) {
      if (!(_formKey.currentState?.validate() ?? false)) return;
      final request = widget.build(
        _sex,
        int.parse(_ageController.text),
        _gradeController.text.trim(),
        _groupController.text.trim(),
      );
      setState(() {
        _request = request;
        _noData = request == null;
        _result = null;
      });
      if (request == null) return;
    }
    final request = _request;
    if (request == null) return;
    setState(() => _sending = true);
    AnalysisResult result;
    try {
      result = await widget.analyze(request, _endpoint);
    } on Object catch (error) {
      result = AnalysisBlocked(message: '分析这一步出错了', advice: '$error');
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _result = result;
    });
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$label')),
    );
  }

  Widget _intro(ThemeData theme) {
    final profile = widget.profile;
    if (profile == null) {
      return Text(
        '这几项决定「和谁比」，应用里没有你的档案，所以每次都要问一遍。',
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '已按「我的资料」填好（更新于 ${formatProfileDate(profile.updatedAt)}）。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '在这里改动只影响这一次分析，不会写回档案。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        if (needsProfileRefresh(profile, DateTime.now())) ...[
          const SizedBox(height: 4),
          Text(
            '$profileStaleFact。可以到「我的资料」里更新，这一次仍按框里的值算。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Text('分析这一组', style: theme.textTheme.titleSmall),
      subtitle: Text(
        '发给决策服务，出一份中文报告',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _intro(theme),
              const SizedBox(height: 12),
              SegmentedButton<Sex>(
                segments: [
                  for (final sex in Sex.values)
                    ButtonSegment(value: sex, label: Text(sex.nameZh)),
                ],
                selected: {_sex},
                onSelectionChanged: (selected) => setState(() => _sex = selected.first),
              ),
              const SizedBox(height: 12),
              _field(
                controller: _ageController,
                label: '年龄',
                hint: '周岁，$decisionAgeMin–$decisionAgeMax',
                numeric: true,
                validator: (value) {
                  final age = int.tryParse(value ?? '');
                  if (age == null) return '请填年龄';
                  if (age < decisionAgeMin || age > decisionAgeMax) {
                    return '年龄要在 $decisionAgeMin 到 $decisionAgeMax 之间';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              _field(controller: _gradeController, label: '年级', hint: '例如：高一'),
              const SizedBox(height: 12),
              _field(controller: _groupController, label: '国标组别', hint: '例如：高中女子'),
              const SizedBox(height: 12),
              _serviceSettings(theme),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _sending ? null : () => _analyze(rebuild: true),
                child: Text(_sending ? '正在分析…' : '分析这一组'),
              ),
              if (_addressError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _addressError!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_noData) ...[
                const SizedBox(height: 12),
                Text(
                  '这一组没有可用于判定的帧，导不出请求。'
                  '（一组里至少要有两帧带时钟的画面才谈得上帧率与可信度。）',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_sending) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(
                  '正在把这一组发给决策服务…',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
              if (!_sending) ..._outcome(theme),
              if (_request != null) ...[
                const SizedBox(height: 12),
                _rawData(theme),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _outcome(ThemeData theme) {
    final result = _result;
    if (result == null) return const [];
    return switch (result) {
      AnalysisReported(:final report) => [
          const SizedBox(height: 12),
          AnalysisReport(report: report),
        ],
      AnalysisFailed(:final failure) => _failure(theme, failure),
      AnalysisBlocked blocked => _blocked(theme, blocked),
    };
  }

  List<Widget> _failure(ThemeData theme, DecisionFailure failure) {
    final scheme = theme.colorScheme;
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.error.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off_outlined, size: 18, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    failure.kind.message,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600, color: scheme.error),
                  ),
                ),
                if (failure.statusCode != null)
                  Text('HTTP ${failure.statusCode}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.outline)),
              ],
            ),
            const SizedBox(height: 6),
            Text(failure.kind.advice, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Text(failure.kind.reassurance, style: theme.textTheme.bodySmall),
            if (failure.detail != null) ...[
              const SizedBox(height: 6),
              Text(
                failure.detail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Courier New', 'monospace'],
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _analyze(rebuild: false),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _blocked(ThemeData theme, AnalysisBlocked blocked) {
    final scheme = theme.colorScheme;
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(blocked.message,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(blocked.advice, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    ];
  }

  Widget _serviceSettings(ThemeData theme) {
    return ExpansionTile(
      key: ValueKey(_settingsOpen),
      initiallyExpanded: _settingsOpen,
      tilePadding: EdgeInsets.zero,
      title: Text('服务设置', style: theme.textTheme.labelSmall),
      subtitle: Text(
        _baseController.text.trim().isEmpty
            ? '未填'
            : DecisionEndpoint(baseUrl: _baseController.text).normalizedBaseUrl,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
      ),
      children: [
        TextField(
          controller: _baseController,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: '服务地址',
            hintText: DecisionEndpoint.defaultBaseUrl,
            border: const OutlineInputBorder(),
            isDense: true,
            errorText: _addressError,
          ),
          onChanged: _onAddressChanged,
        ),
        if (_loopback) ...[
          const SizedBox(height: 6),
          Text(
            '默认地址指向手机自己的回环：要用 USB 线接上电脑，'
            '在电脑上执行 adb reverse tcp:8080 tcp:8080，'
            '手机上的这个地址才会通到电脑。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _keyController,
          decoration: const InputDecoration(
            labelText: '共享密钥（服务端没配就留空）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '密钥只作为 Authorization 头发出去，不落盘。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _rawData(ThemeData theme) {
    final request = _request!;
    final requestJson = const JsonEncoder.withIndent('  ').convert(request.toJson());
    final result = _result;
    final reported = result is AnalysisReported ? result : null;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('原始数据', style: theme.textTheme.labelSmall),
      children: [
        _jsonBlock(
          theme,
          label: '发出去的请求',
          text: requestJson,
          onCopy: () => _copy('这一组的请求 JSON', requestJson),
        ),
        if (reported != null) ...[
          const SizedBox(height: 8),
          if (reported.elapsed > Duration.zero)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                reported.isFromDevice
                    ? '本机判定用了 '
                        '${(reported.elapsed.inMilliseconds / 1000).toStringAsFixed(2)} 秒'
                        '（没有网络往返）'
                    : '端侧实测往返 '
                        '${(reported.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} 秒'
                        '（服务端自报 ${reported.report.tech.latencyMs} 毫秒，只算它自己那一段）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          _jsonBlock(
            theme,
            label: reported.isFromDevice ? '本机生成的响应' : '服务端返回的响应',
            text: reported.rawJson,
            onCopy: () => _copy(
              reported.isFromDevice ? '本机生成的响应 JSON' : '服务端返回的 JSON',
              reported.rawJson,
            ),
          ),
        ],
      ],
    );
  }

  Widget _jsonBlock(
    ThemeData theme, {
    required String label,
    required String text,
    required VoidCallback onCopy,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.labelLarge)),
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制'),
            ),
          ],
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier New', 'monospace'],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool numeric = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters: [
        if (numeric) FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(20),
      ],
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      validator: validator ??
          (value) => (value == null || value.trim().isEmpty) ? '请填$label' : null,
    );
  }
}
