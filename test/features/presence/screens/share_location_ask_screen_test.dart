import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/location_consent_provider.dart';
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
  late NoticeService notices;
  late List<AppNotice> seen;

  /// What iOS reports; `ensureLocation` (the one prompt) moves it to [afterPrompt].
  late LocationPermissionResult permissionNow;

  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: 'fallback')));

  setUp(() {
    repo = _MockEmployeesRepo();
    presence = _MockPresence();
    permissions = _MockPermissions();
    notices = NoticeService();
    seen = [];
    notices.stream.listen(seen.add);
    when(() => repo.updateSelfDetails(any())).thenAnswer((_) async {});
    when(presence.unregister).thenAnswer((_) async => true);
    when(permissions.openSettings).thenAnswer((_) async => true);
    when(permissions.currentStatus).thenAnswer((_) async => permissionNow);
  });

  /// Pushes the page over a stub home, so a pop is observable.
  Widget harness({
    required EmployeeRecord me,
    required LocationPermissionResult permission,
    required LocationPermissionResult afterPrompt,
    required double textScale,
    DateTime? consentAt,
  }) {
    permissionNow = permission;
    when(
      permissions.ensureLocation,
    ).thenAnswer((_) async => permissionNow = afterPrompt);
    when(presence.sync).thenAnswer((_) async {});
    return ProviderScope(
      overrides: [
        myEmployeeRecordProvider.overrideWith((_) => me),
        myLocationConsentAtProvider.overrideWith((_) => consentAt),
        employeesRepositoryProvider.overrideWithValue(repo),
        presenceSyncControllerProvider.overrideWithValue(presence),
        locationPermissionServiceProvider.overrideWithValue(permissions),
        featureFlagsProvider.overrideWithValue(FeatureFlags.defaults),
        noticeServiceProvider.overrideWithValue(notices),
        isOfflineProvider.overrideWithValue(false),
        sessionFenceProvider.overrideWithValue(
          SessionFence(readUid: () => 'test-uid'),
        ),
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
    LocationPermissionResult afterPrompt = LocationPermissionResult.granted,
    DateTime? consentAt,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      harness(
        me: me,
        permission: permission,
        afterPrompt: afterPrompt,
        consentAt: consentAt,
        textScale: textScale,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  List<bool> writtenFlags() => verify(
    () => repo.updateSelfDetails(captureAny()),
  ).captured.map((r) => (r as EmployeeRecord).locationSharingEnabled).toList();

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

    expect(writtenFlags(), [true]);
    expect(find.byType(ShareLocationAskScreen), findsNothing);
  });

  testWidgets('a declined prompt never turns the flag on, says so, and keeps '
      'the page open in its Open Settings form', (tester) async {
    await openPage(
      tester,
      afterPrompt: LocationPermissionResult.permanentlyDenied,
    );

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    verifyNever(() => repo.updateSelfDetails(any()));
    verify(presence.unregister).called(1);
    expect(seen.single, isA<NoticeError>());
    expect(find.byType(ShareLocationAskScreen), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Turn on'), findsNothing);
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

  testWidgets('a refusal iOS will not re-ask opens Settings and writes '
      'nothing, keeping the page for Turn on afterwards', (tester) async {
    await openPage(
      tester,
      permission: LocationPermissionResult.permanentlyDenied,
    );

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    verify(permissions.openSettings).called(1);
    verifyNever(() => repo.updateSelfDetails(any()));
    expect(find.byType(ShareLocationAskScreen), findsOneWidget);
  });

  testWidgets('a consent just given in setup turns the page into its iOS '
      'step, and Turn on still saves the flag', (tester) async {
    await openPage(
      tester,
      consentAt: DateTime.now().subtract(const Duration(seconds: 30)),
    );

    expect(find.text('Finish setting up the team map'), findsOneWidget);
    expect(find.text('Be on the team map'), findsNothing);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    expect(writtenFlags(), [true]);
    expect(find.byType(ShareLocationAskScreen), findsNothing);
  });

  testWidgets('an old consent gets the ordinary question', (tester) async {
    await openPage(
      tester,
      consentAt: DateTime.now().subtract(const Duration(days: 40)),
    );

    expect(find.text('Be on the team map'), findsOneWidget);
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
