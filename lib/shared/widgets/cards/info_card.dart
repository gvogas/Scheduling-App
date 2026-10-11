import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// Bordered card stacking rows with hairline dividers.
class InfoCard extends StatelessWidget {
  const InfoCard({required this.rows, super.key});

  final List<InfoCardRow> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.r16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 60),
              rows[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One row in an InfoCard — an icon chip, a value, and an optional trailing
/// affordance.
class InfoCardRow extends StatelessWidget {
  const InfoCardRow({
    required this.icon,
    required this.text,
    this.iconColor,
    this.onTap,
    this.trailingIcon,
    this.emphasize = false,
    this.semanticLabel,
    super.key,
  });

  final IconData icon;
  final String text;
  final Color? iconColor;
  final VoidCallback? onTap;
  final IconData? trailingIcon;

  /// Render value as bold title.
  final bool emphasize;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chipColor = iconColor ?? scheme.primary;
    final compact = context.isCompact;

    final content = _buildContent(theme, scheme, chipColor, compact);

    if (onTap == null) return content;

    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(onTap: onTap, child: content),
    );
  }

  Widget _buildContent(
    ThemeData theme,
    ColorScheme scheme,
    Color chipColor,
    bool compact,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp16,
        vertical: AppSpacing.sp12,
      ),
      child: Row(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: theme.cardStyle.iconChipAlpha),
              borderRadius: BorderRadius.circular(AppRadius.r8),
            ),
            child: Icon(icon, size: 18, color: chipColor),
          ),
          const SizedBox(width: AppSpacing.sp12),
          Expanded(
            child: Text(
              text,
              style: emphasize
                  ? theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      height: 1.3,
                    ),
            ),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: AppSpacing.sp8),
            Padding(
              padding: EdgeInsets.only(top: compact ? 2 : 0),
              child: Icon(
                trailingIcon,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
