// Mocktail-style stubs of sealed Firestore types (the canonical workaround
// for testing repos without fake_cloud_firestore).
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/features/notifications/data/fcm_token_repository.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockDoc extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _MockSnap extends Mock
    implements DocumentSnapshot<Map<String, dynamic>> {}

void main() {
  late _MockFirestore firestore;
  late _MockCollection usersCol;
  late _MockDoc userDoc;
  late _MockCollection tokensCol;
  late _MockDoc tokenDoc;
  late _MockSnap tokenSnap;
  late List<Map<String, dynamic>> setData;

  setUpAll(() {
    registerFallbackValue(SetOptions(merge: true));
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    firestore = _MockFirestore();
    usersCol = _MockCollection();
    userDoc = _MockDoc();
    tokensCol = _MockCollection();
    tokenDoc = _MockDoc();
    tokenSnap = _MockSnap();
    setData = [];
    when(() => firestore.collection('users')).thenReturn(usersCol);
    when(() => usersCol.doc('u1')).thenReturn(userDoc);
    when(() => userDoc.collection('fcmTokens')).thenReturn(tokensCol);
    when(() => tokensCol.doc('tok')).thenReturn(tokenDoc);
    when(() => tokenDoc.delete()).thenAnswer((_) async {});
    // upsertToken is a deliberate plain get-then-set (NOT a transaction — see
    // the repo's plugin-crash note).
    when(() => tokenDoc.get()).thenAnswer((_) async => tokenSnap);
    // Record the written payload here (rather than verify(captureAny())) so the
    // assertion doesn't hinge on mocktail's concrete-vs-matcher arg mixing.
    when(() => tokenDoc.set(any(), any())).thenAnswer((inv) async {
      setData.add(
        (inv.positionalArguments.first as Map).cast<String, dynamic>(),
      );
    });
  });

  test(
    'exit during a held token lookup prevents the registration write',
    () async {
      final read = Completer<DocumentSnapshot<Map<String, dynamic>>>();
      final session = SessionFence(readUid: () => 'uid1');
      when(() => tokenDoc.get()).thenAnswer((_) => read.future);
      final repo = FcmTokenRepository(firestore: firestore, session: session);
      final pending = repo.upsertToken(
        userDocId: 'u1',
        token: 'tok',
        platform: 'ios',
        locale: 'en',
        uid: 'uid1',
      );
      session.beginExit();
      read.complete(tokenSnap);
      await pending;
      expect(setData, isEmpty);
    },
  );

  test(
    'a token refresh with an obsolete owner does not read or write Firestore',
    () async {
      final session = SessionFence(readUid: () => 'uid2');
      final repo = FcmTokenRepository(firestore: firestore, session: session);
      await repo.upsertToken(
        userDocId: 'u1',
        token: 'tok',
        platform: 'ios',
        locale: 'en',
        uid: 'uid1',
      );
      expect(setData, isEmpty);
      verifyNever(() => tokenDoc.get());
    },
  );

  test(
    'upsertToken on a new doc stamps createdAt (rule-allowed field set)',
    () async {
      when(() => tokenSnap.exists).thenReturn(false);
      final repo = FcmTokenRepository(firestore: firestore);
      await repo.upsertToken(
        userDocId: 'u1',
        token: 'tok',
        platform: 'android',
        locale: 'fr',
        uid: 'uid1',
      );

      final captured = setData.single;
      expect(captured.keys.toSet(), {
        'platform',
        'locale',
        'uid',
        'createdAt',
        'updatedAt',
      });
      expect(captured['platform'], 'android');
      expect(captured['locale'], 'fr');
      expect(captured['uid'], 'uid1');
    },
  );

  test(
    'upsertToken on an existing doc preserves createdAt (omits it)',
    () async {
      when(() => tokenSnap.exists).thenReturn(true);
      final repo = FcmTokenRepository(firestore: firestore);
      await repo.upsertToken(
        userDocId: 'u1',
        token: 'tok',
        platform: 'ios',
        locale: 'en',
        uid: 'uid1',
      );

      final captured = setData.single;
      // A refresh must not re-stamp createdAt, but still refreshes updatedAt and
      // stays within the rule allowlist (subset is permitted by hasOnly).
      expect(captured.containsKey('createdAt'), isFalse);
      expect(captured.keys.toSet(), {'platform', 'locale', 'uid', 'updatedAt'});
    },
  );

  test('upsertToken reports a write failure to its retrying caller', () async {
    when(() => tokenSnap.exists).thenReturn(false);
    when(() => tokenDoc.set(any(), any())).thenThrow(Exception('offline'));
    final repo = FcmTokenRepository(firestore: firestore);
    await expectLater(
      repo.upsertToken(
        userDocId: 'u1',
        token: 'tok',
        platform: 'ios',
        locale: 'en',
        uid: 'uid1',
      ),
      throwsException,
    );
  });

  test('deleteToken deletes the token doc', () async {
    final repo = FcmTokenRepository(firestore: firestore);
    await repo.deleteToken(userDocId: 'u1', token: 'tok');
    verify(() => tokenDoc.delete()).called(1);
  });
}
