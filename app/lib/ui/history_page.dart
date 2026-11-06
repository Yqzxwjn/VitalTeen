//历史记录页，只读
library;

import 'package:flutter/material.dart';

import '../app/action_spec.dart' show repUnitText;
import '../app/history.dart';
import '../app/session_record.dart';
import 'design.dart';
import 'heatmap_card.dart';
import 'illustration_slot.dart';
import 'theme.dart' show tabularFigures;

/// 练习记录。
///
/// 一种「没有」是空的，另一种是「有记录但没有分」—— 这一页用三个不同的
/// 位置说这两件事，绝不拿 0 顶替：空页是一整块邀请，平均分缺数据是「—」，
/// 而连续天数是真的 0。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.records, this.onStartTraining});

  final List<SessionRecord> records;

  /// 空状态里那个出口。外面（四标签外壳）接的是「切回开始运动」——
  /// 一个刚装上的应用第一次走到这一屏时，最该看到的就是这个动作。
  final VoidCallback? onStartTraining;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('练习记录'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: records.isEmpty
            ? _EmptyState(onStartTraining: onStartTraining)
            : _HistoryList(records: records),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onStartTraining});
  final VoidCallback? onStartTraining;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 空状态要**在可视区里居中**，而不是贴着标题栏往下堆。
        // 先给一个等于可视高度的最小高度，内容比它高时照样能滚。
        final minHeight = (constraints.maxHeight - Space.s600).clamp(
          0.0,
          double.infinity,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s300,
            vertical: Space.s300,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 168,
                      child: IllustrationSlot(
                        path: 'assets/images/empty_history.webp',
                        fit: BoxFit.contain,
                        fallback: const _EmptyMark(),
                      ),
                    ),
                    const SizedBox(height: Space.s400),
                    Text(
                      '还没有练习记录',
                      textAlign: TextAlign.center,
                      style: AppText.heading6.copyWith(color: AppColors.ink),
                    ),
                    const SizedBox(height: Space.s100),
                    Text(
                      '练完一组之后，这里会记下那一次的次数和姿势分。',
                      textAlign: TextAlign.center,
                      style: AppText.caption2.copyWith(
                        color: AppColors.inkSoft,
                        height: 1.7,
                      ),
                    ),
                    if (onStartTraining != null) ...[
                      const SizedBox(height: Space.s300),
                      SizedBox(
                        width: 200,
                        child: FilledButton(
                          onPressed: onStartTraining,
                          child: const Text('去选一个动作'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 空状态那张图的兜底：一块浅底 + 一个还没被点亮的 3×3 打卡格。
///
/// 选的是热力图的语言（这一页本来就有一张热力图），而不是一个通用的
/// 「空盒子」——它说的是「这里以后会长出你的打卡记录」。
class _EmptyMark extends StatelessWidget {
  const _EmptyMark();

  static const double _cell = 16;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brandTint,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row < 3; row++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: row == 2 ? 0 : _gap,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var col = 0; col < 3; col++)
                      Padding(
                        padding: EdgeInsets.only(
                          right: col == 2 ? 0 : _gap,
                        ),
                        child: Container(
                          width: _cell,
                          height: _cell,
                          decoration: BoxDecoration(
                            color: row == 1 && col == 1
                                ? AppColors.brand
                                : AppColors.brand.withValues(alpha: 0.18),
                            borderRadius: Radii.xsAll,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.records});
  final List<SessionRecord> records;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final summary = summarize(records, now);
    final groups = groupByDay(records);
    return AppPageBody(
      children: [
        _SummaryCard(summary: summary),
        const SizedBox(height: Space.s300),
        HeatmapCard(records: records, now: now),
        const SizedBox(height: Space.s400),
        for (final group in groups) ...[
          _DayHeader(
            label: historyDayLabel(group.day, now),
            setCount: group.records.length,
          ),
          _DayCard(records: group.records),
          const SizedBox(height: Space.s300),
        ],
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.setCount});
  final String label;
  final int setCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: Space.s50,
        right: Space.s50,
        bottom: Space.s100,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            label,
            style: AppText.title2.copyWith(
              color: AppColors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            '$setCount 组',
            style: AppText.caption5.copyWith(color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}

/// 一天一张卡，卡里每一组一行，行间用细线分开。
///
/// 一组一张卡会长出九条边 —— 边多了之后，读的人先看见框，后看见内容。
class _DayCard extends StatelessWidget {
  const _DayCard({required this.records});
  final List<SessionRecord> records;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < records.length; i++) ...[
            if (i > 0) const Hairline(indent: Space.s200, endIndent: Space.s200),
            _RecordRow(record: records[i]),
          ],
        ],
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record});
  final SessionRecord record;

  @override
  Widget build(BuildContext context) {
    final score = record.score;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s200,
        vertical: Space.s200,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        record.actionNameZh,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title3.copyWith(
                          color: AppColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (record.provisional) ...[
                      const SizedBox(width: Space.s75),
                      const StatusTag(
                        '暂定',
                        foreground: AppColors.warningInk,
                        background: AppColors.orangeTint,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.s25),
                Text(
                  '${historyClockText(record.finishedAt)} · '
                  '${record.repCount} ${repUnitText(record.isTimed)}',
                  style: AppText.caption5.copyWith(color: AppColors.inkSoft),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s100),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                score?.toString() ?? '—',
                style: AppText.heading6.copyWith(
                  color: score == null ? AppColors.inkFaint : AppColors.ink,
                  fontWeight: FontWeight.w600,
                  fontFeatures: tabularFigures,
                ),
              ),
              Text(
                '参考分',
                style: AppText.caption5.copyWith(color: AppColors.inkFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final HistorySummary summary;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const EyebrowLabel('练习概览'),
          const SizedBox(height: Space.s200),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Stat(
                label: '练习次数',
                value: '${summary.totalCount}',
                unit: '组',
              ),
              _Stat(
                label: '平均姿势分',
                value: summary.averageScore?.toString() ?? '—',
              ),
              _Stat(
                label: '连续天数',
                value: '${summary.streakDays}',
                unit: '天',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final missing = value == '—';
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AppText.heading4.copyWith(
                  color: missing ? AppColors.inkFaint : AppColors.ink,
                  fontWeight: FontWeight.w600,
                  fontFeatures: tabularFigures,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: Space.s25),
                Text(
                  unit!,
                  style: AppText.caption4.copyWith(color: AppColors.inkFaint),
                ),
              ],
            ],
          ),
          const SizedBox(height: Space.s25),
          Text(
            label,
            style: AppText.caption5.copyWith(color: AppColors.inkSoft),
          ),
        ],
      ),
    );
  }
}
