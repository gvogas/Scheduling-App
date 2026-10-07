// Behavioural cover for AccountSetupScreen — the P4c first-sign-in flow where
// an invited employee replaces the temporary starting password and activates
// their own account. The screen was previously only swept for overflow, so
// every gate below could be deleted with a green suite.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/screens/account_setup_screen.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class _MockAuthService extends Mock implements AuthService {}

class _StubSignInController extends SignInController {
  _StubSignInController(this._resumeOutcome);

  final SignInOutcome _resumeOutcome;

  @override
  SignInState build() => const SignInState();

  @override
  Future<SignInOutcome> resumeAfterSignUp() async => _resumeOutcome;
}

/// A password meeting the policy the screen gates on: 8+ characters with an
/// upper, a lower and a digit.
const _chosen = 'Chosen1!pass';

Widget _harness({
  required AuthService auth,
  bool offline = false,
  SignInOutcome? resumeOutcome,
}) {
  return ProviderScope(
    overrides: [
      isOfflineProvider.overrideWithValue(offline),
      if (resumeOutcome != null)
        signInControllerProvider.overrideWith(
          () => _StubSignInController(resumeOutcome),
        ),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        routes: {
          AppRoutes.login: (_) => const Scaffold(body: Text('login screen')),
          AppRoutes.mainCalendar: (_) =>
              const Scaffold(body: Text('main calendar')),
        },
        home: AccountSetupScreen(authService: auth),
      ),
    ),
  );
}

/// Fills the four required fields. Leaves consent untouched.
Future<void> _fillForm(WidgetTester tester, {String password = _chosen}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Alex');
  await tester.enterText(fields.at(1), 'Tremblay');
  await tester.enterText(fields.at(3), password);
  await tester.enterText(fields.at(4), password);
  await tester.pumpAndSettle();
}

Future<void> _consent(WidgetTester tester) async {
  final box = find.byType(Checkbox).first;
  await tester.ensureVisible(box);
  await tester.pumpAndSettle();
  await tester.tap(box);
  await tester.pumpAndSettle();
}

/// The consent row and the CTA sit below the fold at the test viewport.
Future<void> _submit(WidgetTester tester) async {
  final button = find.byType(FilledButton).last;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  late _MockAuthService auth;

  setUp(() {
    auth = _MockAuthService();
    when(() => auth.currentUser).thenReturn(null);
    when(
      () => auth.completeAccountSetup(
        newPassword: any(named: 'newPassword'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        phone: any(named: 'phone'),
        termsAccepted: any(named: 'termsAccepted'),
        locationConsent: any(named: 'locationConsent'),
      ),
    ).thenAnswer((_) async {});
  });

  group('the consent gate', () {
    testWidgets('a keyboard submit without consent does not activate', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();
      await _fillForm(tester);

      // Submitting from the confirm field reaches _finishSetup directly,
      // without consulting the disabled CTA — which is exactly why the gate
      // is enforced inside _finishSetup and not only on the button.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verifyNever(
        () => auth.completeAccountSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      );
    });

    testWidgets('consent is passed through as true once given', (tester) async {
      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      await _submit(tester);

      final call = verify(
        () => auth.completeAccountSetup(
          newPassword: captureAny(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: captureAny(named: 'termsAccepted'),
          locationConsent: captureAny(named: 'locationConsent'),
        ),
      )..called(1);
      expect(call.captured[0], _chosen);
      // The server stamps the consent timestamps only when these are true, so
      // a flow that activates without them mints an account with no record.
      expect(call.captured[1], isTrue);
      expect(call.captured[2], isTrue);
    });
  });

  group('the terms link in the consent row', () {
    testWidgets('the sentence carries a tappable "terms of service" run', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();

      // Ticking this box stamps termsAcceptedAt, so the agreement has to be
      // reachable from the row that records the acceptance. The link is a
      // TextSpan run inside the checkbox title, found by locating the run that
      // carries a recognizer rather than by matching the copy.
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('setupConsent')),
          matching: find.byType(Text),
        ),
      );
      final spans = <InlineSpan>[];
      title.textSpan!.visitChildren((span) {
        spans.add(span);
        return true;
      });
      final linked = spans.whereType<TextSpan>().where(
        (s) => s.recognizer != null,
      );

      expect(
        linked,
        hasLength(1),
        reason: 'exactly one run of the consent sentence should be a link',
      );
      // The link text must be a real run of the sentence, not empty — an ARB
      // drift that stops the link text appearing in the sentence falls back to
      // one plain unlinked span, which this would catch.
      expect(linked.single.text, isNotEmpty);
    });
  });

  group('the offline guard', () {
    testWidgets('does not call the server while offline', (tester) async {
      await tester.pumpWidget(_harness(auth: auth, offline: true));
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      await _submit(tester);

      // An awaited write offline never resolves until the connection returns,
      // so the button would just spin.
      verifyNever(
        () => auth.completeAccountSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      );
    });
  });

  group('the setup sign-out path', () {
    testWidgets('signing out returns to login', (tester) async {
      when(() => auth.signOut()).thenAnswer((_) async {});
      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();

      final logOut = find.widgetWithText(TextButton, 'Log out');
      await tester.ensureVisible(logOut);
      await tester.pumpAndSettle();
      await tester.tap(logOut);
      await tester.pumpAndSettle();

      verify(() => auth.signOut()).called(1);
      expect(find.text('login screen'), findsOneWidget);
    });

    // The log-out control and _finishSetup share one _isTransitionBusy gate.
    // Only the SOURCE of busy-ness changed when the verification round-trips
    // went away, so the gate is re-pinned against the submit path: without it
    // a mid-activation sign-out revokes the credential completeAccountSetup is
    // still using.
    testWidgets('log out stays disabled while activation is in flight', (
      tester,
    ) async {
      final activation = Completer<void>();
      when(
        () => auth.completeAccountSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      ).thenAnswer((_) => activation.future);

      // A resume outcome that only sets a banner, so completing the activation
      // below neither navigates nor reaches the sign-out recovery path.
      await tester.pumpWidget(
        _harness(
          auth: auth,
          resumeOutcome: const SignInError(AuthFailureUnknown()),
        ),
      );
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      // Not `_submit`: its pumpAndSettle never returns while the CTA spinner
      // is running.
      final cta = find.byType(FilledButton).last;
      await tester.ensureVisible(cta);
      await tester.pumpAndSettle();
      await tester.tap(cta, warnIfMissed: false);
      await tester.pump();

      final logOut = find.widgetWithText(TextButton, 'Log out');
      expect(tester.widget<TextButton>(logOut).onPressed, isNull);

      await tester.tap(logOut, warnIfMissed: false);
      await tester.pump();
      verifyNever(() => auth.signOut());

      activation.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('shows a recoverable error if sign-out fails', (tester) async {
      when(() => auth.signOut()).thenThrow(Exception('sign-out failed'));
      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Log out'));
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      expect(
        find.text('Something went wrong, please try again'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('post-setup recovery', () {
    testWidgets('a pending resume routes back to login for a clean retry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(auth: auth, resumeOutcome: const SignInProfilePending()),
      );
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      await _submit(tester);
      await tester.pumpAndSettle();

      expect(find.text('login screen'), findsOneWidget);
    });

    testWidgets(
      'unexpected resume outcomes re-enable the screen instead of leaving it stuck loading',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            auth: auth,
            resumeOutcome: const SignInError(AuthFailureUnknown()),
          ),
        );
        await tester.pumpAndSettle();
        await _fillForm(tester);
        await _consent(tester);

        await _submit(tester);

        expect(
          find.text('Something went wrong, please try again'),
          findsOneWidget,
        );
        final button = tester.widget<FilledButton>(
          find.byType(FilledButton).last,
        );
        expect(button.onPressed, isNotNull);
      },
    );
  });

  group('the two special-cased setup failures', () {
    // Both grep as covered because `auth_service_test.dart` asserts the THROW;
    // what is unpinned is the screen that has to branch on them.

    testWidgets('an already-complete account is walked INTO the app', (
      tester,
    ) async {
      // The password change precedes activation, so this person's new password
      // DID land. A banner here strands an invited employee on a dead-end
      // screen holding the one session that could have got them out.
      when(
        () => auth.completeAccountSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      ).thenThrow(const AuthFailureSetupAlreadyComplete());

      await tester.pumpWidget(
        _harness(
          auth: auth,
          resumeOutcome: const SignInSuccess(
            EmployeeRecord(id: 'e1', name: 'Alex Tremblay'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      await _submit(tester);
      await tester.pumpAndSettle();

      expect(find.text('main calendar'), findsOneWidget);
      expect(
        find.textContaining('already set up'),
        findsNothing,
        reason: 'the generic banner would be the failure this branch prevents',
      );
    });

    testWidgets('retyping the starting password is a FIELD error', (
      tester,
    ) async {
      // One field's problem: a banner names the failure without pointing at
      // the box to fix, and the CTA has to come back so they can retype.
      when(
        () => auth.completeAccountSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      ).thenThrow(const AuthFailureStartingPasswordReused());

      await tester.pumpWidget(_harness(auth: auth));
      await tester.pumpAndSettle();
      await _fillForm(tester);
      await _consent(tester);

      await _submit(tester);

      // The sentence alone proves nothing: the generic banner renders the same
      // string for this failure, so the assertion has to be about WHERE it is.
      final password = tester
          .widgetList<AuthPasswordField>(find.byType(AuthPasswordField))
          .first;
      expect(
        password.errorText,
        'Choose a different password from the one you were given',
      );
      expect(
        tester.widget<AuthBanner>(find.byType(AuthBanner)).message,
        isNull,
        reason: 'a banner names the failure without pointing at the box',
      );
      final button = tester.widget<FilledButton>(
        find.byType(FilledButton).last,
      );
      expect(button.onPressed, isNotNull);
    });
  });

  // The callable caps `newPassword` at TextLimits.password; a longer one used
  // to pass every client check and fail as "weak password".
  testWidgets('both password fields stop at the server cap', (tester) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();

    final tooLong = 'Aa1${'x' * (TextLimits.password + 50)}';
    final fields = find.descendant(
      of: find.byType(AuthPasswordField),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), tooLong);
    await tester.enterText(fields.at(1), tooLong);
    await tester.pumpAndSettle();

    for (final field in tester.widgetList<TextField>(fields)) {
      expect(field.controller!.text.length, TextLimits.password);
    }
  });
}
