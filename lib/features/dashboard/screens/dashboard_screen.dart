import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/layout/primary_scroll_scope.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/dashboard/application/dashboard_providers.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/dashboard/widgets/sections/attention_flags_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/business_trends_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/daily_load_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/dashboard_hero.dart';
import 'package:scheduling/features/dashboard/widgets/sections/employee_workload_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/new_clients_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/period_summary_section.dart';
import 'package:scheduling/features/dashboard/widgets/sections/upcoming_today_section.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/feedback/centered_error_text.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';

/// Business overview for admins only, reached from the settings drawer.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    required this.isAdmin,
    required this.employeeId,
    super.key,
    this.userName,
    this.email,
  });

  final bool isAdmin;
  final String employeeId;
  final String? userName;
  final String? email;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final _tour = TourSteps(
    const DestinationTour(PushedDestination.dashboard),
    isAdmin: widget.isAdmin,
  );

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(dashboardStatsProvider);
    ref.listen<AsyncValue<DashboardStats>>(dashboardStatsProvider, (
      previous,
      next,
    ) {
      if (!isFirstAsyncError(previous, next)) return;
      ref
          .read(loggerProvider)
          .warn('DASH-LOAD dashboard failed', next.error, next.stackTrace);
      ref
          .read(noticeServiceProvider)
          .error(
            composeErrorNotice(
              context,
              intro: context.l10n.error_introLoadDashboard,
              error: next.error!,
            ),
          );
    });

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: widget.isAdmin,
      stepKeys: _tour.keys,
      // Gated on the data: an ungated start against the loading skeleton finds
      // zero targets and permanently marks the screen seen.
      ready: stats is AsyncData<DashboardStats>,
      autoScroll: true,
      child: _buildScaffold(context, stats),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    AsyncValue<DashboardStats> stats,
  ) {
    return Scaffold(
      appBar: AppTopBar(
        title: context.l10n.dashboard_title,
        compact: context.isLandscape,
        // A pushed route now, so back means back.
        onBack: () => Navigator.maybePop(context),
        actions: const [AppHeaderPair()],
      ),
      endDrawer: AppNavDrawer(
        isAdmin: widget.isAdmin,
        employeeId: widget.employeeId,
        userName: widget.userName,
        email: widget.email,
      ),
      body: PrimaryScrollScope(
        child: switch (stats) {
          AsyncData(:final value) => _StatsList(
            stats: value,
            isAdmin: widget.isAdmin,
            tour: _tour,
          ),
          AsyncError() => CenteredErrorText(
            message: context.l10n.error_introLoadDashboard,
            onRetry: () => ref.invalidate(dashboardStatsProvider),
          ),
          _ => const _LoadingList(),
        },
      ),
    );
  }
}

class _StatsList extends ConsumerWidget {
  const _StatsList({
    required this.stats,
    required this.isAdmin,
    required this.tour,
  });

  final DashboardStats stats;

  /// Gates the admin-only actions on the appointment sheets these cards open.
  final bool isAdmin;

  /// Passed down rather than read from an inherited widget — the host lives
  /// above this subtree and owns the keys.
  final TourSteps tour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorMap = ref.watch(employeeColorMapProvider);
    final nameMap = ref.watch(employeeNameMapProvider);
    final now = ref.watch(dashboardClockProvider)();
    // Both the hero card and the sections below carry their own sp16 inset.
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        tour.stepIf(
          TourStepId.dashboardHero,
          DashboardHero(ops: stats.todayOps, now: now),
        ),
        Padding(
          // No top inset: the hero's bottom margin already supplies it.
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sp16,
            0,
            AppSpacing.sp16,
            AppSpacing.sp16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Its own provider, so changing the period recomputes four
              // counters instead of every section on the screen.
              ?switch (ref.watch(dashboardPeriodSummaryProvider)) {
                AsyncData(:final value) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sp24),
                  child: PeriodSummarySection(summary: value),
                ),
                AsyncError() => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sp24),
                  child: CenteredErrorText(
                    message: context.l10n.error_introLoadDashboard,
                    onRetry: () =>
                        ref.invalidate(dashboardPeriodSummaryProvider),
                  ),
                ),
                _ => null,
              },
              tour.stepIf(
                TourStepId.dashboardUpcoming,
                UpcomingTodaySection(
                  ops: stats.todayOps,
                  colorMap: colorMap,
                  nameMap: nameMap,
                  isAdmin: isAdmin,
                ),
              ),
              const SizedBox(height: AppSpacing.sp24),
              tour.stepIf(
                TourStepId.dashboardWorkload,
                EmployeeWorkloadSection(workload: stats.workload),
              ),
              const SizedBox(height: AppSpacing.sp24),
              DailyLoadSection(days: stats.dailyLoad),
              const SizedBox(height: AppSpacing.sp24),
              BusinessTrendsSection(
                buckets: stats.weekBuckets,
                busiestWeekday: stats.busiestWeekday,
              ),
              const SizedBox(height: AppSpacing.sp24),
              ?ref
                  .watch(newClientsProvider)
                  .whenOrNull(
                    data: (clients) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sp24),
                      child: NewClientsSection(
                        clients: clients,
                        weeklyCounts: [
                          for (final b in stats.weekBuckets) b.newClients,
                        ],
                      ),
                    ),
                  ),
              tour.stepIf(
                TourStepId.dashboardAttention,
                AttentionFlagsSection(
                  flags: stats.flags,
                  colorMap: colorMap,
                  nameMap: nameMap,
                  isAdmin: isAdmin,
                  // Both default to empty, so a source still settling shows the
                  // appointment flags rather than blocking the section.
                  neverSetUp:
                      ref.watch(neverSetUpAccountsProvider).value ?? const [],
                  availabilityConflicts:
                      ref.watch(availabilityConflictsProvider).value ??
                      const [],
                ),
              ),
              const SizedBox(height: AppSpacing.sp16),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.sp16),
      children: [for (var i = 0; i < 8; i++) const SkeletonAppointmentRow()],
    );
  }
}
