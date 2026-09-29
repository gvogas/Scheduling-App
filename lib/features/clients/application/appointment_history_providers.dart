import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// A thin facade over calendar-owned appointment history, so this file only
/// needs the calendar domain import for the record type.
final historyPagerProvider = Provider<HistoryPager>(
  (ref) => HistoryPager(ref.watch(appointmentsRepositoryProvider)),
);

/// Cursor-paged (newest-first) reads over terminal appointments.
class HistoryPager {
  const HistoryPager(this._repo);

  final AppointmentsRepository _repo;

  /// [employeeId] scopes the page to one assignee's jobs; null is the
  /// business-wide archive.
  Future<List<AppointmentRecord>> fetchPage({
    required int limit,
    AppointmentRecord? after,
    String? employeeId,
  }) {
    return _repo.fetchHistoryPage(
      after: after,
      limit: limit,
      employeeId: employeeId,
    );
  }
}

/// One history search: the words, and whose history.
typedef HistorySearchKey = ({String query, String? employeeId});

/// Database-backed history search across the whole window.
final historySearchProvider = FutureProvider.autoDispose
    .family<List<AppointmentRecord>, HistorySearchKey>((ref, key) async {
      final repo = ref.watch(appointmentsRepositoryProvider);
      // Resolved HERE, not inside the callback: this is autoDispose, so the
      // `Ref` is gone the moment the last listener does, and Riverpod 3's
      // `ref.read` THROWS on a disposed one.
      final logger = ref.read(loggerProvider);
      // Invalidate on local write so deleted visits don't linger in cached results.
      final sub = repo.onLocalWrite.listen(
        (_) => ref.invalidateSelf(),
        onError: (Object e, StackTrace st) =>
            logger.warn('HIST-SEARCH invalidate error', e, st),
      );
      ref.onDispose(sub.cancel);
      return await repo.searchHistory(key.query, employeeId: key.employeeId);
    });

/// How far back the booking form looks for a client's previous addresses and
/// last visit. The form renders two lines off this.
const int kClientBookingHistoryVisits = 20;

/// The booking form's newest visits; never self-invalidates on an open form.
final clientBookingHistoryProvider = FutureProvider.autoDispose
    .family<List<AppointmentRecord>, String>((ref, clientId) async {
      final repo = ref.watch(appointmentsRepositoryProvider);
      // Page one past the cap: `pageToCap` asks for `cap + 1 - fetched`, so a
      // page size equal to the cap costs a second round trip to learn there
      // are more — on the form-open path, for the repeat clients this serves.
      return await repo.fetchClientHistory(
        clientId: clientId,
        limit: kClientBookingHistoryVisits + 1,
        cap: kClientBookingHistoryVisits,
      );
    });

/// How many past visits the Job history section lists.
const int kClientJobHistoryVisits = 50;

/// Documents read for them: days 2+ of a multi-day run are dropped in Dart.
const int kClientJobHistoryScan = kClientJobHistoryVisits + 10;

/// The newest [kClientJobHistoryVisits] PAST visits for the Job history section.
final clientJobHistoryProvider = FutureProvider.autoDispose
    .family<List<AppointmentRecord>, String>((ref, clientId) async {
      final repo = ref.watch(appointmentsRepositoryProvider);
      // Hoisted for the same reason as `historySearchProvider` above.
      final logger = ref.read(loggerProvider);
      // Not `onLocalWrite`: a photo or crew note changes nothing listed here.
      final sub = repo.onRecordWrite.listen(
        (_) => ref.invalidateSelf(),
        onError: (Object e, StackTrace st) =>
            logger.warn('HIST-LOAD invalidate error', e, st),
      );
      ref.onDispose(sub.cancel);
      final visits = await repo.fetchClientHistory(
        clientId: clientId,
        limit: kClientJobHistoryScan + 1,
        cap: kClientJobHistoryScan,
        pastOnly: true,
      );
      return visits.take(kClientJobHistoryVisits).toList();
    });
