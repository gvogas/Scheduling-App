import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/features/calendar/data/pending_upload_store.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RejectQueueWrites extends InMemorySharedPreferencesStore {
  _RejectQueueWrites(super.data) : super.withData();
  bool reject = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      reject && key == 'flutter.pending_photo_uploads'
      ? Future.value(false)
      : super.setValue(valueType, key, value);
}

class _RejectingPreferencesStore extends InMemorySharedPreferencesStore {
  _RejectingPreferencesStore() : super.empty();
  _RejectingPreferencesStore.withData(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> remove(String key) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'expiry recording survives a failed queue save without reporting removal early',
    () async {
      const entry = PendingUpload(
        appointmentId: 'job',
        batchId: 'batch',
        paths: ['/staged.jpg'],
        enqueuedAtMs: 1000,
        ownerUid: 'A',
        ownerEmployeeId: 'employee-A',
      );
      final prefs = _RejectQueueWrites({
        'flutter.pending_photo_uploads': jsonEncode([entry.toJson()]),
      });
      SharedPreferencesStorePlatform.instance = prefs;
      final store = PendingUploadStore();
      await expectLater(store.prune(now: DateTime(2026)), throwsStateError);
      expect(await store.expiredFor('A'), isEmpty);
      expect(await store.load(), hasLength(1));
      prefs.reject = false;
      await store.prune(now: DateTime(2026));
      expect((await PendingUploadStore().expiredFor('A')).single.count, 1);
    },
  );

  test(
    'expiry outcomes survive restart, stay owner-bound and acknowledge independently',
    () async {
      final store = PendingUploadStore();
      final now = DateTime(2026, 10, 18);
      for (final uid in ['A', 'B']) {
        await store.add(
          PendingUpload(
            appointmentId: 'job-$uid',
            batchId: 'batch-$uid',
            paths: ['/staged/$uid.jpg'],
            enqueuedAtMs: now
                .subtract(const Duration(days: 8))
                .millisecondsSinceEpoch,
            ownerUid: uid,
            ownerEmployeeId: 'employee-$uid',
          ),
        );
      }
      expect(await store.prune(now: now), hasLength(2));
      final restarted = PendingUploadStore();
      expect((await restarted.expiredFor('A')).single.count, 1);
      expect((await restarted.expiredFor('B')).single.appointmentId, 'job-B');
      await restarted.prune(now: now);
      expect(await restarted.expiredFor('A'), hasLength(1));
      await restarted.acknowledgeExpiry('A', {'batch-A', 'batch-B'});
      expect(await restarted.expiredFor('A'), isEmpty);
      expect(await restarted.expiredFor('B'), hasLength(1));
    },
  );

  test('corrupt expiry outcomes do not block pruning the queue', () async {
    SharedPreferences.setMockInitialValues({'expired_photo_uploads': '[1'});
    final store = PendingUploadStore();
    final now = DateTime(2026, 10, 18);
    await store.add(
      PendingUpload(
        appointmentId: 'job',
        batchId: 'batch',
        paths: const ['/staged/1.jpg'],
        enqueuedAtMs: now
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
        ownerUid: 'A',
        ownerEmployeeId: 'employee-A',
      ),
    );

    expect(await store.prune(now: now), hasLength(1));
    expect((await store.expiredFor('A')).single.appointmentId, 'job');
  });

  test(
    'does not read an unpersisted receipt from the preferences cache',
    () async {
      const entry = PendingUpload(
        appointmentId: 'a1',
        paths: ['/staging/1.jpg'],
        enqueuedAtMs: 1000,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      );
      SharedPreferencesStorePlatform.instance =
          _RejectingPreferencesStore.withData({
            'flutter.pending_photo_uploads': jsonEncode([entry.toJson()]),
          });
      final store = PendingUploadStore();
      await expectLater(
        store.checkpoint(
          entry.id,
          const PendingUpload(
            appointmentId: 'a1',
            paths: [],
            enqueuedAtMs: 1000,
            ownerUid: 'uid-1',
            ownerEmployeeId: 'doc-1',
            cleanupPaths: ['/staging/1.jpg'],
          ),
        ),
        throwsStateError,
      );

      final recovered = (await PendingUploadStore().load()).single;

      expect(recovered.paths, entry.paths);
      expect(recovered.cleanupPaths, isEmpty);
    },
  );

  test('a rejected queue clear keeps the persisted batch reachable', () async {
    const entry = PendingUpload(
      appointmentId: 'a1',
      paths: ['/staging/1.jpg'],
      enqueuedAtMs: 1000,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    SharedPreferencesStorePlatform.instance =
        _RejectingPreferencesStore.withData({
          'flutter.pending_photo_uploads': jsonEncode([entry.toJson()]),
        });
    final store = PendingUploadStore();

    await expectLater(
      store.clearOwner('uid-1', isCurrent: () => true),
      throwsStateError,
    );

    expect((await store.load()).single.paths, entry.paths);
  });

  test(
    'rejects a queue write when the preferences backend returns false',
    () async {
      SharedPreferencesStorePlatform.instance = _RejectingPreferencesStore();

      await expectLater(
        PendingUploadStore().add(
          const PendingUpload(
            appointmentId: 'a1',
            paths: ['/staging/1.jpg'],
            enqueuedAtMs: 1000,
            ownerUid: 'uid-1',
            ownerEmployeeId: 'doc-1',
          ),
        ),
        throwsStateError,
      );
    },
  );

  test('load returns empty when nothing stored', () async {
    final store = PendingUploadStore();
    expect(await store.load(), isEmpty);
  });

  test(
    'round-trips upload identities and cleanup paths across store instances',
    () async {
      final intent = ImageUploadIntent(
        uploadId: '00000000-0000-4000-8000-000000000000',
        ownerUid: 'uid-1',
        image: AppointmentImage(
          storagePath:
              'appointments/a1/images/00000000-0000-4000-8000-000000000000.jpg',
          fileName: '00000000-0000-4000-8000-000000000000.jpg',
          uploadedAt: DateTime.utc(2026, 10, 18, 1, 2, 3, 4, 5),
        ),
        digest: 'a' * 64,
        byteLength: 123,
      );
      await PendingUploadStore().add(
        PendingUpload(
          appointmentId: 'a1',
          paths: const ['/staging/1.jpg'],
          enqueuedAtMs: 1000,
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
          intents: {'/staging/1.jpg': intent},
          cleanupPaths: const ['/staging/old.jpg'],
        ),
      );

      final recovered = (await PendingUploadStore().load()).single;

      expect(recovered.intents['/staging/1.jpg']?.toJson(), intent.toJson());
      expect(recovered.cleanupPaths, ['/staging/old.jpg']);
    },
  );

  test('add then load round-trips an entry', () async {
    final store = PendingUploadStore();
    const entry = PendingUpload(
      appointmentId: 'a1',
      paths: ['/x/1.jpg', '/x/2.jpg'],
      enqueuedAtMs: 1000,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    await store.add(entry);
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.appointmentId, 'a1');
    expect(loaded.first.paths, ['/x/1.jpg', '/x/2.jpg']);
    expect(loaded.first.id, 'a1_1000');
  });

  test(
    'round-trips already-uploaded images preserving the exact timestamp',
    () async {
      // Microsecond precision must survive so the arrayUnion re-link stays
      // idempotent against a Firestore Timestamp minted from the same instant.
      final uploadedAt = DateTime.utc(2026, 7, 26, 13, 45, 12, 340, 567);
      final store = PendingUploadStore();
      await store.add(
        PendingUpload(
          appointmentId: 'a1',
          paths: const [],
          enqueuedAtMs: 1000,
          uploaded: [
            AppointmentImage(
              url: 'https://example.com/1.jpg',
              storagePath: 'appointments/a1/images/1.jpg',
              fileName: '1.jpg',
              uploadedAt: uploadedAt,
            ),
          ],
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
        ),
      );
      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.paths, isEmpty);
      final img = loaded.single.uploaded.single;
      // The download URL is deliberately NOT persisted: it is a permanent,
      // auth-free `?alt=media&token=…` link and this queue is a plaintext blob
      // in SharedPreferences. The drain re-resolves it from `storagePath`.
      expect(img.url, isEmpty);
      expect(img.storagePath, 'appointments/a1/images/1.jpg');
      expect(img.uploadedAt, uploadedAt);
    },
  );

  test('keeps the url of a legacy image that has no storage path', () async {
    // There the url is the only identity the entry has, so dropping it would
    // strand the bytes with nothing able to re-resolve them.
    final store = PendingUploadStore();
    await store.add(
      PendingUpload(
        appointmentId: 'a1',
        paths: const [],
        enqueuedAtMs: 1000,
        uploaded: [
          AppointmentImage(
            url: 'https://example.com/legacy.jpg',
            fileName: 'legacy.jpg',
            uploadedAt: DateTime.utc(2026, 7, 26, 13, 45, 12),
          ),
        ],
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    final loaded = await store.load();
    expect(loaded.single.uploaded.single.url, 'https://example.com/legacy.jpg');
  });

  test(
    'an entry without uploaded images omits the field and loads empty',
    () async {
      final store = PendingUploadStore();
      await store.add(
        const PendingUpload(
          appointmentId: 'a1',
          paths: ['/x/1.jpg'],
          enqueuedAtMs: 1,
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
        ),
      );
      expect((await store.load()).single.uploaded, isEmpty);
    },
  );

  test('remove drops only the matching entry', () async {
    final store = PendingUploadStore();
    await store.add(
      const PendingUpload(
        appointmentId: 'a1',
        paths: ['/x/1.jpg'],
        enqueuedAtMs: 1,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    await store.add(
      const PendingUpload(
        appointmentId: 'a1',
        paths: ['/x/2.jpg'],
        enqueuedAtMs: 2,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    await store.remove('a1_1');
    final loaded = await store.load();
    expect(loaded.single.id, 'a1_2');
  });

  test('replace swaps an entry in place and leaves the others', () async {
    final store = PendingUploadStore();
    await store.add(
      const PendingUpload(
        appointmentId: 'a1',
        paths: ['/x/1.jpg', '/x/2.jpg'],
        enqueuedAtMs: 1,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    await store.add(
      const PendingUpload(
        appointmentId: 'a2',
        paths: ['/x/3.jpg'],
        enqueuedAtMs: 2,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );

    await store.replace(
      'a1_1',
      const PendingUpload(
        appointmentId: 'a1',
        paths: ['/x/2.jpg'],
        enqueuedAtMs: 1,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );

    final loaded = await store.load();
    expect(loaded.map((e) => e.id), ['a2_2', 'a1_1']);
    expect(loaded.last.paths, ['/x/2.jpg']);
  });

  test('an overlapping add and replace do not erase each other', () async {
    // B5: the requeue was `remove` then `add`, two separate serialized
    // read-modify-writes. `replace` is ONE, so a mutation that interleaves
    // between the halves can no longer be lost.
    final store = PendingUploadStore();
    const first = PendingUpload(
      appointmentId: 'a1',
      paths: ['/x/1.jpg', '/x/2.jpg'],
      enqueuedAtMs: 1000,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    await store.add(first);

    final replacing = store.replace(
      first.id,
      const PendingUpload(
        appointmentId: 'a1',
        paths: ['/x/2.jpg'],
        enqueuedAtMs: 1000,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    final adding = store.add(
      const PendingUpload(
        appointmentId: 'a2',
        paths: ['/x/3.jpg'],
        enqueuedAtMs: 2000,
        ownerUid: 'uid-1',
        ownerEmployeeId: 'doc-1',
      ),
    );
    await Future.wait([replacing, adding]);

    final loaded = await store.load();
    expect(loaded.map((e) => e.id).toSet(), {'a1_1000', 'a2_2000'});
    expect(loaded.firstWhere((e) => e.id == 'a1_1000').paths, ['/x/2.jpg']);
  });

  test('prune removes entries older than maxAge and returns them', () async {
    final store = PendingUploadStore();
    const old = PendingUpload(
      appointmentId: 'old',
      paths: ['/x/o.jpg'],
      enqueuedAtMs: 0,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    final fresh = PendingUpload(
      appointmentId: 'new',
      paths: const ['/x/n.jpg'],
      enqueuedAtMs: DateTime.utc(2026, 7, 13).millisecondsSinceEpoch,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    await store.add(old);
    await store.add(fresh);
    final pruned = await store.prune(now: DateTime.utc(2026, 7, 13));
    expect(pruned.single.appointmentId, 'old');
    expect((await store.load()).single.appointmentId, 'new');
  });

  test('malformed stored JSON resets to empty instead of throwing', () async {
    SharedPreferences.setMockInitialValues({
      'pending_photo_uploads': 'not-json',
    });
    final store = PendingUploadStore();
    expect(await store.load(), isEmpty);
  });

  test(
    'a pre-upgrade entry loads without an owner, so prune can reach it',
    () async {
      // It used to be DROPPED here, which stranded its staged files on disk with
      // nothing left pointing at them. It must not be adopted either: on a shared
      // or handed-over phone the next account would finish somebody else's
      // upload, which is the whole reason the queue gained an owner.
      SharedPreferences.setMockInitialValues({
        'pending_photo_uploads':
            '[{"appointmentId":"a1","paths":["/x/1.jpg"],"enqueuedAtMs":1}]',
      });

      final store = PendingUploadStore();
      final loaded = await store.load();

      expect(loaded, hasLength(1));
      expect(loaded.single.hasOwner, isFalse);
      expect(loaded.single.paths, ['/x/1.jpg']);
    },
  );

  test('an overlapping add and remove do not erase each other', () async {
    // Every other test here drives ONE mutation at a time, which is exactly
    // the shape that passed while this bug was live. `add`/`remove`/`prune`
    // are each load() -> mutate -> _save() over ONE SharedPreferences key, so
    // without `_serialized` both callers read the same list and the second
    // save wipes the first's change: a save staging a batch while a drain
    // removed a finished one wrote [E1, E2] then [], stranding E2's files
    // with no queue entry and no failure notice.
    final store = PendingUploadStore();
    const first = PendingUpload(
      appointmentId: 'a1',
      paths: ['/x/1.jpg'],
      enqueuedAtMs: 1000,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    const second = PendingUpload(
      appointmentId: 'a2',
      paths: ['/x/2.jpg'],
      enqueuedAtMs: 2000,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    await store.add(first);

    // Deliberately NOT awaited between the two — that interleaving is the
    // whole point.
    final adding = store.add(second);
    final removing = store.remove(first.id);
    await Future.wait([adding, removing]);

    final loaded = await store.load();
    expect(loaded.map((e) => e.appointmentId), ['a2']);
  });
}
