import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';

void main() {
  const me = EmployeeRecord(id: 'e1', uid: 'uid-1', status: 'active');

  bool ask({
    EmployeeRecord? record = me,
    bool alreadyAsked = false,
    bool calendarTourPending = false,
  }) => shouldAskToShareLocation(
    me: record,
    alreadyAsked: alreadyAsked,
    calendarTourPending: calendarTourPending,
  );

  test('asks an active real account that has not turned sharing on', () {
    expect(ask(), isTrue);
  });

  test('does not ask before the record has loaded', () {
    expect(ask(record: null), isFalse);
  });

  test('does not ask an account that is not active', () {
    expect(ask(record: me.copyWith(status: 'invited')), isFalse);
  });

  test('does not ask a test account', () {
    expect(ask(record: me.copyWith(isTestAccount: true)), isFalse);
  });

  test('does not ask someone already sharing', () {
    expect(ask(record: me.copyWith(locationSharingEnabled: true)), isFalse);
  });

  test('does not ask twice on this device', () {
    expect(ask(alreadyAsked: true), isFalse);
  });

  test('does not ask over a calendar tour that is still to run', () {
    expect(ask(calendarTourPending: true), isFalse);
  });

  test('does not ask a record with no uid to remember the answer against', () {
    expect(ask(record: me.copyWith(uid: '')), isFalse);
  });
}
