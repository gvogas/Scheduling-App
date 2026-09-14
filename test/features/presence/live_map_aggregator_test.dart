import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';

void main() {
  final now = DateTime(2026, 7, 17, 12);

  EmployeeRecord user({
    required String id,
    String name = 'A',
    Color color = Colors.red,
    String status = 'active',
  }) => EmployeeRecord(id: id, name: name, color: color, status: status);

  group('LiveMapAggregator.join', () {
    test('carries name and color from the matching user', () {
      final points = LiveMapAggregator.join(
        fixes: [
          const PresenceFix(
            userDocId: 'u1',
            lat: 45.5,
            lng: -73.6,
            updatedAt: null,
          ),
        ],
        users: [user(id: 'u1', name: 'Alice', color: Colors.blue)],
      );

      expect(points, hasLength(1));
      expect(points.single.name, 'Alice');
      expect(points.single.color, Colors.blue);
      expect(points.single.lat, 45.5);
      expect(points.single.lng, -73.6);
    });

    test('drops a fix with no matching user', () {
      final points = LiveMapAggregator.join(
        fixes: [
          const PresenceFix(
            userDocId: 'ghost',
            lat: 1,
            lng: 2,
            updatedAt: null,
          ),
        ],
        users: [user(id: 'u1')],
      );

      expect(points, isEmpty);
    });

    test('drops fixes for disabled or invited users', () {
      final points = LiveMapAggregator.join(
        fixes: [
          const PresenceFix(
            userDocId: 'disabled',
            lat: 1,
            lng: 2,
            updatedAt: null,
          ),
          const PresenceFix(
            userDocId: 'invited',
            lat: 3,
            lng: 4,
            updatedAt: null,
          ),
        ],
        users: [
          user(id: 'disabled', status: 'disabled'),
          user(id: 'invited', status: 'invited'),
        ],
      );

      expect(points, isEmpty);
    });

    test('result is sorted by name', () {
      final points = LiveMapAggregator.join(
        fixes: [
          const PresenceFix(userDocId: 'z', lat: 1, lng: 1, updatedAt: null),
          const PresenceFix(userDocId: 'a', lat: 2, lng: 2, updatedAt: null),
          const PresenceFix(userDocId: 'm', lat: 3, lng: 3, updatedAt: null),
        ],
        users: [
          user(id: 'z', name: 'Zack'),
          user(id: 'a', name: 'Amy'),
          user(id: 'm', name: 'Max'),
        ],
      );

      expect(points.map((p) => p.name), ['Amy', 'Max', 'Zack']);
    });

    test('drops a test account even when it is active and sharing', () {
      final points = LiveMapAggregator.join(
        fixes: [
          const PresenceFix(userDocId: 't', lat: 1, lng: 2, updatedAt: null),
        ],
        users: [
          const EmployeeRecord(id: 't', status: 'active', isTestAccount: true),
        ],
      );

      expect(points, isEmpty);
    });
  });

  group('LiveMapAggregator.groupTeam', () {
    PresenceFix fix(String id, Duration age) => PresenceFix(
      userDocId: id,
      lat: 45.5,
      lng: -73.6,
      updatedAt: now.subtract(age),
    );

    EmployeeRecord person(
      String id, {
      bool sharing = false,
      bool testAccount = false,
      String status = 'active',
    }) => EmployeeRecord(
      id: id,
      name: id,
      status: status,
      locationSharingEnabled: sharing,
      isTestAccount: testAccount,
    );

    test('a fresh fix is on the map', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: [fix('a', const Duration(minutes: 5))],
        users: [person('a', sharing: true)],
      );

      expect(team.onMap.map((p) => p.userDocId), ['a']);
      expect(team.notSeen, isEmpty);
      expect(team.sharingOff, isEmpty);
    });

    test('a days-old fix stays on the map while sharing is on', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: [fix('a', const Duration(days: 3))],
        users: [person('a', sharing: true)],
      );

      expect(team.onMap.map((p) => p.userDocId), ['a']);
    });

    test('a fix whose owner has sharing off is SHARING OFF, not a pin', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: [fix('a', const Duration(minutes: 5))],
        users: [person('a')],
      );

      expect(team.onMap, isEmpty);
      expect(team.sharingOff.single.userDocId, 'a');
    });

    test('sharing on with no fix at all is NOT SEEN, not SHARING OFF', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: const [],
        users: [person('a', sharing: true)],
      );

      expect(team.notSeen.single.userDocId, 'a');
      expect(team.sharingOff, isEmpty);
    });

    test('sharing off with no fix is SHARING OFF', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: const [],
        users: [person('a')],
      );

      expect(team.sharingOff.single.userDocId, 'a');
      expect(team.notSeen, isEmpty);
    });

    test('a test account is in none of the three sections', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: [
          fix('fresh', const Duration(minutes: 1)),
          fix('old', const Duration(hours: 5)),
        ],
        users: [
          person('fresh', sharing: true, testAccount: true),
          person('old', sharing: true, testAccount: true),
          person('none', testAccount: true),
        ],
      );

      expect(team.onMap, isEmpty);
      expect(team.notSeen, isEmpty);
      expect(team.sharingOff, isEmpty);
    });

    test('a disabled or invited account is in none of the three sections', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: const [],
        users: [
          person('d', status: 'disabled'),
          person('i', status: 'invited'),
        ],
      );

      expect(team.notSeen, isEmpty);
      expect(team.sharingOff, isEmpty);
    });

    test('the off-map sections are sorted by name', () {
      final team = LiveMapAggregator.groupTeam(
        fixes: const [],
        users: [person('zoe'), person('amy'), person('max')],
      );

      expect(team.sharingOff.map((a) => a.name), ['amy', 'max', 'zoe']);
      expect(team.offMapCount, 3);
    });
  });

  group('LiveMapAggregator.isStale', () {
    test('null updatedAt is fresh', () {
      expect(LiveMapAggregator.isStale(null, now), isFalse);
    });

    test('24m59s is fresh', () {
      final updatedAt = now.subtract(const Duration(minutes: 24, seconds: 59));
      expect(LiveMapAggregator.isStale(updatedAt, now), isFalse);
    });

    test('exactly 25m00s is NOT stale (strict >)', () {
      final updatedAt = now.subtract(const Duration(minutes: 25));
      expect(LiveMapAggregator.isStale(updatedAt, now), isFalse);
    });

    test('25m01s is stale', () {
      final updatedAt = now.subtract(const Duration(minutes: 25, seconds: 1));
      expect(LiveMapAggregator.isStale(updatedAt, now), isTrue);
    });
  });

  StaffMapPoint point(String id, double lat, double lng) => StaffMapPoint(
    userDocId: id,
    name: id,
    color: Colors.blue,
    lat: lat,
    lng: lng,
    updatedAt: null,
  );

  group('LiveMapAggregator.distanceMeters', () {
    test('zero distance for the same point', () {
      expect(LiveMapAggregator.distanceMeters(45.5, -73.6, 45.5, -73.6), 0);
    });

    test('~1.11 km per 0.01 degree of latitude', () {
      final d = LiveMapAggregator.distanceMeters(45, -73, 45.01, -73);
      expect(d, closeTo(1113, 5));
    });
  });

  group('LiveMapAggregator.sortedByProximity', () {
    test('self leads, rest ordered nearest-first', () {
      final points = [
        point('far', 45.6, -73.6),
        point('me', 45.5, -73.6),
        point('near', 45.51, -73.6),
      ];
      final ordered = LiveMapAggregator.sortedByProximity(
        points,
        selfDocId: 'me',
      );
      expect(ordered.map((p) => p.userDocId), ['me', 'near', 'far']);
    });

    test('no self point preserves incoming order', () {
      final points = [point('b', 1, 1), point('a', 2, 2)];
      final ordered = LiveMapAggregator.sortedByProximity(
        points,
        selfDocId: 'ghost',
      );
      expect(ordered.map((p) => p.userDocId), ['b', 'a']);
    });

    test('null selfDocId preserves incoming order', () {
      final points = [point('b', 1, 1), point('a', 2, 2)];
      final ordered = LiveMapAggregator.sortedByProximity(
        points,
        selfDocId: null,
      );
      expect(ordered.map((p) => p.userDocId), ['b', 'a']);
    });
  });

  group('LiveMapAggregator.cityFromAddress', () {
    test('extracts city from a full Canadian street address', () {
      expect(
        LiveMapAggregator.cityFromAddress(
          '123 Rue Example, Montréal, QC H2X 1Y4, Canada',
        ),
        'Montréal',
      );
    });

    test('extracts city from a province-only tail', () {
      expect(LiveMapAggregator.cityFromAddress('Québec, QC, Canada'), 'Québec');
    });

    test('handles no postal code', () {
      expect(
        LiveMapAggregator.cityFromAddress('45 Main St, Laval, QC, Canada'),
        'Laval',
      );
    });

    test('null / empty returns null', () {
      expect(LiveMapAggregator.cityFromAddress(null), isNull);
      expect(LiveMapAggregator.cityFromAddress('   '), isNull);
    });

    test('a bare single token is returned as-is', () {
      expect(LiveMapAggregator.cityFromAddress('Sherbrooke'), 'Sherbrooke');
    });
  });

  group('LiveMapAggregator.freshnessOf', () {
    test('null updatedAt is justNow', () {
      expect(LiveMapAggregator.freshnessOf(null, now), isA<FreshnessJustNow>());
    });

    test('under 60s is justNow', () {
      final updatedAt = now.subtract(const Duration(seconds: 30));
      expect(
        LiveMapAggregator.freshnessOf(updatedAt, now),
        isA<FreshnessJustNow>(),
      );
    });

    test('1-59 minutes buckets as minutesAgo', () {
      final updatedAt = now.subtract(const Duration(minutes: 5));
      final bucket = LiveMapAggregator.freshnessOf(updatedAt, now);
      expect(bucket, isA<FreshnessMinutesAgo>());
      expect((bucket as FreshnessMinutesAgo).minutes, 5);
    });

    test('60+ minutes buckets as hoursAgo', () {
      final updatedAt = now.subtract(const Duration(hours: 3));
      final bucket = LiveMapAggregator.freshnessOf(updatedAt, now);
      expect(bucket, isA<FreshnessHoursAgo>());
      expect((bucket as FreshnessHoursAgo).hours, 3);
    });
  });
}
