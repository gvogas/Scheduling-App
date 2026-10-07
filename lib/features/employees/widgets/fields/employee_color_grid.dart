import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// A tap-friendly grid of employee colors. Hides colors already in use and
/// shows a swatch for the custom picker.
class EmployeeColorGrid extends ConsumerWidget {
  const EmployeeColorGrid({
    required this.selectedColor,
    required this.onColorSelected,
    super.key,
    this.usedColors = const {},
  });

  final int selectedColor;
  final ValueChanged<int> onColorSelected;
  final Set<int> usedColors;

  void _pick(int colorInt) {
    HapticFeedback.selectionClick();
    onColorSelected(colorInt);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Offer only unused colors (selected always stays visible).
    final available = [
      for (final color in AppColors.crewPalette)
        if (!usedColors.contains(color.toARGB32()) ||
            color.toARGB32() == selectedColor)
          color,
    ];
    final isCustomColor = !available.any((c) => c.toARGB32() == selectedColor);

    return Wrap(
      spacing: AppSpacing.sp4,
      runSpacing: AppSpacing.sp4,
      children: [
        for (var i = 0; i < available.length; i++)
          _SwatchButton(
            // Keyed by the STORED argb so a test can assert a specific swatch
            // is offered (or hidden as taken).
            key: ValueKey(available[i].toARGB32()),
            // Display resolves through the theme; the STORED value stays the
            // canonical light int.
            color: crewColorOf(theme, available[i].toARGB32()),
            isSelected: available[i].toARGB32() == selectedColor,
            semanticLabel: context.l10n.employees_colorOption(i + 1),
            onTap: () => _pick(available[i].toARGB32()),
          ),
        if (isCustomColor)
          _SwatchButton(
            color: crewColorOf(theme, selectedColor),
            isSelected: true,
            semanticLabel: context.l10n.employees_customColor,
            onTap: null,
          ),
        _CustomColorButton(onTap: () => _openCustomPicker(context, ref)),
      ],
    );
  }

  Future<void> _openCustomPicker(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final picked = await showColorPickerDialog(
      context,
      Color(selectedColor),
      title: Text(
        l10n.employees_customColor,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      // Just a tap-to-pick palette with shade rows — no color wheel, since
      // that needs precise finger-dragging, and no hex field either.
      pickersEnabled: const <ColorPickerType, bool>{
        ColorPickerType.primary: true,
        ColorPickerType.accent: false,
        ColorPickerType.wheel: false,
      },
      borderRadius: 20,
      actionButtons: const ColorPickerActionButtons(
        okButton: true,
        closeButton: true,
        dialogActionButtons: false,
      ),
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 320),
    );
    if (!context.mounted) return;
    final pickedInt = picked.toARGB32();
    // A custom pick can still collide with another employee's custom color.
    if (usedColors.contains(pickedInt)) {
      ref
          .read(noticeServiceProvider)
          .error(context.l10n.error_colorAlreadyUsed);
      return;
    }
    if (pickedInt != selectedColor) _pick(pickedInt);
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.isSelected,
    required this.semanticLabel,
    required this.onTap,
    super.key,
  });

  static const double _targetSize = 48;
  static const double _swatchSize = 38;

  final Color color;
  final bool isSelected;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      selected: isSelected,
      label: semanticLabel,
      child: InkResponse(
        onTap: onTap,
        radius: _targetSize / 2,
        child: SizedBox(
          width: _targetSize,
          height: _targetSize,
          child: Center(
            child: AnimatedContainer(
              duration: AppDuration.fast,
              curve: Curves.easeOut,
              width: _swatchSize,
              height: _swatchSize,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? scheme.onSurface : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: isSelected
                  ? Icon(
                      Icons.check,
                      color: avatarForegroundFor(theme, color),
                      size: 18,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The "more colors" affordance — a rainbow-ringed swatch that reads as
/// "any color". It's sized and rippled the same way as the palette swatches.
class _CustomColorButton extends StatelessWidget {
  const _CustomColorButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = context.l10n.employees_customColor;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 38,
                height: 38,
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: AppColors.decorativeHueRing),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surface,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
