import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/appointment_history_providers.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

const HistorySearchKey _leak = (query: 'leak', employeeId: null);

void main() {
  late _MockAppointmentsRepo repo;
  late StreamController<void> localWrites;
  late StreamController<void> recordWrites;
  late ProviderContainer container;

  setUp(() {
    repo = _MockAppointmentsRepo();
    localWrites = StreamController<void>.broadcast();
    recordWrites = StreamController<void>.broadcast();
    when(() => repo.onLocalWrite).thenAnswer((_) => localWrites.stream);
    when(() => repo.onRecordWrite).thenAnswer((_) => recordWrites.stream);
    when(() => repo.searchHistory(any())).thenAnswer((_) async => const []);

    container = ProviderContainer(
      overrides: [appointmentsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(() async {
      container.dispose();
      await localWrites.close();
      await recordWrites.close();
    });
  });

  test('a local appointment write invalidates the committed search results '
      '(a just-deleted visit must not stay listed)', () async {
    container.listen(historySearchProvider(_leak), (_, _) {});
    await container.read(historySearchProvider(_leak).future);
    verify(() => repo.searchHistory('leak')).called(1);

    localWrites.add(null);
    // Let the stream event deliver and the invalidation land.
    await Future<void>.delayed(Duration.zero);
    await container.read(historySearchProvider(_leak).future);

    verify(() => repo.searchHistory('leak')).called(1);
  });

  test('disposing the provider cancels its local-write subscription', () async {
    final sub = container.listen(historySearchProvider(_leak), (_, _) {});
    await container.read(historySearchProvider(_leak).future);
    expect(localWrites.hasListener, isTrue);

    sub.close();
    // AutoDispose teardown runs after the current microtask loop.
    await Future<void>.delayed(Duration.zero);
    expect(localWrites.hasListener, isFalse);
  });

  group('clientJobHistoryProvider', () {
    AppointmentRecord visit(int i) => AppointmentRecord(
      id: 'v$i',
      startTime: DateTime(2026, 6, 1, 9),
      endTime: DateTime(2026, 6, 1, 10),
      status: 'done',
    );

    void stubHistory(int count) => when(
      () => repo.fetchClientHistory(
        clientId: any(named: 'clientId'),
        limit: any(named: 'limit'),
        cap: any(named: 'cap'),
        pastOnly: any(named: 'pastOnly'),
      ),
    ).thenAnswer((_) async => [for (var i = 0; i < count; i++) visit(i)]);

    test('reads a bounded window of PAST visits only', () async {
      stubHistory(1);
      container.listen(clientJobHistoryProvider('c1'), (_, _) {});
      await container.read(clientJobHistoryProvider('c1').future);

      verify(
        () => repo.fetchClientHistory(
          clientId: 'c1',
          limit: kClientJobHistoryScan + 1,
          cap: kClientJobHistoryScan,
          pastOnly: true,
        ),
      ).called(1);
    });

    test('lists at most kClientJobHistoryVisits visits', () async {
      stubHistory(kClientJobHistoryScan);
      container.listen(clientJobHistoryProvider('c1'), (_, _) {});

      final visits = await container.read(
        clientJobHistoryProvider('c1').future,
      );

      expect(visits, hasLength(kClientJobHistoryVisits));
    });

    test('a photo or crew-note poke does NOT re-read the history', () async {
      stubHistory(1);
      container.listen(clientJobHistoryProvider('c1'), (_, _) {});
      await container.read(clientJobHistoryProvider('c1').future);

      localWrites.add(null);
      await Future<void>.delayed(Duration.zero);
      await container.read(clientJobHistoryProvider('c1').future);

      verify(
        () => repo.fetchClientHistory(
          clientId: 'c1',
          limit: any(named: 'limit'),
          cap: any(named: 'cap'),
          pastOnly: any(named: 'pastOnly'),
        ),
      ).called(1);
    });

    test('a write to an appointment re-reads the history', () async {
      stubHistory(1);
      container.listen(clientJobHistoryProvider('c1'), (_, _) {});
      await container.read(clientJobHistoryProvider('c1').future);

      recordWrites.add(null);
      await Future<void>.delayed(Duration.zero);
      await container.read(clientJobHistoryProvider('c1').future);

      verify(
        () => repo.fetchClientHistory(
          clientId: 'c1',
          limit: any(named: 'limit'),
          cap: any(named: 'cap'),
          pastOnly: any(named: 'pastOnly'),
        ),
      ).called(2);
    });
  });
}
