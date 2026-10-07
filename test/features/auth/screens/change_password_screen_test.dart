import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_service.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/screens/change_password_screen.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

import '../../../support/account_exit_stubs.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockPush extends Mock implements PushRegistrationController {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockLiveActivity extends Mock
    implements LiveActivityRegistrationController {}

class _RecordingAnalytics extends AnalyticsService {
  final List<String> calls = [];

  @override
  void logSignOut() => calls.add('logSignOut');

  @override
  void setUserRole(String? role) => calls.add('setUserRole($role)');
}

class _StubSignInController extends SignInController {
  _StubSignInController(this._resumeOutcome);

  final SignInOutcome _resumeOutcome;

  @override
  SignInState build() => const SignInState();

  @override
  Future<SignInOutcome> resumeAfterSignUp() async => _resumeOutcome;
}

const _chosen = 'Chosen1pass';
const _employee = EmployeeRecord(id: 'doc1', status: 'active');

/// Every step of the device teardown, in the order it must run before sign-out.
const _teardownThenSignOut = [
  'push',
  'presence',
  'liveActivity',
  'imageCache',
  'imageUploads',
  'clients',
  'appointments',
  'signOut',
];

/// Device-registration doubles that record each teardown step into [calls].
List<Override> _deviceOverrides(List<String> calls) {
  final push = _MockPush();
  final presence = _MockPresence();
  final liveActivity = _MockLiveActivity();
  when(push.unregisterCurrentDevice).thenAnswer((_) async => calls.add('push'));
  when(presence.unregister).thenAnswer((_) async {
    calls.add('presence');
    return true;
  });
  when(
    liveActivity.unregister,
  ).thenAnswer((_) async => calls.add('liveActivity'));
  when(push.sync).thenAnswer((_) async {});
  when(presence.sync).thenAnswer((_) async {});
  when(liveActivity.sync).thenAnswer((_) async {});
  return [
    pushRegistrationControllerProvider.overrideWithValue(push),
    presenceSyncControllerProvider.overrideWithValue(presence),
    liveActivityRegistrationControllerProvider.overrideWithValue(liveActivity),
    ...accountExitStubOverrides(calls: calls),
  ];
}

Widget _harness({
  required AuthService auth,
  List<String>? calls,
  bool offline = false,
  SignInOutcome resumeOutcome = const SignInSuccess(_employee),
  double textScale = 1,
  AnalyticsService? analytics,
}) {
  return ProviderScope(
    overrides: [
      if (analytics != null)
        analyticsServiceProvider.overrideWithValue(analytics),
      isOfflineProvider.overrideWithValue(offline),
      ..._deviceOverrides(calls ?? <String>[]),
      signInControllerProvider.overrideWith(
        () => _StubSignInController(resumeOutcome),
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
          child: child ?? const SizedBox.shrink(),
        ),
        routes: {
          AppRoutes.login: (_) => const Scaffold(body: Text('login screen')),
          AppRoutes.mainCalendar: (_) =>
              const Scaffold(body: Text('main calendar')),
        },
        home: ChangePasswordScreen(authService: auth),
      ),
    ),
  );
}

Future<void> _fill(
  WidgetTester tester, {
  String password = _chosen,
  String? confirm,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), password);
  await tester.enterText(fields.at(1), confirm ?? password);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  final button = find.byType(FilledButton).last;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  late _MockAuthService auth;
  late List<String> calls;

  setUp(() {
    auth = _MockAuthService();
    calls = <String>[];
    when(() => auth.completePasswordReset(any())).thenAnswer((_) async {});
    when(() => auth.signOut()).thenAnswer((_) async => calls.add('signOut'));
  });

  testWidgets('saves the new password and routes into the app', (tester) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    verify(() => auth.completePasswordReset(_chosen)).called(1);
    expect(find.text('main calendar'), findsOneWidget);
  });

  testWidgets('a mismatched confirmation never calls the server', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester, confirm: 'Different1x');

    await _submit(tester);

    expect(find.text('Passwords do not match'), findsOneWidget);
    verifyNever(() => auth.completePasswordReset(any()));
  });

  testWidgets('a password failing the checklist never calls the server', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester, password: 'alllower1x');

    await _submit(tester);

    expect(
      find.text("Password doesn't meet all the requirements below"),
      findsOneWidget,
    );
    verifyNever(() => auth.completePasswordReset(any()));
  });

  testWidgets('a server refusal shows in the banner and re-enables the form', (
    tester,
  ) async {
    when(
      () => auth.completePasswordReset(any()),
    ).thenThrow(const AuthFailureWeakPassword());
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(
      tester.widget<AuthBanner>(find.byType(AuthBanner)).message,
      isNotNull,
    );
    expect(
      tester
          .widget<AnimatedLoadingButton>(find.byType(AnimatedLoadingButton))
          .isLoading,
      isFalse,
    );
    expect(find.text('main calendar'), findsNothing);
  });

  testWidgets('the temporary password is a field error, not a banner', (
    tester,
  ) async {
    when(
      () => auth.completePasswordReset(any()),
    ).thenThrow(const AuthFailureStartingPasswordReused());
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(
      find.text('Choose a different password from the one you were given'),
      findsOneWidget,
    );
    expect(tester.widget<AuthBanner>(find.byType(AuthBanner)).message, isNull);
    expect(find.text('main calendar'), findsNothing);
  });

  testWidgets('an already-cleared flag walks them into the app', (
    tester,
  ) async {
    when(
      () => auth.completePasswordReset(any()),
    ).thenThrow(const AuthFailureSetupAlreadyComplete());
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(find.text('main calendar'), findsOneWidget);
  });

  testWidgets('a pending profile after the change signs out to login', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        auth: auth,
        calls: calls,
        resumeOutcome: const SignInProfilePending(),
      ),
    );
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(calls, _teardownThenSignOut);
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('offline fails fast with a banner and no server call', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth, offline: true));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    verifyNever(() => auth.completePasswordReset(any()));
    expect(
      tester.widget<AuthBanner>(find.byType(AuthBanner)).message,
      isNotNull,
    );
  });

  testWidgets('a keyboard submit then a tap submits once', (tester) async {
    final gate = Completer<void>();
    when(
      () => auth.completePasswordReset(any()),
    ).thenAnswer((_) => gate.future);
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);
    final button = find.byType(FilledButton).last;
    await tester.ensureVisible(button);
    await tester.showKeyboard(find.byType(TextField).at(1));
    await tester.pumpAndSettle();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    // No pump: the button still holds its enabled callback, so only the guard stops it.
    await tester.tap(button, warnIfMissed: false);
    gate.complete();
    await tester.pumpAndSettle();

    verify(() => auth.completePasswordReset(_chosen)).called(1);
  });

  testWidgets('Log out tears the device down, then signs out to login', (
    tester,
  ) async {
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(
      _harness(auth: auth, calls: calls, analytics: analytics),
    );
    await tester.pumpAndSettle();
    final logOut = find.text('Log out');
    await tester.ensureVisible(logOut);
    await tester.pumpAndSettle();

    await tester.tap(logOut);
    await tester.pumpAndSettle();

    expect(calls, _teardownThenSignOut);
    expect(analytics.calls, ['logSignOut', 'setUserRole(null)']);
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('both fields cap at TextLimits.password with IME learning off', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<AuthPasswordField>(
      find.byType(AuthPasswordField),
    );
    expect(fields, hasLength(2));
    for (final field in fields) {
      expect(field.maxLength, TextLimits.password);
    }
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  group('at 260x640 and 2.0 text scale', () {
    Future<void> pumpSmall(WidgetTester tester) async {
      tester.view.physicalSize = const Size(260, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_harness(auth: auth, textScale: 2));
      await tester.pumpAndSettle();
    }

    testWidgets('the idle screen lays out', (tester) async {
      await pumpSmall(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a server failure banner lays out', (tester) async {
      when(
        () => auth.completePasswordReset(any()),
      ).thenThrow(const AuthFailureWeakPassword());
      await pumpSmall(tester);
      await _fill(tester);

      await _submit(tester);

      expect(
        tester.widget<AuthBanner>(find.byType(AuthBanner)).message,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('field errors lay out', (tester) async {
      await pumpSmall(tester);
      await _fill(tester, confirm: 'Different1x');

      await _submit(tester);

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a successful save settles into the app', (tester) async {
      await pumpSmall(tester);
      await _fill(tester);

      await _submit(tester);

      expect(find.text('main calendar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
