//站位自检清单，把「能不能开始」拆成四行
library;

import 'package:flutter/material.dart';

import '../app/camera_position_check.dart';

enum CheckLine {
  present,
  inFrame,
  distance,
  view,
}

enum CheckState { unknown, ok, warning, blocked }

class _Row {
  const _Row(this.line, this.state, this.detail);
  final CheckLine line;
  final CheckState state;
  final String? detail;
}

const Map<CheckLine, String> _titles = {
  CheckLine.present: '人在画面里',
  CheckLine.inFrame: '全身入镜',
  CheckLine.distance: '距离合适',
  CheckLine.view: '站成 45°',
};

const Map<CheckLine, IconData> _icons = {
  CheckLine.present: Icons.person_outline,
  CheckLine.inFrame: Icons.accessibility_new,
  CheckLine.distance: Icons.straighten,
  CheckLine.view: Icons.threed_rotation,
};

class PositionChecklist extends StatelessWidget {
  const PositionChecklist({
    super.key,
    required this.report,
    required this.sawFrame,
    required this.cameraRunning,
    this.framingHint,
  });
  final PositionReport report;
  final bool sawFrame;
  final bool cameraRunning;
  final String? framingHint;

  @override
  Widget build(BuildContext context) {
    final rows = _rowsOf(report, sawFrame, framingHint);
    final banner = _bannerText();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (banner != null) ...[
          _banner(context, banner),
          const SizedBox(height: 8),
        ],
        for (final row in rows) _tile(context, row),
      ],
    );
  }

  String? _bannerText() {
    if (sawFrame) return null;
    if (!cameraRunning) return '正在启动相机…';
    return '请站到画面里 —— 让整个人出现在镜头中间，离手机大约两米。';
  }

  Widget _banner(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static List<_Row> _rowsOf(
    PositionReport report,
    bool sawFrame,
    String? framingHint,
  ) {
    final byCode = {for (final issue in report.issues) issue.code: issue};
    CheckState worst(Iterable<PositionIssueCode> codes) {
      var state = CheckState.ok;
      for (final code in codes) {
        final issue = byCode[code];
        if (issue == null) continue;
        state = issue.blocking ? CheckState.blocked : CheckState.warning;
        if (state == CheckState.blocked) break;
      }
      return state;
    }
    String? detailOf(Iterable<PositionIssueCode> codes) {
      for (final code in codes) {
        final issue = byCode[code];
        if (issue != null && issue.blocking) return issue.message;
      }
      for (final code in codes) {
        final issue = byCode[code];
        if (issue != null) return issue.message;
      }
      return null;
    }
    if (!sawFrame) {
      return [
        for (final line in CheckLine.values)
          _Row(line, CheckState.unknown, null),
      ];
    }
    const absentCodes = [
      PositionIssueCode.missingTorso,
      PositionIssueCode.missingLegs,
    ];
    const frameCodes = [
      ...absentCodes,
      PositionIssueCode.missingLeftFoot,
      PositionIssueCode.missingFeet,
    ];
    const distanceCodes = [
      PositionIssueCode.tooFar,
      PositionIssueCode.tooClose,
      PositionIssueCode.cropped,
    ];
    const viewCodes = [
      PositionIssueCode.facingFront,
      PositionIssueCode.notFacingFront,
      PositionIssueCode.facingSide,
      PositionIssueCode.viewUnstable,
    ];
    final allPointsMissing = absentCodes.every(byCode.containsKey);
    final presentState = allPointsMissing
        ? CheckState.blocked
        : CheckState.ok;
    return [
      _Row(
        CheckLine.present,
        presentState,
        allPointsMissing
            ? (framingHint ?? '让整个人进到画面中间，别站在边上。')
            : null,
      ),
      _Row(
        CheckLine.inFrame,
        worst(frameCodes),
        detailOf(frameCodes),
      ),
      _Row(
        CheckLine.distance,
        worst(distanceCodes),
        detailOf(distanceCodes),
      ),
      _Row(
        CheckLine.view,
        worst(viewCodes),
        detailOf(viewCodes),
      ),
    ];
  }

  Widget _tile(BuildContext context, _Row row) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (row.state) {
      CheckState.unknown => (scheme.outline, Icons.help_outline),
      CheckState.ok => (Colors.green.shade700, Icons.check_circle_outline),
      CheckState.warning => (Colors.orange.shade800, Icons.info_outline),
      CheckState.blocked => (scheme.error, Icons.error_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_icons[row.line], size: 16, color: scheme.outline),
                    const SizedBox(width: 4),
                    Text(
                      _titles[row.line]!,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (row.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.detail!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
