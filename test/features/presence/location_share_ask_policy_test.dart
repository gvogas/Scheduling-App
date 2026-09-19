import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';

void main() {
  const me = EmployeeRecord(id: 'e1', uid: 'uid-1', status: 'active');

  group('isLocationShareAskDue', () {
    bool due({EmployeeRecord? record = me, bool askedThisBuild = false}) =>
        isLocationShareAskDue(me: record, askedThisBuild: askedThisBuild);

    test('is due for an active real account not yet asked on this build', () {
      expect(due(), isTrue);
    });

    test('is due for someone already sharing too', () {
      expect(due(record: me.copyWith(locationSharingEnabled: true)), isTrue);
    });

    test('is not due twice on the same build', () {
      expect(due(askedThisBuild: true), isFalse);
    });

    test('is not due before the record has loaded', () {
      expect(due(record: null), isFalse);
    });

    test('is not due for an account that is not active', () {
      expect(due(record: me.copyWith(status: 'invited')), isFalse);
    });

    test('is not due for a test account', () {
      expect(due(record: me.copyWith(isTestAccount: true)), isFalse);
    });

    test('is not due for a record with no uid to remember it against', () {
      expect(due(record: me.copyWith(uid: '')), isFalse);
    });
  });

  group('locationShareAskVariant', () {
    LocationShareAskVariant variant(
      LocationPermissionResult permission, {
      required bool sharing,
    }) => locationShareAskVariant(sharing: sharing, permission: permission);

    test('someone sharing with location allowed is told they are on', () {
      expect(
        variant(LocationPermissionResult.granted, sharing: true),
        LocationShareAskVariant.alreadyOn,
      );
    });

    test('sharing off offers Turn on while iOS can still prompt', () {
      expect(
        variant(LocationPermissionResult.granted, sharing: false),
        LocationShareAskVariant.turnOn,
      );
      expect(
        variant(LocationPermissionResult.denied, sharing: false),
        LocationShareAskVariant.turnOn,
      );
    });

    test(
      'sharing on but never allowed still offers Turn on, which prompts',
      () {
        expect(
          variant(LocationPermissionResult.denied, sharing: true),
          LocationShareAskVariant.turnOn,
        );
      },
    );

    test('a refusal iOS will not re-ask sends them to Settings', () {
      for (final sharing in [true, false]) {
        expect(
          variant(LocationPermissionResult.permanentlyDenied, sharing: sharing),
          LocationShareAskVariant.openSettings,
        );
        expect(
          variant(LocationPermissionResult.servicesDisabled, sharing: sharing),
          LocationShareAskVariant.openSettings,
        );
      }
    });
  });
}
