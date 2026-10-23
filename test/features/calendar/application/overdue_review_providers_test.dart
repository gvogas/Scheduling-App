import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/overdue_review_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

void main() {
  group('overdueReviewBoundary', () {
    test('floors to the quarter hour', () {
      expect(
        overdueReviewBoundary(DateTime(2026, 8, 15, 10, 14, 59)),
        DateTime(2026, 8, 15, 10),
      );
      expect(
        overdueReviewBoundary(DateTime(2026, 8, 15, 10, 44)),
        DateTime(2026, 8, 15, 10, 30),
      );
    });

    test('is never after now and at most one quarter behind it', () {
      // Only bites under a DST zone (TZ=America/Toronto); the UTC suite
      // passes it either way.
      final now = DateTime.utc(2026, 11, 1, 6, 37).toLocal();
      final boundary = overdueReviewBoundary(now);
      expect(boundary.isAfter(now), isFalse);
      expect(now.difference(boundary), lessThan(kOverdueReviewRefresh));
    });

    test('a time on the boundary is its own boundary', () {
      expect(
        overdueReviewBoundary(DateTime(2026, 8, 15, 10, 45)),
        DateTime(2026, 8, 15, 10, 45),
      );
    });
  });

  group('overdueOpenJobsProvider', () {
    late _MockAppointmentsRepo repo;

    setUpAll(() => registerFallbackValue(DateTime(2026)));

    setUp(() {
      repo = _MockAppointmentsRepo();
      when(
        () => repo.watchOverdueOpen(any()),
      ).thenAnswer((_) => Stream.value(const <AppointmentRecord>[]));
    });

    ProviderContainer containerAt(DateTime Function() clock) {
      final container = ProviderContainer(
        overrides: [
          authUidProvider.overrideWith((ref) => Stream.value('uid-1')),
          appointmentsRepositoryProvider.overrideWithValue(repo),
          overdueReviewClockProvider.overrideWithValue(clock),
        ],
      );
      addTearDown(container.dispose);
      container.listen(overdueOpenJobsProvider, (_, _) {});
      return container;
    }

    test('two opens inside one quarter hour issue the SAME query', () async {
      // The SDK resumes a listener's cached target only for an identical
      // query, so a drawer reopened at :07 must ask for the :00 boundary
      // its predecessor at :02 asked for, not a fresh `now`.
      final first = containerAt(() => DateTime(2026, 8, 15, 10, 2));
      await first.read(overdueOpenJobsProvider.future);
      first.dispose();
      final second = containerAt(() => DateTime(2026, 8, 15, 10, 7));
      await second.read(overdueOpenJobsProvider.future);

      final boundaries = verify(
        () => repo.watchOverdueOpen(captureAny()),
      ).captured;
      expect(boundaries, [
        DateTime(2026, 8, 15, 10),
        DateTime(2026, 8, 15, 10),
      ]);
    });

    test('the boundary is re-issued AT the next quarter, not 15 min later', () {
      fakeAsync((async) {
        var now = DateTime(2026, 8, 15, 10, 14);
        containerAt(() => now);
        async.elapse(Duration.zero);
        verify(
          () => repo.watchOverdueOpen(DateTime(2026, 8, 15, 10)),
        ).called(1);

        now = DateTime(2026, 8, 15, 10, 15);
        async.elapse(const Duration(minutes: 1));
        verify(
          () => repo.watchOverdueOpen(DateTime(2026, 8, 15, 10, 15)),
        ).called(1);
      });
    });
  });
}
