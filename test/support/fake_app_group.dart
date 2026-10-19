import 'dart:async';
import 'dart:convert';

import 'package:scheduling/core/platform/app_group_mirror_store.dart';

/// An in-memory App Group behind the real [AppGroupMirrorStore].
class FakeAppGroup {
  final values = <String, String>{};
  final saves = <String>[];

  /// Throws on the next save of this key.
  String? failNextSaveOf;

  /// Parks the next read until completed.
  Completer<void>? holdNextRead;

  late final store = AppGroupMirrorStore(
    read: (key) async {
      final hold = holdNextRead;
      if (hold != null) {
        holdNextRead = null;
        await hold.future;
      }
      return values[key];
    },
    save: (key, value) async {
      saves.add(key);
      if (failNextSaveOf == key) {
        failNextSaveOf = null;
        throw StateError('App Group write failed');
      }
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
    },
  );

  Map<String, dynamic>? decoded(String key) {
    final raw = values[key];
    return raw == null
        ? null
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  int savesOf(String key) => saves.where((k) => k == key).length;
}
