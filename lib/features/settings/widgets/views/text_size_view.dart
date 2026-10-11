import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/l10n/l10n.dart';

class TextSizeView extends StatefulWidget {
  const TextSizeView({super.key, this.onApplied});

  final VoidCallback? onApplied;

  @override
  State<TextSizeView> createState() => _TextSizeViewState();
}

class _TextSizeViewState extends State<TextSizeView> {
  List<(String, double)> _buildOptions(AppLocalizations l10n) => [
    (l10n.settings_textScaleSmall, 0.8),
    (l10n.settings_textScaleMedium, 1.0),
    (l10n.settings_textScaleLarge, 1.2),
    (l10n.settings_textScaleXL, 1.4),
  ];

  late double _selected;
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _selected = ThemeNotifier.of(context).textScale;
    _seeded = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = context.isCompact;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.sp16),
      children: [
        _PreviewCard(selected: _selected),
        const SizedBox(height: AppSpacing.sp12),
        _buildOptionsCard(compact),
        const SizedBox(height: AppSpacing.sp8),
        Text(
          context.l10n.settings_textSizeAppliesAppWide,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),
        _buildApplyButton(context, scheme),
      ],
    );
  }

  Widget _buildOptionsCard(bool compact) {
    return Builder(
      builder: (context) {
        final options = _buildOptions(context.l10n);
        return _Card(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sp4,
            horizontal: AppSpacing.sp8,
          ),
          child: Column(
            children: [
              for (int i = 0; i < options.length; i++) ...[
                _SizeRow(
                  label: options[i].$1,
                  scale: options[i].$2,
                  isSelected: (_selected - options[i].$2).abs() < 0.01,
                  compact: compact,
                  onTap: () => setState(() => _selected = options[i].$2),
                ),
                if (i < options.length - 1)
                  const Divider(height: 1, indent: 52),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildApplyButton(BuildContext context, ColorScheme scheme) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.r12),
        ),
      ),
      onPressed: () {
        ThemeNotifier.of(context).setTextScale(_selected);
        widget.onApplied?.call();
      },
      child: Text(
        context.l10n.settings_apply,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.selected});

  final double selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.settings_previewText.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sp12),
          MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(selected)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.settings_previewApptTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  context.l10n.settings_previewApptWhen,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 3),
                Text(
                  context.l10n.settings_previewApptContact,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: appCardDecoration(theme, color: theme.colorScheme.surface),
      padding: padding ?? const EdgeInsets.all(AppSpacing.sp16),
      child: child,
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.label,
    required this.scale,
    required this.isSelected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final double scale;
  final bool isSelected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: isSelected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.r8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.r8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sp12,
            horizontal: AppSpacing.sp8,
          ),
          child: compact
              ? _buildStacked(theme, scheme)
              : _buildInline(theme, scheme),
        ),
      ),
    );
  }

  Widget _buildStacked(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ScaleGlyph(
              scale: scale,
              isSelected: isSelected,
              primary: scheme.primary,
              muted: scheme.onSurfaceVariant,
            ),
            const Spacer(),
            Icon(
              isSelected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sp8),
        Padding(
          padding: const EdgeInsets.only(left: 48),
          child: Text(
            label,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? scheme.primary : null,
              fontSize: 15,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInline(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        _ScaleGlyph(
          scale: scale,
          isSelected: isSelected,
          primary: scheme.primary,
          muted: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.sp8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? scheme.primary : null,
              fontSize: 15,
            ),
          ),
        ),
        Icon(
          isSelected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded,
          size: 20,
          color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

class _ScaleGlyph extends StatelessWidget {
  const _ScaleGlyph({
    required this.scale,
    required this.isSelected,
    required this.primary,
    required this.muted,
  });

  final double scale;
  final bool isSelected;
  final Color primary;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Center(
        child: Text(
          'A',
          style: TextStyle(
            fontSize: 11 + (scale - 0.8) * 16,
            fontWeight: FontWeight.w700,
            color: isSelected ? primary : muted,
            height: 1,
          ),
        ),
      ),
    );
  }
}
