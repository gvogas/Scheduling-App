import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per device and uid, the app build the team-map page last showed on.
class LocationShareAskStore {
  static String _key(String uid) => 'location_share_asked_build_$uid';

  Future<bool> hasAsked(String uid, {required String build}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(uid)) == build;
  }

  Future<void> markAsked(String uid, {required String build}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(uid), build);
  }
}

final locationShareAskStoreProvider = Provider<LocationShareAskStore>(
  (ref) => LocationShareAskStore(),
);
