import 'dart:async';
import 'dart:convert';

import 'package:scheduling/core/images/image_upload_intent.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/photo_upload_expiry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One queued photo batch for an appointment (staged file paths on disk).
class PendingUpload {
  const PendingUpload({
    required this.appointmentId,
    required this.paths,
    required this.enqueuedAtMs,
    required this.ownerUid,
    required this.ownerEmployeeId,
    this.uploaded = const [],
    this.intents = const {},
    this.cleanupPaths = const [],
    this.stagingSources = const {},
    this.batchId,
  });

  final String appointmentId;
  final List<String> paths;
  final int enqueuedAtMs;

  /// Who staged this batch. Empty on a LEGACY entry — one written by a build
  /// from before the queue carried an owner. Such an entry is never uploaded
  /// (an empty id matches nobody, which is the point: on a shared or
  /// handed-over phone the next account must not finish somebody else's
  /// upload) but it is still PARSED, so `prune` reaches it and deletes its
  /// staged files. Dropping it at parse time stranded those files forever.
  final String ownerUid;
  final String ownerEmployeeId;

  bool get hasOwner => ownerUid.isNotEmpty && ownerEmployeeId.isNotEmpty;

  /// Already-uploaded images waiting for an append-only retry.
  final List<AppointmentImage> uploaded;
  final Map<String, ImageUploadIntent> intents;
  final List<String> cleanupPaths;
  final Map<String, String> stagingSources;
  final String? batchId;

  String get id => batchId ?? '${appointmentId}_$enqueuedAtMs';

  PendingUpload copyWith({
    List<String>? paths,
    List<AppointmentImage>? uploaded,
    Map<String, ImageUploadIntent>? intents,
    List<String>? cleanupPaths,
    Map<String, String>? stagingSources,
  }) => PendingUpload(
    appointmentId: appointmentId,
    paths: paths ?? this.paths,
    enqueuedAtMs: enqueuedAtMs,
    ownerUid: ownerUid,
    ownerEmployeeId: ownerEmployeeId,
    uploaded: uploaded ?? this.uploaded,
    intents: intents ?? this.intents,
    cleanupPaths: cleanupPaths ?? this.cleanupPaths,
    stagingSources: stagingSources ?? this.stagingSources,
    batchId: batchId,
  );

  Map<String, dynamic> toJson() => {
    'appointmentId': appointmentId,
    'paths': paths,
    'enqueuedAtMs': enqueuedAtMs,
    'ownerUid': ownerUid,
    'ownerEmployeeId': ownerEmployeeId,
    if (batchId != null) 'batchId': batchId,
    if (uploaded.isNotEmpty) 'uploaded': uploaded.map(_imageToJson).toList(),
    if (intents.isNotEmpty)
      'intents': {
        for (final item in intents.entries) item.key: item.value.toJson(),
      },
    if (cleanupPaths.isNotEmpty) 'cleanupPaths': cleanupPaths,
    if (stagingSources.isNotEmpty) 'stagingSources': stagingSources,
  };

  static PendingUpload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final appointmentId = (map['appointmentId'] ?? '').toString();
    final enqueuedAtMs = map['enqueuedAtMs'];
    final paths = map['paths'];
    final ownerUid = (map['ownerUid'] ?? '').toString();
    final ownerEmployeeId = (map['ownerEmployeeId'] ?? '').toString();
    if (appointmentId.isEmpty || enqueuedAtMs is! int || paths is! List) {
      return null;
    }
    final rawUploaded = map['uploaded'];
    return PendingUpload(
      appointmentId: appointmentId,
      paths: paths.map((p) => p.toString()).toList(),
      enqueuedAtMs: enqueuedAtMs,
      ownerUid: ownerUid,
      ownerEmployeeId: ownerEmployeeId,
      batchId: map['batchId'] is String ? map['batchId'] as String : null,
      stagingSources: {
        if (map['stagingSources'] case final Map<Object?, Object?> sources)
          for (final item in sources.entries)
            if (item case MapEntry(
              key: final String target,
              value: final String source,
            ))
              target: source,
      },
      intents: _readIntents(map['intents']),
      cleanupPaths: map['cleanupPaths'] is List
          ? (map['cleanupPaths'] as List).whereType<String>().toList()
          : const [],
      uploaded: rawUploaded is List
          ? rawUploaded
                .whereType<Map<Object?, Object?>>()
                .map((m) => AppointmentImage.fromMap(m.cast<String, dynamic>()))
                .toList()
          : const [],
    );
  }

  static Map<String, ImageUploadIntent> _readIntents(Object? raw) {
    final intents = <String, ImageUploadIntent>{};
    if (raw is! Map) return intents;
    for (final item in raw.entries) {
      final intent = ImageUploadIntent.fromJson(item.value);
      if (intent != null) intents[item.key.toString()] = intent;
    }
    return intents;
  }

  // JSON-safe image shape for SharedPreferences.
  static Map<String, dynamic> _imageToJson(AppointmentImage image) => {
    ...image.toMap(),
    if (image.storagePath.isNotEmpty) 'url': '',
    'uploadedAt': image.uploadedAt?.toIso8601String(),
  };
}

/// Durable SharedPreferences queue for pending photo uploads.
class PendingUploadStore {
  PendingUploadStore({AppLogger? logger}) : _logger = logger ?? AppLogger();

  static const _key = 'pending_photo_uploads';
  static const _expiryKey = 'expired_photo_uploads';
  static const _maxAge = Duration(days: 7);

  final AppLogger _logger;

  /// Serializes read-modify-write queue mutations.
  Future<void> _mutations = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    // Keep the internal chain alive while returning the real result.
    _mutations = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<PendingUpload>> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _logger.warn('IMG-UPLOAD pending queue was not a JSON list; reset');
        return const [];
      }
      return decoded
          .map(PendingUpload.fromJson)
          .whereType<PendingUpload>()
          .toList();
    } on FormatException catch (e, st) {
      // Resetting the queue drops batches the user expects to upload.
      _logger.warn('IMG-UPLOAD pending queue decode failed; reset', e, st);
      return const [];
    }
  }

  Future<void> _save(List<PendingUpload> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
    if (!saved) throw StateError('pending photo queue was not saved');
  }

  Future<void> add(PendingUpload entry) => _serialized(() async {
    final entries = await load();
    if (entries.any((existing) => existing.id == entry.id)) return;
    await _save([...entries, entry]);
  });

  Future<void> remove(String id) => _serialized(() async {
    final entries = await load();
    await _save(entries.where((e) => e.id != id).toList());
  });

  /// Replaces [id] atomically so failed requeues keep the old entry reachable.
  Future<void> replace(String id, PendingUpload entry) => _serialized(() async {
    final entries = await load();
    await _save([
      ...entries.where((e) => e.id != id && e.id != entry.id),
      entry,
    ]);
  });

  /// Saves progress only while the queued batch still exists.
  Future<bool> checkpoint(String id, PendingUpload entry) =>
      _serialized(() async {
        final entries = await load();
        if (!entries.any((existing) => existing.id == id)) return false;
        await _save([
          for (final existing in entries)
            if (existing.id == id) entry else existing,
        ]);
        return true;
      });

  /// Drops entries older than [_maxAge] and returns them so the caller can
  /// clean up their files.
  Future<List<PendingUpload>> prune({required DateTime now}) =>
      _serialized(() async {
        final entries = await load();
        final cutoff = now.subtract(_maxAge).millisecondsSinceEpoch;
        final kept = <PendingUpload>[];
        final pruned = <PendingUpload>[];
        for (final entry in entries) {
          (entry.enqueuedAtMs < cutoff ? pruned : kept).add(entry);
        }
        if (pruned.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final outcomes = _readExpiry(prefs);
          for (final entry in pruned) {
            final count = entry.paths.length + entry.uploaded.length;
            if (!entry.hasOwner || count == 0) continue;
            outcomes['${entry.ownerUid}/${entry.id}'] = {
              'owner': entry.ownerUid,
              'id': entry.id,
              'appointmentId': entry.appointmentId,
              'count': count,
            };
          }
          if (!await prefs.setString(_expiryKey, jsonEncode(outcomes))) {
            throw StateError('photo expiry outcomes were not saved');
          }
          await _save(kept);
        }
        return pruned;
      });

  Map<String, dynamic> _readExpiry(SharedPreferences prefs) {
    final raw = prefs.getString(_expiryKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on FormatException catch (error, stack) {
      _logger.warn('IMG-UPLOAD expiry outcomes decode failed', error, stack);
      rethrow;
    }
  }

  Future<List<PhotoUploadExpiry>> expiredFor(String uid) async {
    final stillQueued = {for (final entry in await load()) entry.id};
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return [
      for (final value in _readExpiry(prefs).values)
        if (value is Map &&
            value['owner'] == uid &&
            value['count'] is int &&
            !stillQueued.contains(value['id']))
          PhotoUploadExpiry(
            id: value['id'] as String,
            appointmentId: value['appointmentId'] as String,
            count: value['count'] as int,
          ),
    ];
  }

  Future<void> acknowledgeExpiry(String uid, Set<String> ids) =>
      _serialized(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final outcomes = _readExpiry(prefs)
          ..removeWhere(
            (key, value) =>
                value is Map &&
                value['owner'] == uid &&
                ids.contains(value['id']),
          );
        if (!await prefs.setString(_expiryKey, jsonEncode(outcomes))) {
          throw StateError('photo expiry acknowledgment was not saved');
        }
      });

  Future<List<PendingUpload>> clearAll() => _serialized(() async {
    final entries = await load();
    if (entries.isEmpty) return const [];
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_key)) {
      throw StateError('pending photo queue was not cleared');
    }
    return entries;
  });

  Future<List<PendingUpload>> clearOwner(
    String uid, {
    required bool Function() isCurrent,
  }) => _serialized(() async {
    final entries = await load();
    if (!isCurrent()) return const [];
    final removed = entries.where((entry) => entry.ownerUid == uid).toList();
    if (removed.isNotEmpty) {
      await _save(entries.where((entry) => entry.ownerUid != uid).toList());
    }
    return removed;
  });
}
