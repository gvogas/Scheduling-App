import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:scheduling/core/logging/app_logger.dart';

/// Best-effort disk cache for fetched appointment photo bytes.
class AppointmentImageDiskCache {
  AppointmentImageDiskCache({
    Future<Directory> Function()? directory,
    AppLogger? logger,
    int? budgetBytes,
  }) : _resolveRoot = directory ?? _platformCacheDirectory,
       _logger = logger ?? AppLogger(),
       _budgetBytes = budgetBytes ?? maxCachedBytes;

  /// Disk cache budget for appointment photos.
  static const int maxCachedBytes = 128 * 1024 * 1024;

  /// Dedicated cache subdirectory cleared as one folder.
  static const String _folder = 'appointment_images';

  final Future<Directory> Function() _resolveRoot;
  final AppLogger _logger;
  final int _budgetBytes;

  Future<Directory>? _root;

  /// Resolves once every queued cache mutation has run.
  Future<void> get settled => _mutations;

  /// Serializes writes, eviction, and clear operations.
  Future<void> _mutations = Future<void>.value();

  /// Bumped by [clear] to drop writes from a previous session.
  int _generation = 0;

  /// Last measured folder size, or null until the next sweep.
  int? _bytesOnDisk;

  static Future<Directory> _platformCacheDirectory() =>
      getApplicationCacheDirectory();

  /// Filesystem-safe fixed-length name for a cache key.
  static String fileNameFor(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  /// Returns cached bytes for [key], or null for a miss.
  Future<Uint8List?> read(String key) async {
    if (key.isEmpty) return null;
    final generation = _generation;
    try {
      await _mutations;
      if (generation != _generation) return null;
      final file = await _fileFor(key);
      final bytes = await file.readAsBytes();
      if (generation != _generation) return null;
      return bytes.isEmpty ? null : bytes;
    } on PathNotFoundException {
      // A missing file is the ordinary cache-miss path.
      return null;
    } catch (e, st) {
      _logger.warn('IMG-DISK read failed: $key', e, st);
      return null;
    }
  }

  /// Current session generation captured before a Storage fetch starts.
  int get generation => _generation;

  /// Stores [bytes] for [key] when the fetch belongs to the current session.
  Future<void> write(String key, Uint8List bytes, {required int generation}) {
    if (key.isEmpty || bytes.isEmpty) return Future<void>.value();
    final startedAt = generation;
    return _serialized(() async {
      // The session ended while the fetch behind this was still in flight.
      if (startedAt != _generation) return;
      final file = await _fileFor(key);
      await file.parent.create(recursive: true);
      // Rename from a temp file so interrupted writes do not corrupt entries.
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      // Sweep only when the running total may exceed the budget.
      final knownBytes = _bytesOnDisk;
      _bytesOnDisk =
          knownBytes == null || knownBytes + bytes.length > _budgetBytes
          ? await _trim()
          : knownBytes + bytes.length;
    }, 'write $key');
  }

  /// Deletes every cached photo for the current session.
  Future<void> clear() {
    _generation += 1;
    return _serialized(() async {
      _bytesOnDisk = null;
      final dir = await _directory();
      // Sync metadata checks are cheap; byte work stays async.
      if (dir.existsSync()) await dir.delete(recursive: true);
    }, 'clear');
  }

  Future<void> _serialized(Future<void> Function() run, String label) {
    final next = _mutations.then((_) async {
      try {
        await run();
      } catch (e, st) {
        // Swallow failures so the mutation chain stays usable.
        _logger.warn('IMG-DISK $label failed', e, st);
      }
    });
    _mutations = next;
    return next;
  }

  Future<Directory> _directory() {
    return _root ??= _resolveRoot()
        .then((root) => Directory(_pathIn(root.path, _folder)))
        .onError<Object>((e, st) {
          // Forget failed directory resolves so the next fetch can retry.
          _root = null;
          // The next directory resolve invalidates the old size measurement.
          _bytesOnDisk = null;
          Error.throwWithStackTrace(e, st);
        });
  }

  Future<File> _fileFor(String key) async {
    final dir = await _directory();
    return File(_pathIn(dir.path, fileNameFor(key)));
  }

  /// Evicts oldest-first and returns the measured remaining bytes.
  Future<int> _trim() async {
    final dir = await _directory();
    if (!dir.existsSync()) return 0;

    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = entity.statSync();
      total += stat.size;
      entries.add((file: entity, size: stat.size, modified: stat.modified));
    }
    if (total <= _budgetBytes) return total;

    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= _budgetBytes) break;
      try {
        await entry.file.delete();
        total -= entry.size;
      } catch (e, st) {
        // One undeletable file must not strand the rest of the eviction.
        _logger.warn('IMG-DISK evict failed: ${entry.file.path}', e, st);
      }
    }
    return total;
  }

  static String _pathIn(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}
