import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/features/calendar/domain/models/photo_upload_expiry.dart';

class PhotoUploadFailure {
  const PhotoUploadFailure({
    required this.appointmentId,
    this.failedCount = 0,
    this.tooLargeFileNames = const [],
  });

  final String appointmentId;
  final int failedCount;
  final List<String> tooLargeFileNames;
}

class PhotoUploadNotifier {
  PhotoUploadNotifier();

  final ValueNotifier<PhotoUploadFailure?> latestFailure = ValueNotifier(null);
  final ValueNotifier<List<PhotoUploadExpiry>> expired = ValueNotifier(
    const [],
  );

  /// Photos still sitting in the offline queue, per appointment id.
  final ValueNotifier<Map<String, int>> pending = ValueNotifier(const {});

  /// Per-appointment failures. A ValueNotifier, not a bare Map: the photos
  /// section gates on `failedCount`, so a batch that failed with nothing
  /// uploaded left the section - and its own error tile - unrendered.
  final ValueNotifier<Map<String, PhotoUploadFailure>> failures = ValueNotifier(
    const {},
  );

  void reportFailure(
    String appointmentId, {
    int failedCount = 0,
    List<String> tooLargeFileNames = const [],
  }) {
    if (failedCount == 0 && tooLargeFileNames.isEmpty) return;
    final failure = PhotoUploadFailure(
      appointmentId: appointmentId,
      failedCount: failedCount,
      tooLargeFileNames: List.unmodifiable(tooLargeFileNames),
    );
    failures.value = {...failures.value, appointmentId: failure};
    latestFailure.value = failure;
  }

  /// Replaces the whole queue snapshot.
  void reportPending(Map<String, int> counts) {
    if (mapEquals(pending.value, counts)) return;
    pending.value = Map.unmodifiable(counts);
  }

  PhotoUploadFailure? failureFor(String appointmentId) =>
      failures.value[appointmentId];

  /// How many photos are still queued for [appointmentId].
  int pendingFor(String appointmentId) => pending.value[appointmentId] ?? 0;

  void clearFailure(String appointmentId) {
    if (!failures.value.containsKey(appointmentId)) return;
    failures.value = {...failures.value}..remove(appointmentId);
  }

  void dispose() {
    latestFailure.dispose();
    expired.dispose();
    pending.dispose();
    failures.dispose();
  }
}

final photoUploadNotifierProvider = Provider<PhotoUploadNotifier>((ref) {
  final notifier = PhotoUploadNotifier();
  ref.onDispose(notifier.dispose);
  return notifier;
});
