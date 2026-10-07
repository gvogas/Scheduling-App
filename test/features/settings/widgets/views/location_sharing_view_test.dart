import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/features/settings/widgets/views/location_sharing_view.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feature_paused_notice.dart';

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
  late NoticeService notices;
  late List<AppNotice> seen;

  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: 'fallback')));

  setUp(() {
    repo = _MockEmployeesRepo();
    presence = _MockPresence();
    notices = NoticeService();
    seen = [];
    notices.stream.listen(seen.add);
    when(() => repo.updateSelfDetails(any())).thenAnswer((_) async {});
    when(presence.sync).thenAnswer((_) async {});
  });

  Future<void> pump(
    WidgetTester tester, {
    required bool cleared,
    bool presenceOn = true,
  }) async {
    when(presence.unregister).thenAnswer((_) async => cleared);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          presenceSyncControllerProvider.overrideWithValue(presence),
          myEmployeeRecordProvider.overrideWith((ref) => _me),
          myPresenceFixProvider.overrideWith((ref) => Stream.value(null)),
          isOfflineProvider.overrideWithValue(false),
          featureFlagsProvider.overrideWithValue(
            FeatureFlags(
              addressAutocomplete: true,
              presence: presenceOn,
              liveActivities: true,
              waveSync: true,
              minSupportedBuild: 0,
            ),
          ),
          // No NoticeListener in this harness, so record at the service.
          noticeServiceProvider.overrideWithValue(notices),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: LocationSharingView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a refused erase reports paused, never cleared', (tester) async {
    // Sharing is off either way; only the ERASED half can fail, and the screen
    // must not claim a location history it did not manage to delete.
    await pump(tester, cleared: false);

    await tester.tap(find.byKey(const Key('clearLocationButton')));
    await tester.pumpAndSettle();

    const paused =
        'Location sharing is paused. Your last location could not be '
        'cleared — try again in a moment.';
    expect(seen.map((n) => n.message), [paused]);
  });

  testWidgets('a successful erase reports the location cleared', (
    tester,
  ) async {
    await pump(tester, cleared: true);

    await tester.tap(find.byKey(const Key('clearLocationButton')));
    await tester.pumpAndSettle();

    expect(seen.map((n) => n.message), [
      'Location sharing is paused and your last location was cleared.',
    ]);
  });

  testWidgets('turning the switch off tears presence down', (tester) async {
    await pump(tester, cleared: true);

    await tester.tap(find.byKey(const Key('locationSharingPrivacySwitch')));
    await tester.pumpAndSettle();

    final written =
        verify(() => repo.updateSelfDetails(captureAny())).captured.single
            as EmployeeRecord;
    expect(written.locationSharingEnabled, isFalse);
    verify(presence.unregister).called(1);
  });

  testWidgets('a paused presence flag shows the notice and locks the switch', (
    tester,
  ) async {
    await pump(tester, cleared: true, presenceOn: false);

    final sharingSwitch = tester.widget<Switch>(
      find.byKey(const Key('locationSharingPrivacySwitch')),
    );
    expect(find.byType(FeaturePausedNotice), findsOneWidget);
    expect(sharingSwitch.onChanged, isNull);
  });
}
