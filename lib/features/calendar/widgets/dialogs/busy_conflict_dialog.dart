import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/app_dialog_frame.dart';
import 'package:scheduling/shared/widgets/dialogs/dialog_action_pair.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// The busy-employee fields an outcome carries, whatever its sealed family.
typedef BusyConflict = ({
  List<EmployeeRecord> busyEmployees,
  DateTime start,
  DateTime end,
});

/// Runs [attempt]; on a busy-employee outcome asks, then re-runs forcing.
///
/// Returns null when the caller must simply return — unmounted, or declined.
/// The mounted check after BOTH awaits is the point: it was re-derived at
/// three call sites and they had already drifted on which one they used.
Future<T?> retryPastBusyConflict<T>(
  BuildContext context, {
  required Future<T> Function({bool forceBusy}) attempt,
  required BusyConflict? Function(T outcome) busyOf,
}) async {
  final first = await attempt(forceBusy: false);
  if (!context.mounted) return null;
  final busy = busyOf(first);
  if (busy == null) return first;
  final confirmed = await showBusyConflictDialog(
    context,
    busyEmployees: busy.busyEmployees,
    start: busy.start,
    end: busy.end,
  );
  if (!confirmed || !context.mounted) return null;
  final second = await attempt(forceBusy: true);
  return context.mounted ? second : null;
}

Future<bool> showBusyConflictDialog(
  BuildContext context, {
  required List<EmployeeRecord> busyEmployees,
  required DateTime start,
  required DateTime end,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => _BusyConflictDialog(
      busyEmployees: busyEmployees,
      start: start,
      end: end,
    ),
  );
  return result ?? false;
}

/// The dialog body as a widget rather than a tree inside the `showDialog`
/// closure — the same move `_BusyEmployeeRow` below already makes, and what
/// keeps the launcher above readable as the one thing it does.
class _BusyConflictDialog extends StatelessWidget {
  const _BusyConflictDialog({
    required this.busyEmployees,
    required this.start,
    required this.end,
  });

  final List<EmployeeRecord> busyEmployees;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColors = theme.statusColors;
    return AppDialogFrame(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: statusColors.warningContainer,
            borderRadius: BorderRadius.circular(AppRadius.r12),
          ),
          child: Icon(
            Icons.warning_amber_rounded,
            color: statusColors.onWarningContainer,
            size: 22,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        Text(
          context.l10n.calendar_scheduleConflict,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sp4),
        Text(
          // The clash is a DAILY-window overlap, so the run being booked
          // must name both its ends — otherwise a Mon–Fri job reports a
          // Thursday conflict under a headline reading "MON 3 AUG".
          DateUtilsHelper.formatWhenLine(
            start,
            end,
            lastDay: lastWorkDayOfWindow(start, end),
          ),
          style: theme.monoType.data,
        ),
        const SizedBox(height: AppSpacing.sp16),
        Text(
          context.l10n.calendar_alreadyBookedThisSlot,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: AppSpacing.sp12),
        ...busyEmployees.map((e) => _BusyEmployeeRow(employee: e)),
        const Divider(height: AppSpacing.sp24),
        _warningNote(context),
        const SizedBox(height: AppSpacing.sp24),
        _actions(context),
      ],
    );
  }

  Widget _warningNote(BuildContext context) => WarningNote(
    message: context.l10n.calendar_doubleBookingWarning,
    filled: false,
  );

  Widget _actions(BuildContext context) => DialogActionPair(
    secondaryLabel: context.l10n.common_cancel,
    onSecondary: () => Navigator.pop(context, false),
    primaryLabel: context.l10n.calendar_scheduleAnyway,
    onPrimary: () => Navigator.pop(context, true),
  );
}

class _BusyEmployeeRow extends StatelessWidget {
  const _BusyEmployeeRow({required this.employee});

  final EmployeeRecord employee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sp8),
      child: Row(
        children: [
          AppAvatar(
            name: employee.name,
            color: employee.color,
            size: AvatarSize.sm,
          ),
          const SizedBox(width: AppSpacing.sp12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employee.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (employee.email.isNotEmpty)
                  Text(
                    employee.email,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
