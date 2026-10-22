import 'dart:convert';
import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';
import 'package:scheduling/core/platform/ios_platform.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// App Group shared with the iOS WidgetKit extension. This is public because
/// the app has to call `HomeWidget.setAppGroupId` with it before any widget
/// read, or iOS throws `AppGroupId not set`.
const widgetAppGroupId = mirrorAppGroup;
const _iosWidgetName = 'ScheduleWidget';
const _payloadKey = mirrorWidgetKey;

/// One job as the widget renders it, scoped to the day it appears on.
///
/// [slice] carries that day's window and position in the run — the widget must
/// show TODAY's clock, not the run's first morning. `dayIndex`/`dayCount` are
/// omitted for a single-day job so a pre-multi-day Swift decoder still parses
/// (it reads them as `Int?`) and so the widget shows no counter.
Map<String, dynamic> _job(AppointmentDaySlice slice) {
  final a = slice.appointment;
  return {
    // Carried so tapping the widget can deep-link back to the job. `?? ''`
    // avoids sending null, since Swift decodes this field as non-optional.
    'id': a.id ?? '',
    // Emit an absolute UTC instant with the Z suffix — a bare toIso8601String()
    // omits the zone designator the widget's formatter needs.
    'startTime': slice.windowStart.toUtc().toIso8601String(),
    'endTime': slice.windowEnd.toUtc().toIso8601String(),
    'clientName': a.clientName,
    'title': a.title,
    'address': a.address,
    'status': a.status,
    // The widget speaks "All day" instead of the stored midnight–23:59 pair.
    'isAllDay': a.isAllDay,
    if (slice.isMultiDay) 'dayIndex': slice.dayIndex,
    if (slice.isMultiDay) 'dayCount': slice.dayCount,
  };
}

/// How long after the last job of the day is finished the widget keeps showing
/// today before it rolls forward to tomorrow's schedule.
const widgetRolloverGrace = Duration(hours: 1);

/// Serializes an employee's schedule into the JSON the iOS widget renders.
/// Pure and unit-testable — carries today's and tomorrow's jobs plus a
/// `rolloverAt` instant so WidgetKit can switch on-device without the app running.
Map<String, dynamic> buildWidgetPayload(
  List<AppointmentRecord> appointments,
  DateTime now, {
  String locale = 'en',
}) {
  final startOfToday = now.dateOnly;
  final startOfTomorrow = DateTime(now.year, now.month, now.day + 1);

  // A job is "on" a day when it WORKS that day — not when its stored startTime
  // happens to fall in it. Without this a run that began yesterday is invisible
  // today, which is the whole point of multi-day support.
  List<AppointmentDaySlice> slicesOn(DateTime day) => [
    for (final a in appointments) ?sliceFor(a, day),
  ];

  final todayAll = slicesOn(startOfToday);
  final todayIncomplete = todayAll
      .where((s) => !isTerminalStatusRaw(s.appointment.status))
      .toList();
  // "Still ahead of you today", judged against THIS day's window. An all-day
  // block starts at midnight, so a start test would drop it the moment the day
  // began — it stays listed until its 23:59 end passes.
  bool stillAhead(AppointmentDaySlice s) => s.appointment.isAllDay
      ? s.windowEnd.isAfter(now)
      : s.windowStart.isAfter(now);

  final todayJobs = todayIncomplete.where(stillAhead).toList()
    ..sort((x, y) => x.windowStart.compareTo(y.windowStart));
  final tomorrowJobs =
      slicesOn(
          startOfTomorrow,
        ).where((s) => !isTerminalStatusRaw(s.appointment.status)).toList()
        ..sort((x, y) => x.windowStart.compareTo(y.windowStart));

  DateTime? rolloverAt;
  if (todayIncomplete.isEmpty) {
    final finished = todayAll
        .where((s) => !isCancelledStatusRaw(s.appointment.status))
        .toList();
    // If today's jobs are empty or all cancelled, use a stable past instant so
    // we don't churn; otherwise roll over 1h after the last job ends. The
    // window end, not the record's — a run rolls the widget over at the end of
    // TODAY's window, not at the end of the whole run.
    rolloverAt = finished.isEmpty
        ? startOfToday
        : finished
              .map((s) => s.windowEnd)
              .reduce((a, b) => a.isAfter(b) ? a : b)
              .add(widgetRolloverGrace);
  }

  String iso(DateTime d) => d.toUtc().toIso8601String();
  return {
    'locale': locale,
    'generatedAt': iso(now),
    'todayDate': iso(startOfToday),
    'tomorrowDate': iso(startOfTomorrow),
    'rolloverAt': rolloverAt == null ? null : iso(rolloverAt),
    'todayJobs': [for (final a in todayJobs) _job(a)],
    'tomorrowJobs': [for (final a in tomorrowJobs) _job(a)],
  };
}

/// Writes an already-encoded payload JSON into the App Group and reloads the
/// widget. iOS-only — used by the FCM background handler, which has no
/// Riverpod container to build the payload the normal way.
Future<void> writeWidgetPayloadJson(String payloadJson) async {
  if (!Platform.isIOS) return;
  if (payloadJson.isEmpty) return;
  try {
    await HomeWidget.setAppGroupId(widgetAppGroupId);
    if (await appGroupMirrorStore.backgroundWidget(payloadJson)) {
      await HomeWidget.updateWidget(iOSName: _iosWidgetName);
    }
  } catch (_) {
    // Best-effort: a background write failure just leaves the widget showing
    // its last state until the app next runs and syncs.
  }
}

Future<void> _reloadScheduleWidget() async {
  await HomeWidget.updateWidget(iOSName: _iosWidgetName);
}

/// Writes the widget payload into the App Group and refreshes the widget.
/// iOS-only; the store and the WidgetKit reload are injectable for tests.
class WidgetSyncService {
  WidgetSyncService({
    required SessionFence session,
    AppLogger? logger,
    bool Function()? isIosPlatform,
    AppGroupMirrorStore? store,
    Future<void> Function()? reloadWidget,
  }) : _session = session,
       _logger = logger ?? AppLogger(),
       _isIos = isIosPlatform ?? defaultIsIosPlatform,
       _store = store ?? appGroupMirrorStore,
       _reloadWidget = reloadWidget ?? _reloadScheduleWidget;

  final SessionFence _session;
  final AppLogger _logger;
  final bool Function() _isIos;
  final AppGroupMirrorStore _store;
  final Future<void> Function() _reloadWidget;

  /// The last landed write, used to skip a repeat while the App Group still holds it.
  String? _lastUid;
  String? _lastSignature;
  String? _lastWritten;
  Map<String, dynamic>? _lastMeaningful;

  Future<void> sync(Map<String, dynamic> payload) async {
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
          await _store.stillHolds(_payloadKey, written)) {
        return;
      }
      final saved = await _store.foreground(
        _payloadKey,
        payload,
        lease.uid,
        () => lease.isCurrent,
      );
      if (saved == null || !lease.isCurrent) return;
      await _reloadWidget();
      // Stamped only after the reload, so a failed write stays retryable.
      _lastUid = lease.uid;
      _lastSignature = signature;
      _lastWritten = saved;
      _lastMeaningful = meaningful;
    } catch (e, st) {
      _logger.warn('WIDGET sync failed', e, st);
    }
  }

  Future<void> clear() async {
    if (!_isIos()) return;
    final current = _session.captureBoundary();
    _lastUid = _lastSignature = _lastWritten = null;
    _lastMeaningful = null;
    try {
      await _store.foreground(_payloadKey, null, null, current);
      if (!current()) return;
      await _reloadWidget();
    } catch (e, st) {
      _logger.warn('WIDGET clear failed', e, st);
    }
  }

  /// The job-relevant slice of [payload] — everything except the ever-changing
  /// `generatedAt` stamp, which must not defeat the unchanged-jobs check.
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

final widgetSyncServiceProvider = Provider<WidgetSyncService>(
  (ref) => WidgetSyncService(
    session: ref.watch(sessionFenceProvider),
    logger: ref.watch(loggerProvider),
  ),
);

/// The current widget payload for the signed-in user, or null when the widget
/// should be cleared. Watches today plus the lookahead range.
final widgetPayloadProvider = Provider.autoDispose<AsyncValue<Map<String, dynamic>?>>((
  ref,
) {
  final identityAsync = ref.watch(activeUserIdentityProvider);
  if (identityAsync.isLoading) return const AsyncValue.loading();
  // Propagate a failed read as an error: a settled null means "signed out" and clears the widget.
  if (identityAsync.hasError) {
    return AsyncValue<Map<String, dynamic>?>.error(
      identityAsync.error!,
      identityAsync.stackTrace ?? StackTrace.current,
    );
  }
  final identity = identityAsync.value;
  if (identity == null) {
    return const AsyncValue<Map<String, dynamic>?>.data(null);
  }
  // Rebuild on day rollover so app doesn't keep showing yesterday's jobs.
  final today = ref.watch(currentDayProvider);
  // The shared mirror window, so the widget and the Siri snapshot share one listener (ADR-0116).
  final range = AppointmentDateRange.forMirrors(today);
  // Admins reuse the business-wide listener, so filter by assignee here: `buildWidgetPayload` doesn't.
  final appts = identity.role == 'admin'
      ? ref
            .watch(appointmentsInRangeProvider(range))
            .whenData(
              (list) => [
                for (final a in list)
                  if (a.employeeIds.contains(identity.docId)) a,
              ],
            )
      : ref.watch(
          myAppointmentsProvider((employeeId: identity.docId, range: range)),
        );
  final locale = currentServerLocale;
  return appts.whenData(
    (list) => buildWidgetPayload(list, DateTime.now(), locale: locale),
  );
});
