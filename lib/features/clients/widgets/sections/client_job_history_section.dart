import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/clients/application/appointment_history_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// Job history block on the admin-only detail view.
// "Book again" is deferred for now — it would need invasive changes to the create flow.
class ClientJobHistorySection extends ConsumerWidget {
  const ClientJobHistorySection({required this.clientId, super.key});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(clientJobHistoryProvider(clientId));

    // The data→error transition, NOT `.when`'s error branch, which fires on
    // every rebuild and would spam Crashlytics.
    ref.listen<AsyncValue<List<AppointmentRecord>>>(
      clientJobHistoryProvider(clientId),
      (previous, next) {
        if (!isFirstAsyncError(previous, next)) return;
        ref
            .read(loggerProvider)
            .warn(
              'HIST-LOAD client job history failed',
              next.error,
              next.stackTrace,
            );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(context.l10n.clients_jobHistory),
        const SizedBox(height: AppSpacing.sp8),
        history.when(
          data: (jobs) => jobs.isEmpty
              ? _EmptyLine(text: context.l10n.clients_noPastJobs)
              : _JobList(
                  jobs: jobs,
                  colorMap: ref.watch(employeeColorMapProvider),
                ),
          loading: () => const Column(
            children: [
              SkeletonAppointmentRow(),
              SizedBox(height: AppSpacing.sp8),
              SkeletonAppointmentRow(),
            ],
          ),
          // Composes without logging on purpose: a builder runs on every
          // rebuild, so the log belongs on the transition in the `ref.listen`
          // above.
          error: (e, _) => _EmptyLine(
            text: composeErrorNotice(
              context,
              intro: context.l10n.error_introLoadHistory,
              error: e,
            ),
            onRetry: () => ref.invalidate(clientJobHistoryProvider(clientId)),
          ),
        ),
      ],
    );
  }
}

class _JobList extends StatelessWidget {
  const _JobList({required this.jobs, required this.colorMap});

  final List<AppointmentRecord> jobs;
  final Map<String, Color> colorMap;

  /// This section is a plain `Column` inside the detail body's own scroll view,
  /// so every row it emits is built whether or not it is on screen — and the
  /// repository scans a client's history up to its 1000-doc ceiling.
  static const int _maxRendered = 50;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final job in jobs.take(_maxRendered)) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sp4),
            child: Text(
              DateUtilsHelper.formatDate(job.startTime),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          AppointmentCard(
            appointment: job,
            // No live name map on this surface — crewFor falls back to the
            // record's denormalized employeeNames, which is what it showed
            // before.
            crew: crewFor(job, colorMap: colorMap),
            dimWhenCancelled: true,
            onTap: () => showEventDetails(
              context,
              job,
              analyticsSource: AnalyticsSources.clientDetail,
              showActions: false,
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
        ],
      ],
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text, this.onRetry});

  final String text;

  /// Present on the ERROR branch only.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry;
    final line = Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (retry == null) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line,
        TextButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.common_retry),
        ),
      ],
    );
  }
}
