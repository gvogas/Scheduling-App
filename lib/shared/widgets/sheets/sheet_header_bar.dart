import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/layout/text_measure.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Painted height of a ghost control; `tapTargetSize.padded` lifts the hit area
/// to the 48px floor around it.
const double _kGhostTile = 38;

/// The ghost style's 14px side padding plus its 1px border, both sides.
const double _kGhostChrome = 30;

/// Ceiling on each side slot, so two long verbs can never crowd the title out
/// entirely at a large text scale.
const double _kSideSlotMax = 0.34;

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
/// Layout notes, all three load-bearing:
///
/// * The two side slots are MEASURED to the wider of the two labels and given
///   that same width, so the title's `Expanded` is centred on the bar by
///   construction — an asymmetric pair ("Send invite" vs "Cancel") cannot drag
///   it off centre.
/// * They are measured rather than shared as a flex. A flat `flex: 3/4/3` left
///   the title 40% of the bar, which truncated "New Appointment" to
///   "New Appoin..." on the WIDEST iPhone at default text size, while both
///   ghost tiles sat half empty. The title now gets every point the verbs
///   don't need.
/// * The slot is capped at [_kSideSlotMax], so the bar still cannot overflow:
///   two intrinsic label widths exceed a 260px viewport once text is scaled
///   up, and an uncapped slot would have nothing to give.
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

  /// Width both side slots take: the wider painted label, capped so the title
  /// always keeps a share of the bar.
  double _sideSlotWidth(BuildContext context, double maxWidth) {
    final labelStyle = Theme.of(context).textTheme.bodyMedium;
    final widest = math.max(
      measureTextWidth(context, context.l10n.common_cancel, labelStyle),
      // Measured from the label even while busy, so swapping in the spinner
      // cannot reflow the bar under the user.
      measureTextWidth(
        context,
        primaryLabel,
        labelStyle?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    return math.min(widest + _kGhostChrome, maxWidth * _kSideSlotMax);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = _ghostStyle(theme);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sp8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = _sideSlotWidth(context, constraints.maxWidth);
          return Row(
            children: [
              SizedBox(
                width: slot,
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
              Expanded(
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
              SizedBox(
                width: slot,
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
            ],
          );
        },
      ),
    );
  }
}
