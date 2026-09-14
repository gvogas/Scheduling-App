import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/live_map_providers.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';

/// A rules rejection on either source must stay DISTINGUISHABLE from "nobody
/// is in the field". A regression to `.value ?? []` renders an empty live map,
/// which an admin reads as the whole crew being off duty.
EmployeeRecord _employee(String id) => EmployeeRecord(
  id: id,
  name: 'Person $id',
  email: '$id@example.com',
  status: 'active',
);

final _now = DateTime(2026, 7, 8, 12);

PresenceFix _fix(String id, {Duration age = Duration.zero}) => PresenceFix(
  userDocId: id,
  lat: 45.5,
  lng: -73.6,
  updatedAt: _now.subtract(age),
);

ProviderContainer _container({
  List<PresenceFix>? fixes,
  List<EmployeeRecord>? users,
  Object? fixesError,
  Object? usersError,
}) => ProviderContainer(
  // Mirrors `main()`: retry is disabled globally, so a failed source settles
  // as an error instead of respinning forever.
  retry: (retryCount, error) => null,
  overrides: [
    liveMapClockProvider.overrideWith(
      (_) =>
          () => _now,
    ),
    liveMapTickProvider.overrideWith((_) => const Stream<int>.empty()),
    allPresenceStreamProvider.overrideWith(
      (_) => fixesError != null
          ? Stream<List<PresenceFix>>.error(fixesError)
          : Stream.value(fixes ?? const []),
    ),
    allUsersStreamProvider.overrideWith(
      (_) => usersError != null
          ? Stream<List<EmployeeRecord>>.error(usersError)
          : Stream.value(users ?? const []),
    ),
  ],
)..listen(liveMapPointsProvider, (_, _) {});

/// Both sources are streams, so a bare read straight after construction only
/// ever sees `loading`.
Future<void> _settle() => pumpEventQueue();

void main() {
  test(
    'a rejected presence feed surfaces as an error, not an empty map',
    () async {
      final container = _container(fixesError: Exception('permission-denied'));
      addTearDown(container.dispose);
      await _settle();

      expect(container.read(liveMapPointsProvider).hasError, isTrue);
    },
  );

  test('a rejected users feed surfaces as an error too', () async {
    final container = _container(usersError: Exception('permission-denied'));
    addTearDown(container.dispose);
    await _settle();

    expect(container.read(liveMapPointsProvider).hasError, isTrue);
  });

  test('a genuinely empty roster settles as data, not an error', () async {
    final container = _container(fixes: const [], users: const []);
    addTearDown(container.dispose);
    await _settle();

    expect(container.read(liveMapPointsProvider).value, isEmpty);
  });

  test('both sources settled join into staff points', () async {
    final container = _container(fixes: [_fix('e1')], users: [_employee('e1')]);
    addTearDown(container.dispose);
    await _settle();

    expect(
      container.read(liveMapPointsProvider).requireValue.single.userDocId,
      'e1',
    );
  });

  test('a fix older than two hours is not a point on the map', () async {
    final container = _container(
      fixes: [_fix('e1', age: const Duration(hours: 3))],
      users: [_employee('e1')],
    );
    addTearDown(container.dispose);
    await _settle();

    expect(container.read(liveMapPointsProvider).requireValue, isEmpty);
  });

  test('the team groups the same fix under NOT SEEN', () async {
    final container = _container(
      fixes: [_fix('e1', age: const Duration(hours: 3))],
      users: [_employee('e1')],
    )..listen(liveMapTeamProvider, (_, _) {});
    addTearDown(container.dispose);
    await _settle();

    expect(
      container.read(liveMapTeamProvider).requireValue.notSeen.single.userDocId,
      'e1',
    );
  });

  test('an unsettled source is loading, not an empty map', () {
    final container = _container(fixes: [_fix('e1')], users: [_employee('e1')]);
    addTearDown(container.dispose);

    expect(container.read(liveMapPointsProvider).isLoading, isTrue);
  });
}
