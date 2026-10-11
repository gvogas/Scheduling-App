import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';

/// Outcome of a presence write. Lets the controller distinguish a transient
/// failure from a rules denial.
enum PresenceWriteResult { ok, failed, denied }

/// Reads and writes the single `users/{docId}/presence/location` doc that
/// feeds the server's travel-time "leave now" reminders. Logs and swallows
/// failures so a presence write never breaks a flow.
class PresenceRepository {
  PresenceRepository({required FirebaseFirestore firestore, AppLogger? logger})
    : _firestore = firestore,
      _logger = logger ?? AppLogger();

  final FirebaseFirestore _firestore;
  final AppLogger _logger;

  DocumentReference<Map<String, dynamic>> _locationDoc(String userDocId) =>
      _firestore
          .collection('users')
          .doc(userDocId)
          .collection('presence')
          .doc('location');

  /// Upserts the device's last fix with a server-timestamp `updatedAt`. Never
  /// throws — the caller uses the returned result to avoid advancing the
  /// throttle clock on failure, and to stop tracking entirely on denial.
  Future<PresenceWriteResult> upsertLocation({
    required String userDocId,
    required String uid,
    required double lat,
    required double lng,
  }) async {
    try {
      await _locationDoc(userDocId).set(<String, dynamic>{
        'lat': lat,
        'lng': lng,
        'uid': uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return PresenceWriteResult.ok;
    } on FirebaseException catch (e, st) {
      _logger.warn('PRESENCE upsertLocation failed', e, st);
      return e.code == 'permission-denied'
          ? PresenceWriteResult.denied
          : PresenceWriteResult.failed;
    } catch (e, st) {
      _logger.warn('PRESENCE upsertLocation failed', e, st);
      return PresenceWriteResult.failed;
    }
  }

  /// Best-effort delete on sign-out — privacy: no stale coordinates left
  /// behind after leaving.
  /// Returns whether the stored fix is actually gone.
  ///
  /// The teardown paths ignore the result — a failed delete there is logged and
  /// nothing more. The Location sharing screen does NOT: it tells the person
  /// their position was erased, and saying that when the delete was refused is
  /// a false statement on the one screen that exists to be trusted.
  Future<bool> deleteLocation({required String userDocId}) async {
    try {
      await _locationDoc(userDocId).delete();
      return true;
    } catch (e, st) {
      _logger.warn('PRESENCE deleteLocation failed', e, st);
      return false;
    }
  }

  Stream<PresenceFix?> watchLocation({required String userDocId}) =>
      _locationDoc(
        userDocId,
      ).snapshots().map((doc) => _fixFrom(userDocId, doc.data()));

  /// The one owner of "what a stored presence doc means"; null when the doc is
  /// missing or carries no usable pair.
  static PresenceFix? _fixFrom(String userDocId, Map<String, dynamic>? data) {
    if (data == null) return null;
    final rawLat = data['lat'];
    final rawLng = data['lng'];
    if (rawLat is! num || rawLng is! num) return null;
    return PresenceFix(
      userDocId: userDocId,
      lat: rawLat.toDouble(),
      lng: rawLng.toDouble(),
      updatedAt: firestoreDateTime(data['updatedAt']),
    );
  }

  /// Live feed of every staff member's last-known fix, for the admin map;
  /// unlike the write paths above, stream errors propagate to the listener.
  Stream<List<PresenceFix>> watchAllPresence() => retryStream(
    () => _firestore
        .collectionGroup('presence')
        // Bounded: this is a live listener over a collection group that grows
        // with the roster, and the map only ever renders one pin per user.
        .limit(_presenceStreamLimit)
        // Needs the COLLECTION_GROUP `presence.updatedAt` override in `firestore.indexes.json`.
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map(_toFixes),
  );

  static const int _presenceStreamLimit = 1000;

  /// One malformed doc must not drop the whole map — skip it and keep going.
  List<PresenceFix> _toFixes(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (snapshot.docs.length >= _presenceStreamLimit) {
      _logger.warn(
        'PRESENCE watchAllPresence hit the $_presenceStreamLimit-doc cap - '
        'the oldest fixes are not on the map',
      );
    }
    final fixes = <PresenceFix>[];
    for (final doc in snapshot.docs) {
      final userDocId = doc.reference.parent.parent?.id;
      if (userDocId == null) continue;
      final fix = _fixFrom(userDocId, doc.data());
      if (fix != null) fixes.add(fix);
    }
    return fixes;
  }
}
