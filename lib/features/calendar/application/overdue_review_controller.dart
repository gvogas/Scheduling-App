import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/overdue_review_outcome.dart';
import 'package:scheduling/features/calendar/application/overdue_review_state.dart';
import 'package:scheduling/features/calendar/domain/overdue_review.dart';

/// The two ways the review closes jobs.
enum OverdueReviewAction {
  complete('done', AnalyticsOverdueReviewActions.complete),
  notDone('cancelled', AnalyticsOverdueReviewActions.notDone);

  const OverdueReviewAction(this.storedStatus, this.analyticsValue);

  final String storedStatus;
  final String analyticsValue;
}

/// Holds the ticked jobs and writes one status across them.
class OverdueReviewController extends Notifier<OverdueReviewState> {
  @override
  OverdueReviewState build() => const OverdueReviewState();

  void toggle(String id) {
    final next = {...state.selected};
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(selected: next);
  }

  void setSelected(Iterable<String> ids, {required bool selected}) {
    final next = {...state.selected};
    if (selected) {
      next.addAll(ids);
    } else {
      next.removeAll(ids);
    }
    state = state.copyWith(selected: next);
  }

  /// Writes [action] to the ticked jobs still in [visibleIds].
  Future<OverdueReviewOutcome> apply(
    OverdueReviewAction action, {
    required Set<String> visibleIds,
  }) async {
    if (state.isApplying) return const OverdueReviewBusy();
    final ids = state.selected.where(visibleIds.contains).toList();
    if (ids.isEmpty) return const OverdueReviewBusy();
    final repo = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(isApplying: true);
    try {
      for (final chunk in chunkIds(ids)) {
        await repo.updateAppointmentStatuses(
          ids: chunk,
          status: action.storedStatus,
        );
      }
      if (ref.mounted) state = const OverdueReviewState();
      return OverdueReviewApplied(ids.length);
    } catch (e, st) {
      logger.warn('APPT-REVIEW bulk status write failed', e, st);
      if (ref.mounted) state = state.copyWith(isApplying: false);
      return OverdueReviewFailed(e);
    }
  }
}

final overdueReviewControllerProvider =
    NotifierProvider.autoDispose<OverdueReviewController, OverdueReviewState>(
      OverdueReviewController.new,
    );
