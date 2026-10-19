// The empty state must not tell employees to "Tap +" (only admins have the
// add FAB) â€” admins keep the actionable copy, employees get a neutral message.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/event_list.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _wrap({
  required List<AppointmentRecord> events,
  required bool isAdmin,
  Map<String, String> nameMap = const {},
}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Column(
        children: [
          EventList(
            // The agenda takes day slices; these single-day jobs each slice on
            // the day they start.
            events: [for (final e in events) sliceFor(e, e.startTime)!],
            nameMap: nameMap,
            colorMap: const {},
            isAdmin: isAdmin,
            // An ordinary February day, so no holiday row joins the rows
            // under test.
            day: DateTime(2026, 2, 10),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  late List<AppointmentRecord> events;

  setUpAll(() async {
    await initializeDateFormatting('en_CA');
  });

  setUp(() {
    events = const <AppointmentRecord>[];
  });

  testWidgets('admin empty state suggests tapping the add FAB', (tester) async {
    await tester.pumpWidget(_wrap(events: events, isAdmin: true));
    await tester.pumpAndSettle();

    expect(find.text('No appointments found'), findsOneWidget);
    expect(find.text('Tap + to schedule an appointment.'), findsOneWidget);
  });

  testWidgets('employee empty state stays neutral (no + FAB to tap)', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(events: events, isAdmin: false));
    await tester.pumpAndSettle();

    expect(find.text('No appointments found'), findsOneWidget);
    expect(find.text('No appointments for this day.'), findsOneWidget);
    expect(find.text('Tap + to schedule an appointment.'), findsNothing);
  });

  testWidgets('admin empty state shows no booking button (use the FAB)', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(events: events, isAdmin: true));
    await tester.pumpAndSettle();
    // The empty state no longer carries a "New Appointment" button; admins
    // schedule via the calendar's FAB instead.
    expect(find.widgetWithText(FilledButton, 'New Appointment'), findsNothing);
  });

  testWidgets('employee empty state shows no booking button', (tester) async {
    await tester.pumpWidget(_wrap(events: events, isAdmin: false));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'New Appointment'), findsNothing);
  });

  testWidgets('appointment card collapses a multi-person crew', (tester) async {
    events = [
      AppointmentRecord(
        id: '1',
        title: 'Kitchen sink',
        startTime: DateTime(2099, 5, 6, 9),
        endTime: DateTime(2099, 5, 6, 10),
        employeeIds: const ['e1', 'e2'],
        status: 'confirmed',
      ),
    ];
    await tester.pumpWidget(
      _wrap(
        events: events,
        isAdmin: true,
        nameMap: const {'e1': 'Alice', 'e2': 'Bob'},
      ),
    );
    await tester.pumpAndSettle();

    // The card leads with the first assignee and counts the rest, rather than
    // listing every name â€” the design's `Theo +1` line.
    expect(find.textContaining('Alice +1'), findsOneWidget);
    expect(find.text('Alice, Bob'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
