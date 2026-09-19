import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_service.dart';
import 'package:scheduling/core/app/analytics_identity_listener.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';

/// Records every `setUserRole` call instead of talking to Firebase.
class _RecordingAnalyticsService extends AnalyticsService {
  final List<String?> roleCalls = [];

  @override
  void setUserRole(String? role) => roleCalls.add(role);
}

/// Drives `userRoleProvider` from the test — a plain `Provider` can't change
/// value on its own, so the walk below needs a real sequence of transitions.
final _role = StateProvider<AsyncValue<String>>(
  (ref) => const AsyncValue.loading(),
);

void main() {
  late _RecordingAnalyticsService analytics;

  setUp(() {
    analytics = _RecordingAnalyticsService();
  });

  /// Mounts a bare Consumer that registers the listener, mirroring how
  /// `main.dart`'s `build()` calls `AnalyticsIdentityListener(ref).registerAll()`.
  Future<ProviderContainer> pump(WidgetTester tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userRoleProvider.overrideWith((ref) => ref.watch(_role)),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            AnalyticsIdentityListener(ref).registerAll();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return container;
  }

  testWidgets(
    'holds the last role through loading/error, clears on empty, and skips '
    'a repeated value',
    (tester) async {
      final container = await pump(tester);
      final role = container.read(_role.notifier)
        ..state = const AsyncValue.data('admin');
      await tester.pump();

      // An unsettled read says nothing about the role — must not clear it.
      role.state = const AsyncValue.loading();
      await tester.pump();

      // A transient error must not clear it either.
      role.state = AsyncValue.error(Exception('boom'), StackTrace.empty);
      await tester.pump();

      // A settled EMPTY role is the bootstrap window / sign-out — clears it.
      role.state = const AsyncValue.data('');
      await tester.pump();

      role.state = const AsyncValue.data('employee');
      await tester.pump();

      // Same value again — must not re-send the identical role.
      role.state = const AsyncValue.data('employee');
      await tester.pump();

      expect(analytics.roleCalls, ['admin', null, 'employee']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a role already settled when the listener mounts fires no call', (
    tester,
  ) async {
    // `ref.listen` only fires on a CHANGE — main.dart's build() runs every
    // frame, so mounting with a role already settled must not spuriously
    // call setUserRole.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userRoleProvider.overrideWith(
            (ref) => const AsyncValue.data('admin'),
          ),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            AnalyticsIdentityListener(ref).registerAll();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    expect(analytics.roleCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
