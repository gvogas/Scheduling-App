import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/application/assignee_availability_provider.dart';
import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/assignee_availability_scope.dart';

/// Pumps [watchAssigneeAvailability] with the given schedule fields and hands
/// back what the picker would render.
Future<AssigneeAvailability> _resolve(
  WidgetTester tester, {
  DateTime? date,
  bool isAllDay = true,
  bool isPersonal = false,
  TimeOfDay? startTime,
  TimeOfDay? endTime,
}) async {
  late AssigneeAvailability seen;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, ref, _) {
          seen = watchAssigneeAvailability(
            ref,
            date: date,
            endDate: null,
            isAllDay: isAllDay,
            isPersonal: isPersonal,
            startTime: startTime,
            endTime: endTime,
            alreadyAssignedIds: const {},
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return seen;
}

void main() {
  final date = DateTime(2026, 8, 26);

  testWidgets('a PERSONAL block dims nobody, so time off stays bookable for '
      'the person who is busy', (tester) async {
    // Dimming means untappable, and the person a day off is FOR is exactly the
    // one most likely to have jobs that day — dimming them makes the absence
    // unbookable and the after-save clash alert unreachable.
    final availability = await _resolve(tester, date: date, isPersonal: true);

    expect(availability.clashes, isEmpty);
    expect(identical(availability, AssigneeAvailability.none), isTrue);
  });

  testWidgets('no date picked answers nothing', (tester) async {
    final availability = await _resolve(tester);

    expect(identical(availability, AssigneeAvailability.none), isTrue);
  });

  testWidgets('a timed span with no times picked answers nothing', (
    tester,
  ) async {
    // A date with no times could still become an 8 pm job, so dimming whoever
    // is booked that morning would be a guess presented as a fact.
    final availability = await _resolve(
      tester,
      date: date,
      isAllDay: false,
    );

    expect(identical(availability, AssigneeAvailability.none), isTrue);
  });

  testWidgets('a settled lookup hands the clashes and stored assignees '
      'through', (tester) async {
    final clash = AppointmentRecord(
      id: 'a1',
      title: 'Leak fix',
      startTime: DateTime(2026, 8, 26, 8),
      endTime: DateTime(2026, 8, 26, 12),
      employeeIds: const ['e1'],
    );
    late AssigneeAvailability seen;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assigneeAvailabilityProvider.overrideWith(
            (ref, span) async => {'e1': clash},
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            seen = watchAssigneeAvailability(
              ref,
              date: date,
              endDate: null,
              isAllDay: true,
              isPersonal: false,
              startTime: null,
              endTime: null,
              alreadyAssignedIds: const {'e2'},
            );
            return const SizedBox();
          },
        ),
      ),
    );
    // Let the family future settle so `.value` is non-null.
    await tester.pumpAndSettle();

    expect(seen.clashes.keys, ['e1']);
    expect(seen.alreadyAssignedIds, {'e2'});
  });
}
