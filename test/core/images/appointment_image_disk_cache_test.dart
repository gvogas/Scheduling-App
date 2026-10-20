// Pins AppointmentImageDiskCache — the reason job photos render offline again
// without reintroducing the leak the render-from-bytes change removed.
//
// cached_network_image cached BYTES too; what made it unacceptable was the
// HANDLE it cached them against: a permanent `?alt=media&token=…` URL readable
// with no auth and no rules evaluation. This cache keys on storagePath and
// stores nothing shareable, so the offline win comes back and the leak does
// not.
//
// The filesystem is real here rather than mocked — it is fast in the VM, and a
// fake would test the fake.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/images/appointment_image_disk_cache.dart';
import 'package:scheduling/core/logging/app_logger.dart';

Uint8List _bytes(String tag) => Uint8List.fromList(tag.codeUnits);

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('img_disk_cache'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AppointmentImageDiskCache cacheOver({int? budgetBytes, Directory? dir}) =>
      AppointmentImageDiskCache(
        directory: () async => dir ?? root,
        logger: AppLogger(),
        budgetBytes: budgetBytes,
      );

  const key = 'appointments/a1/images/123_photo.jpg';

  test('bytes survive the round trip', () async {
    final cache = cacheOver();
    await cache.write(key, _bytes('photo'), generation: cache.generation);

    expect(await cache.read(key), _bytes('photo'));
  });

  test('a key that was never written is a miss, not a throw', () async {
    expect(await cacheOver().read(key), isNull);
  });

  test('bytes outlive the instance that wrote them', () async {
    // The whole point: a photo fetched in one session renders in the next one
    // with no network at all.
    final writer = cacheOver();
    await writer.write(key, _bytes('photo'), generation: writer.generation);

    expect(await cacheOver().read(key), _bytes('photo'));
  });

  test('two keys never collide, however long or path-like', () async {
    // Serving one photo's bytes for another is the failure this area keeps
    // being bitten by, and the keys are neither filesystem-safe nor bounded:
    // a storagePath carries `/`, and a legacy `url:` key can run past the
    // 255-character file name limit once escaped.
    final legacyA =
        'url:https://firebasestorage.googleapis.com/v0/b/'
        '${'x' * 300}/o/a.jpg?alt=media&token=aaa';
    final legacyB =
        'url:https://firebasestorage.googleapis.com/v0/b/'
        '${'x' * 300}/o/b.jpg?alt=media&token=bbb';
    final cache = cacheOver();

    await cache.write(legacyA, _bytes('a'), generation: cache.generation);
    await cache.write(legacyB, _bytes('b'), generation: cache.generation);

    expect(await cache.read(legacyA), _bytes('a'));
    expect(await cache.read(legacyB), _bytes('b'));
  });

  test('an empty result is never written', () async {
    // Empty is a REFUSAL — a rules rejection or a transport failure — not a
    // value. Persisting one would outlive the entitlement change or the
    // network outage that caused it.
    final cache = cacheOver();
    await cache.write(key, Uint8List(0), generation: cache.generation);

    expect(await cache.read(key), isNull);
  });

  test(
    'clear() removes everything, so photos do not outlive a session',
    () async {
      // These bytes outlive the PROCESS, so a shared handset would otherwise
      // hand the next person every job photo the last one opened.
      final cache = cacheOver();
      await cache.write(key, _bytes('photo'), generation: cache.generation);

      await cache.clear();

      expect(await cache.read(key), isNull);
    },
  );

  test('a write already in flight when the session ends is dropped', () async {
    // The loader fills this cache with an unawaited write, so a fetch that
    // resolves just after sign-out would otherwise re-seed a cache that was
    // deliberately emptied a moment earlier.
    //
    // The ordering here is the REAL one, and it is the whole point: the
    // generation is read where the FETCH starts, then `clear()` runs, and the
    // write arrives afterwards carrying the stale value. Capturing the
    // generation inside `write` instead passes with clear-then-write reversed
    // and lets the bytes through in exactly this case.
    final cache = cacheOver();
    final generation = cache.generation;
    await cache.clear();
    await cache.write(key, _bytes('photo'), generation: generation);

    expect(await cache.read(key), isNull);
  });

  test('a write started after the session ended is kept', () async {
    // The mirror of the case above - a fresh session must still fill the cache.
    final cache = cacheOver();
    await cache.clear();
    await cache.write(key, _bytes('photo'), generation: cache.generation);

    expect(await cache.read(key), isNotNull);
  });

  test('the folder is trimmed oldest-first once it is over budget', () async {
    final cache = cacheOver(budgetBytes: 300);
    for (final tag in const ['old', 'mid', 'new']) {
      await cache.write(
        'key/$tag',
        Uint8List(200),
        generation: cache.generation,
      );
      // Distinct mtimes: the eviction order is what is under test, and a
      // coarse filesystem timestamp would make it arbitrary.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await cache.read('key/old'), isNull);
    expect(await cache.read('key/new'), isNotNull);
  });

  test('a folder left over budget by an earlier process is trimmed', () async {
    // The running total that keeps writes off the full sweep starts UNKNOWN,
    // so the first write of a process must still measure what is already
    // there — otherwise a folder inherited over budget never shrinks.
    final seeder = cacheOver(budgetBytes: 300);
    for (final tag in const ['old', 'mid']) {
      await seeder.write(
        'key/$tag',
        Uint8List(200),
        generation: seeder.generation,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final fresh = cacheOver(budgetBytes: 300);
    await fresh.write('key/new', Uint8List(200), generation: fresh.generation);

    expect(await fresh.read('key/old'), isNull);
    expect(await fresh.read('key/new'), isNotNull);
  });

  test(
    'the total is re-measured after a clear, so eviction still runs',
    () async {
      // clear() forgets the running total rather than zeroing it: the recursive
      // delete is best-effort, and a total that drifts LOW is the one direction
      // that would let the folder grow past its budget unchecked.
      final cache = cacheOver(budgetBytes: 300);
      await cache.write(
        'key/first',
        Uint8List(200),
        generation: cache.generation,
      );
      await cache.clear();

      for (final tag in const ['old', 'mid', 'new']) {
        await cache.write(
          'key/$tag',
          Uint8List(200),
          generation: cache.generation,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(await cache.read('key/old'), isNull);
      expect(await cache.read('key/new'), isNotNull);
    },
  );

  test('a read is not held behind a queued write of another key', () async {
    // The loader reads disk BEFORE the network; a strip of first-time photos
    // queues one write per fetch, and a later photo's read used to wait for
    // the whole chain. Keys are independent and a rename is atomic, so it no
    // longer does.
    final gate = Completer<Directory>();
    var resolves = 0;
    final cache = AppointmentImageDiskCache(
      directory: () {
        resolves += 1;
        return resolves == 1 ? gate.future : Future.value(root);
      },
      logger: AppLogger(),
    );
    final seeded = cacheOver();
    await seeded.write(key, _bytes('photo'), generation: seeded.generation);

    // Held in the directory resolve, so the chain never settles until released.
    unawaited(cache.write('other', _bytes('x'), generation: cache.generation));
    final read = cache.read(key);
    gate.complete(root);

    expect(await read, _bytes('photo'));
  });

  test('a read still waits for a clear already under way', () async {
    // The one mutation a read must not race: it would hand the next session a
    // file the clear is about to delete.
    final cache = cacheOver();
    await cache.write(key, _bytes('photo'), generation: cache.generation);

    final clearing = cache.clear();
    final read = cache.read(key);
    await clearing;

    expect(await read, isNull);
  });

  test('an unresolvable directory degrades to a miss, never a throw', () async {
    // A disk failure must cost a network fetch, not a photo that fails to
    // render.
    final cache = AppointmentImageDiskCache(
      directory: () async => throw const FileSystemException('no cache dir'),
      logger: AppLogger(),
    );

    await cache.write(key, _bytes('photo'), generation: cache.generation);
    expect(await cache.read(key), isNull);
  });

  test('a directory failure is not remembered', () async {
    // The resolved directory is memoized, and a memoized REJECTION is sticky:
    // one hiccup while resolving it would otherwise disable offline photos for
    // the rest of the process, silently.
    var attempts = 0;
    final cache = AppointmentImageDiskCache(
      directory: () async {
        attempts += 1;
        if (attempts == 1) throw const FileSystemException('transient');
        return root;
      },
      logger: AppLogger(),
    );

    expect(await cache.read(key), isNull);
    await cache.write(key, _bytes('photo'), generation: cache.generation);

    expect(await cache.read(key), _bytes('photo'));
  });
}
