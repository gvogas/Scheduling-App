import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_header_bar.dart';

/// Matches the fling the modal bottom sheet's own drag treats as a dismiss.
const _kDismissFlingVelocity = 700.0;

/// Form-sheet chrome from `06-sheets-and-dialogs.md`: a fixed-height sheet
/// whose header is the shared [SheetHeaderBar] (**Cancel · title · primary
/// verb**), with no grabber.
///
/// Fixed height rather than draggable is the design's own call — the bar is the
/// dismiss affordance, and a form that resizes under the keyboard loses the
/// user's place. The scrim still dismisses on tap, and a fling down on the bar
/// does too; with [isDirty] supplied, both (and Cancel, and system back) first
/// ask "Discard changes?" while the form differs from its seed.
///
/// This is the only form-sheet chrome; every add/edit sheet in the app uses it.
/// The older `FormSheetScaffold` (drag handle + inline headline, a second
/// header style) was retired once P3/P4 migrated the last client and employee
/// sheets onto this frame.
class FormSheetFrame extends StatefulWidget {
  const FormSheetFrame({
    required this.title,
    required this.primaryLabel,
    required this.children,
    super.key,
    this.onPrimary,
    this.onCancel,
    this.isDirty,
    this.isBusy = false,
    this.heightFactor = 0.92,
    this.headerTourWrap,
    this.scrollCacheExtent,
  });

  final String title;
  final String primaryLabel;
  final List<Widget> children;

  /// Null disables the primary verb.
  final VoidCallback? onPrimary;

  /// Defaults to popping the sheet.
  final VoidCallback? onCancel;

  /// Consulted at dismiss time; true shows the discard confirm first. Null
  /// means the sheet never guards (nothing to lose).
  final ValueGetter<bool>? isDirty;
  final bool isBusy;
  final double heightFactor;

  /// Wraps the header bar as a feature-tour step — the primary verb lives
  /// there, and it's the last step of every create-flow walkthrough. Null on
  /// a sheet with no tour (every edit sheet).
  final Widget Function(Widget child)? headerTourWrap;

  /// Inflates the scroll cache so below-fold rows are built. A tour needs
  /// this: `isTargetRendered` can't find a step whose row a lazy list has
  /// never built, and it would silently drop it.
  final ScrollCacheExtent? scrollCacheExtent;

  @override
  State<FormSheetFrame> createState() => _FormSheetFrameState();
}

class _FormSheetFrameState extends State<FormSheetFrame> {
  bool _isConfirming = false;

  Widget _wrapHeader(Widget bar) => widget.headerTourWrap?.call(bar) ?? bar;

  /// True when the sheet may go: clean, or the person chose Discard.
  Future<bool> _mayDismiss(BuildContext context) async {
    final isDirty = widget.isDirty;
    if (isDirty == null || !isDirty()) return true;
    if (_isConfirming) return false;
    _isConfirming = true;
    final l10n = context.l10n;
    final discard = await showConfirmDialog(
      context,
      title: l10n.common_discardChangesTitle,
      message: l10n.common_discardChangesBody,
      confirmLabel: l10n.common_discard,
      cancelLabel: l10n.common_keepEditing,
    );
    _isConfirming = false;
    return discard && context.mounted;
  }

  /// Guarded so a frame hosted outside a sheet (tests) never pops its page.
  void _pop(BuildContext context, [Object? result]) {
    if (Navigator.canPop(context)) Navigator.pop(context, result);
  }

  Future<void> _cancel(BuildContext sheetContext) async {
    if (!await _mayDismiss(sheetContext)) return;
    if (!sheetContext.mounted) return;
    (widget.onCancel ?? () => _pop(sheetContext))();
  }

  /// Scrim tap and system back arrive here through `maybePop`.
  Future<void> _onPopInvoked(
    BuildContext context,
    bool didPop,
    Object? result,
  ) async {
    if (didPop || !await _mayDismiss(context)) return;
    if (context.mounted) _pop(context, result);
  }

  /// The modal's own drag pops without asking, so the frame takes the gesture
  /// and keeps only its fling-to-dismiss.
  Future<void> _onDragEnd(BuildContext context, DragEndDetails details) async {
    if ((details.primaryVelocity ?? 0) < _kDismissFlingVelocity) return;
    if (!await _mayDismiss(context)) return;
    if (context.mounted) _pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopScope<Object?>(
      canPop: widget.isDirty == null,
      onPopInvokedWithResult: (didPop, result) =>
          _onPopInvoked(context, didPop, result),
      child: DraggableScrollableSheet(
        initialChildSize: widget.heightFactor,
        minChildSize: widget.heightFactor,
        maxChildSize: widget.heightFactor,
        expand: false,
        builder: (sheetContext, scrollController) =>
            _buildSheet(sheetContext, scrollController, theme, scheme),
      ),
    );
  }

  Widget _buildSheet(
    BuildContext sheetContext,
    ScrollController scrollController,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(sheetContext).unfocus(),
      onVerticalDragEnd: (details) => _onDragEnd(sheetContext, details),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.rSheet),
          ),
          boxShadow: theme.cardStyle.sheetShadow,
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.rSheet),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                _wrapHeader(
                  SheetHeaderBar(
                    title: widget.title,
                    primaryLabel: widget.primaryLabel,
                    onPrimary: widget.onPrimary,
                    // Defaulting the dismiss here rather than in the bar
                    // keeps SheetHeaderBar free of any assumption about how
                    // the surface hosting it is closed.
                    onCancel: () => _cancel(sheetContext),
                    isBusy: widget.isBusy,
                  ),
                ),
                _buildList(sheetContext, scrollController),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext sheetContext, ScrollController controller) {
    return Expanded(
      child: ListView(
        controller: controller,
        scrollCacheExtent: widget.scrollCacheExtent,
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: AppSpacing.sp16,
          // Keyboard-inset aware, so the focused field is never
          // hidden behind the keyboard.
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 30,
        ),
        children: widget.children,
      ),
    );
  }
}
