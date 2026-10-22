import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:scheduling/core/images/image_magic.dart';
import 'package:scheduling/core/images/image_upload_failure.dart';
import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/performance/performance_trace.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

class ImageStorageService {
  ImageStorageService({FirebaseStorage? storage, AppLogger? logger})
    : _storage = storage ?? FirebaseStorage.instance,
      _logger = logger ?? AppLogger();

  static const int maxUploadBytes = 8 * 1024 * 1024;

  final FirebaseStorage _storage;
  final AppLogger _logger;

  Future<bool> _isValidImageFile(File file) async {
    final raf = await file.open();
    try {
      return hasValidImageMagic(await raf.read(4));
    } finally {
      await raf.close();
    }
  }

  Future<AppointmentImage> uploadQueuedImage(
    String appointmentId,
    File file,
    ImageUploadIntent intent, {
    bool Function()? isCurrent,
  }) async {
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) {
        throw StateError('photo upload session ended');
      }
    }

    checkCurrent();
    final image = intent.image;
    final fileName = image.fileName ?? '';
    final expectedPrefix = 'appointments/$appointmentId/images/';
    if (image.storagePath != '$expectedPrefix${image.fileName}' ||
        !RegExp(
          '^${RegExp.escape(intent.uploadId)}\\.(jpg|png)\$',
        ).hasMatch(fileName)) {
      throw StateError('invalid queued photo destination');
    }
    if (!await _isValidImageFile(file)) {
      throw const ImageUploadFailureInvalidFormat();
    }
    final size = await file.length();
    if (size > maxUploadBytes) throw const ImageUploadFailureTooLarge();
    final digest = await sha256.bind(file.openRead()).first;
    checkCurrent();
    if (size != intent.byteLength || digest.toString() != intent.digest) {
      throw StateError('queued photo bytes changed');
    }
    final ref = _storage.ref(image.storagePath);
    FullMetadata? existing;
    try {
      existing = await ref.getMetadata();
    } on FirebaseException catch (error) {
      if (error.code != 'object-not-found') rethrow;
    }
    checkCurrent();
    if (existing != null) {
      final metadata = existing.customMetadata ?? const <String, String>{};
      if (existing.size != size ||
          intent.metadata.entries.any(
            (item) => metadata[item.key] != item.value,
          )) {
        throw StateError('queued photo object does not match its upload');
      }
      return image;
    }
    await PerformanceTrace.measure(
      PerformanceOperation.photoUpload,
      () => ref.putFile(
        file,
        SettableMetadata(
          contentType: _contentTypeFor(fileName),
          cacheControl: 'private, max-age=31536000',
          customMetadata: intent.metadata,
        ),
      ),
    );
    checkCurrent();
    return image;
  }

  Future<void> _deleteImage(AppointmentImage image) async {
    final path = image.storagePath.isNotEmpty
        ? image.storagePath
        : _pathFromUrl(image.url);
    if (path.isEmpty) return;
    try {
      await _storage.ref(path).delete();
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return;
      rethrow;
    }
  }

  Future<void> deleteImages(List<AppointmentImage> images) async {
    await Future.wait(
      images.map((img) async {
        try {
          await _deleteImage(img);
        } catch (e, st) {
          _logger.warn(
            'IMG-DEL deleteImage failed (orphaned bytes): ${img.storagePath}',
            e,
            st,
          );
        }
      }),
    );
  }

  String _pathFromUrl(String url) {
    if (url.isEmpty) return '';
    try {
      final parts = url.split('/o/');
      if (parts.length < 2) return '';
      final encoded = parts[1].split('?').first;
      return Uri.decodeComponent(encoded);
    } catch (e, st) {
      _logger.warn('IMG-DEL pathFromUrl failed', e, st);
      return '';
    }
  }

  String _contentTypeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    return 'image/jpeg';
  }
}
