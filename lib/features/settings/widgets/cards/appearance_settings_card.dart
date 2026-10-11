import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/settings/widgets/cards/settings_tiles.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Dark-mode, text-size, and language rows. Reads the [ThemeNotifier] and the
/// active locale itself; the host supplies only the text-size tap handler.
class AppearanceSettingsCard extends StatelessWidget {
  const AppearanceSettingsCard({required this.onTextSizeTap, super.key});

  final VoidCallback onTextSizeTap;

  String _textScaleLabel(BuildContext context, double scale) {
    if (scale <= 0.85) return context.l10n.settings_textScaleSmall;
    if (scale <= 1.05) return context.l10n.settings_textScaleMedium;
    if (scale <= 1.25) return context.l10n.settings_textScaleLarge;
    return context.l10n.settings_textScaleXL;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ThemeNotifier.of(context);
    final langCode = Localizations.localeOf(context).languageCode;
    // Resolve against live OS brightness so the switch tracks system theme changes.
    final isDark = isDarkMode(
      notifier.themeMode,
      MediaQuery.platformBrightnessOf(context),
    );
    return SettingsSectionCard(
      child: Column(
        children: [
          SettingsTile(
            iconBg: scheme.primaryContainer,
            icon: isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
            iconColor: scheme.primary,
            label: context.l10n.settings_darkMode,
            trailing: Switch.adaptive(
              value: isDark,
              onChanged: (_) => notifier.toggleTheme(),
              activeTrackColor: scheme.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SettingsTileDivider(),
          _buildTextSizeTile(context, scheme, notifier),
          const SettingsTileDivider(),
          SettingsTile(
            iconBg: scheme.secondaryContainer,
            icon: Icons.language_rounded,
            iconColor: scheme.secondary,
            label: context.l10n.common_language,
            trailing: LanguageToggle(
              currentCode: langCode,
              onChanged: notifier.setLanguage,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextSizeTile(
    BuildContext context,
    ColorScheme scheme,
    ThemeNotifier notifier,
  ) {
    return SettingsTile(
      iconBg: scheme.tertiaryContainer,
      icon: Icons.text_fields_rounded,
      iconColor: scheme.tertiary,
      label: context.l10n.settings_textSize,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sp4,
        runSpacing: AppSpacing.sp4,
        children: [
          SettingsTrailingPill(
            label: _textScaleLabel(context, notifier.textScale),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
      onTap: onTextSizeTap,
    );
  }
}
