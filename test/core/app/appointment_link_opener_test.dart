// Pins the external-entry-point router that used to live as private State
// methods on the app root: the id each tap shape carries, the signed-out and
// no-hub early returns (the latter is the one that used to discard a tap with
// nothing recording it), and the unavailable-appointment notice.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/appointment_link_opener.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class _MockRepository extends Mock implements AppointmentsRepository {}

class _MockNotices extends Mock implements NoticeService {}

class _FakeHub implements AppointmentLinkHub {
  _FakeHub({this.isAdmin = false});

  @override
  final bool isAdmin;

  @override
  String get employeeId => 'me';

  final calls = <String>[];

  @override
  void showCalendar() => calls.add('showCalendar');

  @override
  void goHome() => calls.add('goHome');
}

void main() {
  late _MockRepository repository;
  late _MockNotices notices;
  late GlobalKey<NavigatorState> navigatorKey;

  final job = AppointmentRecord(
    id: 'a1',
    title: 'Job',
    startTime: DateTime(2026, 8, 10, 9),
    endTime: DateTime(2026, 8, 10, 11),
    employeeIds: const ['me'],
  );

  setUp(() {
    repository = _MockRepository();
    notices = _MockNotices();
    navigatorKey = GlobalKey<NavigatorState>();
  });

  /// Pumps a real MaterialApp so `navigatorKey.currentContext` resolves and
  /// `AppLocalizations.of` finds a delegate — the opener bails without both.
  Future<AppointmentLinkOpener> pumpOpener(
    WidgetTester tester, {
    required bool signedIn,
    AppointmentLinkHub? hub,
    List<AppointmentRecord?>? shown,
    List<bool>? shownWithActions,
    List<RouteSettings>? pushedRoutes,
    Duration hubPollInterval = const Duration(milliseconds: 200),
  }) async {
    late AppointmentLinkOpener opener;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(repository),
          noticeServiceProvider.overrideWithValue(notices),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          onGenerateRoute: (settings) {
            pushedRoutes?.add(settings);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const SizedBox.shrink(),
            );
          },
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              opener = AppointmentLinkOpener(
                ref: ref,
                navigatorKey: navigatorKey,
                isMounted: () => true,
                isSignedIn: () => signedIn,
                resolveHub: () => hub,
                hubPollInterval: hubPollInterval,
                showDetails:
                    (
                      context,
                      record, {
                      required showActions,
                      required analyticsSource,
                    }) async {
                      shown?.add(record);
                      shownWithActions?.add(showActions);
                    },
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return opener;
  }

  testWidgets('a push tap opens the appointment it names', (tester) async {
    when(
      () => repository.getAppointmentById('a1'),
    ).thenAnswer((_) async => job);
    final hub = _FakeHub(isAdmin: true);
    final shown = <AppointmentRecord?>[];
    final withActions = <bool>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: hub,
      shown: shown,
      shownWithActions: withActions,
    );

    await opener.handlePushTap(
      const RemoteMessage(data: {'appointmentId': ' a1 '}),
    );
    await tester.pump();

    expect(shown.single, job);
    // The live role gates the sheet's edit/cancel/delete controls.
    expect(withActions.single, isTrue);
    expect(hub.calls, ['showCalendar', 'goHome']);
  });

  testWidgets('a widget tap reads the id from the URI query', (tester) async {
    when(
      () => repository.getAppointmentById('a1'),
    ).thenAnswer((_) async => job);
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: _FakeHub(),
      shown: shown,
    );

    await opener.handleWidgetTap(
      Uri.parse('esproschedule://appointment?id=%20a1%20&homeWidget'),
    );
    await tester.pump();

    expect(shown.single, job);
  });

  testWidgets('a signed-out tap opens nothing', (tester) async {
    final hub = _FakeHub();
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: false,
      hub: hub,
      shown: shown,
    );

    await opener.handlePushTap(
      const RemoteMessage(data: {'appointmentId': 'a1'}),
    );
    await tester.pump();

    expect(shown, isEmpty);
    expect(hub.calls, isEmpty);
    verifyNever(() => repository.getAppointmentById(any()));
  });

  testWidgets('a null message is ignored', (tester) async {
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: _FakeHub(),
      shown: shown,
    );

    await opener.handlePushTap(null);
    await opener.handleWidgetTap(null);
    await tester.pump();

    expect(shown, isEmpty);
  });

  testWidgets('an unavailable appointment surfaces a notice', (tester) async {
    when(
      () => repository.getAppointmentById('gone'),
    ).thenAnswer((_) async => null);
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: _FakeHub(),
      shown: shown,
    );

    await opener.handlePushTap(
      const RemoteMessage(data: {'appointmentId': 'gone'}),
    );
    await tester.pump();

    expect(shown, isEmpty);
    verify(() => notices.info(any())).called(1);
  });

  testWidgets('an id that is not a doc id is never fetched', (tester) async {
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: _FakeHub(),
      shown: shown,
    );

    for (final id in ['a1/fieldNotes/n1', 'x' * 129]) {
      await opener.handleWidgetTap(
        Uri.parse('esproschedule://appointment?id=$id'),
      );
      await tester.pump();
    }

    expect(shown, isEmpty);
    verifyNever(() => repository.getAppointmentById(any()));
    verify(() => notices.info(any())).called(2);
  });

  testWidgets('an id-less tap just shows the calendar', (tester) async {
    final hub = _FakeHub();
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: hub,
      shown: shown,
    );

    await opener.handlePushTap(const RemoteMessage(data: {'kind': 'digest'}));
    await tester.pump();

    expect(hub.calls, ['showCalendar', 'goHome']);
    expect(shown, isEmpty);
    verifyNever(() => repository.getAppointmentById(any()));
    verifyNever(() => notices.info(any()));
  });

  testWidgets('a hub that never appears gives up without opening', (
    tester,
  ) async {
    // B9: this branch used to return silently, so a tap on a slow cold start
    // vanished with no trace. It now logs the missing hub.
    when(
      () => repository.getAppointmentById('a1'),
    ).thenAnswer((_) async => job);
    final shown = <AppointmentRecord?>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      shown: shown,
      hubPollInterval: const Duration(milliseconds: 1),
    );

    final pending = opener.handlePushTap(
      const RemoteMessage(data: {'appointmentId': 'a1'}),
    );
    // 50 poll ticks at 1ms.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pending;

    expect(shown, isEmpty);
  });

  testWidgets('a throwing sheet is swallowed instead of escaping the zone', (
    tester,
  ) async {
    when(
      () => repository.getAppointmentById('a1'),
    ).thenAnswer((_) async => job);
    late AppointmentLinkOpener opener;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(repository),
          noticeServiceProvider.overrideWithValue(notices),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              opener = AppointmentLinkOpener(
                ref: ref,
                navigatorKey: navigatorKey,
                isMounted: () => true,
                isSignedIn: () => true,
                resolveHub: _FakeHub.new,
                showDetails:
                    (
                      context,
                      record, {
                      required showActions,
                      required analyticsSource,
                    }) async => throw StateError('boom'),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await expectLater(
      opener.handlePushTap(const RemoteMessage(data: {'appointmentId': 'a1'})),
      completes,
    );
  });

  testWidgets('an overdueReview push opens the review, never an appointment', (
    tester,
  ) async {
    final hub = _FakeHub(isAdmin: true);
    final pushed = <RouteSettings>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: hub,
      pushedRoutes: pushed,
    );

    await opener.handlePushTap(
      const RemoteMessage(data: {'kind': 'overdueReview', 'count': '3'}),
    );
    await tester.pump();

    final route = pushed.singleWhere((s) => s.name == AppRoutes.overdueReview);
    final args = route.arguments! as OverdueReviewArgs;
    expect(args.isAdmin, isTrue);
    expect(args.employeeId, 'me');
    expect(hub.calls, ['showCalendar', 'goHome']);
    verifyNever(() => repository.getAppointmentById(any()));
  });

  testWidgets('an overdueReview push to a non-admin just shows the calendar', (
    tester,
  ) async {
    final hub = _FakeHub();
    final pushed = <RouteSettings>[];
    final opener = await pumpOpener(
      tester,
      signedIn: true,
      hub: hub,
      pushedRoutes: pushed,
    );

    await opener.handlePushTap(
      const RemoteMessage(data: {'kind': 'overdueReview', 'count': '3'}),
    );
    await tester.pump();

    expect(pushed.where((s) => s.name == AppRoutes.overdueReview), isEmpty);
    expect(hub.calls, ['showCalendar', 'goHome']);
  });
}
