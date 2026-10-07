import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/presence/screens/share_location_ask_screen.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockPermissions extends Mock implements LocationPermissionService {}

const _me = EmployeeRecord(
  id: 'me-1',
  uid: 'uid-1',
  name: 'Theo Roy',
  status: 'active',
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
    when(permissions.openSettings).thenAnswer((_) async => true);
  });

  /// Pushes the page over a stub home, so a pop is observable.
  Widget harness({
    required EmployeeRecord me,
    required LocationPermissionResult permission,
    required double textScale,
  }) {
    when(permissions.currentStatus).thenAnswer((_) async => permission);
    return ProviderScope(
      overrides: [
        myEmployeeRecordProvider.overrideWith((_) => me),
        employeesRepositoryProvider.overrideWithValue(repo),
        presenceSyncControllerProvider.overrideWithValue(presence),
        locationPermissionServiceProvider.overrideWithValue(permissions),
        isOfflineProvider.overrideWithValue(false),
      ],
      child: ThemeNotifier(
        themeMode: ThemeMode.light,
        toggleTheme: () {},
        textScale: textScale,
        setTextScale: (_) {},
        setLanguage: (_) {},
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ShareLocationAskScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openPage(
    WidgetTester tester, {
    EmployeeRecord me = _me,
    LocationPermissionResult permission = LocationPermissionResult.denied,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      harness(me: me, permission: permission, textScale: textScale),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Not now closes the page without writing anything', (
    tester,
  ) async {
    await openPage(tester);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(find.byType(ShareLocationAskScreen), findsNothing);
    verifyNever(() => repo.updateSelfDetails(any()));
  });

  testWidgets('Turn on saves sharing on, starts presence and closes', (
    tester,
  ) async {
    await openPage(tester);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    final written =
        verify(() => repo.updateSelfDetails(captureAny())).captured.single
            as EmployeeRecord;
    expect(written.locationSharingEnabled, isTrue);
    expect(find.byType(ShareLocationAskScreen), findsNothing);
  });

  testWidgets('someone already on sees the confirmation, and Done closes '
      'without writing', (tester) async {
    await openPage(
      tester,
      me: _me.copyWith(locationSharingEnabled: true),
      permission: LocationPermissionResult.granted,
    );

    expect(find.text("You're on the team map"), findsOneWidget);
    expect(find.text('Not now'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(ShareLocationAskScreen), findsNothing);
    verifyNever(() => repo.updateSelfDetails(any()));
  });

  testWidgets('a refusal iOS will not re-ask saves sharing on and opens '
      'Settings', (tester) async {
    await openPage(
      tester,
      permission: LocationPermissionResult.permanentlyDenied,
    );

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    final written =
        verify(() => repo.updateSelfDetails(captureAny())).captured.single
            as EmployeeRecord;
    expect(written.locationSharingEnabled, isTrue);
    verify(permissions.openSettings).called(1);
    expect(find.byType(ShareLocationAskScreen), findsNothing);
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openPage(
      tester,
      textScale: 2,
      permission: LocationPermissionResult.permanentlyDenied,
    );

    expect(find.byType(ShareLocationAskScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
