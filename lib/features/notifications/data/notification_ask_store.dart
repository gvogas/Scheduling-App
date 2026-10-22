import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per device and uid, that the notifications page was shown once.
class NotificationAskStore {
  static String _key(String uid) => 'notification_ask_seen_$uid';

  Future<bool> hasSeen(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(uid)) ?? false;
  }

  Future<void> markSeen(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(uid), true);
  }
}

final notificationAskStoreProvider = Provider<NotificationAskStore>(
  (ref) => NotificationAskStore(),
);
