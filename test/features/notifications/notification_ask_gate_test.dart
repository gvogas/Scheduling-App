import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/notifications/push_notification_service.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/notifications/data/notification_ask_store.dart';
import 'package:scheduling/features/notifications/domain/notification_ask_policy.dart';
import 'package:scheduling/features/notifications/widgets/notification_ask_gate.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockPushService extends Mock implements PushNotificationService {}

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

void main() {
  late _MockPushService service;
  late List<bool> holds;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = _MockPushService();
    holds = [];
  });

  group('isNotificationAskDue', () {
    test('is due for an active employee and an active admin', () {
      expect(isNotificationAskDue(me: _me), isTrue);
      expect(isNotificationAskDue(me: _me.copyWith(role: 'admin')), isTrue);
    });

    test('is not due before the record loads, nor for an inactive, test or '
        'uid-less account', () {
      expect(isNotificationAskDue(me: null), isFalse);
      expect(isNotificationAskDue(me: _me.copyWith(status: 'invited')), isFalse);
      expect(isNotificationAskDue(me: _me.copyWith(isTestAccount: true)), isFalse);
      expect(isNotificationAskDue(me: _me.copyWith(uid: '')), isFalse);
    });
  });

  /// The calendar as the gate sees it; [holds] records every `holdsTour`.
  Future<void> pumpCalendar(
    WidgetTester tester, {
    EmployeeRecord? me = _me,
    AuthorizationStatus status = AuthorizationStatus.notDetermined,
  }) async {
    when(service.authorizationStatus).thenAnswer((_) async => status);
    final container = ProviderContainer(
      overrides: [
        myEmployeeRecordProvider.overrideWith((ref) => me),
        pushNotificationServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (context) => settings.name == AppRoutes.notificationAsk
                ? Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('ask page'),
                    ),
                  )
                : HubShellScope(
                    shell: const _NoShell(),
                    current: HubTab.calendar,
                    child: NotificationAskGate(
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

  testWidgets('shows the page once while iOS has never been asked, marking it '
      'seen before the push', (tester) async {
    await pumpCalendar(tester);

    expect(find.text('ask page'), findsOneWidget);
    expect(await NotificationAskStore().hasSeen('uid-1'), isTrue);
  });

  testWidgets('holds the calendar tour until the page is popped', (
    tester,
  ) async {
    await pumpCalendar(tester);
    expect(holds, everyElement(isTrue));

    await tester.tap(find.text('ask page'));
    await tester.pumpAndSettle();

    expect(find.text('ask page'), findsNothing);
    expect(holds.last, isFalse);
  });

  testWidgets('a seen flag skips it for good', (tester) async {
    await NotificationAskStore().markSeen('uid-1');

    await pumpCalendar(tester);

    expect(find.text('ask page'), findsNothing);
    verifyNever(service.authorizationStatus);
    expect(holds.last, isFalse);
  });

  for (final status in [
    AuthorizationStatus.authorized,
    AuthorizationStatus.denied,
    AuthorizationStatus.provisional,
  ]) {
    testWidgets('an OS prompt already answered ${status.name} skips it', (
      tester,
    ) async {
      await pumpCalendar(tester, status: status);

      expect(find.text('ask page'), findsNothing);
      expect(holds.last, isFalse);
    });
  }

  testWidgets('a test account is never asked and never holds the tour', (
    tester,
  ) async {
    await pumpCalendar(tester, me: _me.copyWith(isTestAccount: true));

    expect(find.text('ask page'), findsNothing);
    expect(holds, everyElement(isFalse));
  });

  testWidgets('a status read that never settles keeps holding, pushes nothing', (
    tester,
  ) async {
    when(
      service.authorizationStatus,
    ).thenAnswer((_) => Completer<AuthorizationStatus>().future);
    final container = ProviderContainer(
      overrides: [
        myEmployeeRecordProvider.overrideWith((ref) => _me),
        pushNotificationServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: HubShellScope(
            shell: const _NoShell(),
            current: HubTab.calendar,
            child: NotificationAskGate(
              builder: (_, {required holdsTour}) {
                holds.add(holdsTour);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(holds, everyElement(isTrue));
  });
}
