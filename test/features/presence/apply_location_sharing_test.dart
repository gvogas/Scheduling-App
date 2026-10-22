import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';

import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockPermissions extends Mock implements LocationPermissionService {}

const _me = EmployeeRecord(
  id: 'me-1',
  name: 'Theo Roy',
  status: 'active',
  locationSharingEnabled: true,
);

FeatureFlags _flags({required bool presence}) => FeatureFlags(
  addressAutocomplete: true,
  presence: presence,
  liveActivities: true,
  waveSync: true,
  minSupportedBuild: 0,
);

void main() {
  late _MockEmployeesRepo repo;
  late _MockPresence presence;
  late _MockPermissions permissions;

  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: 'fallback')));

  setUp(() {
    repo = _MockEmployeesRepo();
    presence = _MockPresence();
    permissions = _MockPermissions();
    when(() => repo.updateSelfDetails(any())).thenAnswer((_) async {});
    when(presence.sync).thenAnswer((_) async {});
    when(presence.unregister).thenAnswer((_) async => true);
    when(
      permissions.ensureLocation,
    ).thenAnswer((_) async => LocationPermissionResult.granted);
  });

  /// `applyLocationSharing` takes a [WidgetRef], so it needs a real consumer
  /// element rather than a bare container.
  Future<WidgetRef> pumpRef(
    WidgetTester tester, {
    bool presenceOn = true,
  }) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          presenceSyncControllerProvider.overrideWithValue(presence),
          locationPermissionServiceProvider.overrideWithValue(permissions),
          featureFlagsProvider.overrideWithValue(_flags(presence: presenceOn)),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  List<bool> writtenFlags() => verify(
    () => repo.updateSelfDetails(captureAny()),
  ).captured.map((r) => (r as EmployeeRecord).locationSharingEnabled).toList();

  testWidgets(
    'a held preference write cannot stop replacement-session tracking',
    (tester) async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      final entered = Completer<void>();
      final release = Completer<void>();
      when(() => repo.updateSelfDetails(any())).thenAnswer((_) {
        entered.complete();
        return release.future;
      });
      final ref = await pumpRef(tester);
      final pending = applyLocationSharing(
        ref,
        _me,
        enabled: false,
        session: session,
      );
      await entered.future;
      uid = 'B';
      release.complete();
      expect(await pending, isA<LocationSharingAbandoned>());
      verifyNever(presence.unregister);
      verifyNever(presence.sync);
    },
  );

  testWidgets('turning sharing off tears presence down as well as writing it', (
    tester,
  ) async {
    // The half that matters: without the unregister the phone keeps uploading
    // fixes after the technician turned sharing off, and the switch reads off.
    final ref = await pumpRef(tester);

    final outcome = await applyLocationSharing(ref, _me, enabled: false);

    expect(outcome, isA<LocationSharingApplied>());
    expect(writtenFlags(), [false]);
    verify(presence.unregister).called(1);
    verifyNever(presence.sync);
  });

  testWidgets('turning sharing on writes the flag and starts tracking', (
    tester,
  ) async {
    final ref = await pumpRef(tester);

    final outcome = await applyLocationSharing(
      ref,
      _me.copyWith(locationSharingEnabled: false),
      enabled: true,
    );

    expect(outcome, isA<LocationSharingApplied>());
    expect(writtenFlags(), [true]);
    verify(presence.sync).called(1);
    verifyNever(presence.unregister);
  });

  for (final refused in [
    LocationPermissionResult.denied,
    LocationPermissionResult.permanentlyDenied,
    LocationPermissionResult.servicesDisabled,
  ]) {
    testWidgets('turning on against a ${refused.name} permission never writes '
        'the flag on and reports it', (tester) async {
      // Settings would otherwise read "On" with nothing able to upload.
      when(permissions.ensureLocation).thenAnswer((_) async => refused);
      final ref = await pumpRef(tester);

      final outcome = await applyLocationSharing(
        ref,
        _me.copyWith(locationSharingEnabled: false),
        enabled: true,
      );

      expect(
        outcome,
        isA<LocationSharingBlocked>().having(
          (o) => o.permission,
          'permission',
          refused,
        ),
      );
      verifyNever(() => repo.updateSelfDetails(any()));
      verifyNever(presence.sync);
      verify(presence.unregister).called(1);
    });
  }

  testWidgets('a refusal puts a stale on flag back to off', (tester) async {
    when(
      permissions.ensureLocation,
    ).thenAnswer((_) async => LocationPermissionResult.denied);
    final ref = await pumpRef(tester);

    final outcome = await applyLocationSharing(ref, _me, enabled: true);

    expect(outcome, isA<LocationSharingBlocked>());
    expect(writtenFlags(), [false]);
  });

  testWidgets('the prompt settles before the flag is written, so a sync '
      'already in flight cannot revert it', (tester) async {
    // A coalesced sync() returns at once, so it can't be what awaits the prompt.
    final inFlight = Completer<void>();
    final prompt = Completer<LocationPermissionResult>();
    when(presence.sync).thenAnswer((_) => inFlight.future);
    when(permissions.ensureLocation).thenAnswer((_) => prompt.future);
    final ref = await pumpRef(tester);
    unawaited(presence.sync());

    final pending = applyLocationSharing(
      ref,
      _me.copyWith(locationSharingEnabled: false),
      enabled: true,
    );
    await tester.pump();
    verify(permissions.ensureLocation).called(1);
    verifyNever(() => repo.updateSelfDetails(any()));

    prompt.complete(LocationPermissionResult.granted);
    await tester.pump();
    inFlight.complete();

    expect(await pending, isA<LocationSharingApplied>());
    expect(writtenFlags(), [true]);
    verifyNever(presence.unregister);
  });

  testWidgets('a paused presence feature applies the flag without reading '
      'the permission', (tester) async {
    // sync() never prompts while paused, so neither may the flip.
    final ref = await pumpRef(tester, presenceOn: false);

    final outcome = await applyLocationSharing(
      ref,
      _me.copyWith(locationSharingEnabled: false),
      enabled: true,
    );

    expect(outcome, isA<LocationSharingApplied>());
    expect(writtenFlags(), [true]);
    verifyNever(permissions.ensureLocation);
  });
}
