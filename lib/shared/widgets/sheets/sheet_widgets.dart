import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

bool _isShortSheetViewport(BuildContext context) =>
    MediaQuery.sizeOf(context).height < Breakpoints.shortViewportHeight;

class DraggableSheetFrame extends StatelessWidget {
  const DraggableSheetFrame({
    required this.builder,
    super.key,
    this.initialChildSize = 0.7,
    this.minChildSize = 0.5,
    this.maxChildSize = 0.95,
  });

  final ScrollableWidgetBuilder builder;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isShort = _isShortSheetViewport(context);

    return DraggableScrollableSheet(
      initialChildSize: isShort ? 0.82 : initialChildSize,
      minChildSize: isShort ? 0.58 : minChildSize,
      maxChildSize: isShort ? 0.98 : maxChildSize,
      expand: false,
      builder: (sheetContext, scrollController) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(sheetContext).unfocus(),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.r16),
              ),
              boxShadow: AppShadow.sheet,
            ),
            // Transparent Material for ListTile backgrounds/ripples.
            child: Material(
              type: MaterialType.transparency,
              child: builder(sheetContext, scrollController),
            ),
          ),
        );
      },
    );
  }
}

class SheetFocusScroll extends StatefulWidget {
  const SheetFocusScroll({required this.child, super.key, this.focusNode});

  final Widget child;

  /// Lets a host `requestFocus()` a non-text field (a picker, a panel) so a
  /// validation error scrolls into view; the host owns and disposes it.
  final FocusNode? focusNode;

  @override
  State<SheetFocusScroll> createState() => _SheetFocusScrollState();
}

class _SheetFocusScrollState extends State<SheetFocusScroll> {
  int _focusRequest = 0;

  Future<void> _ensureVisible(int request) async {
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted || request != _focusRequest) return;

    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeInOutCubic,
      alignment: 0.3,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      skipTraversal: widget.focusNode != null,
      onFocusChange: (hasFocus) {
        if (hasFocus) _ensureVisible(++_focusRequest);
      },
      child: widget.child,
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outline,
          borderRadius: BorderRadius.circular(AppRadius.rFull),
        ),
      ),
    );
  }
}

/// Standard scrollable body for a detail view — a bottom sheet with a drag
/// handle ([showHandle]), or a master-detail pane. Centralizes the padding
/// and the keyboard-inset-aware bottom gap.
class DetailSheetListView extends StatelessWidget {
  const DetailSheetListView({
    required this.children,
    super.key,
    this.scrollController,
    this.showHandle = false,
    this.bottomPadding = 24,
    this.handleGap = 16,
  });

  final List<Widget> children;
  final ScrollController? scrollController;
  final bool showHandle;
  final double bottomPadding;

  /// Gap between the drag handle and the first child (only when [showHandle]).
  final double handleGap;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(
        left: AppSpacing.sp16,
        right: AppSpacing.sp16,
        top: AppSpacing.sp12,
        bottom: bottomInset + bottomPadding,
      ),
      children: [
        if (showHandle) ...[const _SheetHandle(), SizedBox(height: handleGap)],
        ...children,
      ],
    );
  }
}
