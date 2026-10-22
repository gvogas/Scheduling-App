// The "Done" rule is the only thing in the agenda that depends on the day
// being sorted open-then-closed, so it is pinned here rather than in the card.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/l10n/l10n.dart';

final _day = DateTime(2026, 8, 3);

AppointmentDaySlice _slice({required String id, required String status}) {
  final record = AppointmentRecord(
    id: id,
    title: id,
    startTime: DateTime(2026, 8, 3, 9),
    endTime: DateTime(2026, 8, 3, 10),
    clientName: 'Marchetti Residence',
    status: status,
  );
  return sliceFor(record, _day)!;
}

Widget _wrap(
  List<AppointmentDaySlice> events, {
  bool hasError = false,
  VoidCallback? onRetry,
}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: lightTheme(),
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          AgendaSliverList(
            events: events,
            nameMap: const {},
            colorMap: const {},
            onAppointmentTap: (_) {},
            hasError: hasError,
            onRetry: onRetry,
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
  setUpAll(() async {
    await initializeDateFormatting('en_CA');
  });

  testWidgets('rules off the closed block and counts the COMPLETE work only', (
    tester,
  ) async {
    // The cancelled card sinks into the same block and renders there, but it
    // is not counted — a called-off visit is not work behind you (owner call,
    // 2026-08-25, which reversed counting `isClosed` here).
    await tester.pumpWidget(
      _wrap([
        _slice(id: 'open', status: 'pending'),
        _slice(id: 'done', status: 'done'),
        _slice(id: 'cancelled', status: 'cancelled'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('COMPLETE · 1'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day with no closed work shows no rule', (tester) async {
    await tester.pumpWidget(
      _wrap([
        _slice(id: 'open', status: 'pending'),
        _slice(id: 'later', status: 'in_progress'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Divider), findsNothing);
    expect(find.textContaining('COMPLETE ·'), findsNothing);
  });

  testWidgets('a day that is entirely closed still gets one rule, at the top', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([
        _slice(id: 'done', status: 'done'),
        _slice(id: 'cancelled', status: 'cancelled'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('COMPLETE · 1'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('COMPLETE · 1')).dy,
      lessThan(tester.getTopLeft(find.text('done')).dy),
    );
  });

  testWidgets('a cold error shows the error text and Retry over the empty '
      'state', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _wrap(const [], hasError: true, onRetry: () => retries++),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load appointments"), findsOneWidget);
    expect(find.text('No appointments found'), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('a card keeps its fade-in State when a job lands above it', (
    tester,
  ) async {
    // A stream emission that inserts or reorders shifts indexes; without a
    // key lookup the list re-inflated every shifted card and re-ran the stagger.
    await tester.pumpWidget(_wrap([_slice(id: 'a', status: 'pending')]));
    await tester.pumpAndSettle();
    final before = tester.state(find.byKey(const ValueKey<String?>('a')));

    await tester.pumpWidget(
      _wrap([
        _slice(id: 'new', status: 'pending'),
        _slice(id: 'a', status: 'pending'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      tester.state(find.byKey(const ValueKey<String?>('a'))),
      same(before),
    );
    expect(find.text('new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day of nothing but cancellations draws no rule', (
    tester,
  ) async {
    // Cancelled work still sinks to the tail, so without suppressing the rule
    // at zero this day would be headed "COMPLETE · 0".
    await tester.pumpWidget(
      _wrap([
        _slice(id: 'one', status: 'cancelled'),
        _slice(id: 'two', status: 'cancelled'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Divider), findsNothing);
    expect(find.textContaining('COMPLETE ·'), findsNothing);
    expect(find.text('one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
