import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/app_sync_listeners.dart';
import 'package:scheduling/core/app/carplay_bridge.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_provider.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_service.dart';

class _FakePush extends Mock implements PushRegistrationController {}

class _FakePresence extends Mock implements PresenceSyncController {}

class _FakeLiveActivity extends Mock
    implements LiveActivityRegistrationController {}

class _FakeUploads extends Mock implements AppointmentImageUploadService {}

class _FakeWidgetSync extends Mock implements WidgetSyncService {}

class _FakeSnapshotSync extends Mock implements ScheduleSnapshotService {}

class _FakeCarPlay extends Mock implements CarPlayBridge {}

/// Drives `isOfflineProvider` from the test so the offline→online flip can be
/// replayed as a real transition (a plain Provider can't change value).
class _OfflineController extends Notifier<bool> {
  @override
  bool build() => false;

  void goOffline() => state = true;

  void goOnline() => state = false;
}

final _offline = NotifierProvider<_OfflineController, bool>(
  _OfflineController.new,
);

/// Feeds one of the two off-screen mirrors from the test.
///
/// A stream, not a static override: an `AsyncError` and a settled `null` are
/// the two emissions the rule under test has to tell apart, and only a real
/// transition produces either — `ref.listen` never fires on an initial value.
/// Each is re-pointed at a per-test controller in `pump`.
final _widgetMirror = StreamProvider<Map<String, dynamic>?>(
  (ref) => const Stream.empty(),
);

final _snapshotMirror = StreamProvider<Map<String, dynamic>?>(
  (ref) => const Stream.empty(),
);

const _account = {'id': 'u1', 'role': 'employee', 'status': 'active'};

const _payload = {
  'todayJobs': [
    {'id': 'a1'},
  ],
};

void main() {
  late _FakePush push;
  late _FakePresence presence;
  late _FakeLiveActivity liveActivity;
  late _FakeUploads uploads;
  late _FakeWidgetSync widgetSync;
  late _FakeSnapshotSync snapshotSync;
  late _FakeCarPlay carPlay;
  late StreamController<Map<String, dynamic>> accountDocs;
  late StreamController<Map<String, dynamic>?> widgetPayloads;
  late StreamController<Map<String, dynamic>?> snapshotPayloads;

  setUp(() {
    push = _FakePush();
    presence = _FakePresence();
    liveActivity = _FakeLiveActivity();
    uploads = _FakeUploads();
    widgetSync = _FakeWidgetSync();
    snapshotSync = _FakeSnapshotSync();
    carPlay = _FakeCarPlay();
    accountDocs = StreamController<Map<String, dynamic>>.broadcast();
    widgetPayloads = StreamController<Map<String, dynamic>?>.broadcast();
    snapshotPayloads = StreamController<Map<String, dynamic>?>.broadcast();
    when(() => push.sync()).thenAnswer((_) async {});
    when(() => presence.sync()).thenAnswer((_) async {});
    when(() => liveActivity.sync()).thenAnswer((_) async {});
    when(() => uploads.drainPending()).thenAnswer((_) async {});
    when(() => widgetSync.sync(any())).thenAnswer((_) async {});
    when(() => widgetSync.clear()).thenAnswer((_) async {});
    when(() => snapshotSync.writeSnapshot(any())).thenAnswer((_) async {});
    when(() => snapshotSync.clearSnapshot()).thenAnswer((_) async {});
    when(() => carPlay.notifySnapshotChanged()).thenAnswer((_) async {});
  });

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  tearDown(() {
    accountDocs.close();
    widgetPayloads.close();
    snapshotPayloads.close();
  });

  /// Mounts a bare ConsumerWidget that registers the listeners, so the wiring
  /// gets exercised without needing a full MaterialApp. That's exactly why
  /// AppSyncListeners was pulled out of `_PaulAppState` in the first place.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool isIos = true,
  }) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserDocProvider.overrideWith((ref) => accountDocs.stream),
          isOfflineProvider.overrideWith((ref) => ref.watch(_offline)),
          pushRegistrationControllerProvider.overrideWithValue(push),
          presenceSyncControllerProvider.overrideWithValue(presence),
          liveActivityRegistrationControllerProvider.overrideWithValue(
            liveActivity,
          ),
          appointmentImageUploadProvider.overrideWithValue(uploads),
          _widgetMirror.overrideWith((ref) => widgetPayloads.stream),
          _snapshotMirror.overrideWith((ref) => snapshotPayloads.stream),
          widgetPayloadProvider.overrideWith((ref) => ref.watch(_widgetMirror)),
          scheduleSnapshotProvider.overrideWith(
            (ref) => ref.watch(_snapshotMirror),
          ),
          widgetSyncServiceProvider.overrideWithValue(widgetSync),
          scheduleSnapshotServiceProvider.overrideWithValue(snapshotSync),
          carPlayBridgeProvider.overrideWithValue(carPlay),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            // The platform gate is injected rather than read off the host:
            // `flutter test` runs on Windows/macOS, so a bare `Platform.isIOS`
            // returns before any seam and leaves both mirror listeners — and
            // the isUnsettled rule they exist to enforce — unreachable.
            AppSyncListeners(ref, isIosPlatform: () => isIos).registerAll();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  group('device registration', () {
    testWidgets('every account-doc emission re-syncs all three controllers', (
      tester,
    ) async {
      await pump(tester);

      accountDocs.add(_account);
      await tester.pump();

      verify(() => push.sync()).called(1);
      verify(() => presence.sync()).called(1);
      verify(() => liveActivity.sync()).called(1);
    });

    testWidgets('a later emission syncs again (token/locale can change)', (
      tester,
    ) async {
      await pump(tester);

      accountDocs.add(_account);
      await tester.pump();
      accountDocs.add({..._account, 'name': 'renamed'});
      await tester.pump();

      verify(() => push.sync()).called(2);
    });
  });

  group('offline→online photo drain', () {
    testWidgets('drains on the offline→online flip while signed in', (
      tester,
    ) async {
      final container = await pump(tester);
      accountDocs.add(_account);
      await tester.pump();
      clearInteractions(uploads);

      container.read(_offline.notifier).goOffline();
      await tester.pump();
      container.read(_offline.notifier).goOnline();
      await tester.pump();

      verify(() => uploads.drainPending()).called(1);
    });

    testWidgets('does NOT drain when signed out', (tester) async {
      // Storage rules need an authed user, so a signed-out drain would just
      // re-queue the batch. That's why the listener gates on a populated account doc.
      final container = await pump(tester);

      container.read(_offline.notifier).goOffline();
      await tester.pump();
      container.read(_offline.notifier).goOnline();
      await tester.pump();

      verifyNever(() => uploads.drainPending());
    });

    testWidgets('does NOT drain on the online→offline direction', (
      tester,
    ) async {
      final container = await pump(tester);
      accountDocs.add(_account);
      await tester.pump();
      clearInteractions(uploads);

      container.read(_offline.notifier).goOffline();
      await tester.pump();

      verifyNever(() => uploads.drainPending());
    });
  });

  group('first-account-doc drain', () {
    testWidgets('drains once when the account doc first arrives', (
      tester,
    ) async {
      await pump(tester);

      accountDocs.add(_account);
      await tester.pump();

      verify(() => uploads.drainPending()).called(1);
    });

    testWidgets('does not re-drain on subsequent populated emissions', (
      tester,
    ) async {
      await pump(tester);

      accountDocs.add(_account);
      await tester.pump();
      accountDocs.add({..._account, 'name': 'renamed'});
      await tester.pump();

      // The transition is empty→populated, not "any populated emission".
      verify(() => uploads.drainPending()).called(1);
    });

    testWidgets('an empty doc (signed out) does not drain', (tester) async {
      await pump(tester);

      accountDocs.add(const {});
      await tester.pump();

      verifyNever(() => uploads.drainPending());
    });

    testWidgets('does not drain on first account-doc arrival while offline', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(_offline.notifier).goOffline();
      await tester.pump();

      accountDocs.add(_account);
      await tester.pump();

      verifyNever(() => uploads.drainPending());
    });
  });

  group('AppSyncListeners.isUnsettled', () {
    test('an emission that is still loading says nothing about sign-out', () {
      expect(
        AppSyncListeners.isUnsettled(const AsyncValue<int?>.loading()),
        isTrue,
      );
    });

    test('a failed read says nothing about sign-out either', () {
      expect(
        AppSyncListeners.isUnsettled(
          AsyncValue<int?>.error(StateError('denied'), StackTrace.empty),
        ),
        isTrue,
      );
    });

    test('a settled null IS a sign-out', () {
      // The one case that must reach `clear()` — and the reason the rule can't
      // simply be `value == null`, which an error and a loading share.
      expect(
        AppSyncListeners.isUnsettled(const AsyncValue<int?>.data(null)),
        isFalse,
      );
    });

    test('settled data is settled', () {
      expect(
        AppSyncListeners.isUnsettled(const AsyncValue<int?>.data(7)),
        isFalse,
      );
    });
  });

  group('home-screen widget mirror', () {
    testWidgets('a failed read neither syncs nor clears', (tester) async {
      // The documented past failure: an AsyncError carries a null value, and
      // null means "signed out, clear the App Group" — so a failed Firestore
      // read blanked the home-screen widget. It is off-screen, so nothing
      // reported it. A stale mirror beats a wrongly-empty one.
      await pump(tester);

      widgetPayloads.addError(StateError('permission-denied'));
      await tester.pumpAndSettle();

      verifyNever(() => widgetSync.clear());
      verifyNever(() => widgetSync.sync(any()));
    });

    testWidgets('a settled null clears the App Group exactly once', (
      tester,
    ) async {
      await pump(tester);

      widgetPayloads.add(null);
      await tester.pumpAndSettle();

      verify(() => widgetSync.clear()).called(1);
      verifyNever(() => widgetSync.sync(any()));
    });

    testWidgets('settled data syncs that payload', (tester) async {
      await pump(tester);

      widgetPayloads.add(_payload);
      await tester.pumpAndSettle();

      verify(() => widgetSync.sync(_payload)).called(1);
      verifyNever(() => widgetSync.clear());
    });

    testWidgets('a widget sync failure is caught instead of escaping', (
      tester,
    ) async {
      when(() => widgetSync.sync(any())).thenThrow(StateError('disk full'));
      await pump(tester);

      widgetPayloads.add(_payload);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the listener never registers off iOS', (tester) async {
      await pump(tester, isIos: false);

      widgetPayloads.add(_payload);
      await tester.pumpAndSettle();

      verifyNever(() => widgetSync.sync(any()));
    });
  });

  group('Siri snapshot mirror', () {
    testWidgets('a failed read neither writes nor clears', (tester) async {
      // Same rule, other surface: a wrongly-cleared snapshot has Siri answer
      // "no appointments" to someone who has jobs.
      await pump(tester);

      snapshotPayloads.addError(StateError('permission-denied'));
      await tester.pumpAndSettle();

      verifyNever(() => snapshotSync.clearSnapshot());
      verifyNever(() => snapshotSync.writeSnapshot(any()));
    });

    testWidgets('a settled null clears the snapshot exactly once', (
      tester,
    ) async {
      await pump(tester);

      snapshotPayloads.add(null);
      await tester.pumpAndSettle();

      verify(() => snapshotSync.clearSnapshot()).called(1);
      verifyNever(() => snapshotSync.writeSnapshot(any()));
    });

    testWidgets('settled data writes that payload', (tester) async {
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      verify(() => snapshotSync.writeSnapshot(_payload)).called(1);
      verifyNever(() => snapshotSync.clearSnapshot());
    });

    testWidgets('a snapshot write failure is caught instead of escaping', (
      tester,
    ) async {
      when(
        () => snapshotSync.writeSnapshot(any()),
      ).thenThrow(StateError('app group locked'));
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the listener never registers off iOS', (tester) async {
      await pump(tester, isIos: false);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      verifyNever(() => snapshotSync.writeSnapshot(any()));
    });
  });

  group('CarPlay ping', () {
    testWidgets('a settled payload pokes the car to re-read', (tester) async {
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      verify(() => carPlay.notifySnapshotChanged()).called(1);
    });

    testWidgets('the ping waits for the App Group WRITE to land', (
      tester,
    ) async {
      // The ping tells the car to re-read the file. Sent while the rewrite is
      // still in flight it reaches the store first, which re-reads the OLD
      // bytes, sees no change and never re-renders. Nothing recovers it: the
      // scene's 60s timer re-ranks, it does not reload.
      final writeLanded = Completer<void>();
      when(
        () => snapshotSync.writeSnapshot(any()),
      ).thenAnswer((_) => writeLanded.future);
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      verify(() => snapshotSync.writeSnapshot(_payload)).called(1);
      verifyNever(() => carPlay.notifySnapshotChanged());

      writeLanded.complete();
      await tester.pumpAndSettle();

      verify(() => carPlay.notifySnapshotChanged()).called(1);
    });

    testWidgets('the ping waits for the sign-out CLEAR to land', (
      tester,
    ) async {
      // The worst case: pinging first has the car re-read a still-populated
      // file and keep rendering the ex-user's clients and addresses.
      final clearLanded = Completer<void>();
      when(
        () => snapshotSync.clearSnapshot(),
      ).thenAnswer((_) => clearLanded.future);
      await pump(tester);

      snapshotPayloads.add(null);
      await tester.pumpAndSettle();

      verify(() => snapshotSync.clearSnapshot()).called(1);
      verifyNever(() => carPlay.notifySnapshotChanged());

      clearLanded.complete();
      await tester.pumpAndSettle();

      verify(() => carPlay.notifySnapshotChanged()).called(1);
    });

    testWidgets('a rewrite failure still pings, and is caught', (tester) async {
      // The chain is what orders them; a throw must not strand the car on a
      // stale render or escape to the zone handler.
      when(
        () => snapshotSync.writeSnapshot(any()),
      ).thenThrow(StateError('app group locked'));
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      verify(() => carPlay.notifySnapshotChanged()).called(1);
    });

    testWidgets('a sign-out pokes it too', (tester) async {
      // The car must drop to its signed-out empty view, not keep rendering the
      // snapshot that was just wiped.
      await pump(tester);

      snapshotPayloads.add(null);
      await tester.pumpAndSettle();

      verify(() => carPlay.notifySnapshotChanged()).called(1);
    });

    testWidgets('a failed read pokes nothing', (tester) async {
      await pump(tester);

      snapshotPayloads.addError(StateError('permission-denied'));
      await tester.pumpAndSettle();

      verifyNever(() => carPlay.notifySnapshotChanged());
    });

    testWidgets('a ping failure is caught instead of escaping', (tester) async {
      // The channel is absent whenever the CarPlay scene has never connected.
      when(
        () => carPlay.notifySnapshotChanged(),
      ).thenThrow(MissingPluginException('no carplay'));
      await pump(tester);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the listener never registers off iOS', (tester) async {
      await pump(tester, isIos: false);

      snapshotPayloads.add(_payload);
      await tester.pumpAndSettle();

      verifyNever(() => carPlay.notifySnapshotChanged());
    });
  });

  group('which stream each mirror opens', () {
    // An ADMIN already holds a business-wide listener on this exact range for
    // the Siri snapshot, so the widget must read it too rather than opening a
    // SECOND permanent Firestore listener over documents the first is already
    // streaming. A technician must never touch the range query at all: it
    // constrains `startTime` alone, and a list query is evaluated against its
    // constraints, so `isAssignedEmployee` rejects the whole thing.
    final today = DateTime(2026, 8, 10);
    final job = AppointmentRecord(
      id: 'a1',
      title: 'Job',
      startTime: DateTime(2026, 8, 10, 9),
      endTime: DateTime(2026, 8, 10, 11),
      employeeIds: const ['me'],
    );

    ({ProviderContainer container, List<String> opened}) harness(
      ActiveUserIdentity identity,
    ) {
      final opened = <String>[];
      final c = ProviderContainer(
        overrides: [
          currentDayProvider.overrideWithValue(today),
          activeUserIdentityProvider.overrideWith((ref) => identity),
          // The admin branch joins the roster for crew colour; without this it
          // would reach FirebaseFirestore.instance.
          allUsersStreamProvider.overrideWith(
            (ref) => Stream.value(const <EmployeeRecord>[]),
          ),
          appointmentsInRangeProvider.overrideWith((ref, range) {
            opened.add('range');
            return Stream.value([job]);
          }),
          myAppointmentsProvider.overrideWith((ref, key) {
            opened.add('mine');
            return Stream.value([job]);
          }),
        ],
      );
      addTearDown(c.dispose);
      return (container: c, opened: opened);
    }

    test('an admin reads the business-wide range stream', () async {
      final h = harness((role: 'admin', docId: 'me'));
      h.container.listen(widgetPayloadProvider, (_, _) {});
      h.container.listen(scheduleSnapshotProvider, (_, _) {});
      await pumpEventQueue();
      h.container
        ..read(widgetPayloadProvider)
        ..read(scheduleSnapshotProvider);

      expect(h.opened, everyElement('range'));
      expect(h.opened, isNotEmpty);
    });

    test('an employee never opens the business-wide range query', () async {
      final h = harness((role: 'employee', docId: 'me'));
      h.container.listen(widgetPayloadProvider, (_, _) {});
      h.container.listen(scheduleSnapshotProvider, (_, _) {});
      await pumpEventQueue();
      h.container
        ..read(widgetPayloadProvider)
        ..read(scheduleSnapshotProvider);

      expect(h.opened, everyElement('mine'));
      expect(h.opened, isNotEmpty);
    });
  });
}
