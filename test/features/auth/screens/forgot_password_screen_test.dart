import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/screens/forgot_password_screen.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockAuthService extends Mock implements AuthService {}

Finder get _sendResetButton =>
    find.widgetWithText(FilledButton, 'Send Reset Email');

Widget _wrap(AuthService authService, {String? initialEmail}) {
  return ProviderScope(
    child: _wrapInner(authService, initialEmail: initialEmail),
  );
}

Widget _wrapInner(AuthService authService, {String? initialEmail}) {
  return ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: 1,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: ForgotPasswordScreen(
        authService: authService,
        initialEmail: initialEmail,
      ),
    ),
  );
}

void main() {
  late _MockAuthService auth;

  setUp(() {
    auth = _MockAuthService();
  });

  testWidgets('renders email field and send button', (tester) async {
    await tester.pumpWidget(_wrap(auth));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(_sendResetButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows validation error for invalid email', (tester) async {
    await tester.pumpWidget(_wrap(auth, initialEmail: 'not-an-email'));
    await tester.pumpAndSettle();

    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    verifyNever(() => auth.sendPasswordResetEmail(any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('calls AuthService.sendPasswordResetEmail on submit', (
    tester,
  ) async {
    when(() => auth.sendPasswordResetEmail(any())).thenAnswer((_) async {});

    await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
    await tester.pumpAndSettle();

    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    verify(() => auth.sendPasswordResetEmail('user@example.com')).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normalizes the submitted email before a retryable failure', (
    tester,
  ) async {
    when(
      () => auth.sendPasswordResetEmail(any()),
    ).thenThrow(FirebaseAuthException(code: 'network-request-failed'));

    await tester.pumpWidget(_wrap(auth, initialEmail: ' USER@Example.COM '));
    await tester.pumpAndSettle();

    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    verify(() => auth.sendPasswordResetEmail('user@example.com')).called(1);
    expect(find.widgetWithText(TextField, 'user@example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('names the admin reset path on the form AND the sent state', (
    tester,
  ) async {
    // U23: employee emails are often not real inboxes, so the reset mail may
    // reach nobody; the one path that always works is an admin reset.
    const note =
        "If your work email isn't a real inbox, ask your admin to reset your "
        'password from the Team screen.';
    when(() => auth.sendPasswordResetEmail(any())).thenAnswer((_) async {});

    await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
    await tester.pumpAndSettle();
    expect(find.text(note), findsOneWidget);

    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    expect(find.text(note), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent state lists the reset facts inside the SENT panel', (
    tester,
  ) async {
    when(() => auth.sendPasswordResetEmail(any())).thenAnswer((_) async {});

    await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
    await tester.pumpAndSettle();
    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    expect(find.text('SENT'), findsOneWidget);
    expect(find.text('The reset link expires in 1 hour.'), findsOneWidget);
    expect(
      find.text('Using it signs you out on every device.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Send it again resends once, then relabels and greys', (
    tester,
  ) async {
    when(() => auth.sendPasswordResetEmail(any())).thenAnswer((_) async {});

    await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
    await tester.pumpAndSettle();
    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send it again'));
    await tester.pumpAndSettle();

    verify(() => auth.sendPasswordResetEmail('user@example.com')).called(2);
    expect(find.text('Send it again'), findsNothing);
    expect(find.text('Sent again just now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed resend does not consume the one allowed retry', (
    tester,
  ) async {
    var calls = 0;
    when(() => auth.sendPasswordResetEmail(any())).thenAnswer((_) async {
      calls++;
      if (calls == 2) {
        throw FirebaseAuthException(code: 'network-request-failed');
      }
    });

    await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
    await tester.pumpAndSettle();
    await tester.tap(_sendResetButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send it again'));
    await tester.pumpAndSettle();

    verify(() => auth.sendPasswordResetEmail('user@example.com')).called(2);
    expect(find.text('Send it again'), findsOneWidget);
    expect(find.text('Sent again just now'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard resubmit while loading does not fire a second reset request',
    (tester) async {
      final completer = Completer<void>();
      when(
        () => auth.sendPasswordResetEmail(any()),
      ).thenAnswer((_) => completer.future);

      await tester.pumpWidget(_wrap(auth, initialEmail: 'user@example.com'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      verify(() => auth.sendPasswordResetEmail('user@example.com')).called(1);

      completer.complete();
      await tester.pumpAndSettle();
    },
  );
}
