import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';

/// The window the today-scoped roster surfaces read. Keyed off
/// `currentDayProvider` rather than `DateTime.now()` so an app left open across
/// midnight rolls over — the same rule the calendar's today-circle and the
/// off-screen mirrors follow.
///
/// Deliberately [AppointmentDateRange.forMirrors] and NOT `forDay`, even
/// though every consumer wants a single day: `appointmentsInRangeProvider` is
/// keyed by range VALUE, and for an admin the Siri snapshot already holds this
/// exact range open for the whole session. `forDay`'s result set is a strict
/// subset of it (same `fetchStart`, narrower `end`), so asking for it forked a
/// SECOND permanent business-wide listener over documents the first was
/// already streaming — and the hub keeps the Team tab mounted, so one visit
/// pinned it for the session. Every consumer below re-scopes with `runsOn`, so
/// the wider list feeds them unchanged. Same rule as `myDetailsRangeProvider`.
final todayRangeProvider = Provider<AppointmentDateRange>((ref) {
  return AppointmentDateRange.forMirrors(ref.watch(currentDayProvider));
});

/// How many jobs each employee is booked for today, keyed by users-doc id.
///
/// ONE day-range listener reduced in Dart — never one query per roster row.
/// Cancelled visits don't count: the row is answering "how loaded are they",
/// and a cancelled job is not load.
///
/// Re-scoped with [runsOn] — the range stream is a 14-day superset.
///
/// `autoDispose` on purpose: a keepAlive watcher of the `autoDispose` range
/// stream is a permanent listener, so its eviction grace could never fire and
/// one visit to the Team tab pinned a live appointments snapshot for the rest
/// of the session.
final employeeJobsTodayProvider = Provider.autoDispose<Map<String, int>>((ref) {
  final range = ref.watch(todayRangeProvider);
  final jobs = appointmentsOrEmpty(
    ref,
    ref.watch(appointmentsInRangeProvider(range)),
    'EMP-TODAY jobs-today range stream failed',
  );
  final counts = <String, int>{};
  for (final job in jobs) {
    // `countsAsLoadOn` owns what counts; the TODAY panel still LISTS a day off (ADR-0047).
    if (!countsAsLoadOn(job, range.start)) continue;
    for (final id in job.employeeIds) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
  }
  return counts;
});

/// One person's emergency contact, from `users/{docId}/private/emergency`.
///
/// Autodisposed and family-keyed: it is read only while a detail surface is
/// open. Rules deny this path to everyone but an admin and the person
/// themselves, so a peer's read errors rather than returning empty — surfaces
/// must render it only when they already know the viewer is entitled, and
/// treat an error as "not shown", never as "none on file".
/// The failure is logged HERE, once per error emission, and rethrown.
///
/// Not in the three consumers' error branches: those live inside `build`, so
/// they fire on every rebuild, and all three would have to carry the same
/// call. Without it a failing read on this path was invisible in Crashlytics
/// while every surface quietly rendered "not shown" — a swallowed failure with
/// no log is the shape the error-handling rules exist to forbid.
final emergencyContactProvider = StreamProvider.autoDispose
    .family<EmergencyContact, String>((ref, docId) {
      final logger = ref.watch(loggerProvider);
      return ref
          .watch(employeesRepositoryProvider)
          .watchEmergencyContact(docId)
          .transform(
            StreamTransformer<EmergencyContact, EmergencyContact>.fromHandlers(
              handleError: (error, stackTrace, sink) {
                logger.warn('EMP-EMERGENCY watch failed', error, stackTrace);
                // Rethrown, so a surface still tells the two apart: an error
                // must never render as "none on file".
                sink.addError(error, stackTrace);
              },
            ),
          );
    });

/// How many future jobs an employee is still assigned to — the caption under
/// the Disable account button. Autodisposed and family-keyed so it is fetched
/// once per sheet open, not per rebuild.
final futureAssignmentCountProvider = FutureProvider.autoDispose
    .family<int, String>((ref, employeeId) {
      return ref
          .read(appointmentsRepositoryProvider)
          .countFutureAssignments(employeeId);
    });

/// One employee's jobs today, in start order — the detail page's TODAY panel.
///
/// Filtered out of the SAME day-range listener the roster rows reduce, never a
/// second per-employee query: the Team tab already holds that stream open, so
/// opening a detail costs no extra read, and the panel can never disagree with
/// the count on the row that opened it.
final employeeTodayJobsProvider = Provider.autoDispose
    .family<List<AppointmentRecord>, String>((ref, employeeId) {
      final range = ref.watch(todayRangeProvider);
      final jobs = appointmentsOrEmpty(
        ref,
        ref.watch(appointmentsInRangeProvider(range)),
        'EMP-TODAY today-panel range stream failed',
      );
      // Sorted by THIS DAY's window start, mirroring `notification_policy.js`; the slice is resolved once per record.
      final keyed = <({AppointmentRecord job, DateTime start})>[];
      for (final job in jobs) {
        if (isCancelledStatusRaw(job.status) ||
            !job.employeeIds.contains(employeeId)) {
          continue;
        }
        final slice = sliceFor(job, range.start);
        if (slice == null) continue;
        keyed.add((job: job, start: slice.windowStart));
      }
      keyed.sort((a, b) => a.start.compareTo(b.start));
      return [for (final entry in keyed) entry.job];
    });
