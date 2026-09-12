// Guards against a layout crash — IntrinsicHeight (which stretches the crew
// colour bar) can't query intrinsic dimensions through AutoSizeText's internal
// LayoutBuilder, so the title has to stay a plain Text.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:scheduling/core/animations/tap_scale.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

const _blue = Color(0xFF005CC8);
const _green = Color(0xFF0E9B6E);
const _theo = [AppointmentCrew(name: 'Theo Bell', color: _blue)];

/// An ordinary, NOT-overdue visit: tomorrow, 10:30–12:00.
///
/// Relative to today on purpose. The card renders `displayStatus`, which
/// derives `overdue` from the wall clock, so a fixture pinned to a calendar
/// literal silently flips to overdue the moment that date passes — this one
/// was `DateTime(2026, 8, 4, 12)` and started failing the warning-glyph test
/// at noon on 2026-08-04. `appointment_record_test.dart` already expresses
/// every clock-dependent fixture this way; match it.
///
/// A fixed time-of-day on a future DATE, not `now + offset`: an offset from
/// now straddles midnight when the suite runs late, which would turn this
/// into an overnight window and change how the card labels it. Calendar
/// arithmetic (`day + 1`), never `add(Duration(days: 1))` — the project's
/// DST rule.
AppointmentRecord _appt({
  String status = 'pending',
  String clientName = 'Marchetti Residence',
  String title = 'Water heater swap',
}) {
  final today = DateTime.now();
  return AppointmentRecord(
    id: 'a1',
    title: title,
    startTime: DateTime(today.year, today.month, today.day + 1, 10, 30),
    endTime: DateTime(today.year, today.month, today.day + 1, 12),
    clientName: clientName,
    employeeIds: const ['e1'],
    employeeNames: const ['Theo Bell'],
    status: status,
  );
}

/// A day off: a personal block flagged `isDayOff`, which is what [
/// AppointmentRecord.isTimeOff] tests for.
AppointmentRecord _dayOff({required String title}) =>
    _appt(title: title).copyWith(isPersonal: true, isDayOff: true);

/// The same visit with one photo attached.
///
/// Photos live in the `images` subcollection, so the card reads the
/// denormalized counter — it renders on every range-query surface and cannot
/// afford a subcollection read each.
AppointmentRecord _withPhoto({String status = 'pending'}) =>
    _appt(status: status).copyWith(pictureCount: 1);

AppointmentRecord _multiDay({
  required DateTime start,
  required DateTime end,
  bool isAllDay = false,
}) => AppointmentRecord(
  id: 'a3',
  title: 'Basement reroute',
  startTime: start,
  endTime: end,
  clientName: 'Marchetti Residence',
  employeeIds: const ['e1'],
  employeeNames: const ['Theo Bell'],
  isAllDay: isAllDay,
);

/// The rendered time range, spelled the way the active locale spells a.m./p.m.
/// so the expectation pins the CLOCK the card shows, not en_CA's punctuation.
String _range(DateTime start, DateTime end) =>
    '${DateUtilsHelper.formatTime(start)} – ${DateUtilsHelper.formatTime(end)}';

// endTime in the past with a non-terminal status resolves to `overdue`.
AppointmentRecord _overdueAppt() => AppointmentRecord(
  id: 'a2',
  title: 'Water heater leak',
  startTime: DateTime(2020, 1, 1, 9),
  endTime: DateTime(2020, 1, 1, 10),
  employeeIds: const ['e1'],
);

Widget _wrap(Widget child, {double width = 375}) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en_CA');
  });

  testWidgets('renders title, status chip, mono time range and crew line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: _theo)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Water heater swap'), findsOneWidget);
    expect(find.byType(StatusChip), findsOneWidget);
    // En-dash, per the design — not a hyphen.
    expect(find.textContaining('–'), findsOneWidget);
    // The crew is the avatar stack now, so the meta line is the client alone.
    expect(find.text('Marchetti Residence'), findsOneWidget);
    expect(find.byType(AppAvatar), findsOneWidget);
  });

  testWidgets('a day off renders the strip, not the card', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _dayOff(title: 'Vacation'),
          crew: _theo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The typed reason leads and the sentence drops to the caption — both
    // slots, never the same string in each.
    expect(find.text('Vacation'), findsOneWidget);
    expect(find.text('Theo Bell is off'), findsOneWidget);
    // No status chip and no crew colour bar: it is not a job.
    expect(find.byType(StatusChip), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an untitled day off keeps the sentence as its headline', (
    tester,
  ) async {
    await tester.pumpWidget(
      // What the add sheet actually stores for an unnamed personal block —
      // the localized placeholder, NOT an empty string. Promoting it would
      // make every untitled day off read "Personal".
      _wrap(
        AppointmentCard(
          appointment: _dayOff(title: 'Personal'),
          crew: _theo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Theo Bell is off'), findsOneWidget);
    expect(find.text('Personal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day off with no assignee never doubles its own title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _dayOff(title: 'Vacation'),
          crew: const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // With nobody to name, the title IS the sentence's subject, so it must
    // not also lead as the reason.
    expect(find.text('Vacation is off'), findsOneWidget);
    expect(find.text('Vacation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the day off wears a dashed rail, and none without a crew', (
    tester,
  ) async {
    // The rail is what lets two stacked absences be told apart before any
    // text is read, so its presence is the point — and it has nothing to
    // colour itself with when nobody is assigned.
    bool hasRail(WidgetTester t) => t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .any((p) => p.painter.runtimeType.toString() == '_DashedRailPainter');

    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _dayOff(title: 'Vacation'),
          crew: _theo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(hasRail(tester), isTrue);

    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _dayOff(title: 'Vacation'),
          crew: const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(hasRail(tester), isFalse);
  });

  testWidgets('the day-off strip survives a small phone at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: AppointmentCard(
            appointment: _dayOff(title: 'Dentist — root canal follow-up'),
            crew: _theo,
          ),
        ),
        width: 260,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a day off that has passed reads as complete', (tester) async {
    final today = DateTime.now();
    final finished = _dayOff(title: 'Vacation').copyWith(
      startTime: DateTime(today.year, today.month, today.day - 3),
      endTime: DateTime(today.year, today.month, today.day - 3, 23, 59),
    );
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: finished, crew: _theo)),
    );
    await tester.pumpAndSettle();

    // Derived from the clock — nothing was written and no button was pressed.
    expect(find.text('Theo Bell was off'), findsOneWidget);
    expect(find.byType(StatusChip), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every assignee gets an avatar, the text stays the client', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _appt(),
          crew: const [
            AppointmentCrew(name: 'Theo Bell', color: _blue),
            AppointmentCrew(name: 'Ana Ruiz', color: _green),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One avatar per assignee — not just the first — and the client name
    // keeps the whole of the text line.
    expect(find.byType(AppAvatar), findsNWidgets(2));
    expect(find.text('Marchetti Residence'), findsOneWidget);
  });

  testWidgets('the colour bar bands every crew member, never greys out', (
    tester,
  ) async {
    BoxDecoration barOf(WidgetTester t) {
      // The bar is the only fixed-width Container in the card's leading slot.
      final containers = t
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxWidth == 4);
      return containers.first.decoration! as BoxDecoration;
    }

    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    // One assignee: a flat colour, no gradient.
    expect(barOf(tester).gradient, isNull);
    expect(barOf(tester).color, isNotNull);

    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _appt(),
          crew: const [
            AppointmentCrew(name: 'Theo Bell', color: _blue),
            AppointmentCrew(name: 'Ana Ruiz', color: _green),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Two assignees: two hard-edged bands, not one grey one.
    final gradient = barOf(tester).gradient! as LinearGradient;
    expect(gradient.colors, hasLength(4));
    expect(gradient.colors[0], gradient.colors[1]);
    expect(gradient.colors[2], gradient.colors[3]);
    expect(gradient.colors[0], isNot(gradient.colors[2]));
    expect(gradient.stops, [0.0, 0.5, 0.5, 1.0]);
  });

  testWidgets('renders inside a ListView without an intrinsic-layout crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          height: 400,
          child: ListView.builder(
            itemCount: 1,
            itemBuilder: (_, _) => Padding(
              padding: const EdgeInsets.all(8),
              child: AppointmentCard(
                appointment: _appt(
                  title:
                      'A fairly long appointment title that needs to wrap onto '
                      'two lines',
                ),
                crew: _theo,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('long appointment title'), findsOneWidget);
  });

  testWidgets('shows a warning glyph only when the visit is overdue', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _overdueAppt(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('shows a photo glyph only when the job carries pictures', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.photo_outlined), findsNothing);

    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _withPhoto(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);

    // It rides the title line, not the time line below it — the placement is
    // the point, so pin it rather than just its presence.
    expect(
      tester.getTopLeft(find.byIcon(Icons.photo_outlined)).dy,
      lessThan(tester.getTopLeft(find.textContaining('–')).dy),
    );
  });

  testWidgets('a collapsed closed job keeps the photo glyph', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _withPhoto(status: 'done'),
          crew: _theo,
          collapseWhenClosed: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
  });

  testWidgets('cancelled strikes the title through when dimming is on', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _appt(status: 'cancelled'),
          crew: _theo,
          dimWhenCancelled: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('Water heater swap'));
    expect(title.style?.decoration, TextDecoration.lineThrough);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(
              of: find.byType(TapScale),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      closeTo(0.6, 0.001),
    );
  });

  testWidgets('cancelled renders plain when dimming is off', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _appt(status: 'cancelled'),
          crew: _theo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.widget<Text>(find.text('Water heater swap'));
    expect(title.style?.decoration, isNot(TextDecoration.lineThrough));
  });

  testWidgets('an unassigned job still renders without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: const [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('Water heater swap'), findsOneWidget);
    // No crew, so the meta line falls back to the client alone.
    expect(find.text('Marchetti Residence'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the whole card carries one coherent semantics label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _wrap(AppointmentCard(appointment: _appt(), crew: _theo)),
    );
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp('Water heater swap.*Theo Bell')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a middle day reads the DAILY window plus a day counter', (
    tester,
  ) async {
    final record = _multiDay(
      start: DateTime(2026, 8, 1, 9),
      end: DateTime(2026, 8, 5, 17),
    );
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: record,
          crew: _theo,
          slice: sliceFor(record, DateTime(2026, 8, 3)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Day 3 of 5'), findsOneWidget);
    // The stored times are the daily window, so day 3 still reads 9–5.
    expect(
      find.textContaining(DateUtilsHelper.formatTime(DateTime(2026, 8, 3, 9))),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overnight run counts NIGHTS and spans midnight', (
    tester,
  ) async {
    final record = _multiDay(
      start: DateTime(2026, 8, 1, 22),
      end: DateTime(2026, 8, 4, 6),
    );
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: record,
          crew: _theo,
          slice: sliceFor(record, DateTime(2026, 8, 2)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final window = _range(DateTime(2026, 8, 2, 22), DateTime(2026, 8, 3, 6));
    expect(find.text('$window · Night 2 of 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a multi-day all-day block keeps "All day" and adds the day', (
    tester,
  ) async {
    final record = _multiDay(
      start: DateTime(2026, 8, 10),
      end: DateTime(2026, 8, 14, 23, 59),
      isAllDay: true,
    );
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: record,
          crew: _theo,
          slice: sliceFor(record, DateTime(2026, 8, 12)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All day · Day 3 of 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-day job never shows a "Day 1 of 1" counter', (
    tester,
  ) async {
    final record = _appt();
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: record,
          crew: _theo,
          slice: sliceFor(record, DateTime(2026, 8, 4)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Day 1 of 1'), findsNothing);
    expect(
      find.text(_range(DateTime(2026, 8, 4, 10, 30), DateTime(2026, 8, 4, 12))),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets("with no slice it falls back to the record's stored span", (
    tester,
  ) async {
    // History and client job history show a job once, not per day.
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: _multiDay(
            start: DateTime(2026, 8, 1, 9),
            end: DateTime(2026, 8, 5, 17),
          ),
          crew: _theo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(_range(DateTime(2026, 8, 1, 9), DateTime(2026, 8, 5, 17))),
      findsOneWidget,
    );
    expect(find.textContaining('Day'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the semantics label carries the day counter too', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final record = _multiDay(
      start: DateTime(2026, 8, 1, 9),
      end: DateTime(2026, 8, 5, 17),
    );
    await tester.pumpWidget(
      _wrap(
        AppointmentCard(
          appointment: record,
          crew: _theo,
          slice: sliceFor(record, DateTime(2026, 8, 3)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(RegExp('Day 3 of 5')), findsOneWidget);
    handle.dispose();
  });

  group("collapseWhenClosed — the agenda's sunk-block treatment", () {
    Color fillOf(WidgetTester t) {
      final box = t.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(TapScale),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (box.decoration as BoxDecoration).color!;
    }

    // 2026-09-11, owner option B: this REVERSES part of the 2026-08-08
    // collapse design. The row stays collapsed, but the avatars come back and
    // the time gets its own line — at ~64px it read as shrunken rather than as
    // finished. The tint and the shorter-than-a-full-card property both stay.
    testWidgets('a done job takes the success tint and KEEPS its avatars', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'done'),
            crew: _theo,
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fillOf(tester), AppColors.greenFill);
      expect(find.byType(AppAvatar), findsOneWidget);
      expect(find.text('Marchetti Residence'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The pair that proves the row stopped reading as shrunken WITHOUT
    // silently becoming a full card (the rejected option A).
    testWidgets('the collapsed row is taller than it was, still shorter than '
        'a full card', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'done'),
            crew: _theo,
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final collapsed = tester.getSize(find.byType(AppointmentCard)).height;

      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'done'),
            crew: _theo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final full = tester.getSize(find.byType(AppointmentCard)).height;

      expect(collapsed, greaterThan(70), reason: 'no longer half-height');
      expect(collapsed, lessThan(full), reason: 'the collapse still collapses');
    });

    testWidgets('the same job stays plain white without the flag', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'done'),
            crew: _theo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fillOf(tester), isNot(AppColors.greenFill));
      expect(find.byType(AppAvatar), findsOneWidget);
    });

    testWidgets('an OPEN job is untouched by the flag', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(),
            crew: _theo,
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fillOf(tester), isNot(AppColors.greenFill));
      expect(find.byType(AppAvatar), findsOneWidget);
    });

    testWidgets('a cancelled job collapses but never turns green', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'cancelled'),
            crew: _theo,
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fillOf(tester), isNot(AppColors.greenFill));
      // Owner call 2026-09-11: cancelled takes the same collapsed branch, so
      // it gets the restoration too rather than becoming the odd row out.
      expect(find.byType(AppAvatar), findsOneWidget);
    });

    testWidgets('the collapsed row clears the 48px tap-target minimum', (
      tester,
    ) async {
      // A short title and no client is the smallest the row can get.
      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: _appt(status: 'done', title: 'Fix', clientName: ''),
            crew: const [],
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(AppointmentCard)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a collapsed multi-day run keeps its day counter', (
      tester,
    ) async {
      final record = _multiDay(
        start: DateTime(2026, 8, 1, 9),
        end: DateTime(2026, 8, 5, 17),
      ).copyWith(status: 'done');

      await tester.pumpWidget(
        _wrap(
          AppointmentCard(
            appointment: record,
            crew: _theo,
            slice: sliceFor(record, DateTime(2026, 8, 3)),
            collapseWhenClosed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Without it, every day of a closed run renders an identical row.
      expect(find.textContaining('Day 3 of 5'), findsOneWidget);

      // The counter used to be ellipsised away here: the time shared a Row
      // with the client name at equal flex, so RenderFlex capped it at HALF
      // the row width even when the name was short. Asserting the width rather
      // than didExceedMaxLines because the test font is far wider per glyph
      // than the shipped one, so this string overflows 375px either way — what
      // changed, and what this pins, is that it now gets the whole row.
      final cardWidth = tester.getSize(find.byType(AppointmentCard)).width;
      final timeWidth = tester.getSize(find.textContaining('Day 3 of 5')).width;
      expect(
        timeWidth,
        greaterThan(cardWidth / 2),
        reason: 'the time line no longer splits the row with the client name',
      );
    });

    testWidgets('collapsed survives 260x640 at a 2.0 text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(260, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: AppointmentCard(
              appointment: _appt(status: 'done'),
              crew: _theo,
              collapseWhenClosed: true,
            ),
          ),
          width: 260,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    // The literal "make the icons match the other status icons" request, kept
    // as a regression guard: nothing ever mis-sized them, and the taller row
    // must not start.
    testWidgets('the photo glyph is the same size collapsed and full', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(260, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Future<Size> glyphSize({required bool collapsed}) async {
        await tester.pumpWidget(
          _wrap(
            MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: AppointmentCard(
                appointment: _withPhoto(status: collapsed ? 'done' : 'pending'),
                crew: _theo,
                collapseWhenClosed: collapsed,
              ),
            ),
            width: 260,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        return tester.getSize(find.byIcon(Icons.photo_outlined));
      }

      final collapsed = await glyphSize(collapsed: true);
      final full = await glyphSize(collapsed: false);
      expect(collapsed, const Size(15, 15));
      expect(collapsed, full);
    });
  });

  testWidgets('survives 260x640 at a 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrap(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: AppointmentCard(
            appointment: _appt(),
            crew: const [
              AppointmentCrew(name: 'Theo Bell', color: _blue),
              AppointmentCrew(name: 'Ana Ruiz', color: _green),
            ],
          ),
        ),
        width: 260,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
