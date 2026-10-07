import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/feature_tour/domain/legacy_tour_steps.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key: the step ids this device has already been shown.
const _keyTourSeenSteps = 'tour_seen_steps';

/// The old key, one entry per SCOPE. Read exactly once, by the migration.
const _keyTourSeenTabs = 'tour_seen_tabs';

/// Tracks which tour STEPS this device has already seen. Await `ready` before
/// reading it, or a cold start can replay steps that were already shown.
///
/// Per STEP, not per screen: a release that adds a step to a screen someone
/// already toured has to be able to show them that one step. The scope flag
/// this replaced could not, and a tour that dropped a step because its target
/// hadn't rendered still marked the whole scope seen, losing it for good.
class TourSeenController extends Notifier<Set<TourStepId>> {
  late final Future<void> ready = _load();

  @override
  Set<TourStepId> build() {
    unawaited(ready);
    return const {};
  }

  Future<void> _load() async {
    final logger = ref.read(loggerProvider);
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_keyTourSeenSteps);
      if (stored != null) {
        // Lookup-based, so a name that no longer maps to a step is dropped
        // rather than resurrecting a dead one.
        final byName = TourStepId.values.asNameMap();
        state = {for (final name in stored) ?byName[name]};
        return;
      }
      // First run on this build: seed from the per-scope flags. The ABSENCE of
      // the step key is the marker, so a resetAll writing an empty list can
      // never re-trigger this.
      final legacy = prefs.getStringList(_keyTourSeenTabs) ?? const <String>[];
      state = {for (final key in legacy) ...?kLegacyTourSteps[key]};
      await _save();
    } catch (e, st) {
      // This is unawaited from build(), so on failure we just fall back to
      // treating the device like a fresh install.
      logger.warn('TOUR read seen flags failed', e, st);
    }
  }

  /// The steps seen so far, readable after an await without touching `ref`.
  Set<TourStepId> get seen => state;

  /// Marks the steps that actually ran — never a whole scope. A step whose
  /// target wasn't rendered has not been seen and must be offered again.
  Future<void> markSteps(Iterable<TourStepId> ids) async {
    final next = {...state, ...ids};
    if (next.length == state.length) return;
    state = next;
    await _save();
  }

  Future<void> resetAll() async {
    state = const {};
    await _save();
  }

  /// Saves aren't serialized, but that's fine since writers never overlap.
  Future<void> _save() async {
    final logger = ref.read(loggerProvider);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_keyTourSeenSteps, [
        for (final id in state) id.name,
      ]);
    } catch (e, st) {
      logger.warn('TOUR write seen flags failed', e, st);
    }
  }
}

final tourSeenProvider = NotifierProvider<TourSeenController, Set<TourStepId>>(
  TourSeenController.new,
);
