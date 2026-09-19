import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/data/location_share_ask_store.dart';
import 'package:scheduling/features/presence/widgets/location_share_ask_gate.dart';
import 'package:scheduling/features/settings/application/app_info_provider.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoShell implements HubTabSelector {
  const _NoShell();

  @override
  void select(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {}

  @override
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {}

  @override
  void goHome() {}
}

const _me = EmployeeRecord(id: 'e1', uid: 'uid-1', status: 'active');
const _build = '1.62.0+91';

void main() {
  late List<bool> holds;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    holds = [];
  });

  /// The calendar as the gate sees it; [holds] records every `holdsTour`.
  Future<void> pumpCalendar(
    WidgetTester tester, {
    EmployeeRecord? me = _me,
  }) async {
    final container = ProviderContainer(
      overrides: [
        myEmployeeRecordProvider.overrideWith((ref) => me),
        activeUserIdentityProvider.overrideWith(
          (ref) => Completer<Never>().future,
        ),
        allUsersStreamProvider.overrideWith((ref) => const Stream.empty()),
        appInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'ES Pro',
            packageName: 'net.vogas.scheduling',
            version: '1.62.0',
            buildNumber: '91',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => settings.name == AppRoutes.shareLocationAsk
                ? const Scaffold(body: Text('ask page'))
                : HubShellScope(
                    shell: const _NoShell(),
                    current: HubTab.calendar,
                    child: LocationShareAskGate(
                      builder: (_, {required holdsTour}) {
                        holds.add(holdsTour);
                        return const SizedBox();
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('someone not sharing gets the page on their first calendar '
      'visit', (tester) async {
    await pumpCalendar(tester);

    expect(find.text('ask page'), findsOneWidget);
    expect(
      await LocationShareAskStore().hasAsked('uid-1', build: _build),
      isTrue,
    );
  });

  testWidgets('someone already sharing gets it too', (tester) async {
    await pumpCalendar(tester, me: _me.copyWith(locationSharingEnabled: true));

    expect(find.text('ask page'), findsOneWidget);
  });

  testWidgets('the same build never shows it twice', (tester) async {
    await LocationShareAskStore().markAsked('uid-1', build: _build);

    await pumpCalendar(tester);

    expect(find.text('ask page'), findsNothing);
  });

  testWidgets('an app update shows it again', (tester) async {
    await LocationShareAskStore().markAsked('uid-1', build: '1.61.0+90');

    await pumpCalendar(tester);

    expect(find.text('ask page'), findsOneWidget);
  });

  testWidgets('holds the calendar tour until the page is decided', (
    tester,
  ) async {
    await LocationShareAskStore().markAsked('uid-1', build: _build);

    await pumpCalendar(tester);

    expect(holds.first, isTrue);
    expect(holds.last, isFalse);
  });

  testWidgets('holds the calendar tour while the record is still loading', (
    tester,
  ) async {
    await pumpCalendar(tester, me: null);

    expect(holds.last, isTrue);
    expect(find.text('ask page'), findsNothing);
  });

  testWidgets('a test account is never asked and never holds the tour', (
    tester,
  ) async {
    await pumpCalendar(tester, me: _me.copyWith(isTestAccount: true));

    expect(find.text('ask page'), findsNothing);
    expect(holds, everyElement(isFalse));
  });
}
