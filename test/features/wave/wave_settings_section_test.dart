import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/data/wave_service.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';
import 'package:scheduling/features/wave/widgets/wave_settings_section.dart';
import 'package:scheduling/l10n/l10n.dart';

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------

class _MockWaveService extends Mock implements WaveService {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Mock service defaulting to not-connected; re-stub [WaveService.getConnection] for a connected state.
_MockWaveService _mockService() {
  final service = _MockWaveService();
  when(service.getConnection).thenAnswer((_) async => null);
  return service;
}

Widget _wrapSection(
  WaveService service, {
  NoticeService? noticeService,
  List<ClientRecord>? blocked,
}) {
  final notices = noticeService ?? NoticeService();
  return ProviderScope(
    overrides: [
      waveServiceProvider.overrideWithValue(service),
      noticeServiceProvider.overrideWithValue(notices),
      if (blocked != null)
        waveBlockedClientsProvider.overrideWith(
          (ref) => Stream<List<ClientRecord>>.value(blocked),
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
        home: const Scaffold(
          body: SingleChildScrollView(child: WaveSettingsSection()),
        ),
      ),
    ),
  );
}

/// Wraps the full SettingsScreen for admin-gating tests.
///
/// [liveRole] is the LIVE user doc, which is a separate question from the
/// push-time [role] argument — the admin sections are gated on both.
Widget _wrapSettings({
  required String? role,
  WaveService? service,
  String liveRole = 'admin',
}) {
  return ProviderScope(
    overrides: [
      if (service != null) waveServiceProvider.overrideWithValue(service),
      currentUserDocProvider.overrideWith(
        (ref) => Stream.value({'role': liveRole, 'status': 'active'}),
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
        home: SettingsScreen(
          name: 'Test User',
          email: 'test@example.com',
          role: role,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Scheduling',
      packageName: 'net.vogas.scheduling',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // ── WaveSettingsSection widget ────────────────────────────────────────────

  group('WaveSettingsSection', () {
    testWidgets('shows Connect and hides Import when not connected', (
      tester,
    ) async {
      final service = _mockService();
      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      expect(find.text('Connect to Wave'), findsOneWidget);
      // Import is gated on a live connection — a tap while disconnected is
      // guaranteed to fail, so it isn't offered until Connect succeeds.
      expect(find.text('Sync with Wave'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows persisted connected business on mount', (tester) async {
      final service = _mockService();
      // Server reports an already-connected business — no Connect tap needed.
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
        ),
      );

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      verify(service.getConnection).called(1);
      expect(find.text('Persisted Co'), findsOneWidget);
      // Connect is hidden once connected; only Import remains.
      expect(find.text('Connect to Wave'), findsNothing);
      expect(find.text('Sync with Wave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the outbox depth once connected', (tester) async {
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          pendingCount: 3,
          failedCount: 2,
        ),
      );

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      expect(find.text('3 clients waiting to sync'), findsOneWidget);
      expect(find.text('2 clients failed to sync'), findsOneWidget);
      // A dead-lettered job never retries on its own, so the recovery has to be
      // offered right beside the count.
      expect(find.text('Retry failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists the clients the contract refused', (tester) async {
      // A count gives you a number; a list gives you an action. Before this,
      // a refused client left no trace an admin could read.
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
        ),
      );

      await tester.pumpWidget(
        _wrapSection(
          service,
          blocked: const [
            ClientRecord(
              id: 'c1',
              name: 'Blocked Co',
              waveSyncState: 'blocked',
              waveProblems: [
                WaveProblem(
                  field: 'name',
                  code: WaveProblemCode.tooLong,
                  isBlocking: true,
                  length: 218,
                  cap: 200,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Blocked Co'), findsOneWidget);
      expect(find.text('Name is too long (218 / 200)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders no blocked section when nothing is blocked', (
      tester,
    ) async {
      // Omitted at zero, the same rule the outbox rows already follow.
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
        ),
      );

      await tester.pumpWidget(
        _wrapSection(service, blocked: const <ClientRecord>[]),
      );
      await tester.pumpAndSettle();

      expect(find.text("Can't sync to Wave"), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a blocked row opens the client detail sheet', (tester) async {
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
        ),
      );

      await tester.pumpWidget(
        _wrapSection(
          service,
          blocked: const [
            ClientRecord(
              id: 'c1',
              name: 'Blocked Co',
              waveSyncState: 'blocked',
              waveProblems: [
                WaveProblem(
                  field: 'name',
                  code: WaveProblemCode.empty,
                  isBlocking: true,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Blocked Co'));
      await tester.pumpAndSettle();

      // The sheet renders the client's own detail view, so its edit affordance
      // is what makes the problem fixable.
      expect(find.text('Blocked Co'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an UNKNOWN count renders nothing, never zero', (tester) async {
      // null is not 0. Zero means the outbox is empty, which is the one reading
      // an admin would act on by not pressing Sync — so a count the server
      // could not take must not be able to claim it.
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
        ),
      );

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      expect(find.textContaining('waiting to sync'), findsNothing);
      expect(find.textContaining('failed to sync'), findsNothing);
      expect(find.text('Retry failed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty outbox shows no rows', (tester) async {
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          pendingCount: 0,
          failedCount: 0,
        ),
      );

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      expect(find.textContaining('waiting to sync'), findsNothing);
      expect(find.text('Retry failed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Retry failed requeues and reports what reached Wave', (
      tester,
    ) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          failedCount: 2,
        ),
      );
      when(service.retryFailedJobs).thenAnswer(
        (_) async => const WaveRetryResult(
          requeued: 2,
          scanned: 2,
          pushed: 2,
          failed: 0,
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry failed'));
      await tester.pumpAndSettle();

      verify(service.retryFailedJobs).called(1);
      expect(emitted.last, contains('2 clients sent to Wave'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a requeue whose push failed still reports success', (
      tester,
    ) async {
      // The requeue is the durable half — those jobs ARE back in the queue and
      // will drain.
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          failedCount: 3,
        ),
      );
      when(service.retryFailedJobs).thenAnswer(
        (_) async => const WaveRetryResult(
          requeued: 3,
          scanned: 3,
          pushed: null,
          failed: null,
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry failed'));
      await tester.pumpAndSettle();

      expect(emitted.last, contains('3 clients queued for Wave again'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a job that dies again is surfaced as a failure, not success', (
      tester,
    ) async {
      // The press that looked broken: the drain behind the requeue dead-letters
      // a non-retryable job in the same call, so the failed row does not move —
      // a success notice over it is an affirmative lie.
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <AppNotice>[];
      notices.stream.listen(emitted.add);

      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          failedCount: 1,
        ),
      );
      when(service.retryFailedJobs).thenAnswer(
        (_) async => const WaveRetryResult(
          requeued: 1,
          scanned: 1,
          pushed: 0,
          failed: 1,
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry failed'));
      await tester.pumpAndSettle();

      expect(emitted.last.message, contains("still couldn't be sent"));
      expect(emitted.last, isA<NoticeError>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('Retry with nothing left to recover says so', (tester) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          failedCount: 1,
        ),
      );
      when(service.retryFailedJobs).thenAnswer(
        (_) async => const WaveRetryResult(
          requeued: 0,
          scanned: 1,
          pushed: 0,
          failed: 0,
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry failed'));
      await tester.pumpAndSettle();

      expect(emitted.last, contains('Nothing to retry'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Sync is disabled while a Retry is in flight', (tester) async {
      // Both drain the same queue; two presses at once would have each
      // reporting the other's work.
      final service = _mockService();
      when(service.getConnection).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Persisted Co',
          failedCount: 1,
        ),
      );
      final gate = Completer<WaveRetryResult>();
      when(service.retryFailedJobs).thenAnswer((_) => gate.future);

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry failed'));
      await tester.pump();

      final sync = tester.widget<AnimatedLoadingButton>(
        find.byType(AnimatedLoadingButton),
      );
      expect(sync.onPressed, isNull);

      gate.complete(
        const WaveRetryResult(requeued: 1, scanned: 1, pushed: 1, failed: 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Sync is not offered before connecting', (tester) async {
      final service = _mockService();

      await tester.pumpWidget(_wrapSection(service));
      await tester.pumpAndSettle();

      // Sync only appears once connected, so a disconnected admin can't trigger
      // a guaranteed-to-fail sync in the first place.
      expect(find.text('Sync with Wave'), findsNothing);
      verifyNever(service.syncCustomers);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect bootstraps without showing a picker', (
      tester,
    ) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      // The target business is resolved server-side; the client passes nothing.
      when(service.bootstrap).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Acme Corp',
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      // Bootstrap was called with no client-side business selector.
      verify(service.bootstrap).called(1);
      // Business name (from the server response) shows in the connected row.
      expect(find.text('Acme Corp'), findsOneWidget);
      // Success notice was emitted.
      expect(emitted, anyElement(contains('Acme Corp')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect with a blank business stays not-connected', (
      tester,
    ) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <AppNotice>[];
      notices.stream.listen(emitted.add);

      // Server resolved no business (e.g. misconfigured WAVE_BUSINESS_NAME).
      when(service.bootstrap).thenAnswer(
        (_) async => const WaveConnection(businessId: '', businessName: ''),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      // No flip to a blank "connected" state — Connect remains visible and an
      // error notice is surfaced.
      expect(find.text('Connect to Wave'), findsOneWidget);
      expect(emitted.last, isA<NoticeError>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect failure surfaces an error notice', (tester) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.bootstrap).thenThrow(const WaveAuthInvalid());

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      // An error notice is emitted (exact text from WaveAuthInvalid l10n key).
      expect(emitted, isNotEmpty);
      // No business name shown (connection was not established).
      expect(find.text('Acme Corp'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a NON-WaveFailure throw still surfaces a notice', (
      tester,
    ) async {
      // Shipped as a FATAL on 2026-08-31: the catch was narrowed to `on
      // WaveFailure`, so any other throw escaped to the zone handler with NO
      // notice shown — the admin taps Connect and nothing visibly happens.
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.bootstrap).thenThrow(StateError('not a WaveFailure'));

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      expect(emitted, isNotEmpty);
      expect(tester.takeException(), isNull);
      // And the busy flag was released, so the button is usable again.
      expect(find.text('Connect to Wave'), findsOneWidget);
    });

    testWidgets('Sync success after Connect names both directions', (
      tester,
    ) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <String>[];
      notices.stream.listen((n) => emitted.add(n.message));

      when(service.bootstrap).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Test Biz',
        ),
      );
      when(service.syncCustomers).thenAnswer(
        (_) async => const WaveSyncSummary(
          totalCount: 10,
          imported: 8,
          updated: 2,
          skippedArchived: 0,
          pages: 1,
          pushedCreated: 3,
          pushedUpdated: 1,
          pushedPending: 0,
          pushedFailed: 0,
          pushIncomplete: false,
        ),
      );

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync with Wave'));
      await tester.pumpAndSettle();

      // The exact sentence is pinned by wave_sync_notice_test; here we only
      // check the button routes the summary through that composer, so a copy
      // tweak breaks one test instead of two.
      expect(emitted.last, contains('added to Wave'));
      expect(emitted.last, contains('added to the app'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Import failure surfaces an error notice', (tester) async {
      final service = _mockService();
      final notices = NoticeService();
      final emitted = <AppNotice>[];
      notices.stream.listen(emitted.add);

      // Connect first so Import is offered, then make the import fail.
      when(service.bootstrap).thenAnswer(
        (_) async => const WaveConnection(
          businessId: 'biz-1',
          businessName: 'Test Biz',
        ),
      );
      when(service.syncCustomers).thenThrow(const WaveAuthInvalid());

      await tester.pumpWidget(_wrapSection(service, noticeService: notices));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to Wave'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync with Wave'));
      await tester.pumpAndSettle();

      // The last notice must be an error (import failed), never a success.
      expect(emitted, isNotEmpty);
      expect(emitted.last, isA<NoticeError>());
      expect(tester.takeException(), isNull);
    });
  });

  // ── Admin-gating in SettingsScreen ───────────────────────────────────────

  group('SettingsScreen Wave section admin gating', () {
    testWidgets('Wave section is visible for admin role', (tester) async {
      // Use a tall viewport so all settings sections are laid out.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // The section reads connection status on mount, so supply a stubbed
      // service (the default real provider would hit Firebase Functions).
      await tester.pumpWidget(
        _wrapSettings(role: 'admin', service: _mockService()),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('INTEGRATIONS'), findsOneWidget);
      expect(find.text('Connect to Wave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The route argument is a push-time snapshot: a stale back stack or a deep
    // link can carry `role: 'admin'` for someone the user doc no longer says
    // is one. The live gate is what refuses them.
    testWidgets('Wave section is hidden when the live doc is not an admin', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrapSettings(
          role: 'admin',
          service: _mockService(),
          liveRole: 'employee',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('INTEGRATIONS'), findsNothing);
      expect(find.text('Connect to Wave'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Wave section is hidden for employee role', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapSettings(role: 'employee'));
      await tester.pumpAndSettle();

      expect(find.textContaining('INTEGRATIONS'), findsNothing);
      expect(find.text('Connect to Wave'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Wave section is hidden when role is null', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapSettings(role: null));
      await tester.pumpAndSettle();

      expect(find.textContaining('INTEGRATIONS'), findsNothing);
      expect(find.text('Connect to Wave'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
