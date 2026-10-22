import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:uuid/uuid.dart';

/// Persisted identity for one immutable Storage upload.
class ImageUploadIntent {
  const ImageUploadIntent({
    required this.uploadId,
    required this.ownerUid,
    required this.image,
    required this.digest,
    required this.byteLength,
  });

  final String uploadId;
  final String ownerUid;
  final AppointmentImage image;
  final String digest;
  final int byteLength;

  static Future<ImageUploadIntent> prepare(
    String appointmentId,
    String ownerUid,
    File file,
  ) async {
    final byteLength = await file.length();
    final digest = await sha256.bind(file.openRead()).first;
    final uploadId = const Uuid().v4();
    final extension = file.path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final fileName = '$uploadId.$extension';
    return ImageUploadIntent(
      uploadId: uploadId,
      ownerUid: ownerUid,
      image: AppointmentImage(
        storagePath: 'appointments/$appointmentId/images/$fileName',
        fileName: fileName,
        uploadedAt: DateTime.now().toUtc(),
      ),
      digest: digest.toString(),
      byteLength: byteLength,
    );
  }

  Map<String, String> get metadata => {
    'uploadId': uploadId,
    'ownerUid': ownerUid,
    'sha256': digest,
    'uploadedAt': image.uploadedAt!.toIso8601String(),
  };

  Map<String, dynamic> toJson() => {
    'uploadId': uploadId,
    'ownerUid': ownerUid,
    'image': {
      'storagePath': image.storagePath,
      'fileName': image.fileName,
      'uploadedAt': image.uploadedAt!.toIso8601String(),
    },
    'digest': digest,
    'byteLength': byteLength,
  };

  static ImageUploadIntent? fromJson(Object? raw) {
    if (raw is! Map || raw['image'] is! Map) return null;
    final image = AppointmentImage.fromMap(
      (raw['image'] as Map).cast<String, dynamic>(),
    );
    final uploadId = raw['uploadId'];
    final ownerUid = raw['ownerUid'];
    final digest = raw['digest'];
    final byteLength = raw['byteLength'];
    if (uploadId is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(uploadId) ||
        ownerUid is! String ||
        ownerUid.isEmpty ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        byteLength is! int ||
        byteLength < 0 ||
        image.uploadedAt == null) {
      return null;
    }
    return ImageUploadIntent(
      uploadId: uploadId,
      ownerUid: ownerUid,
      image: image,
      digest: digest,
      byteLength: byteLength,
    );
  }
}
