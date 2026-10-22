import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The assigned-employee "Start job" branch added 2026-09-01, and the one
/// thing it must NOT have done: widen the mark-done branch.
void main() {
  late final rules = File('firestore.rules').readAsStringSync();

  List<String> employeeBranches() {
    final parts = rules.split('|| (isAssignedEmployee(resource.data)');
    expect(parts.length, greaterThan(1));
    return [
      for (final part in parts.skip(1))
        if (part.contains(');'))
          part.substring(0, part.indexOf(');') + 1)
        else
          part,
    ];
  }

  String collapsed(String source) =>
      source.replaceAll(RegExp('//[^\n]*'), '').replaceAll(RegExp(r'\s+'), ' ');

  String branchNaming(String term) {
    for (final branch in employeeBranches()) {
      if (collapsed(branch).contains(term)) return collapsed(branch);
    }
    fail('no assigned-employee branch names $term');
  }

  String markDone() => branchNaming("== 'done'");
  String startJob() => branchNaming("== 'in_progress'");

  group('the mark-done branch is untouched', () {
    test('still restricts the diff to status and updatedAt', () {
      expect(
        markDone(),
        contains("affectedKeys() .hasOnly(['status', 'updatedAt'])"),
      );
    });

    test('no employee branch writes the time record', () {
      // `startedAt`/`completedAt` are stamped SERVER-SIDE by the write trigger.
      for (final branch in employeeBranches()) {
        final body = collapsed(branch);
        expect(body, isNot(contains("'startedAt'")));
        expect(body, isNot(contains("'completedAt'")));
      }
    });
  });

  group('the Start-job branch', () {
    test('is its own disjunct with the same two-key diff', () {
      expect(
        startJob(),
        contains("affectedKeys() .hasOnly(['status', 'updatedAt'])"),
      );
      expect(startJob(), isNot(contains("== 'done'")));
    });

    test('only ever writes in_progress', () {
      expect(
        startJob(),
        contains("request.resource.data.status == 'in_progress'"),
      );
    });

    test(
      'moves a job FORWARD only: never from in-progress or a closed state',
      () {
        final body = startJob();
        for (final closed in const [
          'in_progress',
          'done',
          'completed',
          'cancelled',
        ]) {
          expect(body, contains("'$closed'"));
        }
        expect(body, contains('!(resource.data.status in'));
      },
    );

    test('pins updatedAt to the server clock', () {
      expect(
        startJob(),
        contains('request.resource.data.updatedAt == request.time'),
      );
    });
  });

  group('the admin shape guard', () {
    // `request.resource.data` on an admin edit is the MERGED document, so the
    // server-stamped instants ride along and must stay absent-or-valid here;
    // the WRITE ban is a `diff().affectedKeys()` test at the rule itself.
    late final validator = collapsed(
      rules.substring(
        rules.indexOf('function isValidAppointmentData(d)'),
        rules.indexOf('match /appointments/{appointmentId}'),
      ),
    );

    test('type-checks both instants, absent-or-valid', () {
      for (final field in const ['startedAt', 'completedAt']) {
        expect(
          validator,
          contains("(!('$field' in d.keys()) || d.$field is timestamp)"),
        );
      }
    });
  });

  group('no CLIENT writes the job time record, admins included', () {
    late final appointments = collapsed(
      rules.substring(rules.indexOf('match /appointments/{appointmentId}')),
    );

    test('create refuses either instant outright', () {
      expect(
        appointments,
        contains(
          '!request.resource.data.keys()'
          ".hasAny(['startedAt', 'completedAt'])",
        ),
      );
    });

    test('the admin update bans a diff that touches either instant', () {
      expect(
        appointments,
        contains(
          '!request.resource.data.diff(resource.data) .affectedKeys()'
          " .hasAny(['pictureCount', 'startedAt', 'completedAt', 'editProtocol', "
          "'editRevision', 'clientSourceUpdatedAt'])",
        ),
      );
    });
  });
}
