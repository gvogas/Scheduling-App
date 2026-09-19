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

/// Every open job whose end has passed, oldest first — shared by the review
/// screen and the drawer count so the two cannot disagree. Admin-only query.
final overdueOpenJobsProvider =
    StreamProvider.autoDispose<List<AppointmentRecord>>((ref) {
      final now = ref.watch(overdueReviewClockProvider)();
      final refresh = Timer(kOverdueReviewRefresh, ref.invalidateSelf);
      ref.onDispose(refresh.cancel);
      return streamForUid(ref, (uid) {
        if (uid == null) return Stream.value(const <AppointmentRecord>[]);
        // Held until the next boundary refresh, so a cold drawer open reuses it.
        keepWarmWithGrace(ref, grace: kOverdueReviewRefresh);
        return ref.watch(appointmentsRepositoryProvider).watchOverdueOpen(now);
      });
    });
