import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/application/calendar_crew_filter_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The admin calendar's "show one person's jobs" control.
class CrewFilterButton extends ConsumerWidget {
  const CrewFilterButton({super.key});

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    List<EmployeeRecord> roster,
  ) async {
    final l10n = context.l10n;
    final filter = ref.read(calendarCrewFilterProvider.notifier);
    // Chosen by INDEX: the "All crew" row selects null, which is also what a
    // dismissal returns.
    final chosen = await showAdaptiveActionSheet<int>(
      context,
      title: l10n.calendar_showJobsFor,
      actions: [
        AdaptiveSheetAction(value: 0, label: l10n.calendar_allCrew),
        for (var i = 0; i < roster.length; i++)
          AdaptiveSheetAction(value: i + 1, label: roster[i].displayName),
      ],
    );
    if (chosen == null) return;
    filter.selection = chosen == 0 ? null : roster[chosen - 1].id;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = ref.watch(calendarCrewFilterProvider) != null;
    // WATCHED here, never read inside the tap handler: a `ref.read` at tap time
    // built the roster cold, got `AsyncLoading` back and disposed it again —
    // the sheet offered "All crew" and nobody else, every single time.
    final roster = [
      for (final e
          in ref.watch(allUsersStreamProvider).asData?.value ??
              const <EmployeeRecord>[])
        if (e.isActive && e.isAssignable) e,
    ];
    final label = context.l10n.calendar_crewFilter;
    return Semantics(
      button: true,
      label: label,
      child: GhostControl.icon(
        onTap: () => _pick(context, ref, roster),
        icon: Icons.person_search_rounded,
        tooltip: label,
        // Active keeps a filled tile: "filtering is on" must stay
        // unmistakable against the ghost controls beside it.
        tone: isActive ? GhostTone.active : GhostTone.ghost,
      ),
    );
  }
}

/// "Showing Marc · Clear" — drawn above the agenda header while the calendar is
/// filtered, so the narrowed schedule is never mistaken for a quiet day.
class CrewFilterBanner extends ConsumerWidget {
  const CrewFilterBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(calendarCrewFilterProvider);
    if (id == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final name = ref.watch(employeeNameMapProvider)[id] ?? id;
    final color = ref.watch(employeeColorMapProvider)[id];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, AppSpacing.sp8, 18, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sp12,
          vertical: AppSpacing.sp4,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppRadius.r12),
        ),
        child: Row(
          children: [
            AppAvatar(name: name, color: color, size: AvatarSize.xs),
            const SizedBox(width: AppSpacing.sp8),
            Expanded(
              child: Text(
                context.l10n.calendar_showingCrewMember(name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: ref.read(calendarCrewFilterProvider.notifier).clear,
              child: Text(context.l10n.calendar_clearFilter),
            ),
          ],
        ),
      ),
    );
  }
}
