//首页那份动作清单常量表
library;

import 'package:flutter/material.dart';

enum ExerciseStatus {
  live,
  reserved,
}

@immutable
class ExerciseEntry {
  const ExerciseEntry({
    required this.code,
    required this.nameZh,
    required this.tagline,
    required this.status,
    required this.icon,
    this.note,
  });
  final String code;
  final String nameZh;
  final String tagline;
  final ExerciseStatus status;
  final IconData icon;
  final String? note;
  bool get isLive => status == ExerciseStatus.live;
}

@immutable
class ExerciseSection {
  const ExerciseSection({
    required this.title,
    required this.entries,
    required this.accent,
  });
  final String title;
  final List<ExerciseEntry> entries;

  /// 这一组的识别色。**只有一个颜色，不是渐变。**
  ///
  /// 卡片上它是图位那块浅底的色相，也是简笔人形描边的颜色。九个动作排下来，
  /// 一组一个色相足够区分；每组再配一道渐变，清单会变成一条彩虹。
  final Color accent;
}

const List<ExerciseSection> kExerciseSections = [
  ExerciseSection(
    title: '下肢力量',
    accent: Color(0xFF0B3D91),
    entries: [
      ExerciseEntry(
        code: 'SQUAT',
        nameZh: '深蹲',
        tagline: '手机架在侧前方 45°，它会跟着你数，'
            '并告诉你膝、髋、踝哪里可以更好。',
        status: ExerciseStatus.live,
        icon: Icons.sports_gymnastics,
      ),
      ExerciseEntry(
        code: 'SLJ',
        nameZh: '立定跳远',
        tagline: '看起跳、腾空、落地三段：双脚是不是同时起跳、同时落地，落地有没有缓冲。',
        status: ExerciseStatus.live,
        note: '只判动作规范性，测不出厘米成绩',
        icon: Icons.directions_run,
      ),
    ],
  ),
  ExerciseSection(
    title: '心肺与协调',
    accent: Color(0xFF0E8FC4),
    entries: [
      ExerciseEntry(
        code: 'JJ',
        nameZh: '开合跳',
        tagline: '正面机位，看开合与上举的幅度到不到位，膝内扣只作提示。',
        status: ExerciseStatus.live,
        note: '前后方向和落地缓冲测不出来：正面机位下这两个量都不成立',
        icon: Icons.accessibility_new,
      ),
      ExerciseEntry(
        code: 'ROPE',
        nameZh: '跳绳',
        tagline: '数得出次数，也看得出落地有没有缓冲、身体有没有前倾、是不是单脚落地。',
        status: ExerciseStatus.live,
        note: '计数是估算：它看得见人，看不见绳子 · 交替跳和前后移动测不出来',
        icon: Icons.loop,
      ),
    ],
  ),
  ExerciseSection(
    title: '上肢与核心',
    accent: Color(0xFFDD7A11),
    entries: [
      ExerciseEntry(
        code: 'PU',
        nameZh: '俯卧撑',
        tagline: '侧视机位，看你下得够不够深、撑起来直不直、身体有没有成一条线。',
        status: ExerciseStatus.live,
        note: '肘外展测不出来：侧视画面上「往两侧张」与「往前摆」同形',
        icon: Icons.horizontal_rule,
      ),
      ExerciseEntry(
        code: 'PULLUP',
        nameZh: '引体向上',
        tagline: '侧视机位，看有没有回到直臂悬垂、下颌有没有过杠，以及摆动幅度。',
        status: ExerciseStatus.live,
        note: '悬垂休息超时测不出来：它要跨次计时 · 腿的摆动与屈膝也不判',
        icon: Icons.vertical_align_top,
      ),
    ],
  ),
  ExerciseSection(
    title: '核心稳定',
    accent: Color(0xFF3F8C12),
    entries: [
      ExerciseEntry(
        code: 'PLANK',
        nameZh: '平板支撑',
        tagline: '计时制：每一段撑了多久，以及中途塌腰、拱起、肘撑得太直几次。',
        status: ExerciseStatus.live,
        note: '趴着不动与真的撑住分不出：单目看不出身体离地多高 · 头颈位置也不判',
        icon: Icons.timer_outlined,
      ),
      ExerciseEntry(
        code: 'SU',
        nameZh: '仰卧起坐',
        tagline: '侧视机位，看肩胛有没有真的贴到垫上、起身时髋有没有顶起来借力。',
        status: ExerciseStatus.live,
        note: '「双手抱头」「肘触膝」测不出来：贴没贴上是个接触关系，2D 点距分不出',
        icon: Icons.airline_seat_recline_normal,
      ),
    ],
  ),
  ExerciseSection(
    title: '柔韧',
    accent: Color(0xFF5B3BB8),
    entries: [
      ExerciseEntry(
        code: 'SRT',
        nameZh: '坐位体前屈',
        tagline: '侧视机位，看腿有没有伸直、有没有靠来回弹把上身甩出去。',
        status: ExerciseStatus.live,
        note: '只判动作规范性，测不出厘米成绩：「双手并拢」也没做，那要一个新特征',
        icon: Icons.straighten,
      ),
    ],
  ),
];

List<ExerciseEntry> allExercises() => [
      for (final section in kExerciseSections) ...section.entries,
    ];

ExerciseEntry? exerciseByCode(String code) {
  for (final entry in allExercises()) {
    if (entry.code == code) return entry;
  }
  return null;
}
