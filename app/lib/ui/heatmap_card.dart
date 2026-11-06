library;

import 'package:flutter/material.dart';

import '../app/history.dart';
import '../app/session_record.dart';
import 'theme.dart';

const double _chipSize = 14;

const double _chipGap = 3;

const double _pitch = _chipSize + _chipGap;

const double _monthRowHeight = 14;

const double _gutterWidth = 16;

const Map<int, String> _gutterRows = {0: '一', 2: '三', 4: '五'};

const double _labelSlack = 24;

const double _infoFontSize = 12;
const double _infoLineHeight = 1.4;

const double _legendChip = 12;

final List<BoxDecoration> _chipDecorations = [
  for (final color in vitalHeatRamp)
    BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
];

class HeatmapCard extends StatefulWidget {
  const HeatmapCard({super.key, required this.records, required this.now});
  final List<SessionRecord> records;
  final DateTime now;
  @visibleForTesting
  static const Key scrollKey = ValueKey('heatmap-scroll');
  @visibleForTesting
  static const Key infoKey = ValueKey('heatmap-info');
  @visibleForTesting
  static Key legendKey(int level) => ValueKey('heatmap-legend-$level');
  @visibleForTesting
  static Key dayKey(DateTime day) => ValueKey(
        'heatmap-day-${day.year}'
        '-${day.month.toString().padLeft(2, '0')}'
        '-${day.day.toString().padLeft(2, '0')}',
      );
  @override
  State<HeatmapCard> createState() => _HeatmapCardState();
}

class _HeatmapCardState extends State<HeatmapCard> {
  DateTime? _selected;

  void _toggle(HeatmapDay cell) {
    setState(() => _selected = _selected == cell.day ? null : cell.day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grid = buildHeatmap(widget.records, widget.now);
    final selected = _selected == null ? null : grid.dayOf(_selected!);
    final info = selected == null
        ? heatmapOverviewText(grid)
        : heatmapDayText(selected, widget.records, widget.now);
    final weeks = grid.weeks.length;
    final contentWidth = _labelSlack + weeks * _pitch;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _gutter(theme),
                Expanded(
                  child: SingleChildScrollView(
                    key: HeatmapCard.scrollKey,
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: SizedBox(
                      width: contentWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _monthRow(theme, grid, weeks, contentWidth),
                          Padding(
                            padding: const EdgeInsets.only(left: _labelSlack),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var row = 0; row < 7; row++)
                                  SizedBox(
                                    height: _pitch,
                                    child: Row(
                                      children: [
                                        for (final week in grid.weeks)
                                          _cell(theme, week.days[row]),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: _infoHeight(context),
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  info,
                  key: HeatmapCard.infoKey,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: _infoFontSize,
                    height: _infoLineHeight,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _legend(theme),
          ],
        ),
      ),
    );
  }

  double _infoHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(_infoFontSize) *
          _infoLineHeight *
          2 +
      1;

  Widget _gutter(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      letterSpacing: 0,
      height: 1,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      width: _gutterWidth,
      child: Column(
        children: [
          const SizedBox(height: _monthRowHeight),
          for (var row = 0; row < 7; row++)
            SizedBox(
              height: _pitch,
              child: Center(
                child: Text(_gutterRows[row] ?? '', style: style),
              ),
            ),
        ],
      ),
    );
  }

  Widget _monthRow(
    ThemeData theme,
    HeatmapGrid grid,
    int weeks,
    double contentWidth,
  ) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      letterSpacing: 0,
      height: 1.2,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      width: contentWidth,
      height: _monthRowHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var w = 0; w < weeks; w++)
            if (grid.weeks[w].monthLabel case final label?)
              Positioned(
                right: (weeks - 1 - w) * _pitch.toDouble(),
                top: 0,
                child: Text(label, style: style),
              ),
        ],
      ),
    );
  }

  Widget _cell(ThemeData theme, HeatmapDay cell) {
    if (!cell.inWindow) {
      return const SizedBox(width: _pitch, height: _pitch);
    }
    final selected = cell.day == _selected;
    return SizedBox(
      width: _pitch,
      height: _pitch,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggle(cell),
        child: Container(
          key: HeatmapCard.dayKey(cell.day),
          decoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: theme.colorScheme.onSurface,
                    width: 1.5,
                  ),
                )
              : null,
          child: Center(
            child: Container(
              width: _chipSize,
              height: _chipSize,
              decoration: _chipDecorations[heatLevel(cell.sets)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legend(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      letterSpacing: 0,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('较少', style: style),
        const SizedBox(width: 6),
        for (var level = 0; level < vitalHeatRamp.length; level++) ...[
          if (level > 0) const SizedBox(width: 3),
          Container(
            key: HeatmapCard.legendKey(level),
            width: _legendChip,
            height: _legendChip,
            decoration: _chipDecorations[level],
          ),
        ],
        const SizedBox(width: 6),
        Text('较多', style: style),
      ],
    );
  }
}
