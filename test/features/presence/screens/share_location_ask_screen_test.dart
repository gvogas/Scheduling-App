import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
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

const _me = EmployeeRecord(
  id: 'me-1',
  uid: 'uid-1',
  name: 'Theo Roy',
  status: 'active',
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
  });

  /// Pushes the page over a stub home, so a pop is observable.
  Widget harness({double textScale = 1}) => ProviderScope(
    overrides: [
      myEmployeeRecordProvider.overrideWith((_) => _me),
      employeesRepositoryProvider.overrideWithValue(repo),
      presenceSyncControllerProvider.overrideWithValue(presence),
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

  Future<void> openPage(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(harness(textScale: textScale));
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

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openPage(tester, textScale: 2);

    expect(find.byType(ShareLocationAskScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
