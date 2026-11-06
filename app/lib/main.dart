//产品入口：钉方向、定主题、串联几屏
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/action_spec.dart';
import 'app/profile.dart';
import 'app/session_record.dart';
import 'platform/avatar_store.dart';
import 'platform/history_store.dart';
import 'platform/local_data.dart';
import 'platform/orientation.dart';
import 'platform/profile_store.dart';
import 'ui/app_icons.dart';
import 'ui/design.dart';
import 'ui/exercise_catalog.dart';
import 'ui/growth_page.dart';
import 'ui/history_page.dart';
import 'ui/home_page.dart';
import 'ui/me_page.dart';
import 'ui/posture_page.dart';
import 'ui/preview_page.dart';
import 'ui/profile_page.dart';
import 'ui/splash_page.dart';
import 'ui/squat_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await applyOrientation(AppOrientation.portrait);
  SystemChrome.setSystemUIOverlayStyle(vitalLightSystemBars);
  runApp(const VitalTeenApp());
}

class VitalTeenApp extends StatelessWidget {
  const VitalTeenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '健知行绎',
      debugShowCheckedModeBanner: false,
      theme: buildVitalTeenTheme(),
      home: const AppEntry(),
    );
  }
}

class AppEntry extends StatefulWidget {
  const AppEntry({super.key, this.splashDuration = SplashPage.defaultDuration});
  final Duration splashDuration;
  @override
  State<AppEntry> createState() => _AppEntryState();
}

enum _Stage { splash, profile, shell, preview, exercise, growth }

enum _Tab {
  workout,
  history,
  posture,
  me,
}

class _AppEntryState extends State<AppEntry> with WidgetsBindingObserver {
  late _Stage _stage = _Stage.splash;
  bool _reportShown = false;
  ActionSpec? _spec;
  ExerciseEntry? _previewEntry;
  Profile? _profile;
  String? _avatarPath;
  _Tab _tab = _Tab.workout;
  List<SessionRecord> _records = const [];
  int _historyEpoch = 0;
  late final ThemeData _cameraTheme = buildCameraTheme();
  late final Future<Profile?> _profileFuture = _readProfile();

  Future<Profile?> _readProfile() async {
    try {
      return Profile.decode(await loadProfileRaw());
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAvatarPath();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncOrientation();
  }

  Future<void> _loadAvatarPath() async {
    final path = await _readAvatarPath();
    if (!mounted || path == null) return;
    setState(() => _avatarPath = path);
  }

  Future<String?> _readAvatarPath() async {
    try {
      return await loadAvatarPath();
    } on Object {
      return null;
    }
  }

  /// 开屏之后：没填过资料就先填，填过就直接进壳
  Future<void> _afterSplash() async {
    final profile = await _profileFuture;
    if (!mounted) return;
    if (profile == null) {
      _go(_Stage.profile);
      return;
    }
    setState(() => _profile = profile);
    _goShell(_Tab.workout);
  }

  Future<void> _onChangeAvatar() async {
    final outcome = await pickAvatar();
    if (!mounted) return;
    if (outcome == AvatarPickOutcome.cancelled) return;
    final path =
        outcome == AvatarPickOutcome.picked ? await loadAvatarPath() : null;
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没能换头像，请再试一次。')),
      );
      return;
    }
    setState(() => _avatarPath = path);
  }

  void _onProfileSaved(Profile profile) {
    final firstFill = _profile == null;
    setState(() => _profile = profile);
    _goShell(firstFill ? _Tab.workout : _Tab.me);
  }

  void _openPreview(ExerciseEntry entry) {
    setState(() {
      _previewEntry = entry;
      _spec = specForCode(entry.code);
    });
    _go(_Stage.preview);
  }

  void _startExercise() {
    if (_spec == null) {
      assert(false, '${_previewEntry?.code} 没有 ActionSpec，预览页不该给「开始」');
      return;
    }
    _reportShown = false;
    _go(_Stage.exercise);
  }

  _Tab? get _backTarget => switch (_stage) {
        _Stage.profile => _profile == null ? null : _Tab.me,
        _Stage.preview || _Stage.exercise => _Tab.workout,
        _Stage.shell => _tab == _Tab.workout ? null : _Tab.workout,
        // 成长页从哪来往哪回（首页那张卡、或「我的」那张卡）
        _Stage.growth => _tab,
        _Stage.splash => null,
      };

  @override
  Widget build(BuildContext context) {
    final backTarget = _backTarget;
    return PopScope(
      canPop: backTarget == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (backTarget == null) return;
        _goShell(backTarget);
      },
      child: AnimatedSwitcher(
        duration: Motion.page,
        switchInCurve: Motion.curve,
        switchOutCurve: Motion.curve,
        child: switch (_stage) {
          _Stage.splash => SplashPage(
              key: const ValueKey('splash'),
              duration: widget.splashDuration,
              onDone: _afterSplash,
            ),
          _Stage.profile => ProfilePage(
              key: const ValueKey('profile'),
              initial: _profile,
              avatarPath: _avatarPath,
              nicknameForAvatar: _profile == null
                  ? ''
                  : profileDisplayName(_profile!),
              onChangeAvatar: _onChangeAvatar,
              onSaved: _onProfileSaved,
              onCancel: _profile == null ? null : () => _goShell(_Tab.me),
            ),
          _Stage.growth => GrowthPage(
              key: const ValueKey('growth'),
              records: _records,
              now: DateTime.now(),
              onBack: () => _goShell(_tab),
            ),
          _Stage.shell => _Shell(
              key: const ValueKey('shell'),
              profile: _profile!,
              tab: _tab,
              records: _records,
              avatarPath: _avatarPath,
              onSelectTab: _selectTab,
              onOpenExercise: _openPreview,
              onOpenGrowth: () => _go(_Stage.growth),
              onEditProfile: () => _go(_Stage.profile),
              onClearData: _clearLocalData,
              onChangeAvatar: _onChangeAvatar,
            ),
          _Stage.preview => PreviewPage(
              key: ValueKey('preview-${_previewEntry!.code}'),
              entry: _previewEntry!,
              onBack: () => _goShell(_Tab.workout),
              onStart: _spec == null ? null : _startExercise,
              framingHint: _spec?.framingHint,
            ),
          _Stage.exercise => Theme(
              data: _cameraTheme,
              child: SquatPage(
                onExit: () => _goShell(_Tab.workout),
                profile: _profile,
                spec: _spec!,
                onReportShown: (showing) {
                  if (_reportShown == showing) return;
                  _reportShown = showing;
                  _syncOrientation();
                },
              ),
            ),
        },
      ),
    );
  }

  void _goShell(_Tab tab) {
    if (!mounted) return;
    setState(() => _tab = tab);
    _go(_Stage.shell);
    _reloadHistory();
  }

  void _selectTab(_Tab tab) {
    if (!mounted || tab == _tab) return;
    setState(() => _tab = tab);
    if (tab == _Tab.history || tab == _Tab.posture) _reloadHistory();
  }

  Future<void> _reloadHistory() async {
    final epoch = ++_historyEpoch;
    final records = await _readHistory();
    if (!mounted || epoch != _historyEpoch) return;
    setState(() => _records = records);
  }

  Future<List<SessionRecord>> _readHistory() async {
    try {
      return decodeHistory(await loadHistoryRaw());
    } on Object {
      return const [];
    }
  }

  Future<bool> _clearLocalData() async {
    final cleared = await clearAllLocalData();
    if (!cleared) return false;
    if (!mounted) return true;
    setState(() {
      _profile = null;
      _records = const [];
      _avatarPath = null;
    });
    _go(_Stage.profile);
    return true;
  }

  void _go(_Stage stage) {
    if (!mounted) return;
    setState(() => _stage = stage);
    _syncOrientation();
  }

  void _syncOrientation() {
    unawaited(
      applyOrientation(
        orientationFor(
          exercise: _stage == _Stage.exercise,
          reportShown: _reportShown,
          requiresLandscape: _spec?.requiresLandscape ?? false,
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    super.key,
    required this.profile,
    required this.tab,
    required this.records,
    required this.avatarPath,
    required this.onSelectTab,
    required this.onOpenExercise,
    required this.onOpenGrowth,
    required this.onEditProfile,
    required this.onClearData,
    required this.onChangeAvatar,
  });
  final Profile profile;
  final _Tab tab;
  final List<SessionRecord> records;
  final String? avatarPath;
  final ValueChanged<_Tab> onSelectTab;
  final ValueChanged<ExerciseEntry> onOpenExercise;
  final VoidCallback onOpenGrowth;
  final VoidCallback onEditProfile;
  final Future<bool> Function() onClearData;
  final VoidCallback onChangeAvatar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: tab.index,
        children: [
          _keepTicking(_Tab.workout, HomePage(
            profile: profile,
            onOpenExercise: onOpenExercise,
            avatarPath: avatarPath,
            records: records,
            onOpenGrowth: onOpenGrowth,
          )),
          _keepTicking(_Tab.history, HistoryPage(
            records: records,
            onStartTraining: () => onSelectTab(_Tab.workout),
          )),
          _keepTicking(_Tab.posture, PosturePage(
            records: records,
            profile: profile,
          )),
          _keepTicking(_Tab.me, MePage(
            profile: profile,
            onEditProfile: onEditProfile,
            onClearData: onClearData,
            avatarPath: avatarPath,
            onChangeAvatar: onChangeAvatar,
            records: records,
            onOpenGrowth: onOpenGrowth,
          )),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        // 一条顶边把底栏与内容分开。它画在底栏上，不是给某张卡片描单边。
        decoration: const BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.hairline)),
        ),
        child: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (index) => onSelectTab(_Tab.values[index]),
          destinations: const [
            NavigationDestination(
              icon: AppIcon(AppGlyph.workout, color: AppColors.inkFaint),
              selectedIcon: AppIcon(AppGlyph.workout, color: AppColors.brand),
              label: '开始运动',
            ),
            NavigationDestination(
              icon: AppIcon(AppGlyph.history, color: AppColors.inkFaint),
              selectedIcon: AppIcon(AppGlyph.history, color: AppColors.brand),
              label: '历史记录',
            ),
            NavigationDestination(
              icon: AppIcon(AppGlyph.posture, color: AppColors.inkFaint),
              selectedIcon: AppIcon(AppGlyph.posture, color: AppColors.brand),
              label: '体态',
            ),
            NavigationDestination(
              icon: AppIcon(AppGlyph.profile, color: AppColors.inkFaint),
              selectedIcon: AppIcon(AppGlyph.profile, color: AppColors.brand),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
  Widget _keepTicking(_Tab which, Widget child) =>
      TickerMode(enabled: which == tab, child: child);
}
