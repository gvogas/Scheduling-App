import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/feature_tour/application/tour_seen_store.dart';
import 'package:scheduling/features/feature_tour/domain/tour_definitions.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:showcaseview/showcaseview.dart';

/// Cache extent a scrolling tour host should give its list, so below-fold
/// steps are actually built. `isTargetRendered` can only find a target the
/// list has built, and it drops the step silently otherwise — which reads as
/// "that step just doesn't exist", not as a bug.
const ScrollCacheExtent kTourScrollCacheExtent = ScrollCacheExtent.pixels(3000);

/// Runs one scope's feature tour — registers the showcase scope, auto-starts
/// once ready, and marks the steps that RAN seen when the tour finishes. A
/// scope is a whole screen or one of the sheets that carries a walkthrough.
///
/// Only unseen steps are offered, so a release that adds a step to a screen
/// someone already toured shows them that one step.
class FeatureTourHost extends ConsumerStatefulWidget {
  const FeatureTourHost({
    required this.scope,
    required this.isAdmin,
    required this.stepKeys,
    required this.child,
    this.ready = true,
    this.autoScroll = false,
    super.key,
  });

  final TourScope scope;
  final bool isAdmin;

  /// Gate for surfaces whose content loads asynchronously — pass `!isLoading`
  /// so the tour doesn't end up targeting skeleton placeholders.
  final bool ready;

  /// Keys for each step — an id that's missing or not yet rendered is just skipped.
  final Map<TourStepId, GlobalKey> stepKeys;

  /// Enable auto-scroll for tabs with below-fold targets (e.g., Settings).
  final bool autoScroll;

  final Widget child;

  @override
  ConsumerState<FeatureTourHost> createState() => _FeatureTourHostState();
}

class _FeatureTourHostState extends ConsumerState<FeatureTourHost> {
  bool _started = false;
  bool _wasVisible = false;

  /// Held as a field, and assigned EAGERLY in [initState] rather than as a
  /// lazy `late final` initializer: [dispose] logs through it, and `ref.read`
  /// throws once the consumer is unmounted (Riverpod 3) — which `dispose`
  /// always is, so a lazy first touch there would throw exactly where this
  /// exists to avoid it. Riverpod's own error text prescribes this: "save the
  /// provider state in a field of your State class."
  late final AppLogger _logger;

  /// True while the tour is actually running, from startShowCase until
  /// onFinish/onDismiss. Gates markSeen so we never mark a tour seen that
  /// didn't actually run.
  bool _tourRunning = false;

  String get _scope => widget.scope.storageKey;

  /// The ids handed to startShowCase, so only they are marked seen. A step
  /// dropped by isTargetRendered was never shown and must stay unseen.
  List<TourStepId> _runningIds = const [];

  /// This scope's catalog minus what the device has already been shown.
  List<TourStepId> _pendingSteps(Set<TourStepId> seen) => [
    for (final id in tourStepsFor(widget.scope, isAdmin: widget.isAdmin))
      if (!seen.contains(id)) id,
  ];

  /// Captured each build. ModalRoute.of cannot be called from
  /// a post-frame callback without registering a spurious dependency, so
  /// the one-shot recheck reads this field instead.
  ModalRoute<Object?>? _route;

  /// A hub tab is visible when the shell shows it and nothing covers the hub;
  /// a pushed destination and a create-flow sheet are both visible when their
  /// own route is on top — a
  /// ModalBottomSheetRoute IS a ModalRoute, so they share one branch. The
  /// sealed type picks the mode — NOT a null HubShellScope, which also
  /// describes a hub screen hosted standalone in a test, where "never start"
  /// must be preserved.
  bool _isVisible(BuildContext context) {
    switch (widget.scope) {
      case DestinationTour(destination: final HubTab tab):
        _route = ModalRoute.of(context);
        return HubShellScope.currentOf(context) == tab &&
            (_route?.isCurrent ?? true);
      case DestinationTour() || FormTour():
        // Depends on the route's _ModalScopeStatus, which notifies on
        // isCurrent changes — this dependency is the only rebuild trigger
        // route mode has, and it re-opens the gate when a route above pops.
        final route = ModalRoute.of(context);
        _route = route;
        return route?.isCurrent ?? false;
    }
  }

  /// Waits out the host route's entrance and any page still sliding off it,
  /// so showcase measures settled target positions.
  Future<void> _routeTransitionSettled() async {
    await _animationSettled(_route?.animation);
    await _animationSettled(_route?.secondaryAnimation);
  }

  static Future<void> _animationSettled(Animation<double>? animation) async {
    if (animation == null || !animation.isAnimating) return;
    final completer = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return;
      }
      animation.removeStatusListener(onStatus);
      if (!completer.isCompleted) completer.complete();
    }

    animation.addStatusListener(onStatus);
    await completer.future;
  }

  @override
  void initState() {
    super.initState();
    _logger = ref.read(loggerProvider);
    // register() replaces any existing scope with the same name, so this is
    // safe to call again on an identity rebuild.
    ShowcaseView.register(
      scope: _scope,
      onFinish: _onTourEnd,
      onDismiss: (_) => _onTourEnd(),
      enableAutoScroll: widget.autoScroll,
    );
  }

  @override
  void dispose() {
    // No unregister here — on an identity rebuild, the new widget's initState
    // runs before this dispose does.
    if (_tourRunning) {
      _tourRunning = false; // Don't mark seen (unfinished tour).
      _runningIds = const [];
      try {
        ShowcaseView.getNamed(_scope).dismiss();
      } catch (e, st) {
        _logger.warn('TOUR dispose dismiss failed', e, st);
      }
    }
    super.dispose();
  }

  /// Finish and dismiss both end the tour, but only a tour that actually ran
  /// marks its steps seen.
  void _onTourEnd() {
    if (!_tourRunning) return;
    _tourRunning = false;
    _markRanStepsSeen();
  }

  void _markRanStepsSeen() {
    unawaited(ref.read(tourSeenProvider.notifier).markSteps(_runningIds));
    _runningIds = const [];
  }

  @override
  Widget build(BuildContext context) {
    final seen = ref.watch(tourSeenProvider);
    final visible = _isVisible(context);
    if (_wasVisible && !visible && _tourRunning) {
      // Dismiss post-frame when tab switched away mid-tour.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_tourRunning) return;
        try {
          ShowcaseView.getNamed(_scope).dismiss();
        } catch (e, st) {
          _tourRunning = false;
          _started = false;
          _logger.warn('TOUR dismiss failed', e, st);
        }
      });
    }
    _wasVisible = visible;
    if (_pendingSteps(seen).isEmpty) {
      // Re-arm so a Settings "replay" reset can start the tour again.
      _started = false;
    } else if (visible && widget.ready && !_started) {
      _started = true;
      unawaited(_start());
    }
    return widget.child;
  }

  Future<void> _start() async {
    // Wait for ready — we never want to act on the optimistic empty default.
    await ref.read(tourSeenProvider.notifier).ready;
    if (!mounted) return;
    if (_pendingSteps(ref.read(tourSeenProvider)).isEmpty) return;
    await _routeTransitionSettled();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Reset _started when the destination's been navigated away from or its
      // host stopped being ready, so we don't get stuck and can retry later.
      final stillVisible = switch (widget.scope) {
        DestinationTour(destination: final HubTab tab) =>
          HubShellScope.readCurrentOf(context) == tab &&
              (_route?.isCurrent ?? true),
        DestinationTour() || FormTour() => _route?.isCurrent ?? false,
      };
      if (!stillVisible || !widget.ready) {
        _started = false;
        return;
      }
      final steps = _pendingSteps(ref.read(tourSeenProvider));
      try {
        final showcaseView = ShowcaseView.getNamed(_scope);
        // showcaseview 5.x never forwards key to Element; use isTargetRendered.
        final running = <TourStepId>[];
        final keys = <GlobalKey>[];
        for (final id in steps) {
          if (widget.stepKeys[id] case final key?
              when showcaseView.isTargetRendered(key)) {
            running.add(id);
            keys.add(key);
          }
        }
        if (keys.isEmpty) {
          // Nothing rendered for this layout, role or job state. Mark NOTHING —
          // these steps haven't been seen, and the next visit retries them.
          return;
        }
        // A form sheet may autofocus its first field, and the keyboard then
        // covers the lower half of every target. Harmless on the screen
        // tours — none of them autofocus.
        FocusManager.instance.primaryFocus?.unfocus();
        _runningIds = running;
        _tourRunning = true;
        showcaseView.startShowCase(keys);
      } catch (e, st) {
        // getNamed throws if the scope's already gone — don't let that crash the tab.
        _tourRunning = false;
        _started = false;
        _runningIds = const [];
        _logger.warn('TOUR start failed', e, st);
      }
    });
  }
}
