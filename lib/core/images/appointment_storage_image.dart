import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

/// Retains a storage handle while the shared loader bounds encoded bytes.
@immutable
class AppointmentStorageImage extends ImageProvider<AppointmentStorageImage> {
  AppointmentStorageImage(this.image, this.loader)
    : generation = loader.generation;

  final AppointmentImage image;
  final AppointmentImageLoader loader;
  final int generation;

  Future<Uint8List> loadBytes() => generation == loader.generation
      ? loader.load(image)
      : Future.value(Uint8List(0));

  @override
  Future<AppointmentStorageImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    AppointmentStorageImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _decode(decode), scale: 1);

  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    final bytes = await loadBytes();
    if (bytes.isEmpty) throw StateError('Appointment photo unavailable');
    return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is AppointmentStorageImage &&
      identical(loader, other.loader) &&
      generation == other.generation &&
      image.storagePath == other.image.storagePath;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(loader), generation, image.storagePath);
}
