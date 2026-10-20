import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sections/client_job_history_section.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

class _FakeAppointmentsRepository extends Fake
    implements AppointmentsRepository {
  _FakeAppointmentsRepository(this._records);

  final List<AppointmentRecord> _records;

  @override
  Stream<Map<String, DateTime?>> get onRecordWrite => const Stream.empty();

  @override
  Stream<void> get onLocalWrite => const Stream.empty();

  @override
  Future<List<AppointmentRecord>> fetchClientHistory({
    required String clientId,
    int limit = 50,
    int? cap,
    bool pastOnly = false,
  }) async => _records;
}

/// The admin details sheet looks the linked client up; nothing is on file.
class _FakeClientsRepository extends Fake implements ClientsRepository {
  @override
  Future<ClientRecord?> getClientById(String id) async => null;
}

AppointmentRecord _job(String title) => AppointmentRecord(
  id: 't1',
  title: title,
  clientId: 'c1',
  startTime: DateTime(2026, 6, 1, 14),
  endTime: DateTime(2026, 6, 1, 15),
  status: 'done',
);

Widget _harness(List<AppointmentRecord> records, {bool isAdmin = false}) =>
    ProviderScope(
      overrides: [
        appointmentsRepositoryProvider.overrideWithValue(
          _FakeAppointmentsRepository(records),
        ),
        employeeColorMapProvider.overrideWithValue(const <String, Color>{}),
        isActiveAdminProvider.overrideWithValue(isAdmin),
        clientsRepositoryProvider.overrideWithValue(_FakeClientsRepository()),
      ],
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ClientJobHistorySection(clientId: 'c1'),
          ),
        ),
      ),
    );

void main() {
  // The admin details sheet hosts the action-bar tour; under the shard's mock store it would start and hang pumpAndSettle.
  setUp(markAllToursSeen);

  testWidgets('renders a card per job with the section header', (tester) async {
    await tester.pumpWidget(_harness([_job('Water heater replacement')]));
    await tester.pumpAndSettle();

    // SectionLabel renders its text uppercased.
    expect(find.text('JOB HISTORY'), findsOneWidget);
    expect(find.byType(AppointmentCard), findsOneWidget);
    expect(find.text('Water heater replacement'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('a job opens with the live admin gate as its actions', () {
    testWidgets("an admin reaches the done job's Edit", (tester) async {
      // History-view parity: this is where finished jobs live, and the edit
      // form is the only route back off Complete.
      await tester.pumpWidget(
        _harness([_job('Water heater replacement')], isAdmin: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Water heater replacement'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('anyone else gets the read-only sheet', (tester) async {
      await tester.pumpWidget(_harness([_job('Water heater replacement')]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Water heater replacement'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsNothing);
    });
  });

  testWidgets('renders at most 50 cards however deep the history is', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness([for (var i = 0; i < 80; i++) _job('Job $i')]),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(AppointmentCard, skipOffstage: false),
      findsNWidgets(50),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the empty line when the client has no jobs', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const []));
    await tester.pumpAndSettle();

    // SectionLabel renders its text uppercased.
    expect(find.text('JOB HISTORY'), findsOneWidget);
    expect(find.text('No jobs yet'), findsOneWidget);
    expect(find.byType(AppointmentCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
