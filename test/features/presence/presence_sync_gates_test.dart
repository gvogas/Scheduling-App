import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/presence/application/presence_sync_controller.dart';

void main() {
  final now = DateTime(2026, 7, 13, 12);

  group('shouldTrackPresence', () {
    test('true only for a signed-in active employee', () {
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: 'active',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isTrue,
      );
    });

    test('admins are tracked too (they receive the timed pushes)', () {
      expect(
        shouldTrackPresence(
          role: 'admin',
          status: 'active',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isTrue,
      );
    });

    test('unknown roles are excluded', () {
      expect(
        shouldTrackPresence(
          role: '',
          status: 'active',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isFalse,
      );
    });

    test('non-active statuses are excluded', () {
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: 'invited',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isFalse,
      );
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: 'disabled',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isFalse,
      );
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: '',
          signedIn: true,
          locationSharingEnabled: true,
        ),
        isFalse,
      );
    });

    test('signed-out is excluded', () {
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: 'active',
          signedIn: false,
          locationSharingEnabled: true,
        ),
        isFalse,
      );
    });

    test(
      'an active signed-in user is excluded until location sharing is on',
      () {
        expect(
          shouldTrackPresence(
            role: 'employee',
            status: 'active',
            signedIn: true,
            locationSharingEnabled: false,
          ),
          isFalse,
        );
      },
    );
  });

  group('shouldWritePresenceFix', () {
    test('first fix always uploads', () {
      expect(shouldWritePresenceFix(lastUploadAt: null, now: now), isTrue);
    });

    test('throttles inside the 2-min gap, allows at the boundary', () {
      expect(
        shouldWritePresenceFix(
          lastUploadAt: now.subtract(const Duration(minutes: 1, seconds: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldWritePresenceFix(
          lastUploadAt: now.subtract(const Duration(minutes: 2)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('shouldHeartbeat', () {
    test('never fires before any upload happened', () {
      expect(shouldHeartbeat(lastUploadAt: null, now: now), isFalse);
    });

    test('fires only once a full heartbeat period elapsed', () {
      expect(
        shouldHeartbeat(
          lastUploadAt: now.subtract(const Duration(minutes: 9, seconds: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldHeartbeat(
          lastUploadAt: now.subtract(const Duration(minutes: 10)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('trailingFlushDelay', () {
    test('null lastUploadAt allows a write now', () {
      expect(trailingFlushDelay(lastUploadAt: null, now: now), isNull);
    });

    test('exactly at the gap allows a write now', () {
      expect(
        trailingFlushDelay(
          lastUploadAt: now.subtract(const Duration(minutes: 2)),
          now: now,
        ),
        isNull,
      );
    });

    test('past the gap allows a write now', () {
      expect(
        trailingFlushDelay(
          lastUploadAt: now.subtract(const Duration(minutes: 3)),
          now: now,
        ),
        isNull,
      );
    });

    test('inside the gap returns the exact remainder', () {
      expect(
        trailingFlushDelay(
          lastUploadAt: now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        const Duration(seconds: 90),
      );
    });
  });
}
