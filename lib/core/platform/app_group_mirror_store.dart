import 'dart:async';
import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:uuid/uuid.dart';

const mirrorOwnerKey = 'schedule_session_owner';
const mirrorWidgetKey = 'schedulePayload';
const mirrorSnapshotKey = 'schedule_snapshot';
const mirrorAppGroup = 'group.net.vogas.scheduling';

typedef MirrorRead = Future<String?> Function(String key);
typedef MirrorSave = Future<void> Function(String key, String? value);

/// Serializes foreground mirrors and binds every payload to durable ownership.
class AppGroupMirrorStore {
  AppGroupMirrorStore({required MirrorRead read, required MirrorSave save})
    : _read = read,
      _save = save;

  final MirrorRead _read;
  final MirrorSave _save;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null) return null;
    final value = jsonDecode(raw);
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  static int? revision(Map<String, dynamic> payload) {
    final generated = payload['generatedAt'];
    if (generated is num) return generated.toInt();
    return generated is String
        ? DateTime.tryParse(generated)?.millisecondsSinceEpoch
        : null;
  }

  Future<String?> ensureOwner(String uid, bool Function() current) =>
      _serial(() async {
        if (!current()) return null;
        final binding = _decode(await _read(mirrorOwnerKey));
        if (!current()) return null;
        if (binding?['ownerUid'] == uid && binding?['epoch'] is String) {
          return binding!['epoch'] as String;
        }
        final epoch = const Uuid().v4();
        await _save(
          mirrorOwnerKey,
          jsonEncode({
            'ownerUid': uid,
            'epoch': epoch,
            'validFrom': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        return current() ? epoch : null;
      });

  Future<void> foreground(
    String key,
    Map<String, dynamic>? payload,
    String? uid,
    bool Function() current,
  ) async {
    final epoch = payload == null || uid == null
        ? null
        : await ensureOwner(uid, current);
    await _serial(() async {
      if (!current()) return;
      if (payload == null) {
        await _save(
          mirrorOwnerKey,
          jsonEncode({
            'ownerUid': null,
            'epoch': const Uuid().v4(),
            'validFrom': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        if (!current()) return;
        await _save(mirrorWidgetKey, null);
        if (!current()) return;
        await _save(mirrorSnapshotKey, null);
        return;
      }
      if (uid == null || epoch == null) return;
      final binding = _decode(await _read(mirrorOwnerKey));
      if (!current() ||
          binding?['ownerUid'] != uid ||
          binding?['epoch'] != epoch) {
        return;
      }
      await _save(
        key,
        jsonEncode({
          ...payload,
          'ownerUid': uid,
          'sessionEpoch': epoch,
          'schema': 1,
          'sourceRevision': revision(payload),
        }),
      );
    });
  }

  Future<bool> backgroundWidget(String raw) => _serial(() async {
    final payload = _decode(raw);
    final binding = _decode(await _read(mirrorOwnerKey));
    if (payload == null ||
        binding == null ||
        binding['ownerUid'] == null ||
        payload['ownerUid'] != binding['ownerUid'] ||
        payload['sessionEpoch'] != binding['epoch']) {
      return false;
    }
    final incoming = revision(payload);
    final cached = _decode(await _read(mirrorWidgetKey));
    if (incoming == null ||
        incoming < (binding['validFrom'] as num).toInt() ||
        (cached != null && (revision(cached) ?? 0) > incoming)) {
      return false;
    }
    final latest = _decode(await _read(mirrorOwnerKey));
    if (latest?['epoch'] != binding['epoch'] ||
        latest?['ownerUid'] != binding['ownerUid']) {
      return false;
    }
    await _save(mirrorWidgetKey, jsonEncode(payload));
    return true;
  });
}

final appGroupMirrorStore = AppGroupMirrorStore(
  read: (key) async {
    await HomeWidget.setAppGroupId(mirrorAppGroup);
    return await HomeWidget.getWidgetData<String>(key);
  },
  save: (key, value) async {
    await HomeWidget.setAppGroupId(mirrorAppGroup);
    await HomeWidget.saveWidgetData<String>(key, value);
  },
);
