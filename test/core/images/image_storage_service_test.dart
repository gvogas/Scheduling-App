// Pins ImageStorageService's four real decisions.
//
// I19: this class was excused as a "method-channel plugin" alongside
// ImagePickerService and went untested because of it. Only `putFile` — the
// byte transfer itself — is genuinely device-only; the format gate, the size
// cap, the file-name bound, the legacy path fallback and the object-not-found
// swallow are all plain logic reachable with an injected FirebaseStorage.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/image_upload_failure.dart';
import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

class _MockStorage extends Mock implements FirebaseStorage {}

class _MockRef extends Mock implements Reference {}

class _MockSnapshot extends Mock implements TaskSnapshot {}

class _MockMetadata extends Mock implements FullMetadata {}

/// `UploadTask` is a `Future<TaskSnapshot>`, so `await ref.putFile(...)` only
/// needs `then` to resolve.
class _FakeUploadTask extends Fake implements UploadTask {
  _FakeUploadTask(this._snapshot);

  final TaskSnapshot _snapshot;

  @override
  Future<S> then<S>(
    FutureOr<S> Function(TaskSnapshot) onValue, {
    Function? onError,
  }) => Future<TaskSnapshot>.value(_snapshot).then(onValue, onError: onError);
}

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

/// The magic-byte prefixes `hasValidImageMagic` accepts, and some that look
/// close enough to have slipped past a weaker check.
const _jpegMagic = [0xFF, 0xD8, 0xFF, 0xE0];
const _pngMagic = [0x89, 0x50, 0x4E, 0x47];
const _gifMagic = [0x47, 0x49, 0x46, 0x38];
const _almostPngMagic = [0x89, 0x50, 0x4E, 0x00];

void main() {
  setUpAll(() {
    registerFallbackValue(SettableMetadata());
    registerFallbackValue(File('fallback'));
  });

  late _MockStorage storage;
  late _RecordingLogger logger;
  late ImageStorageService service;
  late Directory tempDir;

  setUp(() {
    storage = _MockStorage();
    logger = _RecordingLogger();
    service = ImageStorageService(storage: storage, logger: logger);
    tempDir = Directory.systemTemp.createTempSync('image_storage_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
  });

  File fileWith(String name, List<int> magic, {int padTo = 0}) {
    final bytes = <int>[
      ...magic,
      ...List<int>.filled(padTo > magic.length ? padTo - magic.length : 0, 0),
    ];
    return File('${tempDir.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(Uint8List.fromList(bytes));
  }

  /// Wires `storage.ref(path)` up to a successful upload, and returns the ref
  /// so a test can inspect what was asked of it.
  ///
  /// `getDownloadURL` is stubbed even though the upload must never call it —
  /// that is what lets "never mints a download url" below assert on silence
  /// rather than on a missing-stub crash.
  _MockRef stubUpload() {
    final ref = _MockRef();
    final snapshot = _MockSnapshot();
    when(() => snapshot.ref).thenReturn(ref);
    when(
      ref.getDownloadURL,
    ).thenAnswer((_) async => 'https://storage/x?token=t');
    when(
      () => ref.putFile(any(), any()),
    ).thenAnswer((_) => _FakeUploadTask(snapshot));
    when(() => storage.ref(any())).thenReturn(ref);
    return ref;
  }

  group('queued upload recovery', () {
    _MockMetadata metadataFor(ImageUploadIntent intent) {
      final metadata = _MockMetadata();
      when(() => metadata.size).thenReturn(intent.byteLength);
      when(() => metadata.customMetadata).thenReturn(intent.metadata);
      return metadata;
    }

    test('uploads to the persisted path with recovery metadata', () async {
      final ref = stubUpload();
      when(ref.getMetadata).thenThrow(
        FirebaseException(plugin: 'firebase_storage', code: 'object-not-found'),
      );
      final file = fileWith('photo.jpg', _jpegMagic);
      final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);

      final image = await service.uploadQueuedImage('j1', file, intent);

      expect(image, intent.image);
      final metadata =
          verify(() => ref.putFile(any(), captureAny())).captured.single
              as SettableMetadata;
      expect(metadata.customMetadata, intent.metadata);
      expect(metadata.cacheControl, startsWith('private'));
      verify(() => storage.ref(intent.image.storagePath)).called(1);
      verifyNever(ref.getDownloadURL);
    });

    test('recovers an existing matching object without overwriting', () async {
      final ref = stubUpload();
      final file = fileWith('photo.jpg', _jpegMagic);
      final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
      when(ref.getMetadata).thenAnswer((_) async => metadataFor(intent));

      final recovered = await service.uploadQueuedImage('j1', file, intent);

      expect(recovered, intent.image);
      verifyNever(() => ref.putFile(any(), any()));
    });

    test(
      'retries an ambiguous transfer using the same object and timestamp',
      () async {
        final ref = stubUpload();
        final file = fileWith('photo.jpg', _jpegMagic);
        final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
        var objectExists = false;
        when(ref.getMetadata).thenAnswer((_) async {
          if (objectExists) return metadataFor(intent);
          throw FirebaseException(
            plugin: 'firebase_storage',
            code: 'object-not-found',
          );
        });
        when(() => ref.putFile(any(), any())).thenAnswer((_) {
          objectExists = true;
          throw FirebaseException(
            plugin: 'firebase_storage',
            code: 'retry-limit-exceeded',
          );
        });
        await expectLater(
          service.uploadQueuedImage('j1', file, intent),
          throwsA(isA<FirebaseException>()),
        );

        final recovered = await service.uploadQueuedImage('j1', file, intent);

        expect(recovered, intent.image);
        verify(() => ref.putFile(any(), any())).called(1);
      },
    );

    for (final mismatch in ['owner', 'digest', 'size', 'timestamp']) {
      test('refuses an existing object with mismatched $mismatch', () async {
        final ref = stubUpload();
        final file = fileWith('photo.jpg', _jpegMagic);
        final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
        final metadata = metadataFor(intent);
        if (mismatch == 'size') {
          when(() => metadata.size).thenReturn(intent.byteLength + 1);
        } else {
          when(() => metadata.customMetadata).thenReturn({
            ...intent.metadata,
            switch (mismatch) {
              'owner' => 'ownerUid',
              'digest' => 'sha256',
              _ => 'uploadedAt',
            }: 'different',
          });
        }
        when(ref.getMetadata).thenAnswer((_) async => metadata);

        await expectLater(
          service.uploadQueuedImage('j1', file, intent),
          throwsStateError,
        );

        verifyNever(() => ref.putFile(any(), any()));
      });
    }

    test('does not write when metadata access is denied', () async {
      final ref = stubUpload();
      final file = fileWith('photo.jpg', _jpegMagic);
      final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
      when(ref.getMetadata).thenThrow(
        FirebaseException(plugin: 'firebase_storage', code: 'unauthorized'),
      );

      await expectLater(
        service.uploadQueuedImage('j1', file, intent),
        throwsA(isA<FirebaseException>()),
      );

      verifyNever(() => ref.putFile(any(), any()));
    });

    test('does not write after exit during the metadata read', () async {
      final ref = stubUpload();
      final file = fileWith('photo.jpg', _jpegMagic);
      final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
      var current = true;
      when(ref.getMetadata).thenAnswer((_) async {
        current = false;
        throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'object-not-found',
        );
      });

      await expectLater(
        service.uploadQueuedImage('j1', file, intent, isCurrent: () => current),
        throwsStateError,
      );

      verifyNever(() => ref.putFile(any(), any()));
    });

    test('does not upload bytes modified after the intent was saved', () async {
      stubUpload();
      final file = fileWith('photo.jpg', _jpegMagic);
      final intent = await ImageUploadIntent.prepare('j1', 'uid-1', file);
      file.writeAsBytesSync([..._jpegMagic, 1]);

      await expectLater(
        service.uploadQueuedImage('j1', file, intent),
        throwsStateError,
      );

      verifyNever(() => storage.ref(any()));
    });
  });

  group('the format gate', () {
    test('accepts a JPEG by its magic bytes', () async {
      stubUpload();

      final image = await service.uploadImage(
        'j1',
        fileWith('photo.jpg', _jpegMagic),
      );

      expect(image.storagePath, startsWith('appointments/j1/images/'));
    });

    test('accepts a PNG by its magic bytes', () async {
      stubUpload();

      final image = await service.uploadImage(
        'j1',
        fileWith('photo.png', _pngMagic),
      );

      expect(image.storagePath, startsWith('appointments/j1/images/'));
    });

    test('rejects a GIF renamed to .jpg — the extension is not the gate', () {
      // Extension and MIME type are attacker-controlled, so the first four
      // bytes are the real format check on this side.
      stubUpload();

      return expectLater(
        service.uploadImage('j1', fileWith('evil.jpg', _gifMagic)),
        throwsA(isA<ImageUploadFailureInvalidFormat>()),
      );
    });

    test('rejects a three-byte PNG prefix with the wrong fourth byte', () {
      // `89 50 4E` alone is not the PNG signature. While this side accepted it
      // on three bytes and the server required four, the upload succeeded and
      // was then deleted server-side — the photo silently vanished with no
      // error on either side.
      stubUpload();

      return expectLater(
        service.uploadImage('j1', fileWith('nearly.png', _almostPngMagic)),
        throwsA(isA<ImageUploadFailureInvalidFormat>()),
      );
    });

    test('never reaches Storage for a rejected file', () async {
      stubUpload();

      await expectLater(
        service.uploadImage('j1', fileWith('evil.jpg', _gifMagic)),
        throwsA(isA<ImageUploadFailureInvalidFormat>()),
      );

      verifyNever(() => storage.ref(any()));
    });
  });

  group('the 8 MB cap', () {
    test('accepts a file exactly at the cap', () async {
      stubUpload();

      final image = await service.uploadImage(
        'j1',
        fileWith(
          'big.jpg',
          _jpegMagic,
          padTo: ImageStorageService.maxUploadBytes,
        ),
      );

      expect(image.storagePath, isNotEmpty);
    });

    test('rejects a file one byte over the cap', () {
      stubUpload();

      return expectLater(
        service.uploadImage(
          'j1',
          fileWith(
            'huge.jpg',
            _jpegMagic,
            padTo: ImageStorageService.maxUploadBytes + 1,
          ),
        ),
        throwsA(isA<ImageUploadFailureTooLarge>()),
      );
    });
  });

  group('composeFileName', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('prefixes the millisecond stamp', () {
      expect(
        ImageStorageService.composeFileName('photo.jpg', now),
        '1700000000000_photo.jpg',
      );
    });

    test('bounds an over-long basename at the rules cap', () {
      // `fileName` is capped at 300 by the appointment-images subcollection
      // rule, and `appendAppointmentPictures` writes the whole batch in ONE
      // WriteBatch — so one over-long name fails the batch with an opaque
      // `permission-denied` and takes the valid photos with it.
      final name = ImageStorageService.composeFileName('x' * 500, now);

      expect(name, hasLength(TextLimits.imageFileName));
      expect(name, startsWith('1700000000000_'));
    });

    test('an upload composes its stored name through this helper', () async {
      // The truncation itself cannot be driven end-to-end: a basename long
      // enough to cross the 300 cap is longer than the host filesystem will
      // let the picker's temp file be named. So pin the WIRING here and the
      // bound in the test above — together they say the stored name is
      // bounded.
      stubUpload();
      final basename = '${'x' * 120}.jpg';

      final image = await service.uploadImage(
        'j1',
        fileWith(basename, _jpegMagic),
      );

      expect(
        image.fileName,
        matches(RegExp(r'^\d+_' + RegExp.escape(basename) + r'$')),
      );
      expect(image.storagePath, 'appointments/j1/images/${image.fileName}');
      expect(
        image.fileName!.length,
        lessThanOrEqualTo(TextLimits.imageFileName),
      );
    });
  });

  group('the retired download url', () {
    // `uploadImage` used to call `getDownloadURL()` and persist the result into
    // `pictures[]`. That link's token is stable per object, never expires and
    // serves the bytes with no auth and no `storage.rules` evaluation — so
    // every upload manufactured a permanent rules-free copy of a job photo.
    // The CONTRACT step removed the write with the array that carried it.
    test('never mints one', () async {
      final ref = stubUpload();

      final image = await service.uploadImage(
        'j1',
        fileWith('photo.jpg', _jpegMagic),
      );

      verifyNever(ref.getDownloadURL);
      expect(image.url, isEmpty);
      expect(image.storagePath, startsWith('appointments/j1/images/'));
    });

    test('a legacy url still resolves an object to DELETE', () async {
      // Reading one is not minting one: documents written before `storagePath`
      // existed carry only a url, and it is the sole handle on their bytes.
      final ref = _MockRef();
      when(
        () => storage.ref('appointments/j1/images/legacy.jpg'),
      ).thenReturn(ref);
      when(ref.delete).thenAnswer((_) async {});

      await service.deleteImages(const [
        AppointmentImage(
          url:
              'https://firebasestorage.googleapis.com/v0/b/b/o/'
              'appointments%2Fj1%2Fimages%2Flegacy.jpg?alt=media',
        ),
      ]);

      verify(ref.delete).called(1);
    });
  });

  group('deleting an image', () {
    test('deletes by storagePath when the doc has one', () async {
      final ref = _MockRef();
      when(() => storage.ref('appointments/j1/images/1_a.jpg')).thenReturn(ref);
      when(ref.delete).thenAnswer((_) async {});

      await service.deleteImages(const [
        AppointmentImage(
          url: 'https://firebasestorage.googleapis.com/v0/b/b/o/other.jpg',
          storagePath: 'appointments/j1/images/1_a.jpg',
        ),
      ]);

      verify(ref.delete).called(1);
      expect(logger.warnings, isEmpty);
    });

    test('falls back to the path encoded in a legacy download url', () async {
      // Docs written before storagePath existed have nothing else to locate
      // the object by; without this the bytes orphan on every delete.
      final ref = _MockRef();
      when(() => storage.ref('appointments/j1/images/1_a.jpg')).thenReturn(ref);
      when(ref.delete).thenAnswer((_) async {});

      await service.deleteImages(const [
        AppointmentImage(
          url:
              'https://firebasestorage.googleapis.com/v0/b/bucket/o/'
              'appointments%2Fj1%2Fimages%2F1_a.jpg?alt=media&token=abc',
        ),
      ]);

      verify(ref.delete).called(1);
      expect(logger.warnings, isEmpty);
    });

    test(
      'does nothing for a doc with neither a path nor a usable url',
      () async {
        await service.deleteImages(const [
          AppointmentImage(url: 'https://example.com/no-object-segment.jpg'),
          AppointmentImage(),
        ]);

        verifyNever(() => storage.ref(any()));
        expect(logger.warnings, isEmpty);
      },
    );

    test('swallows object-not-found — the bytes are already gone', () async {
      final ref = _MockRef();
      when(() => storage.ref(any())).thenReturn(ref);
      when(ref.delete).thenThrow(
        FirebaseException(plugin: 'firebase_storage', code: 'object-not-found'),
      );

      await service.deleteImages(const [
        AppointmentImage(storagePath: 'appointments/j1/images/1_a.jpg'),
      ]);

      // Nothing orphaned, so nothing to report — logging it would file a
      // non-fatal for a delete that achieved exactly what it set out to.
      expect(logger.warnings, isEmpty);
    });

    test('reports any other failure as orphaned bytes', () async {
      final ref = _MockRef();
      when(() => storage.ref(any())).thenReturn(ref);
      when(ref.delete).thenThrow(
        FirebaseException(plugin: 'firebase_storage', code: 'unauthorized'),
      );

      await service.deleteImages(const [
        AppointmentImage(storagePath: 'appointments/j1/images/1_a.jpg'),
      ]);

      expect(logger.warnings.single, startsWith('IMG-DEL'));
      expect(
        logger.warnings.single,
        contains('appointments/j1/images/1_a.jpg'),
      );
    });

    test('one failure does not abandon the rest of the batch', () async {
      final failing = _MockRef();
      final ok = _MockRef();
      when(() => storage.ref('bad')).thenReturn(failing);
      when(() => storage.ref('good')).thenReturn(ok);
      when(failing.delete).thenThrow(
        FirebaseException(plugin: 'firebase_storage', code: 'unauthorized'),
      );
      when(ok.delete).thenAnswer((_) async {});

      await service.deleteImages(const [
        AppointmentImage(storagePath: 'bad'),
        AppointmentImage(storagePath: 'good'),
      ]);

      verify(ok.delete).called(1);
      expect(logger.warnings, hasLength(1));
    });
  });
}
