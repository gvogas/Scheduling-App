import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.label,
    this.iconBg,
    this.icon,
    this.iconColor,
    this.labelColor,
    this.trailing,
    this.onTap,
    super.key,
  });

  final Color? iconBg;
  final IconData? icon;
  final Color? iconColor;
  final String label;
  final Color? labelColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrowOrLarge = context.isCompact;

    final Widget? leading = icon != null && iconBg != null && iconColor != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(AppRadius.r8),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: AppSpacing.sp12),
            ],
          )
        : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.r8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp12),
        child: narrowOrLarge
            ? _buildStacked(theme, leading)
            : _buildInline(theme, leading),
      ),
    );
  }

  Widget _buildStacked(ThemeData theme, Widget? leading) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?leading,
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ),
          ],
        ),
        if (trailing != null) ...[
          const SizedBox(height: AppSpacing.sp8),
          Align(alignment: Alignment.centerLeft, child: trailing),
        ],
      ],
    );
  }

  Widget _buildInline(ThemeData theme, Widget? leading) {
    return Row(
      children: [
        ?leading,
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
              color: labelColor,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A [SettingsTile] whose control is a switch and whose whole row toggles it.
///
/// The switch is shrink-wrapped: a bare `Switch.adaptive` row is about 31pt,
/// under both tap minimums, so the ROW is the target. Spelling that per site
/// is what left two halves of one Settings screen at different row heights.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.switchKey,
    this.isBusy = false,
    this.onTap,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool value;
  final void Function({required bool value}) onChanged;
  final Key? switchKey;
  final bool isBusy;

  /// Replaces the default whole-row toggle — the location row opens a screen.
  final VoidCallback? onTap;

  /// Rendered after the switch, for a row that also navigates.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final control = Switch.adaptive(
      key: switchKey,
      value: value,
      onChanged: isBusy ? null : (next) => onChanged(value: next),
      activeTrackColor: scheme.primary,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return SettingsTile(
      iconBg: scheme.primaryContainer,
      icon: icon,
      iconColor: scheme.primary,
      label: label,
      onTap: onTap ?? (isBusy ? null : () => onChanged(value: !value)),
      trailing: trailing == null
          ? control
          : Row(mainAxisSize: MainAxisSize.min, children: [control, trailing!]),
    );
  }
}

class SettingsTrailingPill extends StatelessWidget {
  const SettingsTrailingPill({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp8,
        vertical: AppSpacing.sp4,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.rFull),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
