import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';

/// Reads and writes `users/{docId}/fcmTokens/{token}` device-token docs.
/// Registration failures propagate so the controller can retry without caching success.
class FcmTokenRepository {
  FcmTokenRepository({
    required FirebaseFirestore firestore,
    AppLogger? logger,
    SessionFence? session,
  }) : _firestore = firestore,
       _session = session,
       _logger = logger ?? AppLogger();

  final FirebaseFirestore _firestore;
  final AppLogger _logger;
  final SessionFence? _session;

  DocumentReference<Map<String, dynamic>> _tokenDoc(
    String userDocId,
    String token,
  ) => _firestore
      .collection('users')
      .doc(userDocId)
      .collection('fcmTokens')
      .doc(token);

  /// Upserts a device token, setting `createdAt` only on the first write.
  /// This is a plain get-then-set rather than a transaction, because
  /// concurrent transactions crash the cloud_firestore iOS plugin.
  Future<void> upsertToken({
    required String userDocId,
    required String token,
    required String platform,
    required String locale,
    required String uid,
  }) async {
    try {
      final lease = _session?.capture();
      if (_session != null && (lease == null || lease.uid != uid)) return;
      final epoch = Platform.isIOS && lease != null
          ? await appGroupMirrorStore.ensureOwner(uid, () => lease.isCurrent)
          : null;
      if (lease != null && !lease.isCurrent) return;
      final ref = _tokenDoc(userDocId, token);
      final snap = await ref.get();
      if (lease != null && !lease.isCurrent) return;
      final data = <String, dynamic>{
        'platform': platform,
        'locale': locale,
        'uid': uid,
        'sessionEpoch': ?epoch,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!snap.exists) 'createdAt': FieldValue.serverTimestamp(),
      };
      await ref.set(data, SetOptions(merge: true));
    } catch (e, st) {
      _logger.warn('FCM upsertToken failed', e, st);
      rethrow;
    }
  }

  Future<void> deleteToken({
    required String userDocId,
    required String token,
  }) async {
    try {
      await _tokenDoc(userDocId, token).delete();
    } catch (e, st) {
      _logger.warn('FCM deleteToken failed', e, st);
    }
  }
}
