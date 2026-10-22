import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/splash/application/splash_controller.dart';
import 'package:scheduling/features/splash/screens/splash_screen.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

/// A cache miss, so the splash falls through to the authoritative provider.
class _MissAuthCache extends Fake implements AuthCache {
  @override
  Future<EmployeeRecord?> loadIfMatch(String uid) async => null;
}

/// Pumps a splash whose authoritative read fails [failures] times with
/// [error] before resolving to the calendar.
Future<void> _pumpAuthoritative(
  WidgetTester tester, {
  required Exception error,
  required int failures,
  required List<String> routes,
}) async {
  final mockAuth = _MockFirebaseAuth();
  final user = _MockUser();
  when(() => user.uid).thenReturn('u1');
  when(() => mockAuth.currentUser).thenReturn(user);
  var attempts = 0;

  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        firebaseAuthProvider.overrideWithValue(mockAuth),
        authCacheProvider.overrideWithValue(_MissAuthCache()),
        isOfflineProvider.overrideWithValue(false),
        splashDestinationProvider.overrideWith((ref) async {
          if (attempts++ < failures) throw error;
          return const SplashGoToCalendar(isAdmin: false, employeeId: 'doc1');
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SplashScreen(),
        onGenerateRoute: (settings) {
          routes.add(settings.name!);
          return MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Text('${settings.name}-stub')),
          );
        },
      ),
    ),
  );
  // Bounded pumps: the progress bar never settles.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Hands the fast path an ADMIN record. `AuthCache` cannot produce one today —
/// it never stores a role — which is exactly why sourcing the role from it
/// would fail nothing.
class _AdminAuthCache extends Fake implements AuthCache {
  @override
  Future<EmployeeRecord?> loadIfMatch(String uid) async => const EmployeeRecord(
    id: 'doc1',
    name: 'Admin',
    role: 'admin',
    status: 'active',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'signed-out cold start reaches login without navigating during build',
    (tester) async {
      final mockAuth = _MockFirebaseAuth();
      when(() => mockAuth.currentUser).thenReturn(null);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [firebaseAuthProvider.overrideWithValue(mockAuth)],
          child: MaterialApp(
            // Mirrors OnboardingGate: SplashScreen mounts during a build,
            // so initState runs mid-build — the path that wedged the Navigator.
            home: const SplashScreen(),
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

      // Bounded pumps: progress bar never settles (pumpAndSettle would hang); one extra frame lets _decideRoute await firebaseReadyProvider (P10) first.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.text('login-stub'), findsOneWidget);
    },
  );

  testWidgets('the warm-cache fast path routes with least privilege', (
    tester,
  ) async {
    // Role is never read from device storage — always Firestore. The live role
    // stream upgrades an admin a frame later; the cache hit must not.
    final mockAuth = _MockFirebaseAuth();
    final user = _MockUser();
    when(() => user.uid).thenReturn('u1');
    when(() => mockAuth.currentUser).thenReturn(user);

    MainCalendarArgs? args;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          authCacheProvider.overrideWithValue(_AdminAuthCache()),
        ],
        child: MaterialApp(
          home: const SplashScreen(),
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.mainCalendar) {
              args = settings.arguments as MainCalendarArgs?;
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('calendar-stub')),
              );
            }
            return null;
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('calendar-stub'), findsOneWidget);
    expect(args?.employeeId, 'doc1');
    expect(args?.isAdmin, isFalse);
  });

  testWidgets(
    'a non-auth failure keeps the session on an offline splash, and Retry '
    'resolves it (U24)',
    (tester) async {
      final routes = <String>[];
      await _pumpAuthoritative(
        tester,
        error: Exception('network down'),
        failures: 1,
        routes: routes,
      );

      expect(routes, isEmpty, reason: 'must not bounce to Login');
      expect(find.text("You're offline — retrying…"), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.tap(find.text('Retry'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('${AppRoutes.mainCalendar}-stub'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an auth-shaped failure still falls to Login', (tester) async {
    final routes = <String>[];
    await _pumpAuthoritative(
      tester,
      error: FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      ),
      failures: 1,
      routes: routes,
    );

    expect(routes, [AppRoutes.login]);
    expect(find.text("You're offline — retrying…"), findsNothing);
  });
}
