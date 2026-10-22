import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';

class AppointmentStatusPicker extends StatelessWidget {
  const AppointmentStatusPicker({
    required this.currentStatus,
    required this.onChanged,
    super.key,
  });

  final String currentStatus;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final selected = AppointmentStatus.fromRaw(currentStatus);

    return Wrap(
      spacing: AppSpacing.sp8,
      runSpacing: AppSpacing.sp8,
      children: AppointmentStatus.appointmentValues.map((s) {
        final isSelected = selected == s;
        final label = statusLabel(l, s);
        void select() => onChanged(s.raw);
        return Semantics(
          button: true,
          onTap: select,
          selected: isSelected,
          label: label,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: select,
            child: ConstrainedBox(
              // Keep the tap target without overflowing at large text scales.
              constraints: BoxConstraints(
                minHeight: 44,
                maxWidth: MediaQuery.sizeOf(context).width - AppSpacing.sp32,
              ),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sp16,
                  vertical: AppSpacing.sp8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? scheme.primaryContainer
                      : Colors.transparent,
                  border: Border.all(
                    color: isSelected ? scheme.primary : scheme.outlineVariant,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.rFull),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isSelected
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
