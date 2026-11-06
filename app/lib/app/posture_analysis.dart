///从练习记录里找反复出现的姿态倾向
library;

import 'package:flutter/foundation.dart';

import 'history.dart' show localDayOf;
import 'session_record.dart';

const int postureWindowDays = 30;

const int postureMinEligibleSets = 6;

@immutable
class PostureDefinition {
  const PostureDefinition({
    required this.id,
    required this.titleZh,
    required this.colloquialZh,
    required this.summaryZh,
    required this.boundaryZh,
    required this.faultCode,
  });
  final String id;
  final String titleZh;
  final String colloquialZh;
  final String summaryZh;
  final String boundaryZh;
  final String faultCode;
}

const List<PostureDefinition> kPostureDefinitions = [
  PostureDefinition(
    id: 'trunk_lean',
    titleZh: '上身前倾倾向',
    colloquialZh: '平时说的「圆背」「驼背」是这一类的说法',
    summaryZh: '蹲下和起身的时候，上身比参考位置更往前倾，而且不止一两次。',
    boundaryZh: '这里量的是下蹲时的前倾角，它受踝关节活动度、腿长比例影响，'
        '不是对脊柱形状的判断。',
    faultCode: 'EXCESSIVE_TRUNK_LEAN',
  ),
  PostureDefinition(
    id: 'asymmetry',
    titleZh: '左右用力不均倾向',
    colloquialZh: '也可以理解成「两边不平衡」',
    summaryZh: '左右两侧的膝角差反复超出参考值，身体在动作里有偏向一侧的习惯。',
    boundaryZh: '这是从两腿角度差读出来的，说的是这一次动作里左右不对称，'
        '不是任何一侧的骨骼形态问题。',
    faultCode: 'ASYMMETRY',
  ),
];

const Map<String, Set<String>> kPostureEligibleActions = {
  'EXCESSIVE_TRUNK_LEAN': {'SQUAT'},
  'ASYMMETRY': {'SQUAT'},
};

enum PostureBand {
  occasional,
  recurring,
  persistent,
}

const double postureRecurringRate = 0.3;
const double posturePersistentRate = 0.6;

@immutable
class PostureFinding {
  const PostureFinding({
    required this.definition,
    required this.setsWithFault,
    required this.eligibleSets,
  });
  final PostureDefinition definition;
  final int setsWithFault;
  final int eligibleSets;
  double get rate => setsWithFault / eligibleSets;

  PostureBand get band {
    if (rate >= posturePersistentRate) return PostureBand.persistent;
    if (rate >= postureRecurringRate) return PostureBand.recurring;
    return PostureBand.occasional;
  }
}

String bandLabelZh(PostureBand band) => switch (band) {
      PostureBand.occasional => '偶有',
      PostureBand.recurring => '反复',
      PostureBand.persistent => '持续',
    };

@immutable
class PostureAnalysis {
  const PostureAnalysis({
    required this.windowDays,
    required this.eligibleSets,
    required this.findings,
  });
  final int windowDays;
  final int eligibleSets;
  final List<PostureFinding> findings;
  bool get hasAnyRecordedData => eligibleSets > 0;
  bool get hasEnoughData => eligibleSets >= postureMinEligibleSets;
  int get setsNeeded =>
      eligibleSets >= postureMinEligibleSets
          ? 0
          : postureMinEligibleSets - eligibleSets;
}

PostureAnalysis analyzePostures(List<SessionRecord> records, DateTime now) {
  final cutoff = DateTime(now.year, now.month, now.day - postureWindowDays);
  var widest = 0;
  final findings = <PostureFinding>[];

  for (final definition in kPostureDefinitions) {
    final eligibleActions = kPostureEligibleActions[definition.faultCode];
    if (eligibleActions == null) continue;
    var eligible = 0;
    var withFault = 0;
    for (final record in records) {
      final faults = record.faultCounts;
      if (faults == null) continue;
      if (!eligibleActions.contains(record.actionCode)) continue;
      if (localDayOf(record.finishedAt).isBefore(cutoff)) continue;
      eligible++;
      if (faults.containsKey(definition.faultCode)) withFault++;
    }
    if (eligible > widest) widest = eligible;
    if (eligible < postureMinEligibleSets) continue;
    if (withFault == 0) continue;
    findings.add(PostureFinding(
      definition: definition,
      setsWithFault: withFault,
      eligibleSets: eligible,
    ));
  }
  findings.sort((a, b) {
    final byRate = b.rate.compareTo(a.rate);
    return byRate != 0 ? byRate : a.definition.id.compareTo(b.definition.id);
  });
  return PostureAnalysis(
    windowDays: postureWindowDays,
    eligibleSets: widest,
    findings: findings,
  );
}

const String kPostureScopeNote =
    '这一页说的是你练过的动作里反复出现的特征，来自手机对画面的判定，'
    '不是对身体状况的评估。判定用的阈值还没有经过体育专业成员核定，'
    '只作训练参考。这些量从本版本起才开始记录，更早的练习不在统计里。';

const String kPostureScoliosisNote =
    '这里判不了「脊柱侧弯」那类左右不对称：深蹲默认从侧面拍，画面里两条腿'
    '几乎重叠，我们也没有量肩线、髋线高低差的特征。测不出来，所以不写。';

const String kPostureStopNote =
    '做这些动作时如果出现疼痛，请停下来，并告诉体育老师或医生。';
