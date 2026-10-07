import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/permissions/location_permission_service.dart';
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
  final controller = StreamController<Position>.broadcast();
  int currentPositionCalls = 0;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      controller.stream;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    currentPositionCalls++;
    return _position();
  }
}

void _lifecycle(AppLifecycleState state) =>
    WidgetsBinding.instance.handleAppLifecycleStateChanged(state);

Position _position() => Position(
  latitude: 45.5,
  longitude: -73.6,
  timestamp: DateTime(2026, 9, 19),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAuth auth;
  late _MockPresenceRepo presence;
  late _FakeGeolocator geolocator;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbackValue(0.0);
  });

  setUp(() {
    auth = _MockAuth();
    final user = _MockUser();
    final employees = _MockEmployeesRepo();
    presence = _MockPresenceRepo();
    final permissions = _MockPermissions();
    geolocator = _FakeGeolocator();
    GeolocatorPlatform.instance = geolocator;

    when(() => user.uid).thenReturn('uid-1');
    when(() => auth.currentUser).thenReturn(user);
    when(
      () => employees.findUserByUid(any()),
    ).thenAnswer((_) async => const UserUidMatch(id: 'doc-1', data: {}));
    when(
      () => presence.upsertLocation(
        userDocId: any(named: 'userDocId'),
        uid: any(named: 'uid'),
        lat: any(named: 'lat'),
        lng: any(named: 'lng'),
      ),
    ).thenAnswer((_) async => PresenceWriteResult.ok);
    when(
      () => presence.deleteLocation(userDocId: any(named: 'userDocId')),
    ).thenAnswer((_) async => true);
    when(
      permissions.ensureLocation,
    ).thenAnswer((_) async => LocationPermissionResult.granted);

    container = ProviderContainer(
      overrides: [
        currentUserDocProvider.overrideWith(
          (ref) => Stream.value(const {
            'role': 'employee',
            'status': 'active',
            'locationSharingEnabled': true,
          }),
        ),
        employeesRepositoryProvider.overrideWithValue(employees),
        presenceRepositoryProvider.overrideWithValue(presence),
        locationPermissionServiceProvider.overrideWithValue(permissions),
        presenceSyncControllerProvider.overrideWith((ref) {
          final controller = PresenceSyncController(ref, auth: auth);
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(currentUserDocProvider, (_, _) {});
    addTearDown(sub.close);
  });

  Future<void> startTracking() async {
    _lifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    await container.read(presenceSyncControllerProvider).sync();
    await pumpEventQueue();
  }

  Future<void> resume() async {
    _lifecycle(AppLifecycleState.inactive);
    _lifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
  }

  test('a resume right after an upload takes no GPS fix', () async {
    await startTracking();
    geolocator.controller.add(_position());
    await pumpEventQueue();

    await resume();

    expect(geolocator.currentPositionCalls, 0);
  });

  test('a resume with no recent upload takes a fresh fix', () async {
    await startTracking();

    await resume();

    expect(geolocator.currentPositionCalls, 1);
  });
}
