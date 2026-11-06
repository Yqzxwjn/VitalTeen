///用户资料，编码成一段 JSON 存在本机
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'decision_request.dart' show Sex, decisionAgeMax, decisionAgeMin;

const int profileSchemaVersion = 2;

const int profileNicknameMaxLength = 12;

const int profileHeightMinCm = 80;
const int profileHeightMaxCm = 250;
const double profileWeightMinKg = 15;
const double profileWeightMaxKg = 200;

@immutable
class Profile {
  const Profile({
    required this.sex,
    required this.age,
    required this.grade,
    required this.standardGroup,
    required this.heightCm,
    required this.weightKg,
    required this.updatedAt,
    this.nickname = '',
  });
  final String nickname;
  final Sex sex;
  final int age;
  final String grade;
  final String standardGroup;
  final int heightCm;
  final double weightKg;
  final DateTime updatedAt;

  Profile copyWith({
    String? nickname,
    Sex? sex,
    int? age,
    String? grade,
    String? standardGroup,
    int? heightCm,
    double? weightKg,
    DateTime? updatedAt,
  }) {
    return Profile(
      nickname: nickname ?? this.nickname,
      sex: sex ?? this.sex,
      age: age ?? this.age,
      grade: grade ?? this.grade,
      standardGroup: standardGroup ?? this.standardGroup,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': profileSchemaVersion,
        'nickname': nickname,
        'sex': sex.wireName,
        'age': age,
        'grade': grade,
        'standard_group': standardGroup,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'updated_at_ms': updatedAt.millisecondsSinceEpoch,
      };
  String encode() => jsonEncode(toJson());

  static Profile? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;
    final version = _int(parsed['v']);
    if (version != 1 && version != 2) return null;
    final nickname = version == 1
        ? ''
        : _nickname(parsed['nickname']);
    if (nickname == null) return null;
    final sex = _sex(parsed['sex']);
    if (sex == null) return null;
    final age = _int(parsed['age']);
    if (age == null || age < decisionAgeMin || age > decisionAgeMax) return null;
    final grade = _shortText(parsed['grade']);
    if (grade == null) return null;
    final group = _shortText(parsed['standard_group']);
    if (group == null) return null;
    final height = _int(parsed['height_cm']);
    if (height == null ||
        height < profileHeightMinCm ||
        height > profileHeightMaxCm) {
      return null;
    }
    final weight = _double(parsed['weight_kg']);
    if (weight == null ||
        weight < profileWeightMinKg ||
        weight > profileWeightMaxKg) {
      return null;
    }
    final ms = _int(parsed['updated_at_ms']);
    if (ms == null) return null;
    return Profile(
      nickname: nickname,
      sex: sex,
      age: age,
      grade: grade,
      standardGroup: group,
      heightCm: height,
      weightKg: weight,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  static Sex? _sex(Object? value) {
    if (value is! String) return null;
    for (final sex in Sex.values) {
      if (sex.wireName == value) return sex;
    }
    return null;
  }
  static int? _int(Object? value) => value is int ? value : null;

  static double? _double(Object? value) {
    if (value is double) return value.isFinite ? value : null;
    if (value is int) return value.toDouble();
    return null;
  }

  static String? _shortText(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 20) return null;
    return trimmed;
  }

  static String? _nickname(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.length > profileNicknameMaxLength) return null;
    return trimmed;
  }
}

/// 按年龄与性别自动分国标组别。年龄是近似（入学早晚差一岁），
/// 但这一项只决定「跟谁的标准比」，比自己选错一档要轻。
String standardGroupFor({required Sex sex, required int age}) {
  final stage = switch (age) {
    <= 8 => '小学一二年级',
    <= 10 => '小学三四年级',
    <= 12 => '小学五六年级',
    <= 15 => '初中',
    <= 18 => '高中',
    _ => '大学',
  };
  return '$stage${sex == Sex.male ? '男子' : '女子'}';
}

bool needsProfileRefresh(Profile profile, DateTime now) =>
    now.difference(profile.updatedAt).inDays >= 365;
const String profileStaleFact = '这份资料填于一年多前，年龄至少长了一岁';

String profileDisplayName(Profile profile) =>
    profile.nickname.isEmpty ? '同学' : profile.nickname;

String profileSummaryLine(Profile profile) =>
    '${profile.sex.nameZh} · ${profile.age} 岁 · '
    '${profile.grade} · ${profile.standardGroup}';

String profileBodyLine(Profile profile) =>
    '身高 ${profile.heightCm} cm · 体重 ${profileWeightText(profile.weightKg)} kg';

String profileWeightText(double kg) =>
    kg.toStringAsFixed(kg == kg.roundToDouble() ? 0 : 1);

String profileBoundText(num value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

String formatProfileDate(DateTime at) {
  final local = at.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
