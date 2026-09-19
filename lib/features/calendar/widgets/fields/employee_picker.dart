import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// Whether the roster feeding [EmployeePicker.allEmployees] has settled.
enum AssigneeRosterStatus { loading, ready, failed }

/// [AssigneeRosterStatus] for the roster provider both save flows watch.
AssigneeRosterStatus rosterStatusOf(AsyncValue<Object?> roster) {
  if (roster.hasValue) return AssigneeRosterStatus.ready;
  if (roster.hasError) return AssigneeRosterStatus.failed;
  return AssigneeRosterStatus.loading;
}

class EmployeePicker extends StatelessWidget {
  const EmployeePicker({
    required this.allEmployees,
    required this.selectedEmployees,
    super.key,
    this.selectable = true,
    this.hasError = false,
    this.errorText,
    this.onToggle,
    this.availability = AssigneeAvailability.none,
    this.rosterStatus = AssigneeRosterStatus.ready,
    this.onRetryRoster,
  });

  final List<EmployeeRecord> allEmployees;
  final List<EmployeeRecord> selectedEmployees;
  final bool selectable;
  final bool hasError;

  /// Error text that also highlights chip borders.
  final String? errorText;
  final void Function(EmployeeRecord)? onToggle;

  /// Crew conflicts for the chosen date/span.
  final AssigneeAvailability availability;

  /// Whether the roster behind [allEmployees] has actually arrived.
  final AssigneeRosterStatus rosterStatus;

  /// Re-runs the roster read. Only reachable from the failed state.
  final VoidCallback? onRetryRoster;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasError = this.hasError || errorText != null;
    // Read-only mode shows selected staff only.
    final displayEmployees = selectable
        ? allEmployees
        : allEmployees
              .where((e) => selectedEmployees.any((s) => s.id == e.id))
              .toList();

    // Hoist shared inputs used by every chip.
    final selectedIds = {for (final e in selectedEmployees) e.id};
    // Tally names once for short-name disambiguation.
    final names = firstNameTally([for (final e in displayEmployees) e.name]);
    final offers = [
      for (final employee in displayEmployees)
        (
          employee: employee,
          state: assigneeOfferState(
            employeeId: employee.id,
            clashes: availability.clashes,
            selectedIds: selectedIds,
            alreadyAssignedIds: availability.alreadyAssignedIds,
          ),
          shortName: shortAssigneeName(employee.name, among: names),
        ),
    ];

    final mutedLabel = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final content = displayEmployees.isEmpty
        ? switch (rosterStatus) {
            // Only ever reached while the list is empty: once a roster has
            // arrived the chips are the answer, and a background refresh must
            // not replace them with a spinner.
            AssigneeRosterStatus.loading => Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sp8),
                Text(context.l10n.common_loadingEmployees, style: mutedLabel),
              ],
            ),
            AssigneeRosterStatus.failed => Row(
              children: [
                Flexible(
                  child: Text(
                    context.l10n.error_errorLoadingEmployees,
                    style: mutedLabel,
                  ),
                ),
                if (onRetryRoster != null)
                  TextButton(
                    onPressed: onRetryRoster,
                    child: Text(context.l10n.common_retry),
                  ),
              ],
            ),
            AssigneeRosterStatus.ready => Text(
              selectable
                  ? context.l10n.common_noEmployeesFound
                  : context.l10n.calendar_noEmployeesAssigned,
              style: mutedLabel,
            ),
          }
        : Wrap(
            spacing: AppSpacing.sp8,
            runSpacing: AppSpacing.sp8,
            children: [
              for (final offer in offers)
                _EmployeeChip(
                  employee: offer.employee,
                  shortName: offer.shortName,
                  isSelected: selectedIds.contains(offer.employee.id),
                  isUnavailable: offer.state == AssigneeOfferState.unavailable,
                  hasError: hasError,
                  // Only time off is untappable; a booked chip is picked and
                  // the Save-time double-booking prompt asks.
                  onTap:
                      selectable &&
                          offer.state != AssigneeOfferState.unavailable
                      ? () => onToggle?.call(offer.employee)
                      : null,
                ),
            ],
          );

    if (errorText == null) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.sp4,
            left: AppSpacing.sp4,
          ),
          child: Text(
            errorText!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
      ],
    );
  }
}

/// One staff chip. Its own widget so a row rebuilds on its own rather than as
/// part of a 60-line closure body re-evaluated per employee.
class _EmployeeChip extends StatelessWidget {
  const _EmployeeChip({
    required this.employee,
    required this.shortName,
    required this.isSelected,
    required this.isUnavailable,
    required this.hasError,
    required this.onTap,
  });

  final EmployeeRecord employee;
  final String shortName;
  final bool isSelected;

  /// Dimmed and untappable: a dashed empty slot rather than a button.
  final bool isUnavailable;
  final bool hasError;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      // Non-null onTap IS selectable — the two cannot disagree.
      button: onTap != null,
      selected: isSelected,
      enabled: !isUnavailable,
      label: employee.name,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          // No `alignment`: one would expand this chip to the Wrap's width.
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sp8,
            AppSpacing.sp4,
            AppSpacing.sp12,
            AppSpacing.sp4,
          ),
          foregroundDecoration: isUnavailable
              ? _DashedPill(color: scheme.outlineVariant)
              : null,
          decoration: BoxDecoration(
            color: isUnavailable
                ? Colors.transparent
                : isSelected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            border: isUnavailable
                ? null
                : Border.all(
                    // An unselected chip carries the error outline, since "pick
                    // someone" is what the error is asking for.
                    color: hasError && !isSelected
                        ? scheme.error
                        : isSelected
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: 1.5,
                  ),
            borderRadius: BorderRadius.circular(AppRadius.rFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: isUnavailable ? 0.42 : 1,
                child: AppAvatar(
                  name: employee.name,
                  color: employee.color,
                  size: AvatarSize.xs,
                ),
              ),
              const SizedBox(width: AppSpacing.sp8),
              Flexible(
                child: Text(
                  shortName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isUnavailable
                        ? theme.palette.textTertiary
                        : isSelected
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The unavailable chip's dashed outline.
class _DashedPill extends Decoration {
  const _DashedPill({required this.color});

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedPillPainter(color);
}

class _DashedPillPainter extends BoxPainter {
  _DashedPillPainter(this.color);

  static const double _dash = 4;
  static const double _gap = 3;

  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = offset & size;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(0.75),
          Radius.circular(size.height / 2),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    for (final metric in outline.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + _dash;
        canvas.drawPath(
          metric.extractPath(
            distance,
            next > metric.length ? metric.length : next,
          ),
          paint,
        );
        distance = next + _gap;
      }
    }
  }
}
