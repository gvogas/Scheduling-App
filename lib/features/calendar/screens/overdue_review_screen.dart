import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/calendar/application/overdue_review_controller.dart';
import 'package:scheduling/features/calendar/application/overdue_review_outcome.dart';
import 'package:scheduling/features/calendar/application/overdue_review_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/views/overdue_review_action_bar.dart';
import 'package:scheduling/features/calendar/widgets/views/overdue_review_list.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';
import 'package:scheduling/shared/widgets/feedback/centered_error_text.dart';

/// Opens one job from the review.
typedef OverdueJobOpener =
    Future<void> Function(BuildContext context, AppointmentRecord job);

/// Every open job whose end has passed, closed in bulk. Admin-only.
class OverdueReviewScreen extends ConsumerStatefulWidget {
  const OverdueReviewScreen({
    required this.isAdmin,
    required this.employeeId,
    super.key,
    this.openJob,
  });

  final bool isAdmin;
  final String employeeId;

  /// Test seam; production opens the details sheet.
  final OverdueJobOpener? openJob;

  @override
  ConsumerState<OverdueReviewScreen> createState() =>
      _OverdueReviewScreenState();
}

class _OverdueReviewScreenState extends ConsumerState<OverdueReviewScreen> {
  @override
  void initState() {
    super.initState();
    final logger = ref.read(loggerProvider);
    ref.listenManual(overdueOpenJobsProvider, (previous, next) {
      if (isFirstAsyncError(previous, next)) {
        logger.warn(
          'APPT-REVIEW overdue load failed',
          next.error,
          next.stackTrace,
        );
      }
    });
  }

  Future<void> _open(AppointmentRecord job) {
    final opener = widget.openJob;
    if (opener != null) return opener(context, job);
    return showEventDetails(
      context,
      job,
      showActions: widget.isAdmin,
      analyticsSource: AnalyticsSources.overdueReview,
    );
  }

  Future<void> _apply(
    OverdueReviewAction action,
    Set<String> visible,
    int count,
  ) async {
    final l10n = context.l10n;
    if (guardedOffline(context, ref, intro: l10n.error_introReviewOverdue)) {
      return;
    }
    final controller = ref.read(overdueReviewControllerProvider.notifier);
    final notices = ref.read(noticeServiceProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final isComplete = action == OverdueReviewAction.complete;
    final confirmed = await showConfirmDialog(
      context,
      title: isComplete
          ? l10n.calendar_overdueReviewConfirmCompleteTitle(count)
          : l10n.calendar_overdueReviewConfirmNotDoneTitle(count),
      message: isComplete
          ? l10n.calendar_overdueReviewConfirmCompleteBody(count)
          : l10n.calendar_overdueReviewConfirmNotDoneBody(count),
      confirmLabel: isComplete
          ? l10n.calendar_overdueReviewComplete
          : l10n.calendar_overdueReviewNotDone,
      cancelLabel: l10n.calendar_overdueReviewGoBack,
      destructive: !isComplete,
    );
    if (!confirmed) return;
    final outcome = await controller.apply(action, visibleIds: visible);
    switch (outcome) {
      case OverdueReviewBusy():
        break;
      case OverdueReviewApplied(:final count):
        analytics.logOverdueReviewApplied(
          action: action.analyticsValue,
          count: count,
        );
        notices.success(
          isComplete
              ? l10n.calendar_overdueReviewMarkedComplete(count)
              : l10n.calendar_overdueReviewMarkedNotDone(count),
        );
      case OverdueReviewFailed(:final error):
        notices.error(
          composeErrorNoticeFor(
            l10n,
            intro: l10n.error_introReviewOverdue,
            error: error,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final jobsValue = ref.watch(overdueOpenJobsProvider);
    final review = ref.watch(overdueReviewControllerProvider);
    final jobs = jobsValue.value ?? const <AppointmentRecord>[];
    final visible = {for (final job in jobs) ?job.id};
    final selectedCount = review.selected.where(visible.contains).length;
    final controller = ref.read(overdueReviewControllerProvider.notifier);

    return Scaffold(
      appBar: AppTopBar(
        title: l10n.calendar_overdueReviewTitle,
        compact: context.isLandscape,
        onBack: () => Navigator.maybePop(context),
        actions: const [AppHeaderPair()],
      ),
      endDrawer: AppNavDrawer(
        isAdmin: widget.isAdmin,
        employeeId: widget.employeeId,
      ),
      body: jobsValue.hasValue
          ? OverdueReviewList(
              jobs: jobs,
              selected: review.selected,
              onToggle: controller.toggle,
              onSetMonth: controller.setSelected,
              onOpen: _open,
            )
          : _loadingOrError(jobsValue),
      bottomNavigationBar: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: selectedCount == 0
            ? const SizedBox.shrink()
            : OverdueReviewActionBar(
                count: selectedCount,
                isBusy: review.isApplying,
                onComplete: () => _apply(
                  OverdueReviewAction.complete,
                  visible,
                  selectedCount,
                ),
                onNotDone: () =>
                    _apply(OverdueReviewAction.notDone, visible, selectedCount),
              ),
      ),
    );
  }

  Widget _loadingOrError(AsyncValue<List<AppointmentRecord>> value) {
    if (!value.hasError) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return CenteredErrorText(
      message: composeErrorNotice(
        context,
        intro: context.l10n.error_introReviewOverdue,
        error: value.error!,
      ),
      onRetry: () => ref.invalidate(overdueOpenJobsProvider),
    );
  }
}
