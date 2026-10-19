import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockPresence extends Mock implements PresenceSyncController {}

const _me = EmployeeRecord(
  id: 'me-1',
  name: 'Theo Roy',
  status: 'active',
  locationSharingEnabled: true,
);

void main() {
  late _MockEmployeesRepo repo;
  late _MockPresence presence;

  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: 'fallback')));

  setUp(() {
    repo = _MockEmployeesRepo();
    presence = _MockPresence();
    when(() => repo.updateSelfDetails(any())).thenAnswer((_) async {});
    when(presence.sync).thenAnswer((_) async {});
    when(presence.unregister).thenAnswer((_) async => true);
  });

  /// `applyLocationSharing` takes a [WidgetRef], so it needs a real consumer
  /// element rather than a bare container.
  Future<WidgetRef> pumpRef(WidgetTester tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          presenceSyncControllerProvider.overrideWithValue(presence),
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
      await pending;
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

    await applyLocationSharing(ref, _me, enabled: false);

    final written =
        verify(() => repo.updateSelfDetails(captureAny())).captured.single
            as EmployeeRecord;
    expect(written.locationSharingEnabled, isFalse);
    verify(presence.unregister).called(1);
    verifyNever(presence.sync);
  });

  testWidgets('turning sharing on writes the flag and starts tracking', (
    tester,
  ) async {
    final ref = await pumpRef(tester);

    await applyLocationSharing(
      ref,
      _me.copyWith(locationSharingEnabled: false),
      enabled: true,
    );

    final written =
        verify(() => repo.updateSelfDetails(captureAny())).captured.single
            as EmployeeRecord;
    expect(written.locationSharingEnabled, isTrue);
    verify(presence.sync).called(1);
    verifyNever(presence.unregister);
  });
}
