import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per device and per uid, that the team-map ask was shown.
class LocationShareAskStore {
  static String _key(String uid) => 'location_share_asked_$uid';

  Future<bool> hasAsked(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(uid)) ?? false;
  }

  Future<void> markAsked(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(uid), true);
  }
}

final locationShareAskStoreProvider = Provider<LocationShareAskStore>(
  (ref) => LocationShareAskStore(),
);
