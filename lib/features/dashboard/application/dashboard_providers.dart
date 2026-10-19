import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/core/utils/presentation_time_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_aggregator.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_period.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/policies/availability_conflict_policy.dart';

/// Injectable clock for tests. The range below is midnight-aligned, which
/// keeps it stable and avoids extra listener churn.
final dashboardClockProvider = Provider<DateTime Function()>(
  (ref) => ref.watch(presentationClockProvider),
);

final dashboardNowProvider = Provider.autoDispose<DateTime>((ref) {
  ref.watch(presentationTimeProvider);
  return ref.watch(dashboardClockProvider)();
});

final _dashboardDayProvider = Provider.autoDispose<DateTime>(
  (ref) => ref.watch(dashboardNowProvider).dateOnly,
);

/// The whole 8-week window. Only the new-clients read uses it now — the
/// appointment side is split into a live half and a one-shot half below.
final dashboardRangeProvider = Provider.autoDispose<AppointmentDateRange>(
  (ref) => DashboardAggregator.rangeAround(ref.watch(_dashboardDayProvider)),
);

/// The current week onwards — the only part of the window that can change
/// while the dashboard is open, and therefore the only part worth a listener.
final dashboardLiveRangeProvider = Provider.autoDispose<AppointmentDateRange>(
  (ref) =>
      DashboardAggregator.liveRangeAround(ref.watch(_dashboardDayProvider)),
);

/// The seven settled weeks behind it, read ONCE.
final dashboardHistoryRangeProvider =
    Provider.autoDispose<AppointmentDateRange>(
      (ref) => DashboardAggregator.historyRangeAround(
        ref.watch(_dashboardDayProvider),
      ),
    );

/// Coalesces a write burst (an overdue review commits per 450-doc chunk).
const Duration kDashboardHistoryRefreshDebounce = Duration(seconds: 2);

/// One-shot read of the settled weeks, kept warm like the live half.
final dashboardHistoryProvider =
    FutureProvider.autoDispose<List<AppointmentRecord>>((ref) async {
      keepWarmWithGrace(ref);
      final range = ref.watch(dashboardHistoryRangeProvider);
      final repo = ref.watch(appointmentsRepositoryProvider);
      final logger = ref.read(loggerProvider);
      final refresh = Debouncer.tagged(
        kDashboardHistoryRefreshDebounce,
        logger: logger,
        tag: 'DASH-LOAD history refresh failed',
      );
      ref.onDispose(refresh.dispose);
      Set<String>? heldIds;
      // The live listener already covers writes outside the history bounds.
      final sub = repo.onRecordWrite.listen(
        (written) {
          if (DashboardAggregator.writeTouchesHistory(
            written,
            range,
            heldIds,
          )) {
            refresh.run(ref.invalidateSelf);
          }
        },
        onError: (Object e, StackTrace st) =>
            logger.warn('DASH-LOAD history write listener failed', e, st),
      );
      ref.onDispose(sub.cancel);
      final records = await repo.fetchInRange(range);
      heldIds = {for (final record in records) ?record.id};
      return records;
    });

/// Clients created within the window, newest first, archived excluded.
final newClientsProvider = FutureProvider.autoDispose<List<ClientRecord>>((
  ref,
) async {
  keepWarmWithGrace(ref);
  ref.watch(clientsRefreshProvider);
  final range = ref.watch(dashboardRangeProvider);
  final clients = await ref
      .watch(clientsRepositoryProvider)
      .fetchClientsCreatedSince(range.start);
  final recent = [
    for (final client in clients)
      if (client.createdAt != null && !client.archived) client,
  ]..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));
  return recent;
});

/// Client createdAt dates, derived from [newClientsProvider] so both agree.
final newClientDatesProvider = Provider.autoDispose<AsyncValue<List<DateTime>>>(
  (ref) => ref
      .watch(newClientsProvider)
      .whenData((clients) => [for (final c in clients) c.createdAt!]),
);

/// The KPI period — an in-memory filter that must never reach a query.
final dashboardPeriodProvider =
    NotifierProvider.autoDispose<DashboardPeriodController, DashboardPeriod>(
      DashboardPeriodController.new,
    );

class DashboardPeriodController extends Notifier<DashboardPeriod> {
  @override
  DashboardPeriod build() => DashboardPeriod.today;

  /// Re-tapping the active segment is a no-op rather than a rebuild of every
  /// section watching this.
  void select(DashboardPeriod period) {
    // The guard also stops a re-tap logging a change.
    if (period == state) return;
    ref
        .read(analyticsServiceProvider)
        .logDashboardPeriodChanged(period: period.name);
    state = period;
  }
}

/// The two halves merged by doc id, with time off dropped once here.
final dashboardRecordsProvider =
    Provider.autoDispose<AsyncValue<List<AppointmentRecord>>>((ref) {
      final liveRange = ref.watch(dashboardLiveRangeProvider);
      final appointments = ref.watch(appointmentsInRangeProvider(liveRange));
      final history = ref.watch(dashboardHistoryProvider);

      final failure = _firstFailure<List<AppointmentRecord>>([
        appointments,
        history,
      ]);
      if (failure != null) return failure;
      // Merged by doc id: the two queries overlap by a fortnight.
      return AsyncValue.data([
        for (final record in DashboardAggregator.mergeById(
          appointments.requireValue,
          history.requireValue,
        ))
          if (!record.isTimeOff) record,
      ]);
    });

/// The KPI numbers for the selected period.
final dashboardPeriodSummaryProvider =
    Provider.autoDispose<AsyncValue<PeriodSummary>>((ref) {
      final records = ref.watch(dashboardRecordsProvider);
      final clientDates = ref.watch(newClientDatesProvider);

      final failure = _firstFailure<PeriodSummary>([records, clientDates]);
      if (failure != null) return failure;
      return AsyncValue.data(
        DashboardAggregator.computePeriodSummary(
          appointments: records.requireValue,
          clientCreatedDates: clientDates.requireValue,
          window: ref
              .watch(dashboardPeriodProvider)
              .windowFor(ref.watch(dashboardNowProvider)),
        ),
      );
    });

/// Combines records, assignable employees and new clients into stats.
final dashboardStatsProvider = Provider.autoDispose<AsyncValue<DashboardStats>>(
  (ref) {
    final records = ref.watch(dashboardRecordsProvider);
    final employees = ref.watch(assignableEmployeesProvider);
    final clientDates = ref.watch(newClientDatesProvider);

    final failure = _firstFailure<DashboardStats>([
      records,
      employees,
      clientDates,
    ]);
    if (failure != null) return failure;
    return AsyncValue.data(
      DashboardAggregator.computeStats(
        appointments: records.requireValue,
        employees: employees.requireValue,
        clientCreatedDates: clientDates.requireValue,
        now: ref.watch(dashboardNowProvider),
      ),
    );
  },
);

/// Re-fetches the errored sources; invalidating a combiner re-reads their cached error.
void retryDashboardSources(WidgetRef ref) {
  final live = appointmentsInRangeProvider(
    ref.read(dashboardLiveRangeProvider),
  );
  if (ref.read(live).hasError) ref.invalidate(live);
  if (ref.read(dashboardHistoryProvider).hasError) {
    ref.invalidate(dashboardHistoryProvider);
  }
  if (ref.read(newClientsProvider).hasError) ref.invalidate(newClientsProvider);
  if (ref.read(employeesStreamProvider).hasError) {
    ref.invalidate(employeesStreamProvider);
  }
}

/// Invited accounts never set up, oldest first (null `createdAt` last).
final neverSetUpAccountsProvider =
    Provider.autoDispose<AsyncValue<List<EmployeeRecord>>>(
      (ref) => ref.watch(allUsersStreamProvider).whenData((users) {
        // Exact match: an empty or unknown status is not an invited account.
        return [
          for (final user in users)
            if (user.isInvited) user,
        ]..sort((a, b) {
          final aAt = a.createdAt;
          final bAt = b.createdAt;
          if (aAt == null) return bAt == null ? 0 : 1;
          if (bAt == null) return -1;
          return aAt.compareTo(bAt);
        });
      }),
    );

/// A person and the weekdays they hold booked work on while being marked
/// unavailable for them.
typedef AvailabilityConflict = ({EmployeeRecord employee, Set<int> days});

/// Roster-wide availability conflicts over the live window only.
final availabilityConflictsProvider =
    Provider.autoDispose<AsyncValue<List<AvailabilityConflict>>>((ref) {
      final records = ref.watch(dashboardRecordsProvider);
      final employees = ref.watch(assignableEmployeesProvider);

      final failure = _firstFailure<List<AvailabilityConflict>>([
        records,
        employees,
      ]);
      if (failure != null) return failure;

      final range = ref.watch(dashboardLiveRangeProvider);
      // Grouped by assignee in ONE pass, not a filtered copy per employee.
      final byEmployee = <String, List<AppointmentRecord>>{};
      for (final a in records.requireValue) {
        for (final id in a.employeeIds) {
          (byEmployee[id] ??= <AppointmentRecord>[]).add(a);
        }
      }
      return AsyncValue.data([
        for (final employee in employees.requireValue)
          if (daysBookedOutsideAvailability(
                appointments: byEmployee[employee.id] ?? const [],
                range: range,
                workingDays: employee.workingDays,
              )
              case final days when days.isNotEmpty)
            (employee: employee, days: days),
      ]);
    });

/// The first error, else loading, among [sources]; null once all have data.
AsyncValue<T>? _firstFailure<T>(List<AsyncValue<Object?>> sources) {
  for (final source in sources) {
    if (source.hasError) {
      return AsyncValue.error(
        source.error!,
        source.stackTrace ?? StackTrace.current,
      );
    }
  }
  if (sources.any((source) => source.isLoading)) {
    return const AsyncValue.loading();
  }
  return null;
}
