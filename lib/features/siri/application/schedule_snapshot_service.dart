import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart'
    show widgetAppGroupId;

/// App Group key the Siri App Intents extension reads its answers from;
/// shares the container with the home-screen widget's `schedulePayload`
/// under a separate key and schema.
const scheduleSnapshotKey = 'schedule_snapshot';

/// Writes the Siri schedule snapshot into the App Group. iOS-only, and it
/// doesn't call `HomeWidget.updateWidget` — the extension just reads this
/// on demand.
class ScheduleSnapshotService {
  ScheduleSnapshotService({AppLogger? logger})
    : _logger = logger ?? AppLogger();

  final AppLogger _logger;

  /// Signature of the last successful write, used to dedup repeat writes.
  /// Null means nothing's been written yet; [_clearedState] means we wiped it.
  static const _clearedState = '__cleared__';
  String? _lastState;

  Future<void> writeSnapshot(Map<String, dynamic> payload) async {
    if (!Platform.isIOS) return;
    final signature = _signatureOf(payload);
    if (signature == _lastState) return;
    try {
      await HomeWidget.setAppGroupId(widgetAppGroupId);
      await HomeWidget.saveWidgetData<String>(
        scheduleSnapshotKey,
        jsonEncode(payload),
      );
      _lastState = signature;
    } catch (e, st) {
      _logger.warn('SIRI snapshot write failed', e, st);
    }
  }

  /// Wipes the snapshot — client names and addresses must not outlive the
  /// session in the shared container.
  Future<void> clearSnapshot() async {
    if (!Platform.isIOS) return;
    if (_lastState == _clearedState) return;
    try {
      await HomeWidget.setAppGroupId(widgetAppGroupId);
      await HomeWidget.saveWidgetData<String>(scheduleSnapshotKey, null);
      _lastState = _clearedState;
    } catch (e, st) {
      _logger.warn('SIRI snapshot clear failed', e, st);
    }
  }

  /// The schedule-relevant slice of [payload] — everything except the
  /// ever-changing `generatedAt` stamp, which must not defeat the
  /// unchanged-schedule check.
  static String _signatureOf(Map<String, dynamic> payload) {
    final meaningful = Map<String, dynamic>.of(payload)..remove('generatedAt');
    return jsonEncode(meaningful);
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
  (ref) => ScheduleSnapshotService(logger: ref.watch(loggerProvider)),
);
