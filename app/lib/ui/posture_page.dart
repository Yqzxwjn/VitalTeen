//体态倾向页：反复出现的特征 + 一组矫正练习
library;

import 'package:flutter/material.dart';

import '../app/plan_catalog.dart';
import '../app/posture_analysis.dart';
import '../app/profile.dart';
import '../app/session_record.dart';
import 'app_icons.dart';
import 'design.dart';
import 'illustration_slot.dart';
import 'outline_tag.dart';

class PosturePage extends StatefulWidget {
  const PosturePage({
    super.key,
    required this.records,
    required this.profile,
    this.now,
    this.loadPlans,
  });
  final List<SessionRecord> records;
  final Profile profile;
  final DateTime Function()? now;
  final Future<PlanCatalog> Function()? loadPlans;
  @override
  State<PosturePage> createState() => _PosturePageState();
}

class _PosturePageState extends State<PosturePage> {
  PlanCatalog? _catalog;
  bool _catalogFailed = false;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    try {
      final catalog = await (widget.loadPlans ?? loadPlanCatalog)();
      if (!mounted) return;
      setState(() => _catalog = catalog);
    } on Object {
      if (!mounted) return;
      setState(() => _catalogFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final analysis = analyzePostures(widget.records, (widget.now ?? DateTime.now)());
    return Scaffold(
      appBar: AppBar(
        title: const Text('体态倾向'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: AppPageBody(
          children: [
            ..._content(analysis),
            const SizedBox(height: Space.s300),
            const _ScopeDisclosure(),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(PostureAnalysis analysis) {
    if (!analysis.hasAnyRecordedData) return const [_EmptyState()];
    if (!analysis.hasEnoughData) {
      return [
        _NotEnough(
          setsNeeded: analysis.setsNeeded,
          eligibleSets: analysis.eligibleSets,
        ),
      ];
    }
    if (analysis.findings.isEmpty) {
      return [
        _NoFindings(
          windowDays: analysis.windowDays,
          eligibleSets: analysis.eligibleSets,
        ),
      ];
    }
    return [
      _Headline(windowDays: analysis.windowDays),
      const SizedBox(height: Space.s200),
      for (final finding in analysis.findings)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s200),
          child: _FindingCard(
            finding: finding,
            windowDays: analysis.windowDays,
            age: widget.profile.age,
            catalog: _catalog,
            catalogFailed: _catalogFailed,
          ),
        ),
    ];
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.s400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 168,
            child: IllustrationSlot(
              path: 'assets/images/empty_posture.webp',
              fit: BoxFit.contain,
              fallback: const _EmptyMark(),
            ),
          ),
          const SizedBox(height: Space.s400),
          Text(
            '还没有可以看的记录',
            textAlign: TextAlign.center,
            style: AppText.heading6.copyWith(color: AppColors.ink),
          ),
          const SizedBox(height: Space.s100),
          Text(
            '这一页看的是动作里反复出现的特征 —— 上身前倾、左右用力不均。'
            '练完几组之后，这里会告诉你哪些特征出现得比较经常。\n\n'
            '这些特征从这一版才开始记录，更早的练习不在里面。',
            textAlign: TextAlign.center,
            style: AppText.caption2.copyWith(
              color: AppColors.inkSoft,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态那种「多看几次才看得见」的意思：同一个标记叠了三层。
class _EmptyMark extends StatelessWidget {
  const _EmptyMark();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brandTint,
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (var i = 2; i >= 0; i--)
              Transform.translate(
                offset: Offset(i * 12.0, i * -10.0),
                child: AppIcon(
                  AppGlyph.posture,
                  size: 64,
                  color: AppColors.brand.withValues(alpha: 0.12 + i * 0.16),
                  strokeWidth: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NotEnough extends StatelessWidget {
  const _NotEnough({required this.setsNeeded, required this.eligibleSets});
  final int setsNeeded;
  final int eligibleSets;

  @override
  Widget build(BuildContext context) {
    return _CenteredCard(
      title: '再练 $setsNeeded 组',
      body: '已经有 $eligibleSets 组可以看了。够 $postureMinEligibleSets 组之后，'
          '才谈得上「反复出现」—— 两三组里出现一次，也可能只是那天没睡醒。',
    );
  }
}

class _NoFindings extends StatelessWidget {
  const _NoFindings({required this.windowDays, required this.eligibleSets});
  final int windowDays;
  final int eligibleSets;

  @override
  Widget build(BuildContext context) {
    return _CenteredCard(
      title: '近 $windowDays 天没有反复出现的特征',
      body: '已记录的 $eligibleSets 组里，没有哪个特征出现得足够经常。'
          '这一条要么是好消息，要么只是最近练得少、动作还没稳定下来。',
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.windowDays});
  final int windowDays;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: Space.s50),
      child: Text(
        '下面是最近 $windowDays 天里看出来的，出现得越经常排在越前面。',
        style: AppText.caption5.copyWith(color: AppColors.inkSoft),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({
    required this.finding,
    required this.windowDays,
    required this.age,
    required this.catalog,
    required this.catalogFailed,
  });
  final PostureFinding finding;
  final int windowDays;
  final int age;
  final PlanCatalog? catalog;
  final bool catalogFailed;

  @override
  Widget build(BuildContext context) {
    final definition = finding.definition;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  definition.titleZh,
                  style: AppText.title2.copyWith(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: Space.s75),
              _BandChip(band: finding.band),
            ],
          ),
          const SizedBox(height: Space.s75),
          Text(
            definition.summaryZh,
            style: AppText.caption2.copyWith(
              color: AppColors.inkSoft,
              height: 1.6,
            ),
          ),
          const SizedBox(height: Space.s100),
          // 依据行是这张卡的**全部依据**：没有它，上面那句话就只剩一个形容词。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s100,
              vertical: Space.s75,
            ),
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: Radii.smAll,
            ),
            child: Text(
              '近 $windowDays 天里，${finding.eligibleSets} 组中有 '
              '${finding.setsWithFault} 组出现',
              style: AppText.caption5.copyWith(color: AppColors.inkSoft),
            ),
          ),
          const SizedBox(height: Space.s100),
          const ProvisionalTag(),
          const SizedBox(height: Space.s200),
          const Hairline(),
          const SizedBox(height: Space.s100),
          Text(
            definition.colloquialZh,
            style: AppText.caption5.copyWith(
              color: AppColors.inkSoft,
              height: 1.7,
            ),
          ),
          const SizedBox(height: Space.s50),
          Text(
            definition.boundaryZh,
            style: AppText.caption5.copyWith(
              color: AppColors.inkFaint,
              height: 1.7,
            ),
          ),
          _practice(context),
        ],
      ),
    );
  }

  Widget _practice(BuildContext context) {
    if (catalogFailed) {
      return _note('建议练习的清单这次没读出来，上面那条不受影响。重装一次应用应该能修好。');
    }
    final catalog = this.catalog;
    if (catalog == null) return const SizedBox.shrink();
    final selection = catalog.selectForFaults(
      [finding.definition.faultCode],
      age: age,
      limit: 2,
    );
    if (selection.plans.isEmpty) {
      return _note('这一条暂时没有适合的练习推荐 —— 也可能只是没有适合你这个年龄段的。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: Space.s200),
        Text(
          '可以这样练',
          style: AppText.body4.copyWith(color: AppColors.ink),
        ),
        if (selection.includesUnreviewed)
          Padding(
            padding: const EdgeInsets.only(top: Space.s25),
            child: Text(
              '这几个动作还没有经过体育专业成员核定，先照着做，别自己加量。',
              style: AppText.caption5.copyWith(color: AppColors.inkFaint),
            ),
          ),
        for (final plan in selection.plans) _planBlock(plan),
      ],
    );
  }

  Widget _planBlock(CorrectionPlan plan) {
    return Container(
      margin: const EdgeInsets.only(top: Space.s100),
      padding: const EdgeInsets.all(Space.s100),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: Radii.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            plan.nameZh,
            style: AppText.body5.copyWith(
              color: AppColors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Space.s25),
          Text(
            plan.goal,
            style: AppText.caption5.copyWith(color: AppColors.inkSoft),
          ),
          if (plan.keyCues.isNotEmpty) ...[
            const SizedBox(height: Space.s75),
            for (final cue in plan.keyCues) _Bullet(cue),
          ],
          const SizedBox(height: Space.s50),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '组次：${plan.dosageText}',
                  style: AppText.caption5.copyWith(color: AppColors.ink),
                ),
              ),
              if (!plan.dosageRatified) ...[
                const SizedBox(width: Space.s50),
                const OutlineTag('剂量待核定'),
              ],
            ],
          ),
          for (final item in plan.contraindications)
            Container(
              margin: const EdgeInsets.only(top: Space.s75),
              padding: const EdgeInsets.all(Space.s75),
              decoration: BoxDecoration(
                color: AppColors.dangerTint,
                borderRadius: Radii.smAll,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: AppIcon(
                      AppGlyph.warning,
                      size: 16,
                      color: AppColors.danger,
                      strokeWidth: 1.5,
                    ),
                  ),
                  const SizedBox(width: Space.s75),
                  Expanded(
                    child: Text(
                      item,
                      style: AppText.caption5.copyWith(
                        color: AppColors.danger,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.s100),
      child: Text(
        text,
        style: AppText.caption5.copyWith(
          color: AppColors.inkFaint,
          height: 1.6,
        ),
      ),
    );
  }
}

class _BandChip extends StatelessWidget {
  const _BandChip({required this.band});
  final PostureBand band;

  @override
  Widget build(BuildContext context) {
    final strong = band == PostureBand.persistent;
    return StatusTag(
      bandLabelZh(band),
      foreground: strong ? AppColors.warningInk : AppColors.brand,
      background: strong ? AppColors.orangeTint : AppColors.brandTint,
    );
  }
}

/// 范围声明。**不折起来，也不只在有结论时才出现。**
///
/// 「判不了脊柱侧弯」这句必须在页面上：不写的话，用户会把「这里没提」
/// 读成「这里没查出来问题」—— 那是把测不出读成了正常。
class _ScopeDisclosure extends StatelessWidget {
  const _ScopeDisclosure();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.s200),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: Radii.lgAll,
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const AppIcon(
                AppGlyph.info,
                size: 16,
                color: AppColors.inkFaint,
                strokeWidth: 1.5,
              ),
              const SizedBox(width: Space.s75),
              Text(
                '看这一页前请知道',
                style: AppText.caption3.copyWith(color: AppColors.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: Space.s75),
          for (final item in const [
            kPostureScopeNote,
            kPostureScoliosisNote,
            kPostureStopNote,
          ])
            _Bullet(item, color: AppColors.inkFaint),
        ],
      ),
    );
  }
}

/// 一条前置圆点的条目。
///
/// 用圆点而不是「· 」：中文标点里的间隔号是**夹在两个字之间**的，
/// 摆在行首会被读成一个错字。这里画的是真正的小圆点，缩进也由它对齐。
class _Bullet extends StatelessWidget {
  const _Bullet(this.text, {this.color = AppColors.inkSoft});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.s50),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 3,
              height: 3,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: Space.s75),
          Expanded(
            child: Text(
              text,
              style: AppText.caption5.copyWith(color: color, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _CenteredCard extends StatelessWidget {
  const _CenteredCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
        vertical: Space.s400,
        horizontal: Space.s300,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.heading6.copyWith(color: AppColors.ink),
          ),
          const SizedBox(height: Space.s100),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppText.caption2.copyWith(
              color: AppColors.inkSoft,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}
