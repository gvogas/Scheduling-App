import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/clear_text_button.dart';

class AppSearchBar extends StatelessWidget implements PreferredSizeWidget {
  const AppSearchBar({
    super.key,
    this.onChanged,
    this.hintText,
    this.controller,
    this.focusNode,
    this.textScaler = TextScaler.noScaling,
  });

  /// Vertical margins around the field. This is fixed chrome, so it doesn't
  /// grow with text size.
  static const double _verticalMargins = AppSpacing.sp8 * 2;

  /// The field itself (text + content padding + border) at text scale 1.0.
  static const double _fieldHeight = 44;

  final ValueChanged<String>? onChanged;

  /// Placeholder shown in the field. Defaults to the localized "Search..." string.
  final String? hintText;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Pass `MediaQuery.textScalerOf(context)` so preferredSize reserves height at large text scale.
  final TextScaler textScaler;

  @override
  Size get preferredSize =>
      Size.fromHeight(_verticalMargins + textScaler.scale(_fieldHeight));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tertiary = theme.palette.textTertiary;
    final pill = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.rFull),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp16,
        vertical: AppSpacing.sp8,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged ?? (_) {},
        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: hintText ?? context.l10n.common_search,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(color: tertiary),
          prefixIcon: Icon(Icons.search, size: 18, color: tertiary),
          // 14px each side of the glyph, and no 48px floor to grow the pill.
          prefixIconConstraints: const BoxConstraints(
            minWidth: 46,
            maxWidth: 46,
          ),
          // Non-dense carries a 48px floor, which is taller than the pill.
          isDense: true,
          constraints: const BoxConstraints(minHeight: _fieldHeight),
          filled: true,
          fillColor: scheme.surface,
          border: pill,
          enabledBorder: pill,
          focusedBorder: pill.copyWith(
            borderSide: BorderSide(color: scheme.primary),
          ),
          contentPadding: const EdgeInsets.fromLTRB(
            0,
            AppSpacing.sp12,
            14,
            AppSpacing.sp12,
          ),
          suffixIcon: controller != null
              ? ClearTextButton(
                  controller: controller!,
                  onCleared: () => onChanged?.call(''),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 44,
            maxHeight: 40,
          ),
        ),
      ),
    );
  }
}
