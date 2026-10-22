import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';

void main() {
  const me = EmployeeRecord(id: 'e1', uid: 'uid-1', status: 'active');

  group('isLocationShareAskDue', () {
    bool due({EmployeeRecord? record = me}) =>
        isLocationShareAskDue(me: record);

    test('is due for an active real account not yet asked on this build', () {
      expect(due(), isTrue);
    });

    test('is due for someone already sharing too', () {
      expect(due(record: me.copyWith(locationSharingEnabled: true)), isTrue);
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

  group('isLocationConsentFresh', () {
    final now = DateTime(2026, 10, 20, 9);

    test('counts a stamp within the window, before or just after now', () {
      expect(
        isLocationConsentFresh(
          consentAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        isTrue,
      );
      // A server stamp can run a little ahead of the device clock.
      expect(
        isLocationConsentFresh(
          consentAt: now.add(const Duration(minutes: 2)),
          now: now,
        ),
        isTrue,
      );
    });

    test('an old or missing stamp is not fresh', () {
      expect(
        isLocationConsentFresh(
          consentAt: now.subtract(kLocationConsentFreshFor * 2),
          now: now,
        ),
        isFalse,
      );
      expect(isLocationConsentFresh(consentAt: null, now: now), isFalse);
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

    test('a consent just given in setup turns the question into its iOS step', () {
      for (final permission in [
        LocationPermissionResult.granted,
        LocationPermissionResult.denied,
      ]) {
        expect(
          locationShareAskVariant(
            sharing: false,
            permission: permission,
            consentFresh: true,
          ),
          LocationShareAskVariant.consented,
        );
      }
    });

    test('a fresh consent changes nothing once sharing is on or iOS refused', () {
      expect(
        locationShareAskVariant(
          sharing: true,
          permission: LocationPermissionResult.granted,
          consentFresh: true,
        ),
        LocationShareAskVariant.alreadyOn,
      );
      expect(
        locationShareAskVariant(
          sharing: false,
          permission: LocationPermissionResult.permanentlyDenied,
          consentFresh: true,
        ),
        LocationShareAskVariant.openSettings,
      );
    });

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
