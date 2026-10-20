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
      permissions.currentStatus,
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
    testWidgets('turning on against a ${refused.name} permission puts the flag '
        'back and reports it', (tester) async {
      // Settings would otherwise read "On" with nothing able to upload.
      when(permissions.currentStatus).thenAnswer((_) async => refused);
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
      expect(writtenFlags(), [true, false]);
      verifyInOrder([presence.sync, presence.unregister]);
    });
  }

  testWidgets('a paused presence feature applies the flag without reading '
      'the permission', (tester) async {
    // sync() returns before the prompt when paused, so an unprompted status
    // would read as a refusal and wrongly revert a real opt-in.
    final ref = await pumpRef(tester, presenceOn: false);

    final outcome = await applyLocationSharing(
      ref,
      _me.copyWith(locationSharingEnabled: false),
      enabled: true,
    );

    expect(outcome, isA<LocationSharingApplied>());
    expect(writtenFlags(), [true]);
    verifyNever(permissions.currentStatus);
  });
}
