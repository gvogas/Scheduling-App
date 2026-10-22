import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/utils/presentation_time_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/dashboard/application/dashboard_providers.dart';

class _Appointments extends Mock implements AppointmentsRepository {}

class _Clients extends Mock implements ClientsRepository {}

void main() {
  setUpAll(() {
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(
      AppointmentDateRange(start: DateTime(2026), end: DateTime(2027)),
    );
  });

  testWidgets(
    'minute ticks change presentation without reopening range queries',
    (tester) async {
      var now = DateTime(2026, 10, 18, 23, 58, 59);
      final container = ProviderContainer(
        overrides: [presentationClockProvider.overrideWithValue(() => now)],
      );
      final times = <DateTime>[];
      final ranges = <AppointmentDateRange>[];
      container
        ..listen(
          dashboardNowProvider,
          (_, value) => times.add(value),
          fireImmediately: true,
        )
        ..listen(
          dashboardRangeProvider,
          (_, value) => ranges.add(value),
          fireImmediately: true,
        );
      final original = ranges.single;
      now = DateTime(2026, 10, 18, 23, 59);
      await tester.pump(const Duration(seconds: 2));
      expect(times.last, now);
      expect(ranges, [original]);
      now = DateTime(2026, 10, 19);
      await tester.pump(const Duration(minutes: 1));
      expect(times.last, now);
      expect(ranges.length, 2);
      expect(ranges.last, isNot(original));
      container.dispose();
    },
  );

  testWidgets('the one-shot reads outlive a 3-minute absence but not an hour', (
    tester,
  ) async {
    // Both self-invalidate on write and roll over at midnight, so leaving the
    // dashboard is no reason to drop ~2k read documents after three minutes.
    final appointments = _Appointments();
    final clients = _Clients();
    when(
      () => appointments.onRecordWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(() => appointments.fetchInRange(any())).thenAnswer((_) async => []);
    when(
      () => clients.fetchClientsCreatedSince(any()),
    ).thenAnswer((_) async => []);
    final container = ProviderContainer(
      overrides: [
        appointmentsRepositoryProvider.overrideWithValue(appointments),
        clientsRepositoryProvider.overrideWithValue(clients),
      ],
    );

    Future<void> visit() async {
      final history = container.listen(dashboardHistoryProvider, (_, _) {});
      final recent = container.listen(newClientsProvider, (_, _) {});
      await container.read(dashboardHistoryProvider.future);
      await container.read(newClientsProvider.future);
      history.close();
      recent.close();
    }

    await visit();
    await tester.pump(const Duration(minutes: 10));
    await visit();
    verify(() => appointments.fetchInRange(any())).called(1);
    verify(() => clients.fetchClientsCreatedSince(any())).called(1);

    // `verify` counts since the last verify: one NEW read each after the grace.
    await tester.pump(kDashboardReadKeepAlive + const Duration(seconds: 1));
    await visit();
    verify(() => appointments.fetchInRange(any())).called(1);
    verify(() => clients.fetchClientsCreatedSince(any())).called(1);
    // Disposing cancels the eviction timer the last visit armed.
    container.dispose();
  });

  test('client mutations refresh the new-clients read', () async {
    final appointments = _Appointments();
    final clients = _Clients();
    when(
      () => appointments.onRecordWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(() => appointments.fetchInRange(any())).thenAnswer((_) async => []);
    when(
      () => clients.fetchClientsCreatedSince(any()),
    ).thenAnswer((_) async => []);
    final container =
        ProviderContainer(
            overrides: [
              appointmentsRepositoryProvider.overrideWithValue(appointments),
              clientsRepositoryProvider.overrideWithValue(clients),
            ],
          )
          ..listen(dashboardHistoryProvider, (_, _) {})
          ..listen(newClientsProvider, (_, _) {});
    await container.read(newClientsProvider.future);
    verify(() => clients.fetchClientsCreatedSince(any())).called(1);
    container.read(clientsRefreshProvider.notifier).bump();
    await container.read(newClientsProvider.future);
    verify(() => clients.fetchClientsCreatedSince(any())).called(1);
    container.dispose();
  });

  group('local appointment writes and the history read', () {
    // Wednesday: history runs Aug 24 (fetched from Aug 10) to Mon Oct 12.
    final now = DateTime(2026, 10, 14, 12);
    final held = AppointmentRecord(
      id: 'held',
      title: 'Old job',
      startTime: DateTime(2026, 9, 1, 9),
      endTime: DateTime(2026, 9, 1, 10),
      status: 'done',
    );
    late _Appointments appointments;
    late StreamController<Map<String, DateTime?>> writes;
    late ProviderContainer container;

    Future<void> open() async {
      appointments = _Appointments();
      writes = StreamController.broadcast(sync: true);
      when(() => appointments.onRecordWrite).thenAnswer((_) => writes.stream);
      when(
        () => appointments.fetchInRange(any()),
      ).thenAnswer((_) async => [held]);
      container = ProviderContainer(
        overrides: [
          presentationClockProvider.overrideWithValue(() => now),
          appointmentsRepositoryProvider.overrideWithValue(appointments),
        ],
      )..listen(dashboardHistoryProvider, (_, _) {});
      await container.read(dashboardHistoryProvider.future);
      verify(() => appointments.fetchInRange(any())).called(1);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(kDashboardHistoryRefreshDebounce);
      await container.read(dashboardHistoryProvider.future);
    }

    Future<void> close() async {
      container.dispose();
      await writes.close();
    }

    testWidgets('a write inside the live window does not re-read history', (
      tester,
    ) async {
      await open();
      writes
        ..add({'new': DateTime(2026, 10, 14, 15)})
        ..add({'other': null});
      await settle(tester);
      verifyNever(() => appointments.fetchInRange(any()));
      await close();
    });

    testWidgets('a write starting inside the history range re-reads it', (
      tester,
    ) async {
      await open();
      writes.add({'moved': DateTime(2026, 9, 15, 9)});
      await settle(tester);
      verify(() => appointments.fetchInRange(any())).called(1);
      await close();
    });

    testWidgets('a write to a held doc re-reads history (moved out, status, '
        'delete)', (tester) async {
      await open();
      writes.add({'held': DateTime(2026, 10, 14, 9)});
      await settle(tester);
      verify(() => appointments.fetchInRange(any())).called(1);
      writes.add({'held': null});
      await settle(tester);
      verify(() => appointments.fetchInRange(any())).called(1);
      await close();
    });

    testWidgets('a burst of history writes coalesces into one re-read', (
      tester,
    ) async {
      await open();
      for (var chunk = 0; chunk < 3; chunk++) {
        writes.add({'held': null});
        await tester.pump(kDashboardHistoryRefreshDebounce ~/ 2);
      }
      verifyNever(() => appointments.fetchInRange(any()));
      await settle(tester);
      verify(() => appointments.fetchInRange(any())).called(1);
      await close();
    });
  });
}
