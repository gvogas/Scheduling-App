import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/utils/date_utils_helper.dart';

/// Injectable clock for the day boundary.
final currentDayClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Current local day, re-emitted just after midnight and on a resume that
/// crosses it.
final currentDayProvider = Provider<DateTime>((ref) {
  final clock = ref.watch(currentDayClockProvider);
  final now = clock();
  final today = now.dateOnly;
  final nextMidnight = DateTime(today.year, today.month, today.day + 1);
  // One second past midnight so rebuild can't see 23:59:59.999.
  final timer = Timer(
    nextMidnight.difference(now) + const Duration(seconds: 1),
    ref.invalidateSelf,
  );
  // The timer's monotonic clock stops while the phone sleeps.
  final lifecycle = AppLifecycleListener(
    onResume: () {
      if (clock().dateOnly != today) ref.invalidateSelf();
    },
  );
  ref.onDispose(() {
    timer.cancel();
    lifecycle.dispose();
  });
  return today;
});
