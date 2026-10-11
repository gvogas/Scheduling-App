import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_header_bar.dart';

/// Form-sheet chrome from `06-sheets-and-dialogs.md`: a fixed-height sheet
/// whose header is the shared [SheetHeaderBar] (**Cancel · title · primary
/// verb**), with no grabber.
///
/// Fixed height rather than draggable is the design's own call — the bar is the
/// dismiss affordance, and a form that resizes under the keyboard loses the
/// user's place. The scrim still dismisses on tap.
///
/// This is the only form-sheet chrome; every add/edit sheet in the app uses it.
/// The older `FormSheetScaffold` (drag handle + inline headline, a second
/// header style) was retired once P3/P4 migrated the last client and employee
/// sheets onto this frame.
class FormSheetFrame extends StatelessWidget {
  const FormSheetFrame({
    required this.title,
    required this.primaryLabel,
    required this.children,
    super.key,
    this.onPrimary,
    this.onCancel,
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

  Widget _wrapHeader(Widget bar) => headerTourWrap?.call(bar) ?? bar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: heightFactor,
      minChildSize: heightFactor,
      maxChildSize: heightFactor,
      expand: false,
      builder: (sheetContext, scrollController) =>
          _buildSheet(sheetContext, scrollController, theme, scheme),
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
                    title: title,
                    primaryLabel: primaryLabel,
                    onPrimary: onPrimary,
                    // Defaulting the dismiss here rather than in the bar
                    // keeps SheetHeaderBar free of any assumption about how
                    // the surface hosting it is closed.
                    onCancel:
                        onCancel ?? () => Navigator.maybePop(sheetContext),
                    isBusy: isBusy,
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
        scrollCacheExtent: scrollCacheExtent,
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: AppSpacing.sp16,
          // Keyboard-inset aware, so the focused field is never
          // hidden behind the keyboard.
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 30,
        ),
        children: children,
      ),
    );
  }
}
