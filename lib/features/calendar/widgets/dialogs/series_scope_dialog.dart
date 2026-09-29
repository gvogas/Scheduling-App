import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/app_dialog_frame.dart';
import 'package:scheduling/shared/widgets/dialogs/dialog_action_pair.dart';

enum SeriesScopeChoice { thisOnly, thisAndFuture }

/// Shared 'this only' / 'this and future' picker for repeating appointments.
///
/// Deliberately has **no Cupertino action-sheet branch**, unlike every other
/// adaptive surface in the app: the design puts a consequence line under each
/// option ("12 remaining visits through 26 Jan"), and an action sheet cannot
/// render one. A single design-mandated exception, not a policy change.
Future<SeriesScopeChoice?> showSeriesScopeDialog(
  BuildContext context, {
  required String title,
  required String thisOnlyLabel,
  required String thisAndFutureLabel,
  required String Function(SeriesScopeChoice choice) primaryLabelFor,
  String? contextLabel,
  String? thisOnlyDetail,
  String? thisAndFutureDetail,
  bool destructive = false,
}) => showDialog<SeriesScopeChoice>(
  context: context,
  builder: (ctx) => _SeriesScopeDialog(
    title: title,
    thisOnlyLabel: thisOnlyLabel,
    thisAndFutureLabel: thisAndFutureLabel,
    primaryLabelFor: primaryLabelFor,
    contextLabel: contextLabel,
    thisOnlyDetail: thisOnlyDetail,
    thisAndFutureDetail: thisAndFutureDetail,
    destructive: destructive,
  ),
);

class _SeriesScopeDialog extends StatefulWidget {
  const _SeriesScopeDialog({
    required this.title,
    required this.thisOnlyLabel,
    required this.thisAndFutureLabel,
    required this.primaryLabelFor,
    required this.destructive,
    this.contextLabel,
    this.thisOnlyDetail,
    this.thisAndFutureDetail,
  });

  final String title;
  final String thisOnlyLabel;
  final String thisAndFutureLabel;
  final String Function(SeriesScopeChoice choice) primaryLabelFor;
  final String? contextLabel;
  final String? thisOnlyDetail;
  final String? thisAndFutureDetail;
  final bool destructive;

  @override
  State<_SeriesScopeDialog> createState() => _SeriesScopeDialogState();
}

class _SeriesScopeDialogState extends State<_SeriesScopeDialog> {
  SeriesScopeChoice _choice = SeriesScopeChoice.thisOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppDialogFrame(
      children: [
        if (widget.contextLabel != null) ...[
          Text(widget.contextLabel!, style: theme.monoType.label),
          const SizedBox(height: AppSpacing.sp8),
        ],
        Text(widget.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: AppSpacing.sp16),
        _ScopeOption(
          label: widget.thisOnlyLabel,
          detail: widget.thisOnlyDetail,
          selected: _choice == SeriesScopeChoice.thisOnly,
          onTap: () => setState(() => _choice = SeriesScopeChoice.thisOnly),
        ),
        const SizedBox(height: AppSpacing.sp8),
        _ScopeOption(
          label: widget.thisAndFutureLabel,
          detail: widget.thisAndFutureDetail,
          selected: _choice == SeriesScopeChoice.thisAndFuture,
          onTap: () =>
              setState(() => _choice = SeriesScopeChoice.thisAndFuture),
        ),
        const SizedBox(height: AppSpacing.sp24),
        DialogActionPair(
          secondaryLabel: context.l10n.common_back,
          onSecondary: () => Navigator.pop(context),
          primaryLabel: widget.primaryLabelFor(_choice),
          onPrimary: () => Navigator.pop(context, _choice),
          // dangerFill, never scheme.error — that slot is the lifted
          // foreground red and is unreadable as a fill.
          primaryBackgroundColor: widget.destructive
              ? theme.palette.dangerFill
              : scheme.primary,
          primaryForegroundColor: widget.destructive
              ? theme.palette.onDangerFill
              : scheme.onPrimary,
        ),
      ],
    );
  }
}

/// One radio row: an 18px ring that fills to a 9px dot when chosen, with the
/// option label and its consequence line.
class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : null,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(AppRadius.r12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? scheme.primary
                          : theme.palette.textMuted,
                      width: 1.5,
                    ),
                  ),
                  child: selected
                      ? Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary,
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.titleMedium),
                    if (detail != null) ...[
                      const SizedBox(height: AppSpacing.sp4),
                      Text(
                        detail!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.palette.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
