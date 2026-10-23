import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// How often a watched review re-issues its `endTime < now` boundary.
const Duration kOverdueReviewRefresh = Duration(minutes: 15);

/// Injectable clock for the review boundary.
final overdueReviewClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// [now] floored to its quarter hour, so every open inside one quarter issues
/// the SAME `endTime < boundary` query and resumes the SDK's cached target.
/// Floored on the epoch, not rebuilt from wall-clock fields: in the repeated
/// fall-back hour `DateTime(y, m, d, h, min)` resolves to the EARLIER 1 a.m.,
/// an hour behind `now`, and the refresh timer re-fires at once all hour.
DateTime overdueReviewBoundary(DateTime now) {
  final ms = now.millisecondsSinceEpoch;
  final step = kOverdueReviewRefresh.inMilliseconds;
  return DateTime.fromMillisecondsSinceEpoch(ms - ms % step);
}

/// Every open job whose end has passed, oldest first — shared by the review
/// screen and the drawer count so the two cannot disagree. Admin-only query.
final overdueOpenJobsProvider =
    StreamProvider.autoDispose<List<AppointmentRecord>>((ref) {
      final clock = ref.watch(overdueReviewClockProvider)();
      final now = overdueReviewBoundary(clock);
      // Re-issued AT the next boundary, so the lag stays under one quarter.
      final refresh = Timer(
        now.add(kOverdueReviewRefresh).difference(clock),
        ref.invalidateSelf,
      );
      ref.onDispose(refresh.cancel);
      return streamForUid(ref, (uid) {
        if (uid == null) return Stream.value(const <AppointmentRecord>[]);
        // Held until the next boundary refresh, so a cold drawer open reuses it.
        keepWarmWithGrace(ref, grace: kOverdueReviewRefresh);
        return ref.watch(appointmentsRepositoryProvider).watchOverdueOpen(now);
      });
    });
