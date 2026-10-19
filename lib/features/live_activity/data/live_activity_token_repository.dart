import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/live_activity/domain/live_activity_token.dart';

/// Reads and writes `users/{docId}/liveActivityTokens/{id}` APNs token docs
/// for starting, updating, and ending cards. Logs and swallows failures.
class LiveActivityTokenRepository {
  LiveActivityTokenRepository({
    required FirebaseFirestore firestore,
    AppLogger? logger,
    SessionFence? session,
  }) : _firestore = firestore,
       _logger = logger ?? AppLogger(),
       _session = session;

  final FirebaseFirestore _firestore;
  final AppLogger _logger;
  final SessionFence? _session;

  DocumentReference<Map<String, dynamic>> _tokenDoc(
    String userDocId,
    String docId,
  ) => _firestore
      .collection('users')
      .doc(userDocId)
      .collection('liveActivityTokens')
      .doc(docId);

  /// Upserts a Live Activity token, setting `createdAt` only on the first
  /// write. This is a plain get-then-set rather than a transaction, because
  /// concurrent transactions crash the cloud_firestore iOS plugin.
  Future<void> upsertToken({
    required String userDocId,
    required String docId,
    required String token,
    required LiveActivityTokenKind kind,
    required String locale,
    required String uid,
    required DateTime expiresAt,
  }) async {
    try {
      final lease = _session?.capture();
      if (_session != null && (lease == null || lease.uid != uid)) return;
      final ref = _tokenDoc(userDocId, docId);
      final snap = await ref.get();
      if (lease != null && !lease.isCurrent) return;
      final data = <String, dynamic>{
        'token': token,
        'kind': kind.raw,
        'employeeDocId': userDocId,
        'platform': 'ios',
        'locale': locale,
        'uid': uid,
        'expiresAt': Timestamp.fromDate(expiresAt),
        'updatedAt': FieldValue.serverTimestamp(),
        if (!snap.exists) 'createdAt': FieldValue.serverTimestamp(),
      };
      await ref.set(data, SetOptions(merge: true));
    } catch (e, st) {
      _logger.warn('LIVE-ACT upsertToken failed', e, st);
    }
  }

  /// Ceiling on the opt-out sweep below, matching every other bounded read in
  /// the repositories. In practice this is devices-per-user (1-3) against a
  /// 3-day TTL, so it is a tail guard rather than a live cost — but this was
  /// the last unbounded query left in any repository here, which made the
  /// "every query names a ceiling" invariant simply untrue.
  static const int _deviceTokenScanLimit = 50;

  /// Deletes every row of [kind] without needing the token value — the
  /// push-to-start doc id IS the token, and a device that opted out may
  /// never have had one to look up.
  Future<void> deleteTokensOfKind({
    required String userDocId,
    required LiveActivityTokenKind kind,
  }) async {
    try {
      final snap = await _firestore
          .collection('users')
          .doc(userDocId)
          .collection('liveActivityTokens')
          .where('kind', isEqualTo: kind.raw)
          .limit(_deviceTokenScanLimit)
          .get();
      if (snap.docs.length == _deviceTokenScanLimit) {
        _logger.warn(
          'LIVE-ACT deleteTokensOfKind hit the scan cap; '
          'some rows survive until their TTL',
        );
      }
      await Future.wait(snap.docs.map((doc) => doc.reference.delete()));
    } catch (e, st) {
      _logger.warn('LIVE-ACT deleteTokensOfKind failed', e, st);
    }
  }

  Future<void> deleteToken({
    required String userDocId,
    required String docId,
  }) async {
    try {
      await _tokenDoc(userDocId, docId).delete();
    } catch (e, st) {
      _logger.warn('LIVE-ACT deleteToken failed', e, st);
    }
  }
}
