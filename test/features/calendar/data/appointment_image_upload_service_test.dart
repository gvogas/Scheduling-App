import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/image_upload_failure.dart';
import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/data/pending_upload_store.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAppointmentsRepository extends Mock
    implements AppointmentsRepository {}

class _MockImageStorageService extends Mock implements ImageStorageService {}

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockFirebaseUser extends Mock implements User {}

/// Fails the requeue write, to pin that a throw there leaves the queue entry
/// (and therefore its staged files) reachable.
class _FailingReplaceStore extends PendingUploadStore {
  @override
  Future<void> replace(String id, PendingUpload entry) async {
    throw const FileSystemException('prefs write failed');
  }
}

class _FailingCheckpointStore extends PendingUploadStore {
  int _checkpoints = 0;

  @override
  Future<bool> checkpoint(String id, PendingUpload entry) async {
    if (++_checkpoints == 2) {
      throw const FileSystemException('prefs write failed');
    }
    return await super.checkpoint(id, entry);
  }
}

class _FailingAddStore extends PendingUploadStore {
  bool fail = true;

  @override
  Future<void> add(PendingUpload entry) async {
    if (fail) throw const FileSystemException('prefs write failed');
    await super.add(entry);
  }
}

AppointmentImage _img(String name) => AppointmentImage(
  url: 'https://example.com/$name',
  storagePath: 'appointments/a1/images/$name',
  fileName: name,
  uploadedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAppointmentsRepository appointments;
  late _MockImageStorageService storage;
  late _MockFirebaseAuth auth;
  late _MockFirebaseUser user;
  late PhotoUploadNotifier notifier;
  late PendingUploadStore store;
  late Directory tempRoot;
  late Directory sourceDir;
  late Directory stagingDir;

  setUpAll(() {
    registerFallbackValue(File('fallback'));
    registerFallbackValue(
      ImageUploadIntent(
        uploadId: '00000000-0000-0000-0000-000000000000',
        ownerUid: 'uid-1',
        image: _img('fallback'),
        digest: '0' * 64,
        byteLength: 0,
      ),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appointments = _MockAppointmentsRepository();
    storage = _MockImageStorageService();
    auth = _MockFirebaseAuth();
    user = _MockFirebaseUser();
    notifier = PhotoUploadNotifier();
    store = PendingUploadStore();
    tempRoot = Directory.systemTemp.createTempSync('img_upload_test');
    sourceDir = Directory('${tempRoot.path}/src')..createSync();
    stagingDir = Directory('${tempRoot.path}/staging')..createSync();

    when(
      () => appointments.appendAppointmentPictures(any(), any()),
    ).thenAnswer((_) async {});
    when(() => user.uid).thenReturn('uid-1');
    when(() => auth.currentUser).thenReturn(user);
  });

  tearDown(() {
    notifier.dispose();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  AppointmentImageUploadService makeService() => AppointmentImageUploadService(
    appointments: appointments,
    notifier: notifier,
    storage: storage,
    store: store,
    stagingDirProvider: () async => stagingDir,
    auth: auth,
    employeeIdForUid: (_) async => 'doc-1',
  );

  File makeSource(String name) =>
      File('${sourceDir.path}/$name')..writeAsStringSync('data');

  // Manually stages files and enqueues an entry, the same way _stageAndRun
  // would. Uses a fresh timestamp so drainPending's 7-day prune leaves it alone.
  Future<PendingUpload> stageEntry(
    String appointmentId,
    List<String> names, {
    int? enqueuedAtMs,
  }) async {
    enqueuedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    final paths = <String>[];
    for (final n in names) {
      final p = '${stagingDir.path}/${enqueuedAtMs}_$n';
      File(p).writeAsStringSync('data');
      paths.add(p);
    }
    final entry = PendingUpload(
      appointmentId: appointmentId,
      paths: paths,
      enqueuedAtMs: enqueuedAtMs,
      ownerUid: 'uid-1',
      ownerEmployeeId: 'doc-1',
    );
    await store.add(entry);
    return entry;
  }

  group('drainPending', () {
    test(
      'persists legacy file identities before transfer and reuses them after a failed receipt',
      () async {
        store = _FailingCheckpointStore();
        final entry = await stageEntry('a1', ['1.jpg']);
        final targets = <ImageUploadIntent>[];
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer((call) async {
          final intent = call.positionalArguments[2] as ImageUploadIntent;
          final persisted =
              (await store.load()).single.intents[entry.paths.single];
          expect(persisted?.toJson(), intent.toJson());
          targets.add(intent);
          return intent.image;
        });

        await makeService().drainPending();
        expect(File(entry.paths.single).existsSync(), isTrue);
        await makeService().drainPending();

        expect(targets, hasLength(2));
        expect(targets.last.toJson(), targets.first.toJson());
        expect(await store.load(), isEmpty);
      },
    );

    test(
      'a held upload cannot link or delete originals after switching accounts',
      () async {
        final entry = await stageEntry('a1', ['1.jpg']);
        final started = Completer<void>();
        final upload = Completer<AppointmentImage>();
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer((_) {
          started.complete();
          return upload.future;
        });
        final drain = makeService().drainPending();
        await started.future;
        final replacement = _MockFirebaseUser();
        when(() => replacement.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(replacement);
        upload.complete(_img('1.jpg'));
        await drain;

        expect(File(entry.paths.single).existsSync(), isTrue);
        expect((await store.load()).single.ownerUid, 'uid-1');
        verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
      },
    );

    test(
      'exit invalidates a held upload even while its UID remains signed in',
      () async {
        final entry = await stageEntry('a1', ['1.jpg']);
        final session = SessionFence(readUid: () => auth.currentUser?.uid);
        final started = Completer<void>();
        final upload = Completer<AppointmentImage>();
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer((_) {
          started.complete();
          return upload.future;
        });
        final service = AppointmentImageUploadService(
          appointments: appointments,
          notifier: notifier,
          storage: storage,
          store: store,
          auth: auth,
          stagingDirProvider: () async => stagingDir,
          employeeIdForUid: (_) async => 'doc-1',
          session: session,
        );
        final drain = service.drainPending();
        await started.future;
        session
          ..beginExit()
          ..resume();
        upload.complete(_img('1.jpg'));
        await drain;

        expect(File(entry.paths.single).existsSync(), isTrue);
        verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
      },
    );

    test(
      'recovers cleanup-only entries without uploading or linking again',
      () async {
        final entry = await stageEntry('a1', ['1.jpg']);
        await store.replace(
          entry.id,
          PendingUpload(
            appointmentId: entry.appointmentId,
            paths: const [],
            enqueuedAtMs: entry.enqueuedAtMs,
            ownerUid: entry.ownerUid,
            ownerEmployeeId: entry.ownerEmployeeId,
            cleanupPaths: entry.paths,
          ),
        );

        await makeService().drainPending();

        expect(await store.load(), isEmpty);
        expect(File(entry.paths.single).existsSync(), isFalse);
        verifyNever(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        );
        verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
      },
    );

    test('a late upload cannot recreate a cleared batch or link it', () async {
      await stageEntry('a1', ['1.jpg']);
      final started = Completer<void>();
      final uploaded = Completer<AppointmentImage>();
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) {
        started.complete();
        return uploaded.future;
      });
      final service = makeService();
      final drain = service.drainPending();
      await started.future;
      await service.clearPending();
      uploaded.complete(_img('1.jpg'));
      await drain;

      expect(await store.load(), isEmpty);
      verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
    });

    test('checkpoints completed chunks while a later upload stalls', () async {
      final entry = await stageEntry('a1', [
        '1.jpg',
        '2.jpg',
        '3.jpg',
        '4.jpg',
        '5.jpg',
      ]);
      final lastStarted = Completer<void>();
      final releaseLast = Completer<AppointmentImage>();
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((call) async {
        final file = call.positionalArguments[1] as File;
        if (file.path.endsWith('5.jpg')) {
          lastStarted.complete();
          return await releaseLast.future;
        }
        return _img(file.uri.pathSegments.last);
      });

      final drain = makeService().drainPending();
      await lastStarted.future;
      try {
        final pending = (await PendingUploadStore().load()).single;
        expect(pending.uploaded, hasLength(4));
        expect(pending.paths, [entry.paths.last]);
        expect(File(entry.paths.last).existsSync(), isTrue);
      } finally {
        releaseLast.complete(_img('5.jpg'));
        await drain;
      }
    });

    test('persists receipts before waiting for the appointment link', () async {
      final entry = await stageEntry('a1', ['1.jpg']);
      final linking = Completer<void>();
      final releaseLink = Completer<void>();
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) async => _img('1.jpg'));
      when(
        () => appointments.appendAppointmentPictures(any(), any()),
      ).thenAnswer((_) {
        linking.complete();
        return releaseLink.future;
      });

      final drain = makeService().drainPending();
      await linking.future;
      try {
        final pending = (await PendingUploadStore().load()).single;
        expect(pending.uploaded.single.storagePath, _img('1.jpg').storagePath);
        expect(pending.uploaded.single.uploadedAt, _img('1.jpg').uploadedAt);
        expect(pending.paths, isEmpty);
        expect(pending.ownerUid, entry.ownerUid);
      } finally {
        releaseLink.complete();
        await drain;
      }
    });

    test('keeps originals when persisting upload receipts fails', () async {
      store = _FailingCheckpointStore();
      final entry = await stageEntry('a1', ['1.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) async => _img('1.jpg'));

      await makeService().drainPending();

      expect(File(entry.paths.single).existsSync(), isTrue);
      expect((await store.load()).single.paths, entry.paths);
      verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
    });

    test('uploads, clears failure, deletes files, empties queue', () async {
      notifier.reportFailure('a1', failedCount: 1); // stale prior failure
      final entry = await stageEntry('a1', ['1.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) async => _img('1.jpg'));

      await makeService().drainPending();

      expect(await store.load(), isEmpty);
      expect(notifier.failureFor('a1'), isNull);
      expect(File(entry.paths.single).existsSync(), isFalse);
      verify(
        () => appointments.appendAppointmentPictures(any(), any()),
      ).called(1);
    });

    test('transient failure re-queues only the unsent paths', () async {
      final entry = await stageEntry('a1', ['ok.jpg', 'fail.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((invocation) {
        final f = invocation.positionalArguments[1] as File;
        if (f.path.endsWith('fail.jpg')) {
          throw const SocketException('offline');
        }
        return Future.value(_img('ok.jpg'));
      });

      await makeService().drainPending();

      final remaining = await store.load();
      expect(remaining, hasLength(1));
      expect(remaining.single.paths.single, endsWith('fail.jpg'));
      // Entry age preserved so a batch never retries past the pruning window.
      expect(remaining.single.enqueuedAtMs, entry.enqueuedAtMs);
      expect(notifier.failureFor('a1')?.failedCount, 1);
    });

    test('append failure re-queues uploaded images for an append-only '
        'retry instead of orphaning them', () async {
      final entry = await stageEntry('a1', ['1.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) async => _img('1.jpg'));
      when(
        () => appointments.appendAppointmentPictures(any(), any()),
      ).thenThrow(const SocketException('offline'));

      await makeService().drainPending();

      final remaining = await store.load();
      expect(remaining, hasLength(1));
      // The upload succeeded so the local file is gone and no path re-uploads,
      // but the uploaded image is carried for an append-only retry.
      expect(remaining.single.paths, isEmpty);
      expect(remaining.single.uploaded, hasLength(1));
      expect(remaining.single.uploaded.single.storagePath, endsWith('1.jpg'));
      expect(remaining.single.enqueuedAtMs, entry.enqueuedAtMs);
      expect(File(entry.paths.single).existsSync(), isFalse);
      expect(notifier.failureFor('a1')?.failedCount, 1);
    });

    test('a re-queued append-only entry re-links without re-uploading '
        'once the write succeeds', () async {
      // Seed the queue directly with a link-only entry (no on-disk paths).
      await store.add(
        PendingUpload(
          appointmentId: 'a1',
          paths: const [],
          enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
          uploaded: [_img('1.jpg')],
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
        ),
      );

      await makeService().drainPending();

      expect(await store.load(), isEmpty);
      expect(notifier.failureFor('a1'), isNull);
      // No file existed to upload; only the append was re-attempted.
      verifyNever(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      );
      verify(
        () => appointments.appendAppointmentPictures(any(), any()),
      ).called(1);
    });

    test('a carried image is appended without any Storage round trip', () async {
      // It used to need one: the queue does not persist download urls, so each
      // carried image had its url re-minted before the re-link. Photo
      // documents carry no url now, so the re-link is the append alone — which
      // matters most here, on the offline→online flip, when the connection is
      // at its worst.
      await store.add(
        PendingUpload(
          appointmentId: 'a1',
          paths: const [],
          enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
          uploaded: [_img('1.jpg')],
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
        ),
      );

      await makeService().drainPending();

      verifyNever(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      );
      final appended =
          verify(
                () =>
                    appointments.appendAppointmentPictures(any(), captureAny()),
              ).captured.single
              as List<AppointmentImage>;
      expect(appended.single.storagePath, 'appointments/a1/images/1.jpg');
      expect(await store.load(), isEmpty);
    });

    test('a failed requeue write leaves the original entry queued', () async {
      // B5: the requeue was `remove(id)` then `add(next)`. A throw in the
      // second half left the entry gone while its staged files stayed on disk,
      // and nothing walks the staging dir — those photos were unreachable
      // forever. One `replace` makes the failure a no-op instead.
      store = _FailingReplaceStore();
      final entry = await stageEntry('a1', ['ok.jpg', 'fail.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((invocation) {
        final f = invocation.positionalArguments[1] as File;
        if (f.path.endsWith('fail.jpg')) {
          throw const SocketException('offline');
        }
        return Future.value(_img('ok.jpg'));
      });

      await makeService().drainPending();

      final remaining = await store.load();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, entry.id);
      expect(remaining.single.paths, [entry.paths.last]);
      expect(
        remaining.single.uploaded.single.storagePath,
        _img('ok.jpg').storagePath,
      );
      expect(File(entry.paths.last).existsSync(), isTrue);
    });

    test('permanent ImageUploadFailure drops the file and the entry', () async {
      await stageEntry('a1', ['bad.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenThrow(const ImageUploadFailureInvalidFormat());

      await makeService().drainPending();

      expect(await store.load(), isEmpty); // gone, never retried
      expect(notifier.failureFor('a1')?.failedCount, 1);
    });

    test('too-large rejection surfaces the file name', () async {
      await stageEntry('a1', ['big.jpg']);
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenThrow(const ImageUploadFailureTooLarge());

      await makeService().drainPending();

      expect(
        notifier.failureFor('a1')?.tooLargeFileNames,
        contains(endsWith('big.jpg')),
      );
    });

    test(
      'a mixed permanent + transient batch still names the too-large file',
      () async {
        await stageEntry('a1', ['big.jpg', 'ok.jpg']);
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer((invocation) async {
          final file = invocation.positionalArguments[1] as File;
          if (file.path.endsWith('big.jpg')) {
            throw const ImageUploadFailureTooLarge();
          }
          throw Exception('network');
        });

        await makeService().drainPending();

        final failure = notifier.failureFor('a1');
        // The oversized file was deleted from staging, so it can NEVER retry —
        // reporting only the retryable one left the user waiting for a retry
        // that cannot happen, with the one actionable detail withheld.
        expect(failure?.tooLargeFileNames, contains(endsWith('big.jpg')));
        // Both count: one permanently rejected, one queued for another go.
        expect(failure?.failedCount, 2);
        // The retryable half is still queued.
        expect((await store.load()).single.paths.single, endsWith('ok.jpg'));
      },
    );

    test('is reentrancy-safe (second call while draining no-ops)', () async {
      await stageEntry('a1', ['1.jpg']);
      final gate = Completer<AppointmentImage>();
      var calls = 0;
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) async {
        calls++;
        return await gate.future;
      });

      final service = makeService();
      final first = service.drainPending(); // enters, blocks on the gate
      await service
          .drainPending(); // synchronous guard, so this is an immediate no-op
      gate.complete(_img('1.jpg'));
      await first;

      expect(calls, 1);
    });

    test(
      'a batch staged mid-drain is coalesced into the in-flight pass',
      () async {
        // The guard alone ("if (_draining) return") would leave this batch
        // queued until the next connectivity flip. CLAUDE.md: coalesce, never
        // drop — the in-flight pass has to loop again and pick it up.
        await stageEntry('a1', ['a.jpg']);
        final gate = Completer<AppointmentImage>();
        final firstUploadStarted = Completer<void>();
        var calls = 0;
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer((invocation) async {
          calls++;
          final file = invocation.positionalArguments[1] as File;
          if (file.path.endsWith('a.jpg')) {
            firstUploadStarted.complete();
            return await gate.future;
          }
          return _img('b.jpg');
        });

        final service = makeService();
        final first = service.drainPending();
        await firstUploadStarted
            .future; // pass 1 is mid-upload on the first batch
        await stageEntry('a2', ['b.jpg']); // staged while that drain is running
        await service.drainPending(); // coalesced, not dropped
        gate.complete(_img('a.jpg'));
        await first;

        expect(calls, 2);
        expect(await store.load(), isEmpty);
      },
    );

    test('an entry with no paths and no carried uploads is the only one '
        'that drains away', () async {
      // Files gone AND nothing carried: genuinely empty, so it is dropped with
      // no upload and no append. An entry carrying uploaded images is never
      // empty in this sense, however few paths it has left.
      await store.add(
        PendingUpload(
          appointmentId: 'a1',
          paths: ['${stagingDir.path}/vanished.jpg'],
          enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
        ),
      );

      await makeService().drainPending();

      expect(await store.load(), isEmpty);
      verifyNever(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      );
      verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
      expect(notifier.failureFor('a1'), isNull);
    });

    test('skips queued files owned by a different account', () async {
      final path = '${stagingDir.path}/other-user.jpg';
      File(path).writeAsStringSync('data');
      final entry = PendingUpload(
        appointmentId: 'a1',
        paths: [path],
        enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
        ownerUid: 'uid-2',
        ownerEmployeeId: 'doc-2',
      );
      await store.add(entry);

      await makeService().drainPending();

      expect((await store.load()).single.id, entry.id);
      expect(File(path).existsSync(), isTrue);
      verifyNever(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      );
      verifyNever(() => appointments.appendAppointmentPictures(any(), any()));
    });
  });

  group('clearPending', () {
    test('only discards the current owner queue', () async {
      final own = await stageEntry('a1', ['own.jpg']);
      final other = await stageEntry('a2', ['other.jpg']);
      await store.replace(
        other.id,
        PendingUpload(
          appointmentId: other.appointmentId,
          paths: other.paths,
          enqueuedAtMs: other.enqueuedAtMs,
          ownerUid: 'uid-2',
          ownerEmployeeId: 'doc-2',
        ),
      );

      await makeService().clearPending();

      expect((await store.load()).single.ownerUid, 'uid-2');
      expect(File(own.paths.single).existsSync(), isFalse);
      expect(File(other.paths.single).existsSync(), isTrue);
    });

    test(
      'a switch during journal recovery cannot clear the replacement queue',
      () async {
        final original = await stageEntry('a1', ['original.jpg']);
        final directory = Completer<Directory>();
        final service = AppointmentImageUploadService(
          appointments: appointments,
          notifier: notifier,
          storage: storage,
          store: store,
          auth: auth,
          stagingDirProvider: () => directory.future,
          employeeIdForUid: (_) async => 'doc-1',
        );
        final clearing = service.clearPending();
        final nextUser = _MockFirebaseUser();
        when(() => nextUser.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(nextUser);
        final replacement = await stageEntry('a2', ['replacement.jpg']);
        await store.replace(
          replacement.id,
          PendingUpload(
            appointmentId: replacement.appointmentId,
            paths: replacement.paths,
            enqueuedAtMs: replacement.enqueuedAtMs,
            ownerUid: 'uid-2',
            ownerEmployeeId: 'doc-2',
          ),
        );
        directory.complete(stagingDir);
        await clearing;

        expect(await store.load(), hasLength(2));
        expect(File(original.paths.single).existsSync(), isTrue);
        expect(File(replacement.paths.single).existsSync(), isTrue);
      },
    );

    test('deletes the staged JPEGs, not just the queue index', () async {
      // `_store.clearAll()` empties the index on its own, so dropping the
      // per-file loop looks like nothing: one user's staged job photos would
      // survive sign-out on a shared handset with nothing pointing at them.
      final one = await stageEntry('a1', ['1.jpg']);
      final two = await stageEntry('a2', ['2.jpg', '3.jpg']);

      await makeService().clearPending();

      expect(await store.load(), isEmpty);
      for (final path in [...one.paths, ...two.paths]) {
        expect(File(path).existsSync(), isFalse, reason: path);
      }
    });
  });

  group('AttemptOutcome.from', () {
    AttemptOutcome outcome({
      int permanentFailures = 0,
      bool transientFailure = false,
      List<String> survivors = const [],
      bool appendThrew = false,
      List<AppointmentImage> uploaded = const [],
    }) => AttemptOutcome.from(
      permanentFailures: permanentFailures,
      transientFailure: transientFailure,
      survivors: survivors,
      appendThrew: appendThrew,
      uploaded: uploaded,
    );

    test('a clean pass drains the entry and clears the failure', () {
      final result = outcome(uploaded: [_img('1.jpg')]);

      expect(result.requeue, isFalse);
      expect(result.uploadedToCarry, isEmpty);
      expect(result.failedCount, 0);
    });

    test('a failed append carries the uploaded images forward, never '
        'drops them', () {
      final images = [_img('1.jpg'), _img('2.jpg')];

      final result = outcome(appendThrew: true, uploaded: images);

      expect(result.requeue, isTrue);
      expect(result.uploadedToCarry, images);
      // No survivor paths: their local files are gone, so the retry is
      // append-only and must never re-upload them.
      expect(result.failedCount, 2);
    });

    test('a transient upload failure re-queues the survivors alone', () {
      final result = outcome(
        transientFailure: true,
        survivors: ['/staging/fail.jpg'],
        uploaded: [_img('ok.jpg')],
      );

      expect(result.requeue, isTrue);
      // The append landed, so re-carrying these would re-link them a second
      // time on the next pass.
      expect(result.uploadedToCarry, isEmpty);
      expect(result.failedCount, 1);
    });

    test('permanent failures alone drain the entry but still report', () {
      final result = outcome(permanentFailures: 2);

      expect(result.requeue, isFalse);
      expect(result.uploadedToCarry, isEmpty);
      expect(result.failedCount, 2);
    });

    test('a mixed permanent + transient pass counts both', () {
      final result = outcome(
        permanentFailures: 1,
        transientFailure: true,
        survivors: ['/staging/ok.jpg'],
      );

      expect(result.requeue, isTrue);
      expect(result.failedCount, 2);
    });
  });

  group('uploadInBackground', () {
    test(
      'an old exit pause cannot block the replacement account queue',
      () async {
        final original = await stageEntry('a1', ['original.jpg']);
        final replacement = await stageEntry('a2', [
          'replacement.jpg',
        ], enqueuedAtMs: original.enqueuedAtMs + 1);
        await store.replace(
          replacement.id,
          PendingUpload(
            appointmentId: replacement.appointmentId,
            paths: replacement.paths,
            enqueuedAtMs: replacement.enqueuedAtMs,
            ownerUid: 'uid-2',
            ownerEmployeeId: 'doc-1',
          ),
        );
        final service = makeService();
        await service.prepareForExit();
        final nextUser = _MockFirebaseUser();
        when(() => nextUser.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(nextUser);
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer(
          (call) async =>
              (call.positionalArguments[2] as ImageUploadIntent).image,
        );

        await service.drainPending();

        expect((await store.load()).single.ownerUid, 'uid-1');
        expect(File(original.paths.single).existsSync(), isTrue);
        expect(File(replacement.paths.single).existsSync(), isFalse);
      },
    );

    test('a disk journal recovers an initial queue write failure', () async {
      final failingStore = _FailingAddStore();
      store = failingStore;
      final source = makeSource('photo.jpg');
      makeService().uploadInBackground(
        appointmentId: 'a1',
        newImages: [source],
      );
      for (var i = 0; i < 100 && notifier.failureFor('a1') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(notifier.failureFor('a1'), isNotNull);
      expect(source.existsSync(), isTrue);
      expect(await store.load(), isEmpty);
      expect(
        stagingDir.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.json'),
        ),
        hasLength(1),
      );
      failingStore.fail = false;
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer(
        (call) async =>
            (call.positionalArguments[2] as ImageUploadIntent).image,
      );

      await makeService().drainPending();

      expect(await store.load(), isEmpty);
      expect(source.existsSync(), isFalse);
      expect(stagingDir.listSync(), isEmpty);
    });

    test(
      'replaying a journal cannot replace a newer append-only receipt',
      () async {
        final original = PendingUpload(
          appointmentId: 'a1',
          paths: ['${stagingDir.path}/photo.jpg'],
          enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
          batchId: 'stable-batch',
          stagingSources: {
            '${stagingDir.path}/photo.jpg': '${sourceDir.path}/gone.jpg',
          },
        );
        await File(
          '${stagingDir.path}/staging_stable-batch.json',
        ).writeAsString(jsonEncode(original.toJson()));
        await store.add(
          original.copyWith(
            paths: const [],
            stagingSources: const {},
            uploaded: [_img('photo.jpg')],
          ),
        );

        await makeService().drainPending();

        expect(await store.load(), isEmpty);
        verifyNever(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        );
        expect(stagingDir.listSync(), isEmpty);
      },
    );

    test('stages picker files into the durable dir before uploading', () async {
      final src = makeSource('photo.jpg');
      final gate = Completer<AppointmentImage>();
      final started = Completer<void>();
      when(
        () => storage.uploadQueuedImage(
          any(),
          any(),
          any(),
          isCurrent: any(named: 'isCurrent'),
        ),
      ).thenAnswer((_) {
        started.complete();
        return gate.future;
      });

      makeService().uploadInBackground(appointmentId: 'a1', newImages: [src]);

      await started.future;
      final entries = await store.load();

      expect(entries, hasLength(1));
      expect(src.existsSync(), isFalse);
      expect(entries.single.paths.single, startsWith(stagingDir.path));
      expect(File(entries.single.paths.single).existsSync(), isTrue);

      gate.complete(_img('photo.jpg'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    PendingUpload unstagedEntry(String appointmentId, Map<String, File> map) =>
        PendingUpload(
          appointmentId: appointmentId,
          paths: [for (final name in map.keys) '${stagingDir.path}/$name'],
          enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
          ownerUid: 'uid-1',
          ownerEmployeeId: 'doc-1',
          batchId: 'batch-$appointmentId',
          stagingSources: {
            for (final item in map.entries)
              '${stagingDir.path}/${item.key}': item.value.path,
          },
        );

    void uploadsSucceed() =>
        when(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        ).thenAnswer(
          (call) async =>
              (call.positionalArguments[2] as ImageUploadIntent).image,
        );

    test(
      'a missing staging source is reported lost and later batches still upload',
      () async {
        await store.add(
          unstagedEntry('a1', {'gone.jpg': File('${sourceDir.path}/gone.jpg')}),
        );
        await stageEntry('a2', ['ok.jpg']);
        uploadsSucceed();

        await makeService().drainPending();

        expect(await store.load(), isEmpty);
        expect(notifier.failureFor('a1')?.failedCount, 1);
        expect(notifier.failureFor('a2'), isNull);
        verify(
          () => appointments.appendAppointmentPictures('a2', any()),
        ).called(1);
      },
    );

    test(
      'a failed staging copy keeps its originals without blocking later batches',
      () async {
        final source = makeSource('blocked.jpg');
        await store.add(unstagedEntry('a1', {'blocked.jpg': source}));
        final blocker = Directory('${stagingDir.path}/blocked.jpg.part')
          ..createSync();
        await stageEntry('a2', ['ok.jpg']);
        uploadsSucceed();

        await makeService().drainPending();

        final pending = (await store.load()).single;
        expect(pending.stagingSources.values, [source.path]);
        expect(source.existsSync(), isTrue);
        expect(notifier.failureFor('a1')?.failedCount, 1);
        verify(
          () => appointments.appendAppointmentPictures('a2', any()),
        ).called(1);

        blocker.deleteSync();
        await makeService().drainPending();

        expect(await store.load(), isEmpty);
        expect(source.existsSync(), isFalse);
      },
    );

    test(
      'exit inspection yields nothing when the session changes mid-wait',
      () async {
        final directory = Completer<Directory>();
        final session = SessionFence(readUid: () => auth.currentUser?.uid);
        final service =
            AppointmentImageUploadService(
              appointments: appointments,
              notifier: notifier,
              storage: storage,
              store: store,
              auth: auth,
              stagingDirProvider: () => directory.future,
              employeeIdForUid: (_) async => 'doc-1',
              session: session,
            )..uploadInBackground(
              appointmentId: 'a1',
              newImages: [makeSource('photo.jpg')],
            );
        final exit = service.prepareForExit();
        session
          ..beginExit()
          ..resume();
        directory.complete(stagingDir);

        expect(await exit, isNull);
      },
    );

    test(
      'exit waits for an enqueue already in progress before counting photos',
      () async {
        final directory = Completer<Directory>();
        final source = makeSource('photo.jpg');
        final service = AppointmentImageUploadService(
          appointments: appointments,
          notifier: notifier,
          storage: storage,
          store: store,
          auth: auth,
          stagingDirProvider: () => directory.future,
          employeeIdForUid: (_) async => 'doc-1',
        );
        final exit =
            (service..uploadInBackground(
                  appointmentId: 'a1',
                  newImages: [source],
                ))
                .prepareForExit();
        directory.complete(stagingDir);

        final check = await exit;

        expect(check?.pendingCount, 1);
        expect(source.existsSync(), isTrue);
        verifyNever(
          () => storage.uploadQueuedImage(
            any(),
            any(),
            any(),
            isCurrent: any(named: 'isCurrent'),
          ),
        );
        await service.clearPending();
        expect(source.existsSync(), isFalse);
      },
    );

    test(
      'exit counts append-only receipts and ignores cleanup-only work',
      () async {
        final entry = await stageEntry('a1', ['photo.jpg']);
        await store.replace(
          entry.id,
          entry.copyWith(
            paths: const [],
            uploaded: [_img('already-uploaded.jpg')],
            cleanupPaths: entry.paths,
          ),
        );

        final service = makeService();
        final check = await service.prepareForExit();

        expect(check?.pendingCount, 1);
        await service.clearPending();
      },
    );
  });
}
