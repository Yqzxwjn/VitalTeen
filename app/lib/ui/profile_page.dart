//我的资料：填写与编辑，档案唯一的写入者
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/decision_request.dart' show Sex, decisionAgeMax, decisionAgeMin;
import '../app/profile.dart';
import '../platform/profile_store.dart';
import 'app_icons.dart';
import 'avatar_image.dart';
import 'design.dart';
import 'privacy_note.dart';
import 'theme.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    this.initial,
    required this.onSaved,
    required this.onCancel,
    this.avatarPath,
    this.onChangeAvatar,
    this.nicknameForAvatar = '',
  });
  final Profile? initial;
  final ValueChanged<Profile> onSaved;
  final VoidCallback? onCancel;
  final String? avatarPath;
  final VoidCallback? onChangeAvatar;

  /// 还没填昵称时，头像兜底上画的那个字
  final String nicknameForAvatar;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  final _ageController = TextEditingController();
  final _gradeController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  late Sex _sex = widget.initial?.sex ?? Sex.male;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial == null) return;
    _nicknameController.text = initial.nickname;
    _ageController.text = '${initial.age}';
    _gradeController.text = initial.grade;
    _heightController.text = '${initial.heightCm}';
    _weightController.text = profileWeightText(initial.weightKg);
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _ageController.dispose();
    _gradeController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final age = int.parse(_ageController.text.trim());
    final profile = Profile(
      nickname: _nicknameController.text.trim(),
      sex: _sex,
      age: age,
      grade: _gradeController.text.trim(),
      standardGroup: standardGroupFor(sex: _sex, age: age),
      heightCm: int.parse(_heightController.text.trim()),
      weightKg: double.parse(_weightController.text.trim()),
      updatedAt: DateTime.now(),
    );
    final saved = await saveProfileRaw(profile.encode());
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('资料没能存到这台设备上，下次打开会再问一次。'),
        ),
      );
    }
    widget.onSaved(profile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: Text(initial == null ? '填写资料' : '我的资料'),
        automaticallyImplyLeading: false,
        leading: widget.onCancel == null
            ? null
            : IconButton(
                tooltip: '放弃改动',
                onPressed: widget.onCancel,
                icon: const Icon(Icons.arrow_back),
              ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _avatarPicker(theme),
                    const SizedBox(height: 16),
                    _intro(theme, initial),
                    const SizedBox(height: 18),
                    _field(
                      controller: _nicknameController,
                      label: '昵称',
                      hint: '可以不填，例如：小陈',
                      maxLength: profileNicknameMaxLength,
                      onChanged: (_) => setState(() {}),
                      validator: (_) => null,
                    ),
                    const SizedBox(height: 14),
                    SegmentedButton<Sex>(
                      // 选中态已经由整块品牌色说明，再挂一个勾只是多一个符号。
                      showSelectedIcon: false,
                      segments: [
                        for (final sex in Sex.values)
                          ButtonSegment(value: sex, label: Text(sex.nameZh)),
                      ],
                      selected: {_sex},
                      onSelectionChanged: (selected) =>
                          setState(() => _sex = selected.first),
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _ageController,
                      label: '年龄',
                      hint: '周岁，$decisionAgeMin–$decisionAgeMax',
                      numeric: true,
                      onChanged: (_) => setState(() {}),
                      validator: (value) {
                        final age = int.tryParse(value ?? '');
                        if (age == null) return '请填年龄';
                        if (age < decisionAgeMin || age > decisionAgeMax) {
                          return '年龄要在 $decisionAgeMin 到 $decisionAgeMax 之间';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    _groupHint(theme),
                    const SizedBox(height: 14),
                    _field(
                      controller: _gradeController,
                      label: '年级',
                      hint: '例如：高一',
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _heightController,
                      label: '身高（厘米）',
                      hint: '例如：165',
                      numeric: true,
                      validator: (value) => _rangeError(
                        value,
                        label: '身高',
                        min: profileHeightMinCm.toDouble(),
                        max: profileHeightMaxCm.toDouble(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _weightController,
                      label: '体重（公斤）',
                      hint: '例如：52.5',
                      decimal: true,
                      validator: (value) => _rangeError(
                        value,
                        label: '体重',
                        min: profileWeightMinKg,
                        max: profileWeightMaxKg,
                      ),
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _saving ? null : _submit,
                      child: Text(_saving ? '正在保存…' : '保存'),
                    ),
                    if (widget.onCancel != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: widget.onCancel,
                        child: const Text('取消'),
                      ),
                    ],
                    const SizedBox(height: 18),
                    const PrivacyNote(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatarPicker(ThemeData theme) {
    const size = 84.0;
    final typed = _nicknameController.text.trim();
    final name = typed.isNotEmpty
        ? typed
        : (widget.nicknameForAvatar.isEmpty ? '同学' : widget.nicknameForAvatar);
    final circle = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: AvatarImage(
          path: widget.avatarPath,
          fallback: initialAvatar(name: name, size: size),
        ),
      ),
    );
    final onChange = widget.onChangeAvatar;
    return Center(
      child: Column(
        children: [
          if (onChange == null)
            circle
          else
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onChange,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  circle,
                  Positioned(right: 0, bottom: 0, child: _avatarBadge(theme)),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            onChange == null ? '头像可以稍后在「我的」里换' : '点头像换一张',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _avatarBadge(ThemeData theme) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: vitalBlue,
        border: Border.all(color: theme.scaffoldBackgroundColor, width: 2),
      ),
      child: const Center(
        child: AppIcon(
          AppGlyph.camera,
          size: 15,
          color: AppColors.onDark,
          strokeWidth: 1.5,
        ),
      ),
    );
  }

  Widget _groupHint(ThemeData theme) {
    final age = int.tryParse(_ageController.text.trim());
    final text = (age == null || age < decisionAgeMin || age > decisionAgeMax)
        ? '填了年龄就会自动分出组别'
        : '国标组别：${standardGroupFor(sex: _sex, age: age)}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: AppIcon(
            AppGlyph.sparkle,
            size: 15,
            color: AppColors.inkFaint,
            strokeWidth: 1.5,
          ),
        ),
        const SizedBox(width: Space.s75),
        Expanded(
          child: Text(
            '$text（按年龄与性别自动分，不用自己选）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _intro(ThemeData theme, Profile? initial) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '这几项决定「和谁比」——同样的动作，初中男生和高中女生的参考标准不一样。'
          '填一次就存下来，以后分析直接用它。',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: AppIcon(
                AppGlyph.info,
                size: 16,
                color: AppColors.inkFaint,
                strokeWidth: 1.5,
              ),
            ),
            const SizedBox(width: Space.s75),
            Expanded(
              child: Text(
                '身高体重这一版只做记录，还没有任何判定用到它们。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        if (initial != null) ...[
          const SizedBox(height: 10),
          Text(
            '上次更新于 ${formatProfileDate(initial.updatedAt)}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ],
    );
  }

  String? _rangeError(
    String? value, {
    required String label,
    required double min,
    required double max,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请填$label';
    final number = double.tryParse(text);
    if (number == null) return '请填数字';
    if (number < min || number > max) {
      return '$label看起来不对：要在 '
          '${profileBoundText(min)} 到 ${profileBoundText(max)} 之间';
    }
    return null;
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool numeric = false,
    bool decimal = false,
    int maxLength = 20,
    ValueChanged<String>? onChanged,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: numeric || decimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: [
        if (numeric) FilteringTextInputFormatter.digitsOnly,
        if (decimal)
          FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}\.?\d{0,2}')),
        LengthLimitingTextInputFormatter(maxLength),
      ],
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator: validator ??
          (value) => (value == null || value.trim().isEmpty) ? '请填$label' : null,
    );
  }
}
