import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/overdue_review_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/screens/overdue_review_screen.dart';
import 'package:scheduling/features/calendar/widgets/views/overdue_review_action_bar.dart';
import 'package:scheduling/features/calendar/widgets/views/overdue_review_list.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

class _MockNotices extends Mock implements NoticeService {}

AppointmentRecord _job(String id, DateTime start) => AppointmentRecord(
  id: id,
  title: 'Job $id',
  startTime: start,
  endTime: start.add(const Duration(hours: 2)),
  clientName: 'Client $id',
);

final _jobs = [
  _job('j1', DateTime(2026, 7, 22, 9)),
  _job('j2', DateTime(2026, 7, 28, 9)),
  _job('j3', DateTime(2026, 8, 4, 9)),
];

void main() {
  late _MockRepo repo;
  late _MockNotices notices;
  late List<AppointmentRecord> opened;

  setUp(() {
    repo = _MockRepo();
    notices = _MockNotices();
    opened = [];
    when(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) async {});
  });

  Widget wrap(List<AppointmentRecord> jobs, {double textScale = 1}) =>
      ProviderScope(
        overrides: [
          overdueOpenJobsProvider.overrideWith((ref) => Stream.value(jobs)),
          appointmentsRepositoryProvider.overrideWithValue(repo),
          noticeServiceProvider.overrideWithValue(notices),
          isOfflineProvider.overrideWithValue(false),
          employeeColorMapProvider.overrideWithValue(const {}),
          employeeNameMapProvider.overrideWithValue(const {}),
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
            home: OverdueReviewScreen(
              isAdmin: true,
              employeeId: 'me',
              openJob: (context, job) async => opened.add(job),
            ),
          ),
        ),
      );

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('an empty list shows the empty state, never a blank screen', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('No overdue jobs'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('months run oldest first, each opening with a splitter', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();

    final july = find.text('JULY 2026 · 2');
    final august = find.text('AUGUST 2026 · 1');
    expect(july, findsOneWidget);
    expect(august, findsOneWidget);
    expect(tester.getTopLeft(july).dy, lessThan(tester.getTopLeft(august).dy));
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('ticking raises the action bar and unticking lowers it', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();
    expect(find.text('Complete (1)'), findsNothing);

    await tester.tap(find.byKey(const Key('overdueReviewCheck-j1')));
    await tester.pumpAndSettle();
    expect(find.text('Complete (1)'), findsOneWidget);
    expect(find.text('Not done (1)'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('overdueReviewCheck-j1')));
    await tester.pumpAndSettle();
    expect(find.text('Complete (1)'), findsNothing);
  });

  testWidgets('tapping the card body opens the job rather than ticking it', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Job j2'));
    await tester.pumpAndSettle();

    expect(opened.map((j) => j.id), ['j2']);
    expect(find.text('1 selected'), findsNothing);
  });

  testWidgets('Select all flips to Clear for that month only', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select all').first);
    await tester.pumpAndSettle();
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Complete (2)'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear'), findsNothing);
    expect(find.text('Complete (2)'), findsNothing);
  });

  testWidgets('Complete confirms, writes done and announces the count', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Complete (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Mark 2 jobs complete?'), findsOneWidget);
    expect(
      find.text(
        "They'll move to History as Complete, stamped with today's date.",
      ),
      findsOneWidget,
    );
    expect(find.text('Go back'), findsOneWidget);

    await tester.tap(find.text('Complete'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => repo.updateAppointmentStatuses(
        ids: captureAny(named: 'ids'),
        status: 'done',
      ),
    ).captured;
    expect((captured.single as List).toSet(), {'j1', 'j2'});
    verify(() => notices.success('2 jobs marked complete')).called(1);
  });

  testWidgets('Not done names the cancellation, and Go back writes nothing', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overdueReviewCheck-j3')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not done (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Mark 1 job not done?'), findsOneWidget);
    expect(
      find.text(
        "It'll be cancelled and move to History. The crew won't be notified.",
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    verifyNever(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    );
    expect(find.text('Not done (1)'), findsOneWidget);
  });

  testWidgets('a failed write composes the review intro', (tester) async {
    when(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).thenThrow(StateError('boom'));
    useTallViewport(tester);
    await tester.pumpWidget(wrap(_jobs));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overdueReviewCheck-j1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not done (1)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not done'));
    await tester.pumpAndSettle();

    final message =
        verify(() => notices.error(captureAny())).captured.single as String;
    expect(message, startsWith("Couldn't update the jobs"));
  });

  testWidgets('the summary, splitter, cards and action bar survive 260 px '
      'wide at 2x text', (tester) async {
    tester.view.physicalSize = const Size(520, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeColorMapProvider.overrideWithValue(const {}),
          employeeNameMapProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: OverdueReviewList(
              jobs: _jobs,
              selected: const {'j1'},
              onToggle: (_) {},
              onSetMonth: (_, {required selected}) {},
              onOpen: (_) {},
            ),
            bottomNavigationBar: OverdueReviewActionBar(
              count: 12,
              isBusy: false,
              onComplete: () {},
              onNotDone: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
