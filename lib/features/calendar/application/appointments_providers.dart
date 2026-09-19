import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

final appointmentsRepositoryProvider = Provider<AppointmentsRepository>((ref) {
  final firestore = ref.watch(firestoreProvider);
  final functions = ref.watch(firebaseFunctionsProvider);
  final repository = FirebaseAppointmentsRepository(
    firestore,
    functions: functions,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// How long an unwatched month keeps its listener warm for reuse on page-back.
const _monthRangeKeepAlive = Duration(minutes: 3);

/// Keeps a provider alive after its watchers leave, enabling reuse on page-back.
///
/// Public because the dashboard's one-shot `.get()` halves need exactly the same
/// grace as the live half beside them: without it, leaving the dashboard and
/// coming straight back — drilling into a job from the Attention list and
/// pressing back is precisely that — tore down and re-issued up to ~2000
/// document reads, while the live stream cost nothing.
void keepWarmWithGrace(Ref ref, {Duration grace = _monthRangeKeepAlive}) =>
    _keepWarmWithGrace(ref, grace: grace);

void _keepWarmWithGrace(Ref ref, {Duration grace = _monthRangeKeepAlive}) {
  final link = ref.keepAlive();
  Timer? evictTimer;
  ref
    ..onCancel(() => evictTimer = Timer(grace, link.close))
    ..onResume(() => evictTimer?.cancel())
    ..onDispose(() => evictTimer?.cancel());
}

final appointmentsInRangeProvider = StreamProvider.family
    .autoDispose<List<AppointmentRecord>, AppointmentDateRange>((ref, range) {
      return streamForUid(ref, (uid) {
        if (uid == null) return Stream.value(const <AppointmentRecord>[]);
        _keepWarmWithGrace(ref);
        return ref.watch(appointmentsRepositoryProvider).watchInRange(range);
      });
    });

/// Family key for [myAppointmentsProvider]. Kept as a private typedef since
/// records are structurally typed anyway.
typedef _MyAppointmentsKey = ({String employeeId, AppointmentDateRange range});

final myAppointmentsProvider = StreamProvider.family
    .autoDispose<List<AppointmentRecord>, _MyAppointmentsKey>((ref, key) {
      return streamForUid(ref, (uid) {
        if (uid == null) return Stream.value(const <AppointmentRecord>[]);
        // Same keep-alive grace as the admin provider.
        _keepWarmWithGrace(ref);
        return ref
            .watch(appointmentsRepositoryProvider)
            .watchForEmployeeInRange(key.employeeId, key.range);
      });
    });

/// The range stream's list, logging once under [tag] when the query failed.
///
/// A bare `.value ?? const []` made a rejected or broken listener
/// indistinguishable from a day with genuinely no work, AND unlogged — so a
/// roster row read "0 jobs today", the TODAY panel read empty and the
/// availability warning never fired, with nothing in Crashlytics. The reducers
/// that consume this deliberately still degrade to an empty list rather than
/// growing an error state: the surfaces are a count badge and two small panels,
/// and "no work" is the honest thing to paint while the failure is recorded.
/// A surface that must tell the two apart reads the `AsyncValue` itself, the
/// way `emergencyContactProvider`'s consumers do.
///
/// Called from a provider body, so it runs once per emission, not per rebuild.
List<AppointmentRecord> appointmentsOrEmpty(
  Ref ref,
  AsyncValue<List<AppointmentRecord>> appointments,
  String tag,
) {
  if (appointments.hasError) {
    ref
        .read(loggerProvider)
        .warn(tag, appointments.error, appointments.stackTrace);
  }
  return appointments.value ?? const [];
}

/// The range the calendar screen currently holds a live listener on, or null
/// when no admin calendar is mounted.
///
/// Published so a surface opened FROM that screen can reduce the stream it
/// already pays for instead of forking a second one — the same rule
/// `forWeekBucketOf` and `forMirrors` exist to enforce, read from the other
/// end. The assignee picker's availability lookup is the only consumer.
///
/// **Admin only.** An employee's calendar reads `myAppointmentsProvider`, and
/// `appointmentsInRangeProvider` constrains `startTime` alone — for a LIST
/// query the rules are evaluated against the constraints, so a technician
/// joining that listener is rejected outright. `MainCalendarScreen` publishes
/// only when it is showing the admin stream.
class OpenCalendarRange extends Notifier<AppointmentDateRange?> {
  @override
  AppointmentDateRange? build() => null;

  /// Whoever published the current range. An OBJECT identity, not the range:
  /// two calendars on the same month publish EQUAL ranges, so a value
  /// comparison cannot tell "still mine" from "the replacement's".
  Object? _owner;

  void publish(Object owner, AppointmentDateRange range) {
    _owner = owner;
    if (state != range) state = range;
  }

  /// Clears only while [owner] is still the one that published.
  ///
  /// A screen-cache clear builds the replacement calendar before disposing the
  /// old one, so an unconditional clear on the way out would drop the range
  /// the NEW screen just published and leave every picker on the one-shot
  /// fallback — silently, since that path answers correctly and only costs
  /// reads.
  void clearIfHolding(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    state = null;
  }
}

final openCalendarRangeProvider =
    NotifierProvider<OpenCalendarRange, AppointmentDateRange?>(
      OpenCalendarRange.new,
    );
