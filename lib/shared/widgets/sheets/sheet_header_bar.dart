import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Painted height of a ghost control; `tapTargetSize.padded` lifts the hit area
/// to the 48px floor around it.
const double _kGhostTile = 38;

/// The one sheet header: **Cancel · title · primary verb**, sitting directly on
/// the sheet surface with ghost controls either side.
///
/// Every add/edit sheet in the app renders this — appointments, clients and
/// people — so the dismiss affordance, the title and the commit verb sit in
/// the same place on every form. `FormSheetFrame` composes it; use it directly
/// only for a sheet that needs different chrome around the same bar.
///
/// It carries the same vocabulary as `AppTopBar`: no coloured band and no
/// divider, a headline title, and controls painted as `scheme.surface` tiles
/// behind a 1px `scheme.outlineVariant` border.
///
/// Layout notes, both load-bearing:
///
/// * The three slots are `Expanded`, not `Flexible`. Loose fit let the middle
///   `Text` shrink to its intrinsic width (the two `Align`s expand, a bare
///   `Text` does not), so the leftover main-axis space pooled at the trailing
///   edge and the title rendered left of centre with the verb floating
///   mid-bar. Tight fit pins each slot to its share.
/// * Every slot is still flexible, so the bar cannot overflow: three intrinsic
///   widths exceed a 260px viewport once text is scaled up, and a non-flex
///   button would have nothing to give. The side slots share a flex so the
///   title stays optically centred between them.
class SheetHeaderBar extends StatelessWidget {
  const SheetHeaderBar({
    required this.title,
    required this.primaryLabel,
    super.key,
    this.onPrimary,
    this.onCancel,
    this.isBusy = false,
  });

  final String title;

  /// The commit verb — "Save", "Add", "Send invite".
  final String primaryLabel;

  /// Null renders the verb disabled.
  final VoidCallback? onPrimary;

  /// Null renders Cancel disabled; supply the dismiss action explicitly.
  final VoidCallback? onCancel;

  /// Swaps the verb for a spinner and blocks both actions, so an in-flight
  /// save can't be double-submitted from the bar.
  final bool isBusy;

  static ButtonStyle _ghostStyle(ThemeData theme) {
    final scheme = theme.colorScheme;
    return TextButton.styleFrom(
      backgroundColor: scheme.surface,
      disabledBackgroundColor: scheme.surface,
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.rFull),
      ),
      minimumSize: const Size(0, _kGhostTile),
      padding: const EdgeInsets.symmetric(horizontal: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _ghostStyle(theme);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sp8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: style,
                onPressed: isBusy ? null : onCancel,
                child: Text(
                  context.l10n.common_cancel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isBusy ? theme.palette.textMuted : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineLarge?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                style: style,
                onPressed: isBusy ? null : onPrimary,
                child: isBusy
                    ? const AdaptiveProgressIndicator(size: 18)
                    : Text(
                        primaryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: onPrimary == null
                              ? theme.palette.textMuted
                              : theme.palette.primaryAccent,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
