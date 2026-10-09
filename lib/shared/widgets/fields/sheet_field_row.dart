import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// A picker row inside a `SheetPanel`: a small label over its value, tappable,
/// with the value in the accent colour for dates, times and phone numbers.
///
/// Replaces the `readOnly` TextField + suffix-icon pattern at the form's six
/// picker positions only. Free-text fields keep `LabeledTextField`, which owns
/// the error shake and the clear button.
class SheetFieldRow extends StatelessWidget {
  const SheetFieldRow({
    required this.label,
    required this.value,
    super.key,
    this.placeholder,
    this.onTap,
    this.accent = false,
    this.trailing,
    this.errorText,
    this.useMonoValue = false,
    this.trailingLabel,
  });

  final String label;
  final String value;
  final String? placeholder;
  final VoidCallback? onTap;
  final bool accent;
  final Widget? trailing;
  final String? errorText;

  /// Muted text after the value, e.g. a run length beside an end date. Null
  /// renders nothing.
  final String? trailingLabel;

  /// Times, dates and other numerals render mono.
  final bool useMonoValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEmpty = value.trim().isEmpty;
    final baseStyle = useMonoValue
        ? theme.monoType.metric
        : theme.textTheme.titleSmall;
    final valueStyle = baseStyle?.copyWith(
      color: isEmpty
          ? theme.palette.textFaint
          : accent
          ? theme.palette.primaryAccent
          : theme.colorScheme.onSurface,
    );

    final content = _buildContent(theme, isEmpty, valueStyle);

    if (onTap == null) return content;
    return Semantics(
      button: true,
      // The trailing label is excluded with the rest of the subtree, so it has
      // to be spoken here or it is invisible to a screen reader.
      label:
          '$label, ${isEmpty ? (placeholder ?? '') : value}'
          '${trailingLabel == null ? '' : ', $trailingLabel'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        // 48 is the tap floor; the painted row is shorter at 1.0 scale.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: content,
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, bool isEmpty, TextStyle? valueStyle) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.palette.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.sp4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        isEmpty ? (placeholder ?? '') : value,
                        style: valueStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailingLabel != null) ...[
                      const SizedBox(width: AppSpacing.sp8),
                      Flexible(
                        child: Text(
                          trailingLabel!,
                          style: theme.monoType.micro.copyWith(
                            color: theme.palette.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                if (errorText != null) ...[
                  const SizedBox(height: AppSpacing.sp4),
                  Text(
                    errorText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
