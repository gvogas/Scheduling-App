import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/storage/secure_storage_service.dart';
import 'package:scheduling/features/onboarding/screens/onboarding_gate.dart';
import 'package:scheduling/features/onboarding/screens/onboarding_screen.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

/// Secure storage whose reads succeed but whose writes throw — the Android
/// keystore/cipher failure mode that used to make onboarding's "Done"
/// permanently unusable (C11).
class _WriteThrowingStorage implements SecureStorageService {
  int writeAttempts = 0;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<bool> readFlag(String key) async => false;

  @override
  Future<void> write(String key, String? value) async {
    writeAttempts++;
    throw Exception('keystore unavailable');
  }

  @override
  Future<void> writeFlag(String key, {required bool value}) async {
    writeAttempts++;
    throw Exception('keystore unavailable');
  }

  @override
  Future<void> delete(String key) async {}
}

void main() {
  testWidgets(
    'a throwing flag write does not wedge onboarding: Done still advances '
    'to the splash flow for the session',
    (tester) async {
      final storage = _WriteThrowingStorage();
      final mockAuth = _MockFirebaseAuth();
      when(() => mockAuth.currentUser).thenReturn(null);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStorageServiceProvider.overrideWithValue(storage),
            firebaseAuthProvider.overrideWithValue(mockAuth),
          ],
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: const OnboardingGate(),
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.login) {
                return MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('login-stub')),
                );
              }
              return null;
            },
          ),
        ),
      );
      await tester.pump(); // Resolve the seen-flag read.
      expect(find.byType(OnboardingScreen), findsOneWidget);

      // One welcome screen (C20): "Get Started" is the only way out.
      expect(find.text('Skip'), findsNothing);
      await tester.tap(find.text('Get Started'));
      await tester.pump(); // _finish: write throws, caught, _seen = true.
      expect(storage.writeAttempts, 1);

      // Bounded pumps (progress bar never settles): splash awaits firebaseReadyProvider (P10) then navigates post-frame to login, so allow a few frames.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text('login-stub'), findsOneWidget);
    },
  );
}
