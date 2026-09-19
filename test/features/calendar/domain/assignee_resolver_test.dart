import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';

EmployeeRecord _person(String id, {JobTitle title = JobTitle.technician}) =>
    EmployeeRecord(
      id: id,
      name: 'Person $id',
      status: 'active',
      jobTitle: title,
    );

void main() {
  group('offerableAssignees', () {
    final tech = _person('e1');
    final dispatcher = _person('e2', title: JobTitle.dispatcher);

    test('a dispatcher is not offered', () {
      final offered = offerableAssignees(
        active: [tech, dispatcher],
        alreadyAssignedIds: const [],
      );
      expect(offered.map((e) => e.id), ['e1']);
    });

    test(
      'a dispatcher ALREADY on the job is offered, so it can be removed',
      () {
        final offered = offerableAssignees(
          active: [tech, dispatcher],
          alreadyAssignedIds: const ['e2'],
        );
        expect(offered.map((e) => e.id), ['e1', 'e2']);
      },
    );

    test('keyed on the STORED assignees, so deselecting is not one-way', () {
      // Keyed on the live selection instead, deselecting the dispatcher took
      // their own chip away on the next rebuild, so the tap could only be
      // undone by abandoning the whole edit.
      final offered = offerableAssignees(
        active: [tech, dispatcher],
        alreadyAssignedIds: const ['e2'],
      );
      expect(offered.map((e) => e.id), contains('e2'));
    });

    test('a DISABLED assignee is never offered, even though it is stored', () {
      // The dangerous case: a disabled assignee is absent from the active
      // stream, so a chip for one would deselect and then be silently
      // re-appended by mergeRetainedAssignees on save.
      final offered = offerableAssignees(
        active: [tech],
        alreadyAssignedIds: const ['gone'],
      );
      expect(offered.map((e) => e.id), ['e1']);
    });
  });

  // I12: `assigneeNameAt` owns the positional bounds check at five call sites,
  // and the edit sheet's result flows into `mergeRetainedAssignees` and is
  // WRITTEN BACK to Firestore — yet it had no direct coverage, only whatever
  // its callers happened to exercise.
  group('assigneeNameAt', () {
    test('returns the name at the paired position', () {
      expect(assigneeNameAt(const ['Ada', 'Bea'], 0), 'Ada');
      expect(assigneeNameAt(const ['Ada', 'Bea'], 1), 'Bea');
    });

    test('returns null past the end — a shorter names list', () {
      // The real shape: a job assigned before names were denormalized, or a
      // partially-written doc. Null means "no name here", and each caller
      // picks its own substitute.
      expect(assigneeNameAt(const ['Ada'], 1), isNull);
      expect(assigneeNameAt(const [], 0), isNull);
    });

    test('returns null for a negative index rather than throwing', () {
      expect(assigneeNameAt(const ['Ada'], -1), isNull);
    });

    test('an empty stored name is a NAME, not a gap', () {
      // Distinct from null on purpose: the caller substitutes only when there
      // is no entry at all, never when the entry is blank.
      expect(assigneeNameAt(const [''], 0), '');
    });
  });

  group('mergeRetainedAssignees', () {
    test('keeps only the selection when every original is active', () {
      final result = mergeRetainedAssignees(
        originalIds: ['a', 'b'],
        originalNames: ['Ann', 'Bob'],
        selectedIds: ['a'],
        selectedNames: ['Ann'],
        activeIds: {'a', 'b'},
      );
      // 'b' was active and deselected — honored, not retained.
      expect(result.ids, ['a']);
      expect(result.names, ['Ann']);
    });

    test('re-appends an original assignee the picker never showed', () {
      // 'c' is disabled/removed (not active), so the picker couldn't show it —
      // dropping it would silently unassign and change visibility.
      final result = mergeRetainedAssignees(
        originalIds: ['a', 'c'],
        originalNames: ['Ann', 'Cid'],
        selectedIds: ['a'],
        selectedNames: ['Ann'],
        activeIds: {'a', 'b'},
      );
      expect(result.ids, ['a', 'c']);
      expect(result.names, ['Ann', 'Cid']);
    });

    test('does not re-append an original that is still selected', () {
      final result = mergeRetainedAssignees(
        originalIds: ['a'],
        originalNames: ['Ann'],
        selectedIds: ['a'],
        selectedNames: ['Ann'],
        activeIds: <String>{},
      );
      // 'a' is inactive but still selected — kept once, not duplicated.
      expect(result.ids, ['a']);
      expect(result.names, ['Ann']);
    });

    test('falls back to an empty name when originals are shorter', () {
      final result = mergeRetainedAssignees(
        originalIds: ['a', 'c'],
        originalNames: ['Ann'], // no name for 'c'
        selectedIds: <String>[],
        selectedNames: <String>[],
        activeIds: {'a'},
      );
      expect(result.ids, ['c']);
      expect(result.names, ['']);
    });

    test('newly selected active staff plus a retained inactive original', () {
      final result = mergeRetainedAssignees(
        originalIds: ['old'],
        originalNames: ['Olga'],
        selectedIds: ['new1', 'new2'],
        selectedNames: ['N1', 'N2'],
        activeIds: {'new1', 'new2'},
      );
      // The selection comes first, then the invisible original 'old' gets
      // appended after it.
      expect(result.ids, ['new1', 'new2', 'old']);
      expect(result.names, ['N1', 'N2', 'Olga']);
    });
  });

  group('assigneeOfferState', () {
    final job = AppointmentRecord(
      id: 'job',
      startTime: DateTime(2026, 8, 26, 8),
      endTime: DateTime(2026, 8, 26, 12),
    );
    final dayOff = AppointmentRecord(
      id: 'off',
      startTime: DateTime(2026, 8, 26),
      endTime: DateTime(2026, 8, 26, 23, 59),
      isPersonal: true,
      isDayOff: true,
    );

    test('nobody clashing is free', () {
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: const {},
          selectedIds: const {},
          alreadyAssignedIds: const {},
        ),
        AssigneeOfferState.free,
      );
    });

    test('someone on another job is booked, not unavailable', () {
      // Double booking is the admin's call, made at the Save-time prompt.
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: {'e1': job},
          selectedIds: const {},
          alreadyAssignedIds: const {},
        ),
        AssigneeOfferState.booked,
      );
    });

    test('someone on time off is unavailable', () {
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: {'e1': dayOff},
          selectedIds: const {},
          alreadyAssignedIds: const {},
        ),
        AssigneeOfferState.unavailable,
      );
    });

    test('an ALREADY-ASSIGNED clash is never dimmed', () {
      // Dimming makes them unremovable, and worse: mergeRetainedAssignees
      // re-appends every original missing from the ACTIVE set, so someone
      // active but merely un-offered is NOT retained — they would be silently
      // unassigned instead.
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: {'e1': dayOff},
          selectedIds: const {},
          alreadyAssignedIds: const {'e1'},
        ),
        AssigneeOfferState.onTheJob,
      );
    });

    test('a SELECTED clash is never dimmed either', () {
      // The add flow has nothing stored, so the live selection is the whole of
      // "on this job" there.
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: {'e1': dayOff},
          selectedIds: const {'e1'},
          alreadyAssignedIds: const {},
        ),
        AssigneeOfferState.onTheJob,
      );
    });

    test('deselecting a stored unavailable assignee is not one-way', () {
      // Keyed on the selection alone their chip would dim on the next rebuild,
      // so the tap could only be undone by abandoning the edit.
      expect(
        assigneeOfferState(
          employeeId: 'e1',
          clashes: {'e1': dayOff},
          selectedIds: const {},
          alreadyAssignedIds: const {'e1'},
        ),
        isNot(AssigneeOfferState.unavailable),
      );
    });
  });

  group('shortAssigneeName', () {
    test('first name when it is unambiguous', () {
      expect(
        shortAssigneeName(
          'Marc Tremblay',
          among: firstNameTally(['Marc Tremblay', 'Nadia B']),
        ),
        'Marc',
      );
    });

    test('two Marcs each take a last initial', () {
      final roster = firstNameTally(['Marc Tremblay', 'Marc Belanger']);
      expect(shortAssigneeName('Marc Tremblay', among: roster), 'Marc T.');
      expect(shortAssigneeName('Marc Belanger', among: roster), 'Marc B.');
    });

    test('a one-word name is left alone', () {
      expect(
        shortAssigneeName('Marc', among: firstNameTally(['Marc', 'Marc'])),
        'Marc',
      );
    });

    test('the tally is case-insensitive on the first name', () {
      // The old per-call scan lowercased both sides; the tally has to key on
      // the same folded form or two spellings of one name stop sharing.
      final roster = firstNameTally(['marc Tremblay', 'MARC Belanger']);
      expect(shortAssigneeName('Marc Tremblay', among: roster), 'Marc T.');
    });

    test('a blank name contributes nothing to the tally', () {
      expect(firstNameTally(['', '   ', 'Marc Tremblay']), {'marc': 1});
    });
  });

  group('replaceAssignee', () {
    AppointmentRecord job({String status = 'pending'}) => AppointmentRecord(
      id: 'job-1',
      startTime: DateTime(2026, 8, 26, 8),
      endTime: DateTime(2026, 8, 26, 12),
      status: status,
      employeeIds: const ['e3', 'e1'],
      employeeNames: const ['Theo Roy', 'Marc Tremblay'],
    );

    test('swaps the id AND the name positionally', () {
      final swapped = replaceAssignee(
        job(),
        removeId: 'e1',
        addId: 'e2',
        addName: 'Nadia Berger',
      );

      expect(swapped.employeeIds, ['e3', 'e2']);
      expect(swapped.employeeNames, ['Theo Roy', 'Nadia Berger']);
    });

    test('a legacy `confirmed` status is normalized, never written back', () {
      // A swap re-serializes the WHOLE record, so an off-allowlist status
      // would reach the rules verbatim and be refused as an opaque
      // permission-denied on an ordinary-looking swap.
      final swapped = replaceAssignee(
        job(status: 'confirmed'),
        removeId: 'e1',
        addId: 'e2',
        addName: 'Nadia Berger',
      );

      expect(swapped.status, 'pending');
    });

    test('a valid status is carried through untouched', () {
      final swapped = replaceAssignee(
        job(status: 'in_progress'),
        removeId: 'e1',
        addId: 'e2',
        addName: 'Nadia Berger',
      );

      expect(swapped.status, 'in_progress');
    });

    test('a missing denormalized name becomes empty, never an offset', () {
      final short = AppointmentRecord(
        id: 'job-2',
        startTime: DateTime(2026, 8, 26, 8),
        endTime: DateTime(2026, 8, 26, 12),
        employeeIds: const ['e3', 'e1'],
        employeeNames: const ['Theo Roy'],
      );

      final swapped = replaceAssignee(
        short,
        removeId: 'e3',
        addId: 'e2',
        addName: 'Nadia Berger',
      );

      expect(swapped.employeeIds, ['e2', 'e1']);
      expect(swapped.employeeNames, ['Nadia Berger', '']);
    });
  });
}
