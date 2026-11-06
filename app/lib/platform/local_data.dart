library;

import 'avatar_store.dart';
import 'history_store.dart';
import 'profile_store.dart';

Future<bool> clearAllLocalData() async {
  final profileGone = await clearProfileRaw();
  final historyGone = await clearHistoryRaw();
  final avatarGone = await clearAvatarRaw();
  return profileGone && historyGone && avatarGone;
}
