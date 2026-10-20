import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/widgets/views/appointment_history_view.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

class _MockAppointmentsRepository extends Mock
    implements AppointmentsRepository {}

AppointmentRecord _appt({
  required String id,
  required String title,
  required DateTime start,
  required String employeeId,
  required String employeeName,
  String clientPhone = '',
  String status = 'done',
}) => AppointmentRecord(
  id: id,
  title: title,
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
  clientName: 'Client $title',
  clientPhone: clientPhone,
  employeeIds: [employeeId],
  employeeNames: [employeeName],
  status: status,
);

final _aliceJob = _appt(
  id: '1',
  title: 'Alice Job',
  start: DateTime(2025, 5, 1, 9),
  employeeId: 'e1',
  employeeName: 'Alice',
);

final _bobJob = _appt(
  id: '2',
  title: 'Bob Job',
  start: DateTime(2024, 8, 3, 9),
  employeeId: 'e2',
  employeeName: 'Bob',
);

final _cancelledJob = _appt(
  id: '3',
  title: 'Called off',
  start: DateTime(2025, 5, 2, 9),
  employeeId: 'e1',
  employeeName: 'Alice',
  status: 'cancelled',
);

Widget _wrap(
  List<AppointmentRecord> history, {
  String searchQuery = '',
  AppointmentsRepository? repository,
  bool isAdmin = false,
}) {
  final repo = repository ?? _MockAppointmentsRepository();
  if (repository == null) {
    when(() => repo.onLocalWrite).thenAnswer((_) => const Stream<void>.empty());
    when(
      () => repo.fetchHistoryPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
      ),
    ).thenAnswer((_) async => history);
  }
  return ProviderScope(
    overrides: [appointmentsRepositoryProvider.overrideWithValue(repo)],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: Scaffold(
          body: AppointmentHistoryView(
            searchQuery: searchQuery,
            isAdmin: isAdmin,
          ),
        ),
      ),
    ),
  );
}

/// The month bars actually painted inside the viewport, in the order they sit
/// down the screen. A bar that has been pushed out stays in the widget tree
/// while it is inside the cache extent, so presence alone proves nothing.
List<String> _visibleMonthBars(WidgetTester tester) {
  final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final bars = <(double, String)>[];
  for (final element in find.byType(SectionLabel).evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    if (rect.bottom <= 0 || rect.top >= screen) continue;
    // SectionLabel uppercases at render, so match what is actually on screen.
    bars.add((rect.top, (element.widget as SectionLabel).text.toUpperCase()));
  }
  bars.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final bar in bars) bar.$2];
}

void main() {
  group("the row opens the detail sheet with the caller's role", () {
    testWidgets("an admin reaches the completed job's edit button", (
      tester,
    ) async {
      await tester.pumpWidget(_wrap([_aliceJob], isAdmin: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Job'));
      await tester.pumpAndSettle();

      // History holds only done and cancelled jobs, so this button is the one
      // affordance an admin needs here — and the only route back off Complete,
      // since the status picker lives in the edit form behind it.
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('an employee gets the read-only sheet', (tester) async {
      await tester.pumpWidget(_wrap([_aliceJob]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice Job'));
      await tester.pumpAndSettle();

      // showActions defaults CLOSED. Offering an employee the edit route here
      // would only earn them an opaque permission-denied from the rules.
      expect(find.text('Edit'), findsNothing);
      // "Complete" twice, not once: the header's status chip and the action
      // bar's disabled indicator both read it on a finished job.
      expect(find.text('Complete'), findsWidgets);
    });
  });

  testWidgets('groups appointments under a sticky month bar', (tester) async {
    await tester.pumpWidget(_wrap([_aliceJob, _bobJob]));
    await tester.pumpAndSettle();

    // The month bar carries the year, so the old bold year separator is gone —
    // keeping both would be a third heading repeating the second.
    expect(find.text('MAY 2025'), findsOneWidget);
    expect(find.text('AUGUST 2024'), findsOneWidget);
    expect(find.text('2025'), findsNothing);
    expect(find.text('Alice Job'), findsOneWidget);
    expect(find.text('Bob Job'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a month bar pushes the previous one out instead of stacking', (
    tester,
  ) async {
    // Twelve rows a month, comfortably under the 25-row page size so the mock
    // is never asked for a second page.
    final rows = [
      for (var day = 12; day >= 1; day--)
        _appt(
          id: 'a$day',
          title: 'August $day',
          start: DateTime(2026, 8, day, 9),
          employeeId: 'e1',
          employeeName: 'Alice',
        ),
      for (var day = 12; day >= 1; day--)
        _appt(
          id: 'j$day',
          title: 'July $day',
          start: DateTime(2026, 7, day, 9),
          employeeId: 'e1',
          employeeName: 'Alice',
        ),
    ];

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(rows));
    await tester.pumpAndSettle();

    expect(_visibleMonthBars(tester), ['AUGUST 2026']);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1400));
    await tester.pumpAndSettle();

    // One bar, not two: a pinned header bounded by its own SliverMainAxisGroup
    // scrolls away with its rows. Without that, a year of history would park
    // twelve bars across the top.
    expect(_visibleMonthBars(tester), ['JULY 2026']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail carries the weekday and day of each new day', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _bobJob]));
    await tester.pumpAndSettle();

    // 1 May 2025 was a Thursday; 3 Aug 2024 a Saturday.
    expect(find.text('THU'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('SAT'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows one mono count carrying the cancelled share', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _bobJob, _cancelledJob]));
    await tester.pumpAndSettle();

    // The cancelled clause is a SUBSET of the total, not an addition.
    expect(find.text('3 JOBS · 1 CANCELLED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drops the cancelled clause when nothing was cancelled', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _bobJob]));
    await tester.pumpAndSettle();

    expect(find.text('2 JOBS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Cancelled quick filter narrows the list to cancelled work', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _cancelledJob]));
    await tester.pumpAndSettle();

    // The chip reads the app's existing status label, so it matches the
    // StatusChip on the card in the same row rather than inventing wording.
    await tester.tap(find.widgetWithText(FilterChip, 'Cancelled'));
    await tester.pumpAndSettle();

    expect(find.text('Called off'), findsOneWidget);
    expect(find.text('Alice Job'), findsNothing);
    expect(find.text('1 JOB · 1 CANCELLED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the selected quick filter clears it', (tester) async {
    await tester.pumpWidget(_wrap([_aliceJob, _cancelledJob]));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'Cancelled'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Cancelled'));
    await tester.pumpAndSettle();

    expect(find.text('Alice Job'), findsOneWidget);
    expect(find.text('Called off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee filter narrows the list to that employee', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _bobJob]));
    await tester.pumpAndSettle();

    // The chip now opens a single-select sheet rather than a MenuAnchor.
    await tester.tap(find.text('All staff'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();

    expect(find.text('Bob Job'), findsOneWidget);
    expect(find.text('Alice Job'), findsNothing);
    // May 2025 was only Alice's month, so its bar is gone too.
    expect(find.text('MAY 2025'), findsNothing);
    expect(find.text('AUGUST 2024'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('search renders flat, and the rail changes shape to carry the date', () {
    // Search spans every appointment, so its hits are not a contiguous run of
    // days — month bars over scattered results would be noise, which is why the
    // rail has to say the month itself.
    final thisYear = DateTime.now().year;
    final recentJob = _appt(
      id: '4',
      title: 'Recent Job',
      start: DateTime(thisYear, 1, 6, 9),
      employeeId: 'e1',
      employeeName: 'Alice',
    );

    testWidgets('drops the month bars', (tester) async {
      await tester.pumpWidget(_wrap([recentJob, _bobJob], searchQuery: 'Job'));
      await tester.pumpAndSettle();

      expect(find.byType(SliverPersistentHeader), findsNothing);
      expect(find.text('AUGUST 2024'), findsNothing);
      expect(find.text('2 RESULTS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the rail speaks the month, and the year only when older', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap([recentJob, _bobJob], searchQuery: 'Job'));
      await tester.pumpAndSettle();

      // Month instead of weekday: a bare `Tue 11` is ambiguous the moment the
      // hits cross months.
      expect(find.text('JAN'), findsOneWidget);
      expect(find.text('AUG'), findsOneWidget);
      // The 2024 hit says its year; this year's does not — that would be
      // overhead on every row.
      expect(find.text('2024'), findsOneWidget);
      expect(find.text('$thisYear'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the list keeps its month bars under a chip filter alone', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_aliceJob, _cancelledJob, _bobJob]));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'Complete'));
    await tester.pumpAndSettle();

    // Chip filters leave the rows a contiguous run of days, so only SEARCH
    // goes flat.
    expect(find.text('MAY 2025'), findsOneWidget);
    expect(find.text('AUGUST 2024'), findsOneWidget);
    expect(find.text('Called off'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search matches a client phone number', (tester) async {
    final aliceWithPhone = _appt(
      id: '1',
      title: 'Alice Job',
      start: DateTime(2025, 5, 1, 9),
      employeeId: 'e1',
      employeeName: 'Alice',
      clientPhone: '(514) 555-0199',
    );

    // Query is digits only, formatted differently than the stored number.
    await tester.pumpWidget(
      _wrap([aliceWithPhone, _bobJob], searchQuery: '5550199'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice Job'), findsOneWidget);
    expect(find.text('Bob Job'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an empty state with no history', (tester) async {
    await tester.pumpWidget(_wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('No appointments found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first-page error offers a Retry that reloads history', (
    tester,
  ) async {
    final repo = _MockAppointmentsRepository();
    when(() => repo.onLocalWrite).thenAnswer((_) => const Stream<void>.empty());
    var calls = 0;
    when(
      () => repo.fetchHistoryPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
      ),
    ).thenAnswer((_) async {
      if (calls++ == 0) throw Exception('boom');
      return [_aliceJob];
    });

    await tester.pumpWidget(_wrap(const [], repository: repo));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("Couldn't load the appointment history"),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Alice Job'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search error offers a Retry that re-runs the search', (
    tester,
  ) async {
    final repo = _MockAppointmentsRepository();
    when(() => repo.onLocalWrite).thenAnswer((_) => const Stream<void>.empty());
    when(
      () => repo.fetchHistoryPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
      ),
    ).thenAnswer((_) async => [_aliceJob]);
    when(() => repo.searchHistory(any())).thenThrow(Exception('boom'));

    // Start unfiltered, then type a query that no loaded row matches, so the
    // committed database search (and its failure) is what gets rendered.
    await tester.pumpWidget(_wrap(const [], repository: repo));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _wrap(const [], repository: repo, searchQuery: 'zzz'),
    );
    // Let the search debounce commit, then the provider fail.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("Couldn't load the appointment history"),
      findsOneWidget,
    );

    when(() => repo.searchHistory(any())).thenAnswer((_) async => [_bobJob]);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Bob Job'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history view does not overflow on phone width at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _wrap([_aliceJob, _bobJob]),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
