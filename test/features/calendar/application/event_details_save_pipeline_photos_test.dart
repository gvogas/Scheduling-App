import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/application/event_details_save_pipeline.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

class _MockStorage extends Mock implements ImageStorageService {}

class _MockUploader extends Mock implements AppointmentImageUploadService {}

/// Pins `applyPhotoChanges`' ORDERING, which is the stated reason
/// `EventDetailsSavePipeline` exists at all: "deleting orphaned bytes only
/// AFTER the doc stops pointing at them."
///
/// The delete-appointment path was already covered; the SAVE path — where a
/// photo is removed from a job that continues to exist — was not, and it is
/// the one with the sharper failure. Deleting the bytes first leaves the array
/// pointing at objects that no longer exist, so every device renders a broken
/// tile for a photo the doc still claims to have; the repository's own comment
/// notes `arrayRemove` matches by deep equality and "cannot silently miss" only
/// because the caller hands back images parsed from that very doc.
void main() {
  late _MockRepo repo;
  late _MockStorage storage;
  late _MockUploader uploader;
  late List<String> calls;

  const removed = AppointmentImage(
    url: 'https://example.com/1.jpg',
    storagePath: 'appointments/a1/images/1.jpg',
    fileName: '1.jpg',
  );

  setUpAll(() {
    registerFallbackValue(<AppointmentImage>[]);
    registerFallbackValue(<File>[]);
  });

  setUp(() {
    repo = _MockRepo();
    storage = _MockStorage();
    uploader = _MockUploader();
    calls = [];

    when(() => repo.removeAppointmentPictures(any(), any())).thenAnswer((
      _,
    ) async {
      calls.add('removeFromDoc');
    });
    when(() => storage.deleteImages(any())).thenAnswer((_) async {
      calls.add('deleteBytes');
    });
    when(
      () => uploader.enqueuePhotos(
        appointmentId: any(named: 'appointmentId'),
        newImages: any(named: 'newImages'),
      ),
    ).thenAnswer((_) async {
      calls.add('upload');
    });
  });

  EventDetailsSavePipeline pipeline() => EventDetailsSavePipeline(
    repo: repo,
    resolveStorage: () => storage,
    logger: AppLogger(),
  );

  test(
    'waits for local photo handoff before the save pipeline completes',
    () async {
      final entered = Completer<void>();
      final handoff = Completer<void>();
      when(
        () => uploader.enqueuePhotos(
          appointmentId: any(named: 'appointmentId'),
          newImages: any(named: 'newImages'),
        ),
      ).thenAnswer((_) {
        entered.complete();
        return handoff.future;
      });
      var completed = false;
      final saving = pipeline()
          .applyPhotoChanges(
            id: 'a1',
            uploader: uploader,
            removedImages: const [],
            newImages: [File('photo.jpg')],
          )
          .then((_) => completed = true);
      await entered.future;
      expect(completed, isFalse);

      handoff.complete();
      await saving;

      expect(completed, isTrue);
    },
  );

  test('drops the doc reference BEFORE deleting the bytes', () async {
    await pipeline().applyPhotoChanges(
      id: 'a1',
      uploader: uploader,
      removedImages: const [removed],
      newImages: const [],
      onRecordWritten: () => calls.add('onRecordWritten'),
    );

    expect(calls, ['removeFromDoc', 'onRecordWritten', 'deleteBytes']);
  });

  test('skips the doc write entirely when nothing was removed', () async {
    await pipeline().applyPhotoChanges(
      id: 'a1',
      uploader: uploader,
      removedImages: const [],
      newImages: const [],
    );

    verifyNever(() => repo.removeAppointmentPictures(any(), any()));
    // And no Storage round-trip either — `deleteOrphanedImages` returns early
    // on an empty list, which is what keeps a photo-less save off Storage.
    verifyNever(() => storage.deleteImages(any()));
  });

  test('hands new files to the uploader after the removals settle', () async {
    final file = File('${Directory.systemTemp.path}/new.jpg');

    await pipeline().applyPhotoChanges(
      id: 'a1',
      uploader: uploader,
      removedImages: const [removed],
      newImages: [file],
    );

    expect(calls, ['removeFromDoc', 'deleteBytes', 'upload']);
  });

  test('a Storage failure does not escape the save', () async {
    // Orphaned bytes are harmless; a thrown save is not. The pipeline logs and
    // continues, so the record write the user actually asked for still stands.
    when(() => storage.deleteImages(any())).thenThrow(Exception('offline'));

    await pipeline().applyPhotoChanges(
      id: 'a1',
      uploader: uploader,
      removedImages: const [removed],
      newImages: const [],
    );

    verify(() => repo.removeAppointmentPictures(any(), any())).called(1);
  });

  test('tolerates a host that is already gone when bytes are deleted', () {
    // `resolveStorage` returns null once the host is disposed — this runs
    // after several awaits. The removal must still have been applied.
    final detached = EventDetailsSavePipeline(
      repo: repo,
      resolveStorage: () => null,
      logger: AppLogger(),
    );

    expect(
      detached.applyPhotoChanges(
        id: 'a1',
        uploader: uploader,
        removedImages: const [removed],
        newImages: const [],
      ),
      completes,
    );
  });
}
