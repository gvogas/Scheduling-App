import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/images/appointment_image_disk_cache.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

/// App-wide loader, injectable so widget tests never touch Storage.
final appointmentImageLoaderProvider = Provider<AppointmentImageLoader>(
  (ref) => AppointmentImageLoader(logger: ref.watch(loggerProvider)),
);

/// Fetches appointment photo bytes from Storage without producing token URLs.
class AppointmentImageLoader {
  AppointmentImageLoader({
    FirebaseStorage? storage,
    AppLogger? logger,
    AppointmentImageDiskCache? diskCache,
  }) : _injectedStorage = storage,
       _logger = logger ?? AppLogger(),
       _disk = diskCache ?? AppointmentImageDiskCache(logger: logger);

  /// Session cache keyed by `storagePath`; empty refusals are never cached.
  final Map<String, Future<Uint8List>> _cache = {};

  /// Settled entry sizes in insertion order for oldest-first trimming.
  final Map<String, int> _sizes = {};
  int _cachedBytes = 0;

  /// Caps simultaneous Storage fetches for long photo strips.
  static const int _maxConcurrentLoads = 4;

  /// Bounds the in-memory photo cache for a session.
  static const int _maxCachedBytes = 24 * 1024 * 1024;

  /// Matches the upload cap required by `getData`.
  static const int _maxImageBytes = ImageStorageService.maxUploadBytes;

  /// Lazily resolved so clearing the cache does not require Firebase.
  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;

  final FirebaseStorage? _injectedStorage;
  final AppLogger _logger;
  final AppointmentImageDiskCache _disk;

  /// Returns photo bytes, or empty bytes when there is no usable handle.
  Future<Uint8List> load(AppointmentImage image) {
    final key = _cacheKeyFor(image);
    if (key.isEmpty) return Future.value(Uint8List(0));

    final cached = _cache[key];
    if (cached != null) return cached;

    final pending = _resolve(image, key);
    _cache[key] = pending;
    unawaited(pending.then((bytes) => _settle(key, pending, bytes)));
    return pending;
  }

  /// Reads disk first, then Storage, and writes successful network bytes back.
  Future<Uint8List> _resolve(AppointmentImage image, String key) async {
    // FIRST, above the disk read too: `clear()` bumps the generation before `signOut()` (ADR-0004).
    final generation = _disk.generation;

    final onDisk = await _disk.read(key);
    if (onDisk != null) return onDisk;

    final bytes = await _fetch(() => _refFor(image), key);
    if (bytes.isNotEmpty) {
      unawaited(_disk.write(key, bytes, generation: generation));
    }
    return bytes;
  }

  /// Returns the `storagePath` cache key, or `''` for an unusable photo.
  static String _cacheKeyFor(AppointmentImage image) => image.storagePath;

  Reference _refFor(AppointmentImage image) => _storage.ref(image.storagePath);

  /// Loads photos in list order so viewer indexes stay stable.
  Future<List<Uint8List>> loadAll(List<AppointmentImage> images) async {
    final loaded = <Uint8List>[];
    for (var i = 0; i < images.length; i += _maxConcurrentLoads) {
      final end = i + _maxConcurrentLoads;
      final batch = images.sublist(
        i,
        end < images.length ? end : images.length,
      );
      loaded.addAll(await Future.wait(batch.map(load)));
    }
    return loaded;
  }

  /// Forgets every cached photo, in memory and on disk.
  Future<void> clear() async {
    _cache.clear();
    _sizes.clear();
    _cachedBytes = 0;
    await _disk.clear();
  }

  /// [refOf] is a thunk so reference construction and the network fetch fail
  /// through the same empty-bytes path.
  Future<Uint8List> _fetch(Reference Function() refOf, String label) async {
    try {
      return await refOf().getData(_maxImageBytes) ?? Uint8List(0);
    } catch (e, st) {
      // Refusals and transport failures both render as empty, never a URL.
      _logger.warn(
        _isRefusal(e)
            ? 'IMG-LOAD refused by storage.rules: $label'
            : 'IMG-LOAD failed: $label',
        e,
        st,
      );
      return Uint8List(0);
    }
  }

  static bool _isRefusal(Object error) {
    if (error is! FirebaseException) return false;
    return error.code == 'unauthorized' || error.code == 'permission-denied';
  }

  void _settle(String path, Future<Uint8List> pending, Uint8List bytes) {
    if (!identical(_cache[path], pending)) return;
    if (bytes.isEmpty) {
      _cache.remove(path);
      return;
    }
    _sizes[path] = bytes.length;
    _cachedBytes += bytes.length;
    if (_cachedBytes <= _maxCachedBytes) return;
    for (final oldest in _sizes.keys.toList()) {
      if (_cachedBytes <= _maxCachedBytes) break;
      _cachedBytes -= _sizes.remove(oldest) ?? 0;
      _cache.remove(oldest);
    }
  }
}
