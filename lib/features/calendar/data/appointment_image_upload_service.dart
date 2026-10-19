import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/image_upload_failure.dart';
import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/pending_upload_store.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/photo_upload_expiry.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:uuid/uuid.dart';

typedef _UploadFilesResult = ({
  List<AppointmentImage> uploaded,
  List<String> survivors,
  List<String> tooLargeNames,
  int permanentFailures,
  bool transientFailure,
});

class AppointmentImageUploadService {
  AppointmentImageUploadService({
    required AppointmentsRepository appointments,
    required PhotoUploadNotifier notifier,
    ImageStorageService? storage,
    AppLogger? logger,
    PendingUploadStore? store,
    Future<Directory> Function()? stagingDirProvider,
    FirebaseAuth? auth,
    Future<String?> Function(String uid)? employeeIdForUid,
    SessionFence? session,
  }) : _appointments = appointments,
       _notifier = notifier,
       _storage = storage ?? ImageStorageService(),
       _logger = logger ?? AppLogger(),
       _store = store ?? PendingUploadStore(),
       _stagingDirProvider = stagingDirProvider ?? _defaultStagingDir,
       _auth = auth ?? FirebaseAuth.instance,
       _employeeIdForUid = employeeIdForUid {
    _session = session ?? SessionFence(readUid: () => _auth.currentUser?.uid);
  }

  final AppointmentsRepository _appointments;
  final PhotoUploadNotifier _notifier;
  final ImageStorageService _storage;
  final AppLogger _logger;
  final PendingUploadStore _store;

  final Future<Directory> Function() _stagingDirProvider;
  final FirebaseAuth _auth;
  final Future<String?> Function(String uid)? _employeeIdForUid;
  late final SessionFence _session;
  int _queueGeneration = 0;

  bool _draining = false;
  final Set<Future<void>> _stagingJobs = {};
  Object? _exitHold;
  SessionLease? _exitHoldLease;

  /// Set when an active drain should loop again.
  bool _pendingDrain = false;

  static Future<Directory> _defaultStagingDir() async {
    final base = await getApplicationSupportDirectory();
    return await Directory(
      _pathIn(base.path, 'pending_uploads'),
    ).create(recursive: true);
  }

  /// Stages files and starts the background upload.
  void uploadInBackground({
    required String appointmentId,
    required List<File> newImages,
  }) {
    unawaited(
      enqueuePhotos(appointmentId: appointmentId, newImages: newImages),
    );
  }

  /// Waits for the local handoff attempt; network transfer stays in the drain.
  Future<void> enqueuePhotos({
    required String appointmentId,
    required List<File> newImages,
  }) {
    if (newImages.isEmpty) return Future<void>.value();
    final job = _stageAndRun(appointmentId, List.of(newImages));
    _stagingJobs.add(job);
    return job.whenComplete(() => _stagingJobs.remove(job));
  }

  Future<void> _stageAndRun(String appointmentId, List<File> images) async {
    final lease = _session.capture();
    final generation = _queueGeneration;
    bool current() =>
        lease?.isCurrent == true && generation == _queueGeneration;
    try {
      final dir = await _stagingDirProvider();
      final owner = await _currentOwner();
      if (!current()) throw StateError('photo staging session ended');
      final enqueuedAtMs = DateTime.now().millisecondsSinceEpoch;
      final batchId = const Uuid().v4();
      final sources = <String, String>{};
      for (var i = 0; i < images.length; i++) {
        final name = _fileName(images[i]);
        final suffix = name.length > 160
            ? name.substring(name.length - 160)
            : name;
        sources[_pathIn(dir.path, '${batchId}_${i}_$suffix')] = images[i].path;
      }
      final entry = PendingUpload(
        appointmentId: appointmentId,
        paths: sources.keys.toList(),
        enqueuedAtMs: enqueuedAtMs,
        ownerUid: owner.uid,
        ownerEmployeeId: owner.employeeId,
        batchId: batchId,
        stagingSources: sources,
      );
      final journal = File(_pathIn(dir.path, 'staging_$batchId.json'));
      final partialJournal = File('${journal.path}.part');
      await partialJournal.writeAsString(
        jsonEncode(entry.toJson()),
        flush: true,
      );
      await partialJournal.rename(journal.path);
      if (!current()) return;
      await _store.add(entry);
      await _deleteQuietly(journal);
      if (!current()) return;
      // Published BEFORE the drain, so an offline device shows "waiting"
      // immediately rather than only after the attempt has failed.
      await _publishPending();
      // Drains are serialized to avoid duplicate upload passes.
      unawaited(drainPending());
    } catch (e, st) {
      if (current()) {
        _notifier.reportFailure(appointmentId, failedCount: images.length);
      }
      _logger.warn('IMG-UPLOAD staging failed for $appointmentId', e, st);
    }
  }

  /// A source already gone (iOS tmp purge) is dropped and counted as lost.
  Future<({PendingUpload entry, int lostCount})?> _finishStaging(
    PendingUpload entry,
    bool Function() current,
  ) async {
    final lost = <String>[];
    for (final item in entry.stagingSources.entries) {
      if (!current()) return null;
      final target = File(item.key);
      if (target.existsSync()) continue;
      final source = File(item.value);
      if (!source.existsSync()) {
        lost.add(target.path);
        continue;
      }
      final partial = File('${target.path}.part');
      await source.copy(partial.path);
      if (!current()) return null;
      await partial.rename(target.path);
    }
    if (lost.isNotEmpty) {
      _logger.warn(
        'IMG-UPLOAD staging source missing for ${entry.appointmentId}: '
        '${lost.length} photo(s) lost',
      );
    }
    final staged = entry.copyWith(
      paths: [
        for (final path in entry.paths)
          if (!lost.contains(path)) path,
      ],
      stagingSources: const {},
      cleanupPaths: [
        ...entry.cleanupPaths,
        ...entry.stagingSources.values,
        for (final path in lost) '$path.part',
      ],
    );
    if (!current() || !await _store.checkpoint(entry.id, staged)) return null;
    return current() ? (entry: staged, lostCount: lost.length) : null;
  }

  Future<void> _recoverStagingJournals(
    String uid,
    bool Function() current,
  ) async {
    final directory = await _stagingDirProvider();
    if (!current()) return;
    await for (final entity in directory.list()) {
      if (!current()) return;
      if (entity is! File ||
          !entity.uri.pathSegments.last.startsWith('staging_') ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      final entry = PendingUpload.fromJson(
        jsonDecode(await entity.readAsString()),
      );
      if (!current()) return;
      if (entry == null || !entry.hasOwner || entry.ownerUid != uid) continue;
      await _store.add(entry);
      if (!current()) return;
      if (!await _deleteQuietly(entity)) {
        throw StateError('staging journal cleanup failed');
      }
    }
  }

  /// Null when the session ended or a newer exit superseded this one.
  Future<PendingPhotoExit?> prepareForExit() async {
    final lease = _session.capture();
    if (lease == null) return null;
    final hold = Object();
    _exitHold = hold;
    _exitHoldLease = lease;
    void resume() {
      if (!identical(_exitHold, hold)) return;
      _exitHold = null;
      _exitHoldLease = null;
      if (_auth.currentUser?.uid == lease.uid) unawaited(drainPending());
    }

    try {
      while (_stagingJobs.isNotEmpty) {
        await Future.wait(List.of(_stagingJobs));
      }
      if (!lease.isCurrent || !identical(_exitHold, hold)) {
        resume();
        return null;
      }
      _queueGeneration++;
      await _recoverStagingJournals(
        lease.uid,
        () => lease.isCurrent && identical(_exitHold, hold),
      );
      final entries = await _store.load();
      if (!lease.isCurrent || !identical(_exitHold, hold)) {
        resume();
        return null;
      }
      final count = entries
          .where((entry) => entry.hasOwner && entry.ownerUid == lease.uid)
          .fold(
            0,
            (count, entry) =>
                count + entry.paths.length + entry.uploaded.length,
          );
      return PendingPhotoExit(
        pendingCount: count,
        onResume: resume,
        readCurrent: () => lease.isCurrent && identical(_exitHold, hold),
      );
    } catch (_) {
      resume();
      rethrow;
    }
  }

  /// The read path chunks at 4; nothing about a write wants a smaller bound.
  static const int _maxConcurrentUploads = 4;

  /// One file's upload, classified. Never throws — the classification IS the
  /// result, so a chunk's `Future.wait` cannot lose its siblings to one throw.
  Future<_UploadOneResult> _uploadOne(
    PendingUpload entry,
    File file,
    bool Function() current,
  ) async {
    try {
      final intent = entry.intents[file.path]!;
      if (intent.ownerUid != entry.ownerUid || !current()) {
        throw StateError('photo upload owner changed');
      }
      final image = await _storage.uploadQueuedImage(
        entry.appointmentId,
        file,
        intent,
        isCurrent: current,
      );
      return _UploadedOne(image);
    } on ImageUploadFailure catch (e, st) {
      _logger.warn(
        'IMG-UPLOAD rejected file for ${entry.appointmentId}',
        e,
        st,
      );
      return _RejectedOne(
        e is ImageUploadFailureTooLarge ? _fileName(file) : null,
      );
    } catch (e, st) {
      _logger.warn(
        'IMG-UPLOAD transient failure for ${entry.appointmentId}',
        e,
        st,
      );
      return _TransientOne(file.path);
    }
  }

  /// Upload result for one pass over a batch's local files.
  Future<_UploadFilesResult> _uploadFiles(
    PendingUpload entry,
    List<File> files,
    bool Function() current,
  ) async {
    var permanentFailures = 0;
    var transientFailure = false;
    final tooLargeNames = <String>[];
    final survivors = <String>[];

    // Previously uploaded images are retried append-only.
    final uploaded = <AppointmentImage>[...entry.uploaded];

    // Chunked like the read path; the per-file try/catch stays INSIDE the mapped function.
    for (var i = 0; i < files.length; i += _maxConcurrentUploads) {
      final chunk = files.skip(i).take(_maxConcurrentUploads).toList();
      final results = await Future.wait([
        for (final file in chunk) _uploadOne(entry, file, current),
      ]);
      for (final result in results) {
        switch (result) {
          case _UploadedOne(:final image):
            uploaded.add(image);
          case _RejectedOne(:final tooLargeName):
            permanentFailures++;
            if (tooLargeName != null) tooLargeNames.add(tooLargeName);
          case _TransientOne(:final path):
            transientFailure = true;
            survivors.add(path);
        }
      }
      if (!current()) throw StateError('photo upload session ended');
      final cleanupPaths = [
        ...entry.cleanupPaths,
        for (final file in files.take(i + chunk.length))
          if (!survivors.contains(file.path)) file.path,
      ];
      // Save receipts before deleting originals or starting the next chunk.
      final saved = await _store.checkpoint(
        entry.id,
        entry.copyWith(
          paths: [
            ...survivors,
            ...files.skip(i + chunk.length).map((file) => file.path),
          ],
          uploaded: uploaded,
          intents: entry.intents,
          cleanupPaths: cleanupPaths,
        ),
      );
      if (!saved) throw StateError('pending photo batch was removed');
      if (!current()) throw StateError('photo upload session ended');
      for (final file in chunk) {
        if (!survivors.contains(file.path)) await _deleteQuietly(file);
      }
    }

    return (
      uploaded: uploaded,
      survivors: survivors,
      tooLargeNames: tooLargeNames,
      permanentFailures: permanentFailures,
      transientFailure: transientFailure,
    );
  }

  /// Links uploaded photos and reports whether the append failed.
  Future<bool> _appendLinks(
    PendingUpload entry,
    List<AppointmentImage> uploaded,
  ) async {
    if (uploaded.isEmpty) return false;
    try {
      // Derived photo ids make partial append retries idempotent.
      await _appointments.appendAppointmentPictures(
        entry.appointmentId,
        uploaded,
      );
      return false;
    } catch (e, st) {
      // Re-queue uploaded images for an append-only retry.
      _logger.warn(
        'IMG-UPLOAD append failed for ${entry.appointmentId}',
        e,
        st,
      );
      return true;
    }
  }

  /// Uploads one queued batch and updates its queue entry.
  Future<void> _attempt(PendingUpload queued, bool Function() current) async {
    var entry = queued;
    if (!await _matchesCurrentOwner(entry)) {
      _logger.warn(
        'IMG-UPLOAD skipped queue entry for ${entry.appointmentId}: '
        '${entry.hasOwner ? 'owner mismatch' : 'no owner (pre-upgrade entry)'}',
      );
      return;
    }
    if (!current()) return;
    var lostCount = 0;
    if (entry.stagingSources.isNotEmpty) {
      try {
        final staged = await _finishStaging(entry, current);
        if (staged == null) return;
        entry = staged.entry;
        lostCount = staged.lostCount;
      } catch (error, stack) {
        if (current()) {
          _notifier.reportFailure(
            entry.appointmentId,
            failedCount: entry.paths.length,
          );
        }
        // Originals stay for the next drain; later batches still run.
        _logger.warn('IMG-UPLOAD staged copy failed', error, stack);
        return;
      }
    }
    for (final path in entry.cleanupPaths) {
      if (!await _deleteQuietly(File(path))) return;
      if (!current()) return;
    }
    final files = entry.paths
        .map(File.new)
        .where((f) => f.existsSync())
        .toList();
    if (files.isEmpty && entry.uploaded.isEmpty) {
      await _store.remove(entry.id);
      if (current()) {
        _notifier.reportFailure(entry.appointmentId, failedCount: lostCount);
      }
      return;
    }

    final intents = {...entry.intents};
    for (final file in files) {
      intents[file.path] ??= await ImageUploadIntent.prepare(
        entry.appointmentId,
        entry.ownerUid,
        file,
      );
      if (!current()) return;
    }
    entry = entry.copyWith(intents: intents);
    if (!await _store.checkpoint(entry.id, entry) || !current()) return;
    final upload = await _uploadFiles(entry, files, current);
    if (!current()) return;
    final appendThrew = await _appendLinks(entry, upload.uploaded);
    if (!current()) return;
    await _settle(
      entry,
      files,
      upload,
      appendThrew: appendThrew,
      lostCount: lostCount,
      current: current,
    );
  }

  /// Requeues the unsent remainder or settles the batch, then reports it.
  Future<void> _settle(
    PendingUpload entry,
    List<File> files,
    _UploadFilesResult upload, {
    required bool appendThrew,
    required int lostCount,
    required bool Function() current,
  }) async {
    final survivors = upload.survivors;
    final outcome = AttemptOutcome.from(
      permanentFailures: upload.permanentFailures,
      transientFailure: upload.transientFailure,
      survivors: survivors,
      appendThrew: appendThrew,
      uploaded: upload.uploaded,
    );
    final failedCount = outcome.failedCount + lostCount;

    if (outcome.requeue) {
      // Replace atomically so failed requeues leave the original entry intact.
      await _store.replace(
        entry.id,
        entry.copyWith(
          paths: survivors,
          uploaded: outcome.uploadedToCarry,
          intents: {for (final path in survivors) path: entry.intents[path]!},
          cleanupPaths: [
            ...entry.cleanupPaths,
            for (final file in files)
              if (!survivors.contains(file.path) && file.existsSync())
                file.path,
          ],
        ),
      );
      if (!current()) return;
      _notifier.reportFailure(
        entry.appointmentId,
        failedCount: failedCount,
        tooLargeFileNames: upload.tooLargeNames,
      );
      return;
    }
    final cleanupPaths = [
      for (final file in files)
        if (!survivors.contains(file.path) && file.existsSync()) file.path,
    ];
    if (cleanupPaths.isEmpty) {
      await _store.remove(entry.id);
    } else {
      await _store.checkpoint(
        entry.id,
        entry.copyWith(
          paths: const [],
          uploaded: const [],
          intents: const {},
          cleanupPaths: cleanupPaths,
        ),
      );
    }
    if (!current()) return;
    if (failedCount > 0) {
      _notifier.reportFailure(
        entry.appointmentId,
        failedCount: failedCount,
        tooLargeFileNames: upload.tooLargeNames,
      );
    } else {
      _notifier.clearFailure(entry.appointmentId);
    }
  }

  /// Drains queued batches without running two drains at once.
  Future<void> drainPending() async {
    if (_exitHold != null && _exitHoldLease?.isCurrent == true) return;
    _exitHold = null;
    _exitHoldLease = null;
    if (_draining) {
      _pendingDrain = true;
      return;
    }
    _draining = true;
    try {
      do {
        _pendingDrain = false;
        _drainOwnerResolved = false;
        _drainOwner = null;
        final lease = _session.capture();
        final generation = _queueGeneration;
        bool current() =>
            lease?.isCurrent == true && generation == _queueGeneration;
        if (!current() || _exitHold != null) continue;
        _drainOwner = await _currentOwnerOrNull();
        _drainOwnerResolved = true;
        if (!current()) continue;
        try {
          await _recoverStagingJournals(lease!.uid, current);
          if (!current()) continue;
          final expired = await _store.prune(now: DateTime.now());
          if (!current()) continue;
          for (final e in expired) {
            for (final p in [
              ...e.paths,
              ...e.cleanupPaths,
              ...e.stagingSources.values,
              for (final target in e.stagingSources.keys) '$target.part',
            ]) {
              await _deleteQuietly(File(p));
            }
          }
          for (final entry in await _store.load()) {
            if (!current()) break;
            try {
              await _attempt(entry, current);
            } catch (e, st) {
              // One bad batch must not strand every batch queued after it.
              _logger.warn(
                'IMG-UPLOAD queue entry failed for ${entry.appointmentId}',
                e,
                st,
              );
            }
            if (!current()) break;
            // Per entry, not per drain: a long queue should visibly shrink.
            await _publishPending();
          }
          if (current()) await _publishPending();
        } catch (e, st) {
          _logger.warn('IMG-UPLOAD drain failed', e, st);
          // A failed drain leaves the queue as it was; republish so the waiting
          // count is never left stale by the failure path.
          if (current()) await _publishPending();
        }
        _drainOwnerResolved = false;
        _drainOwner = null;
      } while (_pendingDrain);
    } finally {
      _drainOwnerResolved = false;
      _drainOwner = null;
      _draining = false;
    }
  }

  Future<void> clearPending() async {
    _queueGeneration++;
    _exitHold = null;
    _exitHoldLease = null;
    _notifier.reportPending(const {});
    _notifier.expired.value = const [];
    final lease = _session.capture(duringExit: true);
    if (lease == null) return;
    final generation = _queueGeneration;
    bool current() => lease.isCurrent && generation == _queueGeneration;
    await _recoverStagingJournals(lease.uid, current);
    if (!current()) return;
    final entries = await _store.clearOwner(lease.uid, isCurrent: current);
    for (final entry in entries) {
      if (!current()) return;
      for (final path in [
        ...entry.paths,
        ...entry.cleanupPaths,
        ...entry.stagingSources.values,
        for (final target in entry.stagingSources.keys) '$target.part',
      ]) {
        if (!current()) return;
        await _deleteQuietly(File(path));
      }
      if (!current()) return;
      _notifier.clearFailure(entry.appointmentId);
    }
    if (current()) await _publishPending();
  }

  Future<({String uid, String employeeId})> _currentOwner() async {
    final lease = _session.capture();
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('signed out');
    final employeeId = await _employeeIdForUid?.call(uid);
    if (lease?.isCurrent != true) throw StateError('photo owner session ended');
    if (employeeId == null || employeeId.isEmpty) {
      throw StateError('no users doc for uid');
    }
    return (uid: uid, employeeId: employeeId);
  }

  /// Memoised only within one generation-fenced drain pass.
  ({String uid, String employeeId})? _drainOwner;
  bool _drainOwnerResolved = false;

  Future<({String uid, String employeeId})?> _currentOwnerOrNull() async {
    if (_drainOwnerResolved) return _drainOwner;
    try {
      return await _currentOwner();
    } catch (e, st) {
      // Without this the caller reports "owner mismatch", so a signed-out or
      // failed resolve reads as another ACCOUNT having staged the photos.
      _logger.warn('IMG-UPLOAD could not resolve the queue owner', e, st);
      return null;
    }
  }

  Future<bool> _matchesCurrentOwner(PendingUpload entry) async {
    if (!entry.hasOwner) return false;
    final owner = await _currentOwnerOrNull();
    return owner != null &&
        owner.uid == entry.ownerUid &&
        owner.employeeId == entry.ownerEmployeeId;
  }

  /// Republishes the queue depth per appointment from the store itself.
  Future<void> acknowledgeExpiry(Set<String> ids) async {
    final lease = _session.capture();
    if (lease == null) return;
    await _store.acknowledgeExpiry(lease.uid, ids);
    if (lease.isCurrent) _notifier.expired.value = const [];
  }

  Future<void> _publishPending() async {
    final lease = _session.capture();
    try {
      final counts = <String, int>{};
      final owner = await _currentOwnerOrNull();
      if (owner != null && owner.uid != lease?.uid) return;
      for (final entry in await _store.load()) {
        if (owner == null ||
            !entry.hasOwner ||
            entry.ownerUid != owner.uid ||
            entry.ownerEmployeeId != owner.employeeId) {
          continue;
        }
        counts[entry.appointmentId] =
            (counts[entry.appointmentId] ?? 0) +
            entry.paths.length +
            entry.uploaded.length;
      }
      final expired = owner == null
          ? const <PhotoUploadExpiry>[]
          : await _store.expiredFor(owner.uid);
      if (lease?.isCurrent == true) {
        _notifier.reportPending(counts);
        _notifier.expired.value = expired;
      }
    } catch (e, st) {
      // Never let the SIGNAL break the upload: this is a status read.
      _logger.warn('IMG-UPLOAD pending count failed', e, st);
    }
  }

  Future<bool> _deleteQuietly(File f) async {
    try {
      if (f.existsSync()) await f.delete();
      return true;
    } catch (e, st) {
      _logger.warn('IMG-UPLOAD cleanup failed for ${f.path}', e, st);
      return false;
    }
  }

  static String _fileName(File file) {
    final segments = file.uri.pathSegments;
    return segments.isNotEmpty ? segments.last : file.path;
  }

  static String _pathIn(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}

/// Queue decision from one upload attempt.
@visibleForTesting
class AttemptOutcome {
  const AttemptOutcome({
    required this.requeue,
    required this.uploadedToCarry,
    required this.failedCount,
  });

  factory AttemptOutcome.from({
    required int permanentFailures,
    required bool transientFailure,
    required List<String> survivors,
    required bool appendThrew,
    required List<AppointmentImage> uploaded,
  }) {
    final requeue = transientFailure || appendThrew;
    final retryableFailures =
        survivors.length + (appendThrew ? uploaded.length : 0);
    return AttemptOutcome(
      requeue: requeue,
      uploadedToCarry: appendThrew ? uploaded : const [],
      // Permanent failures still count when retryable failures requeue.
      failedCount: requeue
          ? retryableFailures + permanentFailures
          : permanentFailures,
    );
  }

  /// Whether the entry goes back on the queue instead of draining away.
  final bool requeue;

  /// Already-uploaded images to carry for append-only retry.
  final List<AppointmentImage> uploadedToCarry;

  /// Failed photo count reported to the notifier.
  final int failedCount;
}

final appointmentImageUploadProvider = Provider<AppointmentImageUploadService>((
  ref,
) {
  return AppointmentImageUploadService(
    appointments: ref.watch(appointmentsRepositoryProvider),
    notifier: ref.watch(photoUploadNotifierProvider),
    session: ref.watch(sessionFenceProvider),
    employeeIdForUid: (uid) async {
      final match = await ref
          .read(employeesRepositoryProvider)
          .findUserByUid(uid);
      return match?.id;
    },
  );
});

/// One file's outcome inside a chunk.
sealed class _UploadOneResult {
  const _UploadOneResult();
}

class _UploadedOne extends _UploadOneResult {
  const _UploadedOne(this.image);

  final AppointmentImage image;
}

class _RejectedOne extends _UploadOneResult {
  const _RejectedOne(this.tooLargeName);

  /// Non-null only when the file was refused for size.
  final String? tooLargeName;
}

class _TransientOne extends _UploadOneResult {
  const _TransientOne(this.path);

  final String path;
}
