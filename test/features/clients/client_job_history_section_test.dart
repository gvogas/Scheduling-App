import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/clients/widgets/sections/client_job_history_section.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

class _FakeAppointmentsRepository extends Fake
    implements AppointmentsRepository {
  _FakeAppointmentsRepository(this._records);

  final List<AppointmentRecord> _records;

  @override
  Stream<void> get onRecordWrite => const Stream<void>.empty();

  @override
  Future<List<AppointmentRecord>> fetchClientHistory({
    required String clientId,
    int limit = 50,
    int? cap,
    bool pastOnly = false,
  }) async => _records;
}

AppointmentRecord _job(String title) => AppointmentRecord(
  id: 't1',
  title: title,
  clientId: 'c1',
  startTime: DateTime(2026, 6, 1, 14),
  endTime: DateTime(2026, 6, 1, 15),
  status: 'done',
);

Widget _harness(List<AppointmentRecord> records) => ProviderScope(
  overrides: [
    appointmentsRepositoryProvider.overrideWithValue(
      _FakeAppointmentsRepository(records),
    ),
    employeeColorMapProvider.overrideWithValue(const <String, Color>{}),
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
  testWidgets('renders a card per job with the section header', (tester) async {
    await tester.pumpWidget(_harness([_job('Water heater replacement')]));
    await tester.pumpAndSettle();

    // SectionLabel renders its text uppercased.
    expect(find.text('JOB HISTORY'), findsOneWidget);
    expect(find.byType(AppointmentCard), findsOneWidget);
    expect(find.text('Water heater replacement'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
