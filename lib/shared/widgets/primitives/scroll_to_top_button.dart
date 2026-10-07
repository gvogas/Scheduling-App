import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/floating_pill.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// Floating "back to top" control for a long list.
///
/// It rides the enclosing [PrimaryScrollController] — every list surface here
/// already sits in a `PrimaryScrollScope` — so a host adds it by stacking it
/// over the list rather than by threading a controller down.
class ScrollToTopButton extends StatefulWidget {
  const ScrollToTopButton({super.key, this.threshold = 400});

  /// How far down the list has to be before the button appears.
  final double threshold;

  @override
  State<ScrollToTopButton> createState() => _ScrollToTopButtonState();
}

class _ScrollToTopButtonState extends State<ScrollToTopButton> {
  ScrollController? _controller;
  bool _visible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = PrimaryScrollController.maybeOf(context);
    if (identical(next, _controller)) return;
    _controller?.removeListener(_onScroll);
    _controller = next?..addListener(_onScroll);
    _onScroll();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScroll);
    super.dispose();
  }

  /// The one attached position, or null.
  ///
  /// NOT `controller.offset`: that asserts unless exactly one scroll view is
  /// attached, and a list that swaps its body — the clients list moving
  /// between its paged and filtered builds — has two attached for a frame.
  /// `hasClients` is false in the other direction, between a rebuild and the
  /// list re-attaching.
  ScrollPosition? get _position {
    final positions = _controller?.positions;
    if (positions == null || positions.length != 1) return null;
    return positions.first;
  }

  void _onScroll() {
    final visible = (_position?.pixels ?? 0) > widget.threshold;
    if (visible == _visible) return;
    setState(() => _visible = visible);
  }

  Future<void> _toTop() async {
    final position = _position;
    if (position == null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      position.jumpTo(0);
      return;
    }
    await position.animateTo(
      0,
      duration: AppDuration.normal,
      curve: AppMotion.emphasized,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FloatingPill(
      visible: _visible,
      tooltip: context.l10n.common_backToTop,
      onTap: _toTop,
      child: SizedBox(
        width: kGhostTapTarget,
        height: kGhostTapTarget,
        child: Icon(
          Icons.arrow_upward_rounded,
          size: 20,
          color: Theme.of(context).palette.primaryAccent,
        ),
      ),
    );
  }
}
