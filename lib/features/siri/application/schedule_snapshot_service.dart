import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';
import 'package:scheduling/core/platform/ios_platform.dart';

/// App Group key the Siri App Intents extension reads its answers from;
/// shares the container with the home-screen widget's `schedulePayload`
/// under a separate key and schema.
const scheduleSnapshotKey = mirrorSnapshotKey;

/// Writes the Siri schedule snapshot into the App Group. iOS-only, and it
/// doesn't call `HomeWidget.updateWidget` — the extension just reads this
/// on demand.
class ScheduleSnapshotService {
  ScheduleSnapshotService({
    required SessionFence session,
    AppLogger? logger,
    bool Function()? isIosPlatform,
    AppGroupMirrorStore? store,
  }) : _session = session,
       _logger = logger ?? AppLogger(),
       _isIos = isIosPlatform ?? defaultIsIosPlatform,
       _store = store ?? appGroupMirrorStore;

  final SessionFence _session;
  final AppLogger _logger;
  final bool Function() _isIos;
  final AppGroupMirrorStore _store;

  /// The last landed write, used to skip a repeat while the App Group still holds it.
  String? _lastUid;
  String? _lastSignature;
  String? _lastWritten;
  Map<String, dynamic>? _lastMeaningful;

  Future<void> writeSnapshot(Map<String, dynamic> payload) async {
    if (!_isIos()) return;
    final meaningful = _meaningfulOf(payload);
    final signature = _signatureFor(meaningful);
    final lease = _session.capture();
    if (lease == null) return;
    try {
      final written = _lastWritten;
      if (written != null &&
          lease.uid == _lastUid &&
          signature == _lastSignature &&
          await _store.stillHolds(scheduleSnapshotKey, written)) {
        return;
      }
      final saved = await _store.foreground(
        scheduleSnapshotKey,
        payload,
        lease.uid,
        () => lease.isCurrent,
      );
      if (saved == null || !lease.isCurrent) return;
      _lastUid = lease.uid;
      _lastSignature = signature;
      _lastWritten = saved;
      _lastMeaningful = meaningful;
    } catch (e, st) {
      _logger.warn('SIRI snapshot write failed', e, st);
    }
  }

  /// Wipes the snapshot — client names and addresses must not outlive the
  /// session in the shared container.
  Future<void> clearSnapshot() async {
    if (!_isIos()) return;
    final current = _session.captureBoundary();
    _lastUid = _lastSignature = _lastWritten = null;
    _lastMeaningful = null;
    try {
      await _store.foreground(scheduleSnapshotKey, null, null, current);
    } catch (e, st) {
      _logger.warn('SIRI snapshot clear failed', e, st);
    }
  }

  /// The schedule-relevant slice of [payload] — everything except the
  /// ever-changing `generatedAt` stamp, which must not defeat the
  /// unchanged-schedule check.
  static Map<String, dynamic> _meaningfulOf(Map<String, dynamic> payload) =>
      Map<String, dynamic>.of(payload)..remove('generatedAt');

  static String _signatureOf(Map<String, dynamic> payload) =>
      jsonEncode(_meaningfulOf(payload));

  /// Reuses the landed signature when nothing changed — a deep compare bails at
  /// the first difference and allocates nothing, where the encode walks it all.
  String _signatureFor(Map<String, dynamic> meaningful) {
    final last = _lastMeaningful;
    final signature = _lastSignature;
    return last != null &&
            signature != null &&
            const DeepCollectionEquality().equals(meaningful, last)
        ? signature
        : jsonEncode(meaningful);
  }

  /// Test hook for the `generatedAt`-insensitive dedup signature.
  @visibleForTesting
  static String signatureForTesting(Map<String, dynamic> payload) =>
      _signatureOf(payload);
}

/// The one clear-or-write rule for a settled snapshot: null clears it.
extension ScheduleSnapshotApply on ScheduleSnapshotService {
  Future<void> apply(Map<String, dynamic>? payload) =>
      payload == null ? clearSnapshot() : writeSnapshot(payload);
}

final scheduleSnapshotServiceProvider = Provider<ScheduleSnapshotService>(
  (ref) => ScheduleSnapshotService(
    session: ref.watch(sessionFenceProvider),
    logger: ref.watch(loggerProvider),
  ),
);
