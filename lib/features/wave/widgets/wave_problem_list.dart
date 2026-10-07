import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The contract's reasons, one sentence each.
///
/// Its own widget because two surfaces show the same reasons — the client
/// detail's badge and the Settings blocked list — and the failure they name
/// must be worded identically in both. The badge stacks it under its chip;
/// the list uses it alone.
class WaveProblemList extends StatelessWidget {
  const WaveProblemList({required this.problems, super.key});

  final List<WaveProblem> problems;

  @override
  Widget build(BuildContext context) {
    if (problems.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final problem in problems)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp4),
            child: Text(
              waveProblemSentence(context, problem),
              style: theme.textTheme.bodySmall?.copyWith(
                color: problem.isBlocking
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// One problem as a sentence an admin can act on.
///
/// The code vocabulary is server-owned, so `unknown` gets a sentence too
/// rather than rendering blank — the same rule the badge's unknown-state warn
/// holds.
String waveProblemSentence(BuildContext context, WaveProblem problem) {
  final l10n = context.l10n;
  final field = _fieldLabel(context, problem.field);
  return switch (problem.code) {
    WaveProblemCode.empty => l10n.wave_problemNameEmpty,
    WaveProblemCode.tooLong => l10n.wave_problemTooLong(
      field,
      problem.length ?? 0,
      problem.cap ?? 0,
    ),
    WaveProblemCode.invalidEmail => l10n.wave_problemInvalidEmail,
    WaveProblemCode.notDialable => l10n.wave_problemNotDialable(field),
    WaveProblemCode.unknown => l10n.wave_problemUnknown(field),
  };
}

/// The localized label for a client-doc field name.
///
/// `problem.field` names the field an admin edits, so it has to read as the
/// input's own label — falling back to the raw name keeps a server-side
/// rename legible instead of blank.
String _fieldLabel(BuildContext context, String field) {
  final l10n = context.l10n;
  return switch (field) {
    'name' => l10n.common_name,
    'firstName' => l10n.clients_firstName,
    'lastName' => l10n.clients_lastName,
    'email' => l10n.common_email,
    'phone' => l10n.clients_phone,
    'mobile' => l10n.common_mobile,
    'address' => l10n.common_address,
    'addressLine2' => l10n.common_addressLine2,
    'city' => l10n.common_city,
    'postalCode' => l10n.common_postalCode,
    _ => field,
  };
}
