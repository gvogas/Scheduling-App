import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_hold.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

class NoticeListener extends ConsumerStatefulWidget {
  const NoticeListener({required this.child, this.navigatorKey, super.key});

  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  ConsumerState<NoticeListener> createState() => _NoticeListenerState();
}

class _NoticeListenerState extends ConsumerState<NoticeListener> {
  StreamSubscription<AppNotice>? _sub;
  OverlayEntry? _currentEntry;
  AppNotice? _currentNotice;

  /// A non-error notice that arrived while an action notice was showing.
  AppNotice? _pending;

  @override
  void initState() {
    super.initState();
    // Resolved here rather than inside the handler: a stream error can arrive
    // after this consumer is unmounted, and Riverpod 3's `ref.read` throws on
    // an unmounted consumer — which would replace the logged notice failure
    // with a StateError escaping to the zone handler as a FATAL.
    final logger = ref.read(loggerProvider);
    // Without onError a stream failure escapes to the zone handler and is
    // recorded as a FATAL crash — for a notice we could not display.
    _sub = ref
        .read(noticeServiceProvider)
        .stream
        .listen(
          _show,
          onError: (Object e, StackTrace st) =>
              logger.warn('NOTICE stream error', e, st),
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    // `remove()` detaches, `dispose()` releases — an entry removed without
    // being disposed trips Flutter's leak tracking in widget tests.
    _currentEntry
      ?..remove()
      ..dispose();
    _currentEntry = null;
    super.dispose();
  }

  void _show(AppNotice notice) {
    if (!mounted) return;
    if (_currentEntry != null &&
        _currentNotice?.action != null &&
        notice is! NoticeError) {
      _pending = notice;
      return;
    }
    final overlay =
        widget.navigatorKey?.currentState?.overlay ?? Overlay.maybeOf(context);
    if (overlay == null) return;

    final accessible =
        MediaQuery.maybeOf(context)?.accessibleNavigation ?? false;
    final duration = noticeHoldFor(notice, accessible: accessible);
    final theme = Theme.of(context);
    final l10n = context.l10n;

    final (tint, icon, semanticsLabel) = switch (notice) {
      NoticeSuccess() => (
        theme.palette.noticeMint,
        Icons.check_circle_outline_rounded,
        l10n.common_noticeSuccessAnnouncement(notice.message),
      ),
      NoticeInfo() => (
        theme.palette.noticeInfo,
        Icons.info_outline_rounded,
        l10n.common_noticeInfoAnnouncement(notice.message),
      ),
      NoticeError() => (
        theme.palette.noticeRed,
        Icons.error_outline_rounded,
        l10n.common_noticeErrorAnnouncement(notice.message),
      ),
    };

    unawaited(switch (notice) {
      NoticeError() => HapticFeedback.mediumImpact(),
      NoticeSuccess() || NoticeInfo() => HapticFeedback.lightImpact(),
    });

    _currentEntry
      ?..remove()
      ..dispose();
    _currentEntry = null;

    late final OverlayEntry entry;
    var dismissed = false;

    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      entry
        ..remove()
        ..dispose();
      if (_currentEntry != entry) return;
      _currentEntry = null;
      _currentNotice = null;
      final next = _pending;
      _pending = null;
      if (next != null) _show(next);
    }

    entry = OverlayEntry(
      builder: (_) => _TopNotice(
        tint: tint,
        icon: icon,
        message: notice.message,
        semanticsLabel: semanticsLabel,
        action: notice.action,
        duration: duration,
        showClose: accessible,
        onDismiss: dismiss,
      ),
    );

    _currentEntry = entry;
    _currentNotice = notice;
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _TopNotice extends StatefulWidget {
  const _TopNotice({
    required this.tint,
    required this.icon,
    required this.message,
    required this.semanticsLabel,
    required this.action,
    required this.duration,
    required this.showClose,
    required this.onDismiss,
  });

  final Color tint;
  final IconData icon;
  final String message;

  /// The kind-prefixed message VoiceOver reads for the live region.
  final String semanticsLabel;
  final NoticeAction? action;
  final Duration duration;

  /// The design has no close button. It renders only under accessible
  /// navigation, where swipe-up is not a usable dismiss affordance.
  final bool showClose;
  final VoidCallback onDismiss;

  @override
  State<_TopNotice> createState() => _TopNoticeState();
}

class _TopNoticeState extends State<_TopNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final CurvedAnimation _slideCurve;
  late final CurvedAnimation _fade;

  // A pausable hold, not a debounce; cancelled with the banner.
  Timer? _hold;
  late Duration _remaining = widget.duration;
  final Stopwatch _elapsed = Stopwatch();
  int _pointersDown = 0;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppAnimationDurations.banner,
    );
    // Held rather than inlined so both can be disposed: a `CurvedAnimation`
    // registers a status listener on its parent, and only `dispose()` removes
    // it. Its sibling `fade_in_item.dart` already does this.
    _slideCurve = CurvedAnimation(
      parent: _controller,
      curve: AppAnimationCurves.entrance,
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(_slideCurve);

    _controller.forward();
    _startHold();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _slideCurve.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startHold() {
    _elapsed
      ..reset()
      ..start();
    _hold = Timer(_remaining, _dismiss);
  }

  void _pauseHold(PointerDownEvent _) {
    _pointersDown++;
    if (_pointersDown > 1 || _dismissing) return;
    _hold?.cancel();
    _hold = null;
    _elapsed.stop();
    _remaining -= _elapsed.elapsed;
    if (_remaining < Duration.zero) _remaining = Duration.zero;
  }

  void _resumeHold(PointerEvent _) {
    if (_pointersDown > 0) _pointersDown--;
    if (_pointersDown == 0 && !_dismissing && mounted) _startHold();
  }

  void _dismiss() {
    if (!mounted || _dismissing) return;
    _dismissing = true;
    _hold?.cancel();
    _hold = null;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  Widget _buildCard(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        boxShadow: theme.cardStyle.noticeShadow,
      ),
      child: Material(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(AppRadius.r16),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            15,
            13,
            widget.showClose ? AppSpacing.sp4 : 15,
            13,
          ),
          child: _buildRow(context, scheme),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, ColorScheme scheme) {
    return Row(
      children: [
        Icon(
          widget.icon,
          key: const ValueKey('notice-icon'),
          color: widget.tint,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ExcludeSemantics(
            child: Text(
              widget.message,
              style: TextStyle(
                fontFamily: kFontSans,
                color: scheme.onInverseSurface,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        if (widget.action != null) ...[
          const SizedBox(width: AppSpacing.sp8),
          TextButton(
            onPressed: () {
              final action = widget.action!;
              _dismiss();
              unawaited(Future<void>.sync(action.onPressed));
            },
            style: TextButton.styleFrom(
              foregroundColor: scheme.onInverseSurface,
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp8),
            ),
            child: Text(
              widget.action!.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        if (widget.showClose) ...[
          const SizedBox(width: AppSpacing.sp4),
          // A real IconButton for the 48px tap target plus
          // tooltip/semantics, not a bare gesture icon.
          IconButton(
            onPressed: _dismiss,
            tooltip: context.l10n.common_close,
            icon: Icon(Icons.close, color: scheme.onInverseSurface, size: 20),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pad left/right too so a landscape notch/camera cutout doesn't cover the text.
    final padding = MediaQuery.of(context).padding;
    // Push the banner toward the side with more safe-area room, away from the notch.
    final alignment = padding.left > padding.right
        ? Alignment.centerRight
        : padding.right > padding.left
        ? Alignment.centerLeft
        : Alignment.center;
    final theme = Theme.of(context);
    return Positioned(
      // padding.top already supplies the real status bar — never a literal 56.
      top: padding.top + AppSpacing.sp16,
      left: padding.left + 14,
      right: padding.right + 14,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          // Cap the width so a landscape/tablet banner reads as a tidy card, not full-width.
          child: Align(
            alignment: alignment,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Semantics(
                liveRegion: true,
                label: widget.semanticsLabel,
                // Swipe up to dismiss. Dismissible already handles the
                // animation, so we just remove the entry directly.
                child: Dismissible(
                  key: const ValueKey('app-notice-banner'),
                  direction: DismissDirection.up,
                  onDismissed: (_) => widget.onDismiss(),
                  child: Listener(
                    onPointerDown: _pauseHold,
                    onPointerUp: _resumeHold,
                    onPointerCancel: _resumeHold,
                    child: _buildCard(context, theme),
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
