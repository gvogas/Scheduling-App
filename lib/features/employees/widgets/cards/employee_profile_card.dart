import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/user_status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// Avatar, name, job title, status chip and the Edit pill — one card, matching
/// the client detail's profile card. The avatar IS the colour swatch, which is
/// why the info panel below carries no COLOUR row.
class EmployeeProfileCard extends StatelessWidget {
  const EmployeeProfileCard({
    required this.employee,
    required this.onEdit,
    super.key,
  });

  final EmployeeRecord employee;

  /// Null hides the pill — the detail is readable by any admin, but only an
  /// admin edits, and the host resolves that.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final title = jobTitleLabel(l10n, employee.jobTitle);
    final name = employee.displayName;

    final identity = _buildIdentity(theme, title, name);

    final pill = onEdit == null ? null : _EditPill(onEdit: onEdit!);

    return DecoratedBox(
      decoration: appCardDecoration(
        theme,
        radius: AppRadius.r16,
        color: theme.colorScheme.surfaceContainerLowest,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sp16),
        // The row holds an avatar, two-to-three text lines, chips and a pill,
        // so it folds rather than overflow once text is scaled up.
        child: context.isCompact
            ? _buildStacked(name, identity, pill)
            : _buildInline(name, identity, pill),
      ),
    );
  }

  Widget _buildIdentity(ThemeData theme, String title, String name) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (title.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sp8),
        Wrap(
          spacing: AppSpacing.sp8,
          runSpacing: AppSpacing.sp4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            UserStatusChip(status: UserStatus.fromRaw(employee.status)),
            // An attention cue beside the status, not a field — which is why
            // the info panel below carries no ON CALL row.
            if (employee.onCall) const _OnCallChip(),
          ],
        ),
      ],
    );
  }

  Widget _buildStacked(String name, Widget identity, Widget? pill) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppAvatar(name: name, color: employee.color, size: AvatarSize.lg),
            const SizedBox(width: AppSpacing.sp12),
            Expanded(child: identity),
          ],
        ),
        if (pill != null) ...[
          const SizedBox(height: AppSpacing.sp12),
          Align(alignment: AlignmentDirectional.centerEnd, child: pill),
        ],
      ],
    );
  }

  Widget _buildInline(String name, Widget identity, Widget? pill) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppAvatar(name: name, color: employee.color, size: AvatarSize.lg),
        const SizedBox(width: AppSpacing.sp12),
        Expanded(child: identity),
        if (pill != null) ...[const SizedBox(width: AppSpacing.sp8), pill],
      ],
    );
  }
}

/// "On call" — tinted with the accent blue at 10%, matching the Edit pill.
class _OnCallChip extends StatelessWidget {
  const _OnCallChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp8,
        vertical: AppSpacing.sp4,
      ),
      decoration: BoxDecoration(
        color: theme.palette.primaryAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.rFull),
      ),
      child: Text(
        context.l10n.employees_onCall,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.palette.primaryAccent,
        ),
      ),
    );
  }
}

/// Tinted Edit pill — the twin of the client detail's.
class _EditPill extends StatelessWidget {
  const _EditPill({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: accentPillButtonStyle(context),
      onPressed: onEdit,
      child: Text(context.l10n.common_edit),
    );
  }
}
