import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// S2: the employee branch of `allow update` on `/appointments` is the only
/// write an assignee can make, and it is the ONLY gate on that write —
/// `DetailsActionBar` hides the button (`!isDone && !isCancelled`) but a
/// modified client never runs it.
void main() {
  late final rules = File('firestore.rules').readAsStringSync();

  /// Every assigned-employee disjunct of `allow update`, body only.
  List<String> employeeBranches() {
    final parts = rules.split('|| (isAssignedEmployee(resource.data)');
    expect(
      parts.length,
      greaterThan(1),
      reason: 'the assigned-employee branches of allow update were removed',
    );
    return [
      for (final part in parts.skip(1))
        if (part.contains(');'))
          part.substring(0, part.indexOf(');') + 1)
        else
          part,
    ];
  }

  /// The disjunct whose `hasOnly` names [firstKey].
  String employeeBranchNaming(String firstKey) {
    for (final branch in employeeBranches()) {
      if (branch.contains(firstKey)) return branch;
    }
    fail('no assigned-employee branch of allow update names $firstKey');
  }

  /// The mark-done branch — what every pre-existing test here means by "the"
  /// employee branch.
  String employeeBranch() => employeeBranchNaming("== 'done'");

  /// The branch as the rules ENGINE sees it: comments dropped, whitespace
  /// flattened.
  String collapsed(String source) =>
      source.replaceAll(RegExp('//[^\n]*'), '').replaceAll(RegExp(r'\s+'), ' ');

  test('the branch still restricts the diff to status and updatedAt', () {
    // The guard below is only safe because this is exact about what MAY change:
    // without it an assignee could carry any other field along.
    expect(
      collapsed(employeeBranch()),
      contains("affectedKeys() .hasOnly(['status', 'updatedAt'])"),
    );
  });

  test('the branch still only ever writes done', () {
    expect(
      collapsed(employeeBranch()),
      contains("request.resource.data.status == 'done'"),
    );
  });

  test('a cancelled job can no longer be flipped to done', () {
    // The finding. Without this term the branch inspects the incoming status
    // alone, so `done` over `cancelled` passes and re-fires
    // notifyAppointmentChanges / endCardOnTerminal on a job the admin closed.
    expect(
      collapsed(employeeBranch()),
      contains("resource.data.status != 'cancelled'"),
    );
  });

  test('the stored-status guard is a refusal of cancelled, not an allowlist', () {
    // Deliberately `!= 'cancelled'` rather than `resource.data.status in
    // ['pending', 'in_progress']`: legacy docs carry `confirmed` and other
    // off-allowlist values (see `AppointmentStatus.storedRaw`), the action bar
    // offers the close button on them, and an allowlist would refuse that close
    // as an opaque `permission-denied`.
    final branch = collapsed(employeeBranch());
    expect(branch, isNot(contains('resource.data.status in [')));
    expect(branch, isNot(contains("resource.data.status == 'pending'")));
  });

  test('updatedAt is pinned to the server clock', () {
    // S1: the diff restriction admits `updatedAt`, so without this an assignee
    // running a modified client could stamp an arbitrary — future, past, or
    // non-timestamp — value on any job they are assigned to.
    expect(
      collapsed(employeeBranch()),
      contains('request.resource.data.updatedAt == request.time'),
    );
  });

  test('the branch carries NO date restriction, deliberately', () {
    // The documented invariant: "Mark as complete" carries no clock gate at
    // all, and the rules allow an assignee to write `status:'done'` with no
    // date restriction.
    final branch = collapsed(
      employeeBranch(),
    ).replaceAll('request.resource.data.updatedAt == request.time', '');
    for (final term in const [
      'request.time',
      'duration.value',
      'startTime',
      'endTime',
      'timestamp',
    ]) {
      expect(
        branch,
        isNot(contains(term)),
        reason: '"$term" reads as a date restriction on the employee branch',
      );
    }
  });

  test('the shape guards stay on the ADMIN branch only', () {
    // An assignee's status flip must keep working on a legacy doc that predates
    // the caps and the span bound — the diff restriction above is what makes
    // skipping them safe.
    final branch = employeeBranch();
    expect(branch, isNot(contains('isValidAppointmentData')));
    expect(branch, isNot(contains('isValidAppointmentSpan')));
    expect(branch, isNot(contains('appointmentSpanNotWidened')));
  });

  group('the photo-touch branch', () {
    // The legacy `fieldNotes` disjunct, narrowed 2026-10-09 (ADR-0188): an
    // assignee photo add batches an `updatedAt`-only parent update, and on an
    // open job this is the only disjunct admitting it.
    String touchBranch() => employeeBranchNaming("hasOnly(['updatedAt'])");

    test('is a SEPARATE disjunct from the mark-done flip', () {
      expect(employeeBranches(), hasLength(3));
      expect(collapsed(touchBranch()), isNot(contains("'status'")));
    });

    test('restricts the diff to updatedAt alone', () {
      expect(
        collapsed(touchBranch()),
        contains("affectedKeys() .hasOnly(['updatedAt'])"),
      );
    });

    test('refuses an assignee write of fieldNotes or notes', () {
      final body = collapsed(touchBranch());
      expect(body, isNot(contains('fieldNotes')));
      expect(body, isNot(contains("'notes'")));
      for (final branch in employeeBranches()) {
        expect(collapsed(branch), isNot(contains('fieldNotes')));
      }
    });

    test('pins updatedAt, so the serverTimestamp photo touch passes', () {
      expect(
        collapsed(touchBranch()),
        contains('request.resource.data.updatedAt == request.time'),
      );
    });

    test('carries NO status gate, deliberately', () {
      // A photo is often the record of a job that went wrong.
      final body = collapsed(touchBranch());
      expect(body, isNot(contains("status != 'cancelled'")));
      expect(body, isNot(contains('status ==')));
    });

    test('the field is still capped on the ADMIN path', () {
      expect(
        rules,
        contains(
          "!('fieldNotes' in d.keys()) || "
          'isBoundedString(d.fieldNotes, 4000)',
        ),
      );
    });
  });
}
