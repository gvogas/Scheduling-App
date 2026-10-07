import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/overdue_review_controller.dart';
import 'package:scheduling/features/calendar/application/overdue_review_outcome.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

void main() {
  late _MockRepo repo;

  setUp(() {
    repo = _MockRepo();
    when(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) async {});
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [appointmentsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    c.listen(overdueReviewControllerProvider, (_, _) {});
    return c;
  }

  OverdueReviewController controller(ProviderContainer c) =>
      c.read(overdueReviewControllerProvider.notifier);

  test('toggle ticks and unticks one job', () {
    final c = container();
    controller(c).toggle('a');
    expect(c.read(overdueReviewControllerProvider).selected, {'a'});
    controller(c).toggle('a');
    expect(c.read(overdueReviewControllerProvider).selected, isEmpty);
  });

  test('setSelected ticks a month and clears only that month', () {
    final c = container();
    controller(c)
      ..toggle('other')
      ..setSelected(['a', 'b'], selected: true);
    expect(c.read(overdueReviewControllerProvider).selected, {
      'other',
      'a',
      'b',
    });
    controller(c).setSelected(['a', 'b'], selected: false);
    expect(c.read(overdueReviewControllerProvider).selected, {'other'});
  });

  test(
    'Complete writes done in 450-id chunks and clears the selection',
    () async {
      final c = container();
      final ids = [for (var i = 0; i < 1000; i++) 'id$i'];
      controller(c).setSelected(ids, selected: true);

      final outcome = await controller(
        c,
      ).apply(OverdueReviewAction.complete, visibleIds: ids.toSet());

      expect(outcome, isA<OverdueReviewApplied>());
      expect((outcome as OverdueReviewApplied).count, 1000);
      final captured = verify(
        () => repo.updateAppointmentStatuses(
          ids: captureAny(named: 'ids'),
          status: 'done',
        ),
      ).captured;
      expect(captured.map((ids) => (ids as List).length), [450, 450, 100]);
      final state = c.read(overdueReviewControllerProvider);
      expect(state.selected, isEmpty);
      expect(state.isApplying, isFalse);
    },
  );

  test('Not done writes cancelled', () async {
    final c = container();
    controller(c).toggle('a');

    await controller(
      c,
    ).apply(OverdueReviewAction.notDone, visibleIds: const {'a'});

    verify(
      () => repo.updateAppointmentStatuses(ids: ['a'], status: 'cancelled'),
    ).called(1);
  });

  test('a ticked job no longer listed is not written', () async {
    final c = container();
    controller(c)
      ..toggle('gone')
      ..toggle('live');

    final outcome = await controller(
      c,
    ).apply(OverdueReviewAction.complete, visibleIds: const {'live'});

    expect((outcome as OverdueReviewApplied).count, 1);
    verify(
      () => repo.updateAppointmentStatuses(ids: ['live'], status: 'done'),
    ).called(1);
  });

  test('the in-flight flag is set before the first await, so a second tap '
      'is Busy', () async {
    final gate = Completer<void>();
    when(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) => gate.future);
    final c = container();
    controller(c).toggle('a');

    final first = controller(
      c,
    ).apply(OverdueReviewAction.complete, visibleIds: const {'a'});
    expect(c.read(overdueReviewControllerProvider).isApplying, isTrue);

    final second = await controller(
      c,
    ).apply(OverdueReviewAction.complete, visibleIds: const {'a'});
    expect(second, isA<OverdueReviewBusy>());

    gate.complete();
    expect(await first, isA<OverdueReviewApplied>());
    verify(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).called(1);
  });

  test('nothing ticked is a no-op, not a write', () async {
    final c = container();
    final outcome = await controller(
      c,
    ).apply(OverdueReviewAction.complete, visibleIds: const {'a'});
    expect(outcome, isA<OverdueReviewBusy>());
    verifyNever(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    );
  });

  test('a failed write returns Failed, releases the flag and keeps the '
      'selection', () async {
    when(
      () => repo.updateAppointmentStatuses(
        ids: any(named: 'ids'),
        status: any(named: 'status'),
      ),
    ).thenThrow(StateError('boom'));
    final c = container();
    controller(c).toggle('a');

    final outcome = await controller(
      c,
    ).apply(OverdueReviewAction.notDone, visibleIds: const {'a'});

    expect(outcome, isA<OverdueReviewFailed>());
    final state = c.read(overdueReviewControllerProvider);
    expect(state.isApplying, isFalse);
    expect(state.selected, {'a'});
  });
}
