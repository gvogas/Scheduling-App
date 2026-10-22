import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Injectable wall clock shared by display-only appointment transitions.
final presentationClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Refreshes visible time-derived content at minute boundaries without database reads.
final presentationTimeProvider = Provider.autoDispose<DateTime>((ref) {
  final now = ref.watch(presentationClockProvider)();
  final remaining = Duration.microsecondsPerMinute -
      now.microsecondsSinceEpoch % Duration.microsecondsPerMinute;
  final timer = Timer(
    Duration(microseconds: remaining) + const Duration(milliseconds: 1),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return now;
});
