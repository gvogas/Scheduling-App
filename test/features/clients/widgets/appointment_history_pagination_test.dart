import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/widgets/views/appointment_history_view.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The view's own page size. A page shorter than this ends the list, so the
/// fixtures below are sized against it rather than against a copied literal.
const int _pageSize = 25;

/// A repository that actually honours the cursor.
class _FakeHistoryRepo implements AppointmentsRepository {
  _FakeHistoryRepo(this.all, {this.failOnCall});

  final List<AppointmentRecord> all;

  /// 1-based fetch number that should throw, once.
  int? failOnCall;

  final List<AppointmentRecord?> cursors = [];
  int calls = 0;

  @override
  Stream<void> get onLocalWrite => const Stream<void>.empty();

  @override
  Future<List<AppointmentRecord>> fetchHistoryPage({
    required int limit,
    AppointmentRecord? after,
  }) async {
    calls += 1;
    cursors.add(after);
    if (failOnCall == calls) {
      failOnCall = null;
      throw Exception('history page load failed');
    }
    final start = after == null
        ? 0
        : all.indexWhere((a) => a.id == after.id) + 1;
    return all.skip(start).take(limit).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// [count] terminal jobs, newest first, walking backwards a day at a time from
/// 2025-05-25 so the run spans more than one month — which is what puts real
/// month bars between the rows.
List<AppointmentRecord> _history(int count) => [
  for (var i = 0; i < count; i++)
    AppointmentRecord(
      id: 'a$i',
      title: 'Job ${i.toString().padLeft(2, '0')}',
      startTime: DateTime(2025, 5, 25 - i, 9),
      endTime: DateTime(2025, 5, 25 - i, 10),
      clientName: 'Client $i',
      employeeIds: const ['e1'],
      employeeNames: const ['Alice'],
      status: 'done',
    ),
];

Widget _wrap(_FakeHistoryRepo repo) => ProviderScope(
  overrides: [
    appointmentsRepositoryProvider.overrideWithValue(repo),
    employeesStreamProvider.overrideWith((_) => const Stream.empty()),
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
      home: const Scaffold(body: AppointmentHistoryView(searchQuery: '')),
    ),
  ),
);

/// Drags the list up repeatedly, settling between drags so a page requested
/// post-frame has a chance to arrive and extend the list.
Future<void> _scrollToEnd(WidgetTester tester, {int drags = 12}) async {
  for (var i = 0; i < drags; i++) {
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  Future<void> pumpView(WidgetTester tester, _FakeHistoryRepo repo) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
  }

  testWidgets('loads the first page on open', (tester) async {
    final repo = _FakeHistoryRepo(_history(_pageSize));
    await pumpView(tester, repo);

    expect(repo.calls, 1);
    expect(repo.cursors.single, isNull);
    expect(find.text('Job 00'), findsOneWidget);
  });

  testWidgets('scrolling to the end loads a second page', (tester) async {
    // The behaviour no previous stub could express.
    final repo = _FakeHistoryRepo(_history(_pageSize + 10));
    await pumpView(tester, repo);
    expect(repo.calls, 1);

    await _scrollToEnd(tester);

    expect(repo.calls, greaterThanOrEqualTo(2));
    // The tail row, which only exists on page two.
    expect(find.text('Job ${_pageSize + 9}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page two is requested from the last row of page one', (
    tester,
  ) async {
    // A cursor taken from anywhere else silently repeats or skips a page.
    final repo = _FakeHistoryRepo(_history(_pageSize + 10));
    await pumpView(tester, repo);

    await _scrollToEnd(tester);

    expect(repo.cursors[1]?.id, 'a${_pageSize - 1}');
  });

  testWidgets('a short page ends the list and stops fetching', (tester) async {
    // getNextPageKey returns null once a page comes back under the page size.
    final repo = _FakeHistoryRepo(_history(_pageSize + 5));
    await pumpView(tester, repo);

    await _scrollToEnd(tester);
    final callsAfterEnd = repo.calls;
    await _scrollToEnd(tester);

    expect(repo.calls, callsAfterEnd);
  });

  testWidgets('a first page shorter than the page size never fetches again', (
    tester,
  ) async {
    final repo = _FakeHistoryRepo(_history(3));
    await pumpView(tester, repo);

    await _scrollToEnd(tester);

    expect(repo.calls, 1);
  });

  testWidgets('an exhausted list keeps its rows rather than emptying', (
    tester,
  ) async {
    final repo = _FakeHistoryRepo(_history(_pageSize + 5));
    await pumpView(tester, repo);

    await _scrollToEnd(tester);

    expect(find.text('Job ${_pageSize + 4}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('refresh', () {
    testWidgets('pull-to-refresh actually re-fetches', (tester) async {
      // `PagingController.refresh()` only RESETS state — it does not fetch.
      final repo = _FakeHistoryRepo(_history(_pageSize));
      await pumpView(tester, repo);
      expect(repo.calls, 1);

      await tester.fling(
        find.byType(CustomScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(repo.calls, greaterThanOrEqualTo(2));
      expect(find.text('Job 00'), findsOneWidget);
    });
  });

  group('failures', () {
    testWidgets('a failed first page offers Retry, which re-fetches', (
      tester,
    ) async {
      final repo = _FakeHistoryRepo(_history(_pageSize), failOnCall: 1);
      await pumpView(tester, repo);

      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(repo.calls, greaterThanOrEqualTo(2));
      expect(find.text('Job 00'), findsOneWidget);
    });

    testWidgets('a failed second page does not spin on retries', (
      tester,
    ) async {
      // `_maybeFetchNext` bails while `state.error != null`, so a failed page
      // must not be re-requested by every subsequent build.
      final repo = _FakeHistoryRepo(_history(_pageSize + 10), failOnCall: 2);
      await pumpView(tester, repo);

      await _scrollToEnd(tester);
      final callsAfterFailure = repo.calls;
      await tester.pumpAndSettle();

      expect(callsAfterFailure, lessThanOrEqualTo(3));
      expect(repo.calls, callsAfterFailure);
      // The failed tail offers a retry row rather than an empty list or a
      // permanent spinner.
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
