import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';

/// Unposted crew-note drafts by appointment id, for the signed-in user only.
///
/// Outside `EventDetailsState` on purpose: that controller autoDisposes with
/// the sheet, and the draft exists to survive a scrim tap or drag dismiss.
class FieldNoteDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    // Rebuilds empty on a uid change, so one tech's draft never pre-fills the
    // next person's compose box on a shared phone.
    ref.watch(authUidProvider.select((uid) => uid.value));
    return const {};
  }

  String draftFor(String appointmentId) => state[appointmentId] ?? '';

  void set(String appointmentId, String text) {
    if (text.isEmpty) return clear(appointmentId);
    state = {...state, appointmentId: text};
  }

  void clear(String appointmentId) {
    if (!state.containsKey(appointmentId)) return;
    state = {...state}..remove(appointmentId);
  }
}

final fieldNoteDraftsProvider =
    NotifierProvider<FieldNoteDrafts, Map<String, String>>(FieldNoteDrafts.new);
