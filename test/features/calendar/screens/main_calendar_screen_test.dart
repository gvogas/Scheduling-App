import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/screens/main_calendar_screen.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_header_block.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_pager.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_week_strip.dart';
import 'package:scheduling/features/calendar/widgets/views/crew_filter_button.dart';
import 'package:scheduling/features/calendar/widgets/views/week_agenda_sliver_list.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

const _jane = EmployeeRecord(
  id: 'e1',
  name: 'Jane Doe',
  email: 'jane@example.com',
  status: 'active',
);

const _bob = EmployeeRecord(
  id: 'e2',
  name: 'Bob Roy',
  email: 'bob@example.com',
  status: 'active',
);

AppointmentRecord _appointment(int id, DateTime day) => AppointmentRecord(
  id: 'a$id',
  title: 'Appt $id',
  startTime: day,
  endTime: day.add(const Duration(hours: 1)),
  clientId: 'c1',
  clientName: 'Alice',
  status: 'booked',
);

Widget _wrap({
  required Stream<List<AppointmentRecord>> appointments,
  required Stream<List<EmployeeRecord>> allUsers,
  required EmployeesRepository repo,
  Stream<List<AppointmentRecord>>? myAppointments,
  bool isAdmin = true,
  double textScale = 1,
}) {
  // `appointmentsInRangeProvider` is a family keyed by RANGE, so anything that
  // moves the focused month — tapping a week bar that belongs to the previous
  // month, paging, entering week mode near a boundary — builds a second
  // instance and listens AGAIN.
  final replayAppointments = appointments.first
    // The error-branch case completes this with an error, and a future nobody
    // has listened to yet reports that as an UNHANDLED async error and fails
    // the test.
    ..ignore();
  // Defaults to the same list, so an existing case cannot depend on WHICH
  // provider the screen picked; a case that passes its own list can.
  final replayMine = myAppointments == null
      ? replayAppointments
      : (myAppointments.first..ignore());
  return ProviderScope(
    overrides: [
      employeesRepositoryProvider.overrideWithValue(repo),
      currentUserNameProvider.overrideWithValue('Jane'),
      allUsersStreamProvider.overrideWith((_) => allUsers),
      // is deliberately NOT overridden: the crew-filter sheet must fill itself
      // from the stream this screen already watches.
      appointmentsInRangeProvider.overrideWith(
        (_, _) => Stream.fromFuture(replayAppointments),
      ),
      myAppointmentsProvider.overrideWith(
        (_, _) => Stream.fromFuture(replayMine),
      ),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: textScale,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: MainCalendar(isAdmin: isAdmin, employeeId: 'admin'),
      ),
    ),
  );
}

/// The en_CA agenda day header, spelled out literally.
///
/// The SHORT spelling: these tests run at phone width, where the full
/// "Thursday, October 1" does not fit beside the count and the view toggle and
/// the header falls back to `DateUtilsHelper.formatDayHeaderShort`.
String _dayHeader(DateTime day) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[day.weekday - 1]}, ${months[day.month - 1]} ${day.day}';
}

Key _dayKey(DateTime day) => ValueKey(
  'calendar-day-${day.year}-'
  '${day.month.toString().padLeft(2, '0')}-'
  '${day.day.toString().padLeft(2, '0')}',
);

void main() {
  late _MockEmployeesRepo repo;

  setUp(() {
    repo = _MockEmployeesRepo();
  });

  // The calendar grid lays out at full phone width — size up to a real device
  // viewport so layout assertions don't trip on cosmetic overflow.
  Future<void> withPhoneViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders the fixed header block for an admin', (tester) async {
    await withPhoneViewport(tester);
    final day = DateTime(2026, 5, 16);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([_appointment(1, day)]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    // The calendar is the one screen without an AppTopBar — its header block
    // hosts the pair instead, and that pair drops the go-home Calendar pill
    // here, since this screen IS where the pill goes.
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(CalendarHeaderBlock), findsOneWidget);
    expect(find.text('Calendar'), findsNothing);
    expect(find.text('SCHEDULE'), findsOneWidget);
    expect(find.byType(AppHeaderPair), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('icon-only controls expose localized tooltips', (tester) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open menu'), findsOneWidget);
    expect(find.byTooltip('New Appointment'), findsOneWidget);
    expect(find.byTooltip('Today'), findsOneWidget);
  });

  testWidgets('the Today pill hides while today is the day on screen', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    // The pill stays mounted and fades instead of unmounting, so assert on the
    // opacity rather than on the finder.
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byTooltip('Today'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacity.opacity, 0);
  });

  testWidgets('the Today pill shows for another day of the current month', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    // Pick a different day that is still inside the visible month — the old
    // month-keyed rule left the pill hidden here.
    final today = DateTime.now();
    final other = today.day == 1
        ? DateTime(today.year, today.month, 2)
        : DateTime(today.year, today.month, today.day - 1);
    final key = ValueKey(
      'calendar-day-${other.year}-'
      '${other.month.toString().padLeft(2, '0')}-'
      '${other.day.toString().padLeft(2, '0')}',
    );
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();

    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byTooltip('Today'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacity.opacity, 1);
  });

  testWidgets("paging a month selects that month's first day", (tester) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // The agenda names the selected day, so it is what proves the selection
    // followed the swipe instead of being left behind in the old month.
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    expect(find.text(_dayHeader(next)), findsOneWidget);
  });

  testWidgets('swiping the collapsed week strip pages a week', (tester) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byTooltip('Hide calendar'), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarWeekStrip), findsOneWidget);

    await tester.fling(
      find.byType(CalendarWeekStrip),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();

    // Next week's first day, in the locale's week order.
    final today = DateTime.now();
    final weekStart = weekStartForLocale('en_CA');
    final expected = weekOf(
      DateTime(today.year, today.month, today.day + 7),
      weekStart: weekStart,
    ).first;
    expect(find.text(_dayHeader(expected)), findsOneWidget);
  });

  testWidgets('tapping the header month opens the month and year picker', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    final today = DateTime.now();
    // EITHER label, because the header picks between them by measured width
    // (`calendar_header_block.dart`) — and this test is date-dependent, so a
    // month whose full name does not fit the phone viewport renders the short
    // one.
    final monthLabel = find.text(DateFormat.MMMM().format(today));
    final shortLabel = find.text(DateFormat.MMM().format(today));
    await tester.tap(
      monthLabel.evaluate().isNotEmpty ? monthLabel : shortLabel,
    );
    await tester.pumpAndSettle();

    // Both wheels — every month and the whole year window, as before the header
    // block replaced the app bar.
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
    expect(find.text(DateFormat.y().format(today)), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agenda header pluralizes the selected day job count', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    // The initially selected day is today.
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([_appointment(1, today)]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 JOB'), findsOneWidget);
    expect(find.textContaining('1 JOBS'), findsNothing);
  });

  testWidgets('agenda header reports how much of the day is done', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today),
          _appointment(2, today),
          _appointment(3, today).copyWith(status: 'done'),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 JOBS · 1 DONE'), findsOneWidget);
  });

  testWidgets('agenda header stays a bare count while nothing is closed', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today),
          _appointment(2, today),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 JOBS'), findsOneWidget);
  });

  testWidgets('a cancelled job is neither counted nor called done', (
    tester,
  ) async {
    // It read "1 JOB · 1 DONE": wrong twice over, and at odds with the month
    // grid, whose dots have dropped cancelled since 2026-08-17.
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today).copyWith(status: 'cancelled'),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 JOBS'), findsOneWidget);
    expect(find.textContaining('DONE'), findsNothing);
  });

  testWidgets('a cancelled job drops out of a mixed day on both sides', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today),
          _appointment(2, today).copyWith(status: 'done'),
          _appointment(3, today).copyWith(status: 'cancelled'),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 JOBS · 1 DONE'), findsOneWidget);
  });

  testWidgets('a day of only cancellations draws no Done rule', (tester) async {
    // The cards still sink to the tail; the rule would have read "Done · 0".
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today).copyWith(status: 'cancelled'),
          _appointment(2, today).copyWith(status: 'cancelled'),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 JOBS'), findsOneWidget);
    expect(find.textContaining('Done'), findsNothing);
  });

  testWidgets('the header block grows with text scale instead of clipping', (
    tester,
  ) async {
    await withPhoneViewport(tester);

    // The block sizes to its content now that it is a plain Column child, so
    // the property to pin is that it grows — the old PreferredSize had to
    // reserve height up front or the labels clipped.
    Future<double> headerHeight(double scale) async {
      await tester.pumpWidget(
        _wrap(
          appointments: Stream.value(const []),
          allUsers: Stream.value(const [_jane]),
          repo: repo,
          textScale: scale,
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(CalendarHeaderBlock)).height;
    }

    final atNormal = await headerHeight(1);
    final atDouble = await headerHeight(2);

    expect(atDouble, greaterThan(atNormal));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging the jobs up collapses the grid into the week strip', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    // Enough jobs that the agenda's own viewport actually scrolls.
    final today = DateTime.now();
    final many = [for (var i = 0; i < 14; i++) _appointment(i, today)];
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(many),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CalendarMonthPager), findsOneWidget);
    expect(find.byType(CalendarWeekStrip), findsNothing);

    // The line between the calendar and the jobs is the handle; the jobs' own
    // scrolling deliberately does nothing to the grid.
    final handle = find.byTooltip('Hide calendar');
    expect(handle, findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarMonthPager), findsOneWidget);
    expect(find.byType(CalendarWeekStrip), findsNothing);

    await tester.drag(handle, const Offset(0, -60));
    await tester.pumpAndSettle();

    // Past 24px of drag the grid unmounts and the strip rises in the header.
    expect(find.byType(CalendarWeekStrip), findsOneWidget);
    expect(find.byType(CalendarMonthPager), findsNothing);
    expect(tester.takeException(), isNull);

    // Dragging the same handle back down brings the grid back.
    await tester.drag(find.byTooltip('Show calendar'), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(find.byType(CalendarMonthPager), findsOneWidget);
    expect(find.byType(CalendarWeekStrip), findsNothing);

    // FadeInItem staggers its first 8 rows by 30ms each.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });

  testWidgets('the split layout renders the agenda header in its own pane', (
    tester,
  ) async {
    // Tablet width, so _content takes the month | agenda branch.
    tester.view.physicalSize = const Size(1024 * 2, 768 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([_appointment(1, today)]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CalendarHeaderBlock), findsOneWidget);
    expect(find.text('1 JOB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a job spanning three days is listed on every one of them', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    // Days 1–3 of the visible month: always in-month, so every cell is tappable
    // whatever today's date is.
    final now = DateTime.now();
    final spanning = AppointmentRecord(
      id: 'span',
      title: 'Three day job',
      startTime: DateTime(now.year, now.month, 1, 9),
      endTime: DateTime(now.year, now.month, 3, 17),
      clientId: 'c1',
      clientName: 'Alice',
    );
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([spanning]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    for (var day = 1; day <= 3; day++) {
      await tester.tap(find.byKey(_dayKey(DateTime(now.year, now.month, day))));
      await tester.pumpAndSettle();
      expect(
        find.text('Three day job'),
        findsOneWidget,
        reason: 'the crew is on site on day $day of the run',
      );
      expect(find.text('1 JOB'), findsOneWidget, reason: 'day $day');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a spanning card names its day within the run', (tester) async {
    await withPhoneViewport(tester);
    final now = DateTime.now();
    final spanning = AppointmentRecord(
      id: 'span',
      title: 'Three day job',
      startTime: DateTime(now.year, now.month, 1, 9),
      endTime: DateTime(now.year, now.month, 3, 17),
    );
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([spanning]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_dayKey(DateTime(now.year, now.month, 2))));
    await tester.pumpAndSettle();

    // The day-scoped window and counter — not the raw stored span.
    expect(find.textContaining('Day 2 of 3'), findsOneWidget);
  });

  testWidgets('an all-day block sorts above a timed job on the same day', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    final now = DateTime.now();
    // The 1st: always in-month, so its cell is tappable whatever today is.
    final day = DateTime(now.year, now.month);
    final timed = AppointmentRecord(
      id: 'timed',
      title: 'Timed job',
      startTime: DateTime(day.year, day.month, day.day, 8),
      endTime: DateTime(day.year, day.month, day.day, 9),
    );
    final block = AppointmentRecord(
      id: 'block',
      title: 'All day block',
      startTime: day,
      endTime: DateTime(day.year, day.month, day.day, 23, 59),
      isAllDay: true,
      isPersonal: true,
    );
    await tester.pumpWidget(
      _wrap(
        // Timed first, so source order can't be what puts the block on top.
        appointments: Stream.value([timed, block]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_dayKey(day)));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('All day block')).dy,
      lessThan(tester.getTopLeft(find.text('Timed job')).dy),
    );
  });

  testWidgets('a six-week month paints its last row above the handle', (
    tester,
  ) async {
    // A real phone WITH its insets, not the roomier bare test viewport: the bug
    // was the grid taking an even flex share of the pane, which only starves a
    // six-week month once the pane is short enough.
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    // Page forward to the next month that actually occupies six weeks, so the
    // assertion holds whatever day the suite runs on.
    final weekStart = weekStartForLocale('en_CA');
    final now = DateTime.now();
    var month = DateTime(now.year, now.month);
    while (monthGridRowCount(month, weekStart: weekStart) != 6) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      month = DateTime(month.year, month.month + 1);
    }

    // Cell 35 is the first of the sixth row, and a six-week month always has a
    // real day there.
    final lastRow = monthGridDays(month, weekStart: weekStart)[35];
    final cell = find.byKey(_dayKey(lastRow));
    expect(cell, findsOneWidget);

    // The handle is the top of the agenda: anything painted below it is under
    // the grid's clip and invisible.
    final handleTop = tester.getRect(find.byTooltip('Hide calendar')).top;
    expect(tester.getRect(cell).bottom, lessThanOrEqualTo(handleTop));
  });

  testWidgets('a six-week month at 2x text does not overflow the pane', (
    tester,
  ) async {
    // The companion to the test above, and it guards the OTHER direction.
    tester.view.physicalSize = const Size(375 * 3, 667 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 20 * 3);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    final weekStart = weekStartForLocale('en_CA');
    final now = DateTime.now();
    var month = DateTime(now.year, now.month);
    while (monthGridRowCount(month, weekStart: weekStart) != 6) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      month = DateTime(month.year, month.month + 1);
    }

    // An overflow paints as a framework error rather than an exception, so it
    // has to be read off `takeException` — a bare pump would pass regardless.
    expect(tester.takeException(), isNull);

    // And the agenda must still be given real extent: an unstarved `Expanded`
    // is what the cap exists to preserve.
    expect(find.byTooltip('Hide calendar'), findsOneWidget);
  });

  testWidgets('survives a stream error without crashing (error branch logs)', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.error(StateError('boom')),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();

    // No app bar, and no go-home pill on the calendar itself.
    expect(find.text('Calendar'), findsNothing);
    expect(find.byType(AppHeaderPair), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the crew filter button is offered to an admin only', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CrewFilterButton), findsOneWidget);
    expect(find.byTooltip('Filter by crew member'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value(const []),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
        isAdmin: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CrewFilterButton), findsNothing);
  });

  testWidgets('an employee calendar reads the employee-scoped stream', (
    tester,
  ) async {
    // Employees see only appointments whose `employeeIds` hold their doc id —
    // the ternary picking `myAppointmentsProvider` is the client half of that
    // invariant, so the two streams must carry DIFFERENT lists here.
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([_appointment(2, today)]),
        myAppointments: Stream.value([_appointment(1, today)]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
        isAdmin: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appt 1'), findsOneWidget);
    expect(find.text('Appt 2'), findsNothing);
  });

  testWidgets('filtering to one person hides the rest and clears back', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    final today = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today).copyWith(
            employeeIds: const ['e1'],
            employeeNames: const ['Jane Doe'],
          ),
          _appointment(2, today).copyWith(
            employeeIds: const ['e2'],
            employeeNames: const ['Bob Roy'],
          ),
        ]),
        allUsers: Stream.value(const [_jane, _bob]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Appt 1'), findsOneWidget);
    expect(find.text('Appt 2'), findsOneWidget);
    expect(find.text('2 JOBS'), findsOneWidget);

    await tester.tap(find.byTooltip('Filter by crew member'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jane Doe').last);
    await tester.pumpAndSettle();

    // The banner names the person, the other job is gone from the agenda AND
    // from the header count — the filter runs before the day index.
    expect(find.byType(CrewFilterBanner), findsOneWidget);
    expect(find.text('Showing Jane Doe'), findsOneWidget);
    expect(find.text('Appt 1'), findsOneWidget);
    expect(find.text('Appt 2'), findsNothing);
    expect(find.text('1 JOB'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Showing Jane Doe'), findsNothing);
    expect(find.text('Appt 2'), findsOneWidget);
    expect(find.text('2 JOBS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('week mode lists every day of the week and a bar tap returns', (
    tester,
  ) async {
    // Taller than `withPhoneViewport`: this asserts all SEVEN bars are built at
    // once, and the agenda header grew by the toggle's tap floor, so on a
    // 915pt phone the last bar now falls outside the viewport and its cache.
    tester.view.physicalSize = const Size(412 * 3, 1000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final today = DateTime.now();
    // Sunday-first (en_CA), spelled as the index: the locale table is only
    // loaded once the app below has pumped, and the jobs are built before it.
    final week = weekOf(today, weekStart: 0);
    // Another day of the SAME week, so its job is off the day agenda but on the
    // week one.
    final other = week.first.day == today.day ? week.last : week.first;
    await tester.pumpWidget(
      _wrap(
        appointments: Stream.value([
          _appointment(1, today),
          _appointment(2, DateTime(other.year, other.month, other.day, 9)),
        ]),
        allUsers: Stream.value(const [_jane]),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Appt 2'), findsNothing);

    // Collapse the grid so the agenda viewport can hold the whole week.
    await tester.drag(find.byTooltip('Hide calendar'), const Offset(0, -60));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Week view'));
    await tester.pumpAndSettle();

    for (final day in week) {
      expect(
        find.byKey(WeekDayBar.keyFor(day)),
        findsOneWidget,
        reason: '$day',
      );
    }
    expect(find.text('Appt 1'), findsOneWidget);
    expect(find.text('Appt 2'), findsOneWidget);
    expect(find.text('2 JOBS'), findsOneWidget);

    await tester.tap(find.byKey(WeekDayBar.keyFor(other)));
    await tester.pumpAndSettle();

    // Back in day mode, on the day whose bar was tapped.
    expect(find.byKey(WeekDayBar.keyFor(today)), findsNothing);
    expect(find.text(_dayHeader(other)), findsOneWidget);
    expect(find.text('Appt 2'), findsOneWidget);
    expect(find.text('Appt 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the week toggle holds its tap floor and the header with it', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    Future<double> headerHeight(double scale) async {
      await tester.pumpWidget(
        _wrap(
          appointments: Stream.value(const []),
          allUsers: Stream.value(const [_jane]),
          repo: repo,
          textScale: scale,
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(AgendaHeader)).height;
    }

    // The toggle is two GhostControls, so it is the 48px tap floor plus the
    // header's own 18/10 padding — and because the floor already exceeds a
    // titleLarge line at 2x, text scaling is ABSORBED rather than compounding
    // with it. It was a 32px SegmentedButton, under the floor, in a 60px row.
    final atDouble = await headerHeight(2);
    final atNormal = await headerHeight(1);
    expect(atNormal, lessThanOrEqualTo(kGhostTapTarget + 28));
    expect(atDouble, lessThanOrEqualTo(atNormal));

    for (final tooltip in ['Day view', 'Week view']) {
      // GhostControl puts the InkWell INSIDE the Tooltip, not above it.
      final tile = find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(tile.first).height, greaterThanOrEqualTo(48));
    }
  });
}
