import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/fields/employee_picker.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

/// "Only active staff are offered" is the premise the whole
/// `mergeRetainedAssignees` invariant rests on: because a disabled assignee
/// never renders a chip, they cannot be deselected, which is why saving must
/// re-append the original assignees missing from the active set.
EmployeeRecord _employee(String id, String name) => EmployeeRecord(
  id: id,
  name: name,
  email: '$id@example.com',
  status: 'active',
);

Future<void> _pump(
  WidgetTester tester, {
  required List<EmployeeRecord> allEmployees,
  required List<EmployeeRecord> selectedEmployees,
  bool selectable = true,
  void Function(EmployeeRecord)? onToggle,
  AssigneeAvailability availability = AssigneeAvailability.none,
}) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: EmployeePicker(
        allEmployees: allEmployees,
        selectedEmployees: selectedEmployees,
        selectable: selectable,
        onToggle: onToggle,
        availability: availability,
      ),
    ),
  ),
);

void main() {
  final active = _employee('e1', 'Ada Lovelace');
  final disabled = _employee('e2', 'Grace Hopper');

  testWidgets('every active employee is offered', (tester) async {
    await _pump(
      tester,
      allEmployees: [active],
      selectedEmployees: const [],
    );

    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('an assignee missing from the active set is not offered', (
    tester,
  ) async {
    await _pump(
      tester,
      allEmployees: [active],
      selectedEmployees: [active, disabled],
    );

    expect(find.text('Grace'), findsNothing);
  });

  testWidgets('a disabled assignee therefore cannot be deselected', (
    tester,
  ) async {
    final toggled = <String>[];
    await _pump(
      tester,
      allEmployees: [active],
      selectedEmployees: [active, disabled],
      onToggle: (e) => toggled.add(e.id),
    );
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();

    expect(toggled, ['e1']);
  });

  testWidgets('the read-only picker shows assignees only', (tester) async {
    await _pump(
      tester,
      allEmployees: [active, _employee('e3', 'Alan Turing')],
      selectedEmployees: [active],
      selectable: false,
    );

    expect(find.text('Alan'), findsNothing);
  });

  group('availability', () {
    AppointmentClashFixtures fixtures() => AppointmentClashFixtures();

    testWidgets('nothing is dimmed and no lines render before a date is '
        'picked', (tester) async {
      await _pump(
        tester,
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: const [],
      );

      expect(find.byType(Divider), findsNothing);
      expect(find.textContaining('is off'), findsNothing);
    });

    testWidgets('an unavailable assignee is not tappable', (tester) async {
      final toggled = <String>[];
      await _pump(
        tester,
        allEmployees: [active],
        selectedEmployees: const [],
        onToggle: (e) => toggled.add(e.id),
        availability: fixtures().offToday(active.id),
      );
      await tester.tap(find.text('Ada'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(toggled, isEmpty);
    });

    testWidgets('a day off says so, with the DATE range and no clock', (
      tester,
    ) async {
      await _pump(
        tester,
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: const [],
        availability: fixtures().offToday(active.id),
      );

      expect(find.text('Ada is off'), findsOneWidget);
      expect(find.text('26 Aug'), findsOneWidget);
    });

    testWidgets('a booked job says so, with the window that would free them', (
      tester,
    ) async {
      await _pump(
        tester,
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: const [],
        availability: fixtures().bookedToday(active.id),
      );

      expect(find.text('Ada is on another job'), findsOneWidget);
      expect(find.textContaining('8:00'), findsOneWidget);
    });

    testWidgets('an ALREADY-ASSIGNED assignee who is off stays tappable and '
        'says so', (tester) async {
      // Dimming would make them unremovable, and mergeRetainedAssignees would
      // then silently put them back on every save.
      final toggled = <String>[];
      await _pump(
        tester,
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: [active],
        onToggle: (e) => toggled.add(e.id),
        availability: fixtures().offToday(active.id, alreadyAssigned: true),
      );
      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();

      expect(toggled, ['e1']);
      expect(find.text('Ada is off — still on this job'), findsOneWidget);
    });

    testWidgets('an assignee already on the job who is BOOKED elsewhere reads '
        'as an explanation, not a refusal', (tester) async {
      // The ordinary outcome of moving the date after picking the crew. The
      // chip stays selected and tappable, so the line must not repeat the
      // sentence used for someone you cannot pick.
      final toggled = <String>[];
      await _pump(
        tester,
        allEmployees: [active],
        selectedEmployees: [active],
        onToggle: (e) => toggled.add(e.id),
        availability: fixtures().bookedToday(active.id),
      );
      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();

      expect(toggled, ['e1'], reason: 'still tappable');
      expect(
        find.text('Ada is on another job — still on this one'),
        findsOneWidget,
      );
      expect(find.text('Ada is on another job'), findsNothing);
    });

    testWidgets('past two clashes the rest collapse behind a count, which '
        'expands in place', (tester) async {
      // One line per clash buries Save on a holiday Monday.
      final blocked = [
        for (var i = 0; i < 4; i++) _employee('e$i', 'Person$i Last'),
      ];
      await _pump(
        tester,
        allEmployees: [...blocked, _employee('free', 'Alan Turing')],
        selectedEmployees: const [],
        availability: fixtures().allOff([for (final e in blocked) e.id]),
      );

      expect(find.textContaining('is off'), findsNWidgets(2));
      expect(find.text("2 more aren't free"), findsOneWidget);

      await tester.tap(find.text("2 more aren't free"));
      await tester.pumpAndSettle();

      expect(find.textContaining('is off'), findsNWidgets(4));
    });

    testWidgets('with nobody free the lines give way to one sentence', (
      tester,
    ) async {
      final crew = [
        for (var i = 0; i < 4; i++) _employee('e$i', 'Person$i Last'),
      ];
      await _pump(
        tester,
        allEmployees: crew,
        selectedEmployees: const [],
        availability: fixtures().allOff(
          [for (final e in crew) e.id],
          whenLabel: '26 Aug',
        ),
      );

      expect(find.textContaining('Nobody is free on 26 Aug'), findsOneWidget);
      expect(find.textContaining('is off'), findsNothing);
    });

    testWidgets('one free colleague keeps the per-person lines', (
      tester,
    ) async {
      final crew = [active, _employee('e3', 'Alan Turing')];
      await _pump(
        tester,
        allEmployees: crew,
        selectedEmployees: const [],
        availability: fixtures().offToday(active.id),
      );

      expect(find.text('Ada is off'), findsOneWidget);
      expect(find.textContaining('Nobody is free'), findsNothing);
    });

    testWidgets('an all-day job reads "All day", not its stored span', (
      tester,
    ) async {
      // The instants really are midnight to 23:59, which rendered as a
      // suspiciously precise workday nobody books.
      await _pump(
        tester,
        // A free colleague, or the lines give way to the "nobody free"
        // sentence and there is no figure to read.
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: const [],
        availability: fixtures().allDayToday(active.id),
      );

      expect(find.text('All day'), findsOneWidget);
      expect(find.textContaining('11:59'), findsNothing);
    });
  });
}

/// Availability fixtures, built from real records so the widget renders the
/// same figures the app would.
class AppointmentClashFixtures {
  static final _day = DateTime(2026, 8, 26);

  AppointmentRecord _dayOff() => AppointmentRecord(
    id: 'off',
    startTime: _day,
    endTime: DateTime(2026, 8, 26, 23, 59),
    isPersonal: true,
    isDayOff: true,
  );

  AssigneeAvailability offToday(String id, {bool alreadyAssigned = false}) =>
      AssigneeAvailability(
        clashes: {id: _dayOff()},
        alreadyAssignedIds: alreadyAssigned ? {id} : const {},
      );

  AssigneeAvailability bookedToday(String id) => AssigneeAvailability(
    clashes: {
      id: AppointmentRecord(
        id: 'job',
        startTime: DateTime(2026, 8, 26, 8),
        endTime: DateTime(2026, 8, 26, 12),
      ),
    },
  );

  AssigneeAvailability allDayToday(String id) => AssigneeAvailability(
    clashes: {
      id: AppointmentRecord(
        id: 'job',
        startTime: _day,
        endTime: DateTime(2026, 8, 26, 23, 59),
        isAllDay: true,
      ),
    },
  );

  AssigneeAvailability allOff(List<String> ids, {String whenLabel = ''}) =>
      AssigneeAvailability(
        clashes: {for (final id in ids) id: _dayOff()},
        whenLabel: whenLabel,
      );
}
