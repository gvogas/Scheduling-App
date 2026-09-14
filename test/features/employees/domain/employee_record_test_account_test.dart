import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';

void main() {
  group('EmployeeRecord.isTestAccount', () {
    test('an absent field reads as a real account', () {
      expect(EmployeeRecord.fromMap('u1', const {}).isTestAccount, isFalse);
    });

    test('only an explicit true marks a test account', () {
      expect(
        EmployeeRecord.fromMap('u1', const {
          'isTestAccount': true,
        }).isTestAccount,
        isTrue,
      );
      expect(
        EmployeeRecord.fromMap('u1', const {
          'isTestAccount': 'true',
        }).isTestAccount,
        isFalse,
      );
    });

    test('toMap round-trips the flag with the other admin fields', () {
      const record = EmployeeRecord(id: 'u1', isTestAccount: true);
      expect(record.toMap()['isTestAccount'], isTrue);
    });
  });

  group('EmployeeRecord.isAssignable', () {
    test('a technician is assignable', () {
      const record = EmployeeRecord(id: 'u1', jobTitle: JobTitle.technician);
      expect(record.isAssignable, isTrue);
    });

    test('a test account is never assignable, whatever its title', () {
      const record = EmployeeRecord(
        id: 'u1',
        jobTitle: JobTitle.technician,
        isTestAccount: true,
      );
      expect(record.isAssignable, isFalse);
    });
  });
}
