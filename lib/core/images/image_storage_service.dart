import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

import 'package:scheduling/core/images/image_magic.dart';
import 'package:scheduling/core/images/image_upload_failure.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/performance/performance_trace.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

class ImageStorageService {
  ImageStorageService({FirebaseStorage? storage, AppLogger? logger})
    : _storage = storage ?? FirebaseStorage.instance,
      _logger = logger ?? AppLogger();

  static const int maxUploadBytes = 8 * 1024 * 1024;

  final FirebaseStorage _storage;
  final AppLogger _logger;

  /// Builds a bounded `<millis>_<originalName>` storage file name.
  static String composeFileName(String originalName, DateTime now) {
    final name = '${now.millisecondsSinceEpoch}_$originalName';
    return name.length <= TextLimits.imageFileName
        ? name
        : name.substring(0, TextLimits.imageFileName);
  }

  Future<bool> _isValidImageFile(File file) async {
    final raf = await file.open();
    try {
      return hasValidImageMagic(await raf.read(4));
    } finally {
      await raf.close();
    }
  }

  Future<AppointmentImage> uploadImage(String appointmentId, File file) async {
    if (!await _isValidImageFile(file)) {
      throw const ImageUploadFailureInvalidFormat();
    }

    final size = await file.length();
    if (size > maxUploadBytes) {
      throw const ImageUploadFailureTooLarge();
    }

    final uploadedAt = DateTime.now();
    final originalName = file.uri.pathSegments.last;
    final fileName = composeFileName(originalName, uploadedAt);
    final path = 'appointments/$appointmentId/images/$fileName';

    final ref = _storage.ref(path);
    final metadata = SettableMetadata(
      contentType: _contentTypeFor(originalName),
      // Keep authenticated photo responses out of shared caches.
      cacheControl: 'private, max-age=31536000',
    );

    await PerformanceTrace.measure(
      PerformanceOperation.photoUpload,
      () => ref.putFile(file, metadata),
    );

    return AppointmentImage(
      storagePath: path,
      fileName: fileName,
      uploadedAt: uploadedAt,
    );
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
