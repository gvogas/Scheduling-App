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
    await _pump(tester, allEmployees: [active], selectedEmployees: const []);

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

    testWidgets('an assignee booked on another job stays tappable', (
      tester,
    ) async {
      // Double booking is decided at the Save-time prompt, not refused here.
      final toggled = <String>[];
      await _pump(
        tester,
        allEmployees: [active, _employee('e3', 'Alan Turing')],
        selectedEmployees: const [],
        onToggle: (e) => toggled.add(e.id),
        availability: fixtures().bookedToday(active.id),
      );
      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();

      expect(toggled, ['e1']);
    });

    testWidgets('an ALREADY-ASSIGNED assignee who is off stays tappable', (
      tester,
    ) async {
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
    });

    testWidgets('no availability text renders under the chips', (
      tester,
    ) async {
      final alan = _employee('e3', 'Alan Turing');
      await _pump(
        tester,
        allEmployees: [active, alan],
        selectedEmployees: const [],
        availability: AssigneeAvailability(
          clashes: {
            ...fixtures().offToday(active.id).clashes,
            ...fixtures().bookedToday(alan.id).clashes,
          },
        ),
      );

      expect(find.byType(Divider), findsNothing);
      expect(find.textContaining('is off'), findsNothing);
      expect(find.textContaining('another job'), findsNothing);
    });
  });
}

/// Availability fixtures, built from real records.
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
}
