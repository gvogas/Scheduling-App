import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/overdue_review.dart';
import 'package:scheduling/features/calendar/widgets/cards/overdue_review_job_row.dart';
import 'package:scheduling/features/calendar/widgets/sections/overdue_month_splitter.dart';
import 'package:scheduling/features/calendar/widgets/sections/overdue_review_summary.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';

/// The summary, then every overdue job in one oldest-first scroll.
class OverdueReviewList extends ConsumerWidget {
  const OverdueReviewList({
    required this.jobs,
    required this.selected,
    required this.onToggle,
    required this.onSetMonth,
    required this.onOpen,
    super.key,
  });

  /// Oldest first.
  final List<AppointmentRecord> jobs;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final void Function(Iterable<String> ids, {required bool selected})
  onSetMonth;
  final ValueChanged<AppointmentRecord> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colorMap = ref.watch(employeeColorMapProvider);
    final nameMap = ref.watch(employeeNameMapProvider);
    final listed = {for (final job in jobs) ?job.id};

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp8,
        AppSpacing.sp16,
        AppSpacing.sp24,
      ),
      children: [
        OverdueReviewSummary(
          count: jobs.length,
          oldest: jobs.isEmpty ? null : jobs.first.startTime,
          selectedCount: selected.where(listed.contains).length,
        ),
        const SizedBox(height: AppSpacing.sp16),
        if (jobs.isEmpty)
          AppEmptyState(
            icon: Icons.task_alt_rounded,
            title: l10n.calendar_overdueReviewEmptyTitle,
            body: l10n.calendar_overdueReviewEmptyBody,
          ),
        for (final group in groupOverdueByMonth(jobs)) ...[
          OverdueMonthSplitter(
            month: group.month,
            count: group.jobs.length,
            allSelected: group.jobs.every((job) => selected.contains(job.id)),
            onToggleAll: (selectAll) => onSetMonth([
              for (final job in group.jobs) ?job.id,
            ], selected: selectAll),
          ),
          for (final job in group.jobs)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sp8),
              child: OverdueReviewJobRow(
                job: job,
                crew: crewFor(job, colorMap: colorMap, nameMap: nameMap),
                selected: selected.contains(job.id),
                onToggle: () => onToggle(job.id ?? ''),
                onOpen: () => onOpen(job),
              ),
            ),
        ],
      ],
    );
  }
}
