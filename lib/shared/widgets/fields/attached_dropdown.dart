import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// The suggestion list under a text field, shared by the client picker and the
/// address field (rules: `.claude/rules/frontend.md`, Forms & sheets).
class AttachedDropdown extends StatelessWidget {
  const AttachedDropdown({required this.children, super.key, this.caption});

  final List<Widget> children;

  /// Warning band above the rows, for results that answer a query nobody
  /// typed. Null renders nothing.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sp4),
      decoration: BoxDecoration(
        color: theme.palette.sheetRow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.r12),
        boxShadow: theme.cardStyle.pillShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (caption != null)
            Container(
              width: double.infinity,
              color: theme.statusColors.warningContainer,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sp12,
                vertical: AppSpacing.sp8,
              ),
              child: Text(
                caption!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.monoType.groupLabel.copyWith(
                  color: theme.statusColors.onWarningContainer,
                ),
              ),
            ),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 || caption != null)
              Divider(height: 1, color: scheme.outlineVariant),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One tappable suggestion: holds the 48px tap floor, and the chevron is its
/// whole affordance (no trailing verb, by owner call).
class AttachedDropdownRow extends StatelessWidget {
  const AttachedDropdownRow({
    required this.headline,
    required this.onTap,
    super.key,
    this.leading,
    this.detail,
    this.headlineStyle,
    this.headlineMaxLines = 1,
  });

  /// Avatar or glyph. Null indents the text to the panel edge.
  final Widget? leading;
  final String headline;

  /// Second line, muted. Null or blank renders nothing.
  final String? detail;
  final TextStyle? headlineStyle;

  /// An address runs long and is the whole answer, so it gets two lines.
  final int headlineMaxLines;
  final VoidCallback onTap;

  static const double _tapFloor = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDetail = detail != null && detail!.trim().isNotEmpty;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _tapFloor),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp12,
            vertical: AppSpacing.sp8,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: AppSpacing.sp12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      maxLines: headlineMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style:
                          headlineStyle ??
                          theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (hasDetail)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.palette.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sp8),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: theme.palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
