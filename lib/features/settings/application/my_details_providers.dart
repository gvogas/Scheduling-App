import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/policies/availability_conflict_policy.dart';

/// One availability edit, as a value so the conflict provider can be a family.
///
/// A class rather than two loose lists because `family` keys on `==`, and
/// `List` equality is identity-based — without this the provider would rebuild
/// on every frame that rebuilt the lists.
@immutable
class AvailabilityChange {
  const AvailabilityChange({
    required this.previousWorkingDays,
    required this.nextWorkingDays,
  });

  final List<bool> previousWorkingDays;
  final List<bool> nextWorkingDays;

  @override
  bool operator ==(Object other) =>
      other is AvailabilityChange &&
      _sameDays(other.previousWorkingDays, previousWorkingDays) &&
      _sameDays(other.nextWorkingDays, nextWorkingDays);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(previousWorkingDays),
    Object.hashAll(nextWorkingDays),
  );

  static bool _sameDays(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The signed-in person's own `users` record.
///
/// Reads the roster stream the app already holds open rather than opening a
/// per-person query. Null while the identity or the stream is still settling —
/// a surface must treat that as "not loaded yet", never as "no record".
final myEmployeeRecordProvider = Provider.autoDispose<EmployeeRecord?>((ref) {
  final docId = ref.watch(activeUserIdentityProvider).value?.docId;
  if (docId == null || docId.isEmpty) return null;
  final all =
      ref.watch(allUsersStreamProvider).value ?? const <EmployeeRecord>[];
  for (final employee in all) {
    if (employee.id == docId) return employee;
  }
  return null;
});

/// The fetch window the availability warning looks across.
///
/// Deliberately [AppointmentDateRange.forMirrors] and not a new window:
/// `appointmentsInRangeProvider` is keyed by range VALUE, and
/// `AppSyncListeners` already holds this exact range open for the whole
/// session for the widget and Siri mirrors. Any other range here would fork a
/// second permanent Firestore listener over overlapping documents.
final myDetailsRangeProvider = Provider.autoDispose<AppointmentDateRange>((
  ref,
) {
  return AppointmentDateRange.forMirrors(ref.watch(currentDayProvider));
});

/// This person's own jobs in that window.
///
/// Role-branched, like the Siri snapshot and the drawer's job badge. The
/// business-wide range query constrains `startTime` alone, and for a LIST
/// query the rules are evaluated against the constraints — so
/// `isAssignedEmployee` rejects a technician's whole query, and this warning
/// silently never fired for the one role the screen exists to serve. An admin
/// keeps reading the shared stream, so the range comment above holds for them.
final myUpcomingAppointmentsProvider =
    Provider.autoDispose<List<AppointmentRecord>>((ref) {
      final identity = ref.watch(activeUserIdentityProvider).value;
      final docId = identity?.docId;
      if (identity == null || docId == null || docId.isEmpty) return const [];
      final range = ref.watch(myDetailsRangeProvider);
      final jobs = appointmentsOrEmpty(
        ref,
        identity.role == 'admin'
            ? ref.watch(appointmentsInRangeProvider(range))
            : ref.watch(
                myAppointmentsProvider((employeeId: docId, range: range)),
              ),
        'MYDET upcoming range stream failed',
      );
      // Time off isn't WORK: the same filter `dashboardRecordsProvider` applies before `daysWithBookedWork`.
      return [
        for (final job in jobs)
          if (job.employeeIds.contains(docId) && !job.isTimeOff) job,
      ];
    });

/// Which weekdays this edit switches off while still holding booked work.
///
/// Sunday-indexed, like `workingDays`. Empty is the common case and costs no
/// day-slicing — see [daysWithBookedWork].
final myAvailabilityConflictProvider = Provider.autoDispose
    .family<Set<int>, AvailabilityChange>((ref, change) {
      return daysWithBookedWork(
        appointments: ref.watch(myUpcomingAppointmentsProvider),
        range: ref.watch(myDetailsRangeProvider),
        previousWorkingDays: change.previousWorkingDays,
        nextWorkingDays: change.nextWorkingDays,
      );
    });
