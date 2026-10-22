import 'package:flutter/material.dart';
import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/password_requirements.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Live checklist under a new-password field: one row per
/// [PasswordRequirement], an empty circle that becomes a checkmark as the
/// typed [password] satisfies it.
class PasswordRequirementsChecklist extends StatelessWidget {
  const PasswordRequirementsChecklist({
    required this.password,
    this.mustDifferFromStarting = false,
    super.key,
  });

  final String password;

  /// Adds the "not the temporary password" note; only the server can check it.
  final bool mustDifferFromStarting;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final requirement in PasswordRequirement.values)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp4),
            child: _RequirementRow(
              label: _label(context, requirement),
              isMet: requirement.isMetBy(password),
            ),
          ),
        if (mustDifferFromStarting)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp4),
            child: _RequirementRow(
              label: context.l10n.validation_passwordReqNotStarting,
              isMet: null,
            ),
          ),
      ],
    );
  }

  String _label(BuildContext context, PasswordRequirement requirement) {
    final l10n = context.l10n;
    return switch (requirement) {
      PasswordRequirement.minLength => l10n.validation_passwordReqMinLength,
      PasswordRequirement.uppercase => l10n.validation_passwordReqUppercase,
      PasswordRequirement.lowercase => l10n.validation_passwordReqLowercase,
      PasswordRequirement.number => l10n.validation_passwordReqNumber,
    };
  }
}

class _RequirementRow extends StatelessWidget {
  const _RequirementRow({required this.label, required this.isMet});

  final String label;

  /// Null is an informational row the client cannot verify.
  final bool? isMet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isMet == true
        ? theme.statusColors.success
        : theme.colorScheme.onSurfaceVariant;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppAnimationDurations.quick;
    final icon = switch (isMet) {
      true => Icons.check_circle,
      false => Icons.circle_outlined,
      null => Icons.info_outline,
    };

    return Row(
      children: [
        AnimatedSwitcher(
          duration: duration,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.7, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: Icon(icon, key: ValueKey(isMet), size: 16, color: color),
        ),
        const SizedBox(width: AppSpacing.sp8),
        Expanded(
          child: AnimatedDefaultTextStyle(
            duration: duration,
            style:
                theme.textTheme.bodySmall?.copyWith(color: color) ??
                TextStyle(color: color),
            child: Text(label),
          ),
        ),
      ],
    );
  }
}
