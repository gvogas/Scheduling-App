import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The Team roster's collapsed "Test accounts" group, starting closed.
class TestAccountsSection extends StatefulWidget {
  const TestAccountsSection({
    required this.accounts,
    required this.rowBuilder,
    super.key,
  });

  final List<EmployeeRecord> accounts;
  final Widget Function(EmployeeRecord employee) rowBuilder;

  @override
  State<TestAccountsSection> createState() => _TestAccountsSectionState();
}

class _TestAccountsSectionState extends State<TestAccountsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = context.l10n.employees_testAccountsSection(
      widget.accounts.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sp16,
                  vertical: AppSpacing.sp8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label.toUpperCase(),
                        style: theme.monoType.label.copyWith(
                          color: theme.palette.textTertiary,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: theme.palette.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded)
          for (final account in widget.accounts)
            KeyedSubtree(
              key: ValueKey(account.id),
              child: widget.rowBuilder(account),
            ),
      ],
    );
  }
}
