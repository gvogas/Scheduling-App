import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/presence/data/presence_repository.dart';

class _MockAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockPresenceRepo extends Mock implements PresenceRepository {}

class _MockPermissions extends Mock implements LocationPermissionService {}

class _FakeGeolocator extends GeolocatorPlatform {
  int listens = 0;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    listens++;
    return const Stream.empty();
  }
}

class _FlagsController extends Notifier<FeatureFlags> {
  @override
  FeatureFlags build() => FeatureFlags.defaults;

  void presence({required bool on}) => state = FeatureFlags(
    addressAutocomplete: true,
    presence: on,
    liveActivities: true,
    waveSync: true,
    minSupportedBuild: 0,
  );
}

final _flagsSource = NotifierProvider<_FlagsController, FeatureFlags>(
  _FlagsController.new,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAuth auth;
  late _MockUser user;
  late _MockEmployeesRepo employees;
  late _MockPresenceRepo presence;
  late _MockPermissions permissions;
  late _FakeGeolocator geolocator;

  setUp(() {
    auth = _MockAuth();
    user = _MockUser();
    employees = _MockEmployeesRepo();
    presence = _MockPresenceRepo();
    permissions = _MockPermissions();
    geolocator = _FakeGeolocator();
    GeolocatorPlatform.instance = geolocator;

    when(() => user.uid).thenReturn('uid-1');
    when(() => auth.currentUser).thenReturn(user);
    when(
      () => permissions.ensureLocation(),
    ).thenAnswer((_) async => LocationPermissionResult.granted);
    when(
      () => employees.findUserByUid(any()),
    ).thenAnswer((_) async => const UserUidMatch(id: 'doc-1', data: {}));
    when(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    ).thenAnswer((_) async => true);
  });

  Future<ProviderContainer> makeContainer({bool sharing = true}) async {
    final container = ProviderContainer(
      overrides: [
        currentUserDocProvider.overrideWith(
          (ref) => Stream.value({
            'role': 'employee',
            'status': 'active',
            'locationSharingEnabled': sharing,
          }),
        ),
        featureFlagsProvider.overrideWith((ref) => ref.watch(_flagsSource)),
        employeesRepositoryProvider.overrideWithValue(employees),
        presenceRepositoryProvider.overrideWithValue(presence),
        locationPermissionServiceProvider.overrideWithValue(permissions),
        presenceSyncControllerProvider.overrideWith(
          (ref) => PresenceSyncController(ref, auth: auth),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(currentUserDocProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    return container;
  }

  void verifyDeletes(int times) =>
      verify(() => presence.deleteLocation(userDocId: 'doc-1')).called(times);

  test(
    'a remote pause deletes the stored fix once, not on every sync',
    () async {
      final container = await makeContainer();
      container.read(_flagsSource.notifier).presence(on: false);
      final controller = container.read(presenceSyncControllerProvider);

      await controller.sync();
      await controller.sync();

      verifyDeletes(1);
    },
  );

  test('a pause after the flag was back on deletes again', () async {
    final container = await makeContainer();
    final flags = container.read(_flagsSource.notifier);
    final controller = container.read(presenceSyncControllerProvider);

    flags.presence(on: false);
    await controller.sync();
    flags.presence(on: true);
    await controller.sync();
    flags.presence(on: false);
    await controller.sync();

    verifyDeletes(2);
  });

  test('a failed delete is retried by the next sync', () async {
    when(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    ).thenThrow(Exception('offline'));
    final container = await makeContainer();
    container.read(_flagsSource.notifier).presence(on: false);
    final controller = container.read(presenceSyncControllerProvider);

    await controller.sync();
    await controller.sync();

    verifyDeletes(2);
  });

  test('the flag staying on never deletes', () async {
    final container = await makeContainer();

    await container.read(presenceSyncControllerProvider).sync();

    verifyNever(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    );
  });

  test('a delete the repository refuses is retried by the next sync', () async {
    final results = [false, true];
    when(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    ).thenAnswer((_) async => results.removeAt(0));
    final container = await makeContainer();
    container.read(_flagsSource.notifier).presence(on: false);
    final controller = container.read(presenceSyncControllerProvider);

    await controller.sync();
    await controller.sync();
    await controller.sync();

    verifyDeletes(2);
  });

  test('a paused flag with sharing already off deletes nothing here', () async {
    final container = await makeContainer(sharing: false);
    container.read(_flagsSource.notifier).presence(on: false);

    await container.read(presenceSyncControllerProvider).sync();

    verifyNever(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    );
  });

  test('tracking restarts once the flag is back on', () async {
    final container = await makeContainer();
    final flags = container.read(_flagsSource.notifier);
    final controller = container.read(presenceSyncControllerProvider);
    flags.presence(on: false);
    await controller.sync();
    expect(geolocator.listens, 0);

    flags.presence(on: true);
    await controller.sync();

    expect(geolocator.listens, 1);
  });
}
