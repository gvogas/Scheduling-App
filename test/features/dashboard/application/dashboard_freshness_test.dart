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

  test(
    'local appointment writes and client mutations refresh one-shot data',
    () async {
      final appointments = _Appointments();
      final clients = _Clients();
      final writes = StreamController<void>.broadcast(sync: true);
      when(() => appointments.onRecordWrite).thenAnswer((_) => writes.stream);
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
      await container.read(dashboardHistoryProvider.future);
      await container.read(newClientsProvider.future);
      verify(() => appointments.fetchInRange(any())).called(1);
      verify(() => clients.fetchClientsCreatedSince(any())).called(1);
      writes.add(null);
      container.read(clientsRefreshProvider.notifier).bump();
      await container.read(dashboardHistoryProvider.future);
      await container.read(newClientsProvider.future);
      verify(() => appointments.fetchInRange(any())).called(1);
      verify(() => clients.fetchClientsCreatedSince(any())).called(1);
      container.dispose();
      await writes.close();
    },
  );
}
