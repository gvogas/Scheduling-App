// Pins AppointmentImageLoader — the reason appointment photos are rendered
// from bytes held in memory rather than from any URL.
//
// getDownloadURL() mints a permanent `?alt=media&token=…` URL readable by
// anyone holding it with no auth and no rules evaluation, so a URL rendered
// while an employee was active kept working after deactivateEmployee revoked
// everything else — and its predecessor, which re-minted that URL at render
// time, only ever gated the MINT. getData() is an authenticated SDK fetch:
// storage.rules is evaluated every time, and nothing shareable is produced.
// The legacy url fallback that once kept this from being a migration was
// removed 2026-08-22, after a prod count found zero documents relying on it.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/images/appointment_image_disk_cache.dart';
import 'package:scheduling/core/images/appointment_image_loader.dart';
import 'package:scheduling/core/images/appointment_storage_image.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';

class _MockStorage extends Mock implements FirebaseStorage {}

class _MockRef extends Mock implements Reference {}

Uint8List _bytes(String tag) => Uint8List.fromList(tag.codeUnits);

void main() {
  late _MockStorage storage;
  late _MockRef ref;
  late Directory cacheRoot;
  late AppointmentImageDiskCache disk;
  late AppointmentImageLoader loader;

  setUp(() {
    storage = _MockStorage();
    ref = _MockRef();
    // A REAL cache over a temp directory rather than a fake: the filesystem is
    // fast in the VM, and the thing under test here is the interaction between
    // the two caches, which a fake would only restate.
    cacheRoot = Directory.systemTemp.createTempSync('img_loader_cache');
    disk = AppointmentImageDiskCache(
      directory: () async => cacheRoot,
      logger: AppLogger(),
    );
    loader = AppointmentImageLoader(
      storage: storage,
      logger: AppLogger(),
      diskCache: disk,
    );
  });

  tearDown(() async {
    // Drain first: the loader's write-back is deliberately unawaited, so a
    // fetch that resolved late can still be creating files here. `clear()`
    // goes through the cache's own mutation queue, so it lands behind every
    // pending write - deleting the directory underneath one fails on Windows
    // with "directory is not empty", which surfaced as a failure attributed to
    // whichever test happened to run at the time.
    await disk.clear();
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  const path = 'appointments/a1/images/123_photo.jpg';
  const stored = 'https://storage/stale?token=old';
  final photo = _bytes('photo-bytes');

  test('remote image handles expire with their image session', () async {
    final first = AppointmentStorageImage(
      const AppointmentImage(storagePath: path),
      loader,
    );
    final same = AppointmentStorageImage(
      const AppointmentImage(storagePath: path),
      loader,
    );
    expect(first, same);
    await loader.clear();
    expect(
      AppointmentStorageImage(
        const AppointmentImage(storagePath: path),
        loader,
      ),
      isNot(first),
    );
    expect(await first.loadBytes(), isEmpty);
    verifyNever(() => storage.ref(any()));
  });

  /// Stubs [r] to answer [answer] for whatever `maxSize` the loader passes.
  void whenGetData(_MockRef r, Future<Uint8List?> Function() answer) {
    when(() => r.getData(any())).thenAnswer((_) => answer());
  }

  test(
    'four stalled old fetches cannot block replacement-session photos',
    () async {
      final oldGate = Completer<Uint8List>();
      final started = Completer<void>();
      var count = 0;
      for (var i = 0; i < 4; i++) {
        final oldRef = _MockRef();
        when(() => storage.ref('old/$i')).thenReturn(oldRef);
        whenGetData(oldRef, () {
          if (++count == 4) started.complete();
          return oldGate.future;
        });
      }
      final old = [
        for (var i = 0; i < 4; i++)
          loader.load(AppointmentImage(storagePath: 'old/$i')),
      ];
      await started.future;
      await loader.clear();
      when(() => storage.ref('new')).thenReturn(ref);
      whenGetData(ref, () async => photo);
      expect(
        await loader
            .load(const AppointmentImage(storagePath: 'new'))
            .timeout(const Duration(seconds: 5)),
        photo,
      );
      oldGate.complete(photo);
      expect(await Future.wait(old), everyElement(isEmpty));
    },
  );

  test(
    'fetches the bytes from storagePath, never from the stored url',
    () async {
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(ref, () async => photo);

      expect(
        await loader.load(
          const AppointmentImage(url: stored, storagePath: path),
        ),
        photo,
      );
      verifyNever(() => storage.refFromURL(any()));
    },
  );

  test(
    'a doc with no storagePath resolves to nothing, never through its url',
    () async {
      // This used to be the LEGACY fallback: a doc written before storagePath
      // existed was fetched via refFromURL. It went on 2026-08-22, once a prod
      // count found zero such documents — the stored string is a permanent,
      // rules-free, transferable download link and nothing revokes it, so the
      // loader must not resolve one even when it is the only handle present.
      // storagePath is now the sole handle, and its absence means "no photo".
      when(() => storage.refFromURL(any())).thenReturn(ref);
      whenGetData(ref, () async => photo);

      expect(await loader.load(const AppointmentImage(url: stored)), isEmpty);
      verifyNever(() => storage.refFromURL(any()));
    },
  );

  test('a doc with neither a storagePath nor a url resolves to nothing', () {
    return expectLater(
      loader.load(const AppointmentImage()),
      completion(isEmpty),
    );
  });

  test('an offline fetch resolves to nothing, never a fallback url', () async {
    // The old resolver fell back to the stored url here, on the grounds that a
    // transport failure says nothing about entitlement. That url is a
    // permanent rules-free link, so there is deliberately no such fallback
    // left: the tile is empty and the next open retries.
    when(() => storage.ref(path)).thenReturn(ref);
    whenGetData(ref, () async => throw Exception('offline'));

    expect(
      await loader.load(const AppointmentImage(url: stored, storagePath: path)),
      isEmpty,
    );
  });

  for (final code in const ['unauthorized', 'permission-denied']) {
    test('a $code rejection resolves to nothing, never the token url', () {
      // The stored url reads with no auth and no rules evaluation, so falling
      // back on a RULES rejection would hand a disabled employee a working
      // link — the exact hole this loader exists to close.
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(
        ref,
        () async =>
            throw FirebaseException(plugin: 'firebase_storage', code: code),
      );

      return expectLater(
        loader.load(const AppointmentImage(url: stored, storagePath: path)),
        completion(isEmpty),
      );
    });
  }

  test('never more than 4 fetches are in flight', () async {
    // The bound itself, not just the ordering it survives: opening a job with
    // a long strip must not fire the whole batch at Storage in one burst.
    // Nothing asserted this, so `_maxConcurrentLoads` could be raised or
    // removed with every existing test still green.
    var inFlight = 0;
    var peak = 0;
    final gates = <String, Completer<Uint8List>>{};
    final started = StreamController<void>.broadcast(sync: true);
    addTearDown(started.close);
    final paths = [for (var i = 0; i < 9; i++) 'p/$i'];
    for (final p in paths) {
      final r = _MockRef();
      when(() => storage.ref(p)).thenReturn(r);
      when(() => r.getData(any())).thenAnswer((_) {
        inFlight += 1;
        if (inFlight > peak) peak = inFlight;
        final gate = Completer<Uint8List>();
        gates[p] = gate;
        started.add(null);
        return gate.future;
      });
    }

    final pending = Future.wait([
      for (final p in paths) loader.load(AppointmentImage(storagePath: p)),
    ]);

    // Drain a batch at a time, re-checking the peak between each. Each batch
    // consults the disk cache before it reaches Storage, so a batch takes more
    // than one microtask turn to open its gates — waiting until they appear
    // keeps this deterministic rather than pumping a guessed number of turns.
    var drained = 0;
    while (drained < paths.length) {
      // Wait until the batch has stopped GROWING, not merely until one gate
      // exists: each item consults the disk cache before it reaches Storage,
      // so a batch opens its gates over several microtask turns, and draining
      // a half-open batch understates the peak — which is what made this test
      // report 3 on some runs and 4 on others.
      final expected = (paths.length - drained).clamp(1, 4);
      while (gates.length < expected) {
        await started.stream.first.timeout(const Duration(seconds: 10));
      }
      final open = gates.keys.toList();
      expect(open, isNotEmpty);
      expect(open.length, lessThanOrEqualTo(4));
      for (final p in open) {
        inFlight -= 1;
        drained += 1;
        gates.remove(p)!.complete(_bytes(p));
      }
    }

    expect(await pending, [for (final p in paths) _bytes(p)]);
    expect(peak, 4);
  });

  group('the session cache', () {
    test('bytes are fetched once and served from memory after', () async {
      // The fetch is a live round-trip paid per widget State — so a sheet
      // toggled View→Edit used to re-fetch every photo. Holding the BYTES
      // rather than a url is what keeps that win without a leakable string.
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(ref, () async => photo);
      const image = AppointmentImage(url: stored, storagePath: path);

      expect(await loader.load(image), photo);
      expect(await loader.load(image), photo);

      verify(() => ref.getData(any())).called(1);
    });

    test('a permission-denied REFUSAL is never cached', () async {
      // Empty is a refusal, not a value, and entitlement can change
      // mid-session — an employee reactivated (or a token propagating right
      // after sign-in) must not stay refused for the rest of the session.
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(
        ref,
        () async => throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'permission-denied',
        ),
      );
      const image = AppointmentImage(url: stored, storagePath: path);

      expect(await loader.load(image), isEmpty);

      whenGetData(ref, () async => photo);
      expect(await loader.load(image), photo);
      verify(() => ref.getData(any())).called(2);
    });

    test('a transient failure is not cached either', () async {
      // It resolves to the same empty refusal, and the network coming back
      // must be enough to render the photo on the next open.
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(ref, () async => throw Exception('offline'));
      const image = AppointmentImage(url: stored, storagePath: path);

      expect(await loader.load(image), isEmpty);

      whenGetData(ref, () async => photo);
      expect(await loader.load(image), photo);
      verify(() => ref.getData(any())).called(2);
    });

    test(
      'two url-only docs both resolve to nothing and neither is cached',
      () async {
        // These two used to be cached under a `url:`-prefixed key space, so
        // that two legacy docs sharing the empty storagePath could not serve
        // each other's bytes. Both the fallback and that key space went on
        // 2026-08-22: a url-only doc now has no handle, so it never reaches
        // Storage and there is nothing to key. The blank-key mixup this
        // guarded against is unreachable for the same reason — `load` returns
        // early on an empty key without touching the cache.
        for (final url in const ['legacy-a', 'legacy-b']) {
          final r = _MockRef();
          when(() => storage.refFromURL(url)).thenReturn(r);
          whenGetData(r, () async => _bytes(url));
        }

        expect(
          await loader.load(const AppointmentImage(url: 'legacy-a')),
          isEmpty,
        );
        expect(
          await loader.load(const AppointmentImage(url: 'legacy-b')),
          isEmpty,
        );
        verifyNever(() => storage.refFromURL(any()));
      },
    );

    test(
      'clear() forgets everything, so bytes do not outlive a session',
      () async {
        // The provider is a process-lifetime singleton, so without this up to
        // 24 MB of one user's job photos stays resident across sign-out into
        // the next user's session on a shared device.
        when(() => storage.ref(path)).thenReturn(ref);
        whenGetData(ref, () async => photo);
        const image = AppointmentImage(url: stored, storagePath: path);

        expect(await loader.load(image), photo);
        await loader.clear();
        expect(await loader.load(image), photo);

        verify(() => ref.getData(any())).called(2);
      },
    );

    test(
      'the cache is bounded, so a long session cannot retain every photo',
      () async {
        // Bytes are far heavier than the urls this replaced. Without a budget a
        // session that opens fifty jobs holds every photo of every one of them
        // for as long as the app runs.
        final big = Uint8List(9 * 1024 * 1024);
        final paths = [for (var i = 0; i < 3; i++) 'big/$i'];
        final refs = <String, _MockRef>{};
        for (final p in paths) {
          final r = _MockRef();
          refs[p] = r;
          when(() => storage.ref(p)).thenReturn(r);
          whenGetData(r, () async => big);
        }

        // Isolated from the disk cache ON PURPOSE. With one behind it a memory
        // eviction is served from disk, which is the right behaviour and is
        // pinned below — but it also makes the memory budget unobservable
        // through `load`, so this unit needs the disk out of the way.
        final memoryOnly = AppointmentImageLoader(
          storage: storage,
          logger: AppLogger(),
          diskCache: AppointmentImageDiskCache(
            directory: () async => throw const FileSystemException('disabled'),
            logger: AppLogger(),
          ),
        );

        for (final p in paths) {
          await memoryOnly.load(AppointmentImage(storagePath: p));
        }
        // 27 MB is over the 24 MB budget, so the oldest entry was evicted and
        // asking for it again refetches; the newest is still served from memory.
        await memoryOnly.load(AppointmentImage(storagePath: paths.first));
        await memoryOnly.load(AppointmentImage(storagePath: paths.last));

        verify(() => refs[paths.first]!.getData(any())).called(2);
        verify(() => refs[paths.last]!.getData(any())).called(1);
      },
    );
  });

  group('the disk cache', () {
    const image = AppointmentImage(url: stored, storagePath: path);

    test('a photo cached on disk renders with no Storage fetch at all', () {
      // The offline win, stated as the thing it is: a tech in a basement or an
      // underground garage opens a job they looked at this morning and the
      // photos are there. `storage.ref` is left unstubbed, so any attempt to
      // reach Storage fails the test rather than quietly succeeding.
      return disk.write(path, photo, generation: disk.generation).then((
        _,
      ) async {
        expect(await loader.load(image), photo);
        verifyNever(() => storage.ref(any()));
      });
    });

    test('a fetched photo is written to disk for the next session', () async {
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(ref, () async => photo);

      expect(await loader.load(image), photo);
      await disk.settled;

      expect(await disk.read(path), photo);
    });

    test('a memory eviction falls back to disk, not to the network', () async {
      // This is what makes the 24 MB memory budget cheap: past it, a photo
      // costs a file read rather than a round trip. Driven through the REAL
      // budget — 27 MB over a 24 MB ceiling — so nothing here depends on a
      // seam that exists only for the test.
      final big = Uint8List(9 * 1024 * 1024);
      final paths = [for (var i = 0; i < 3; i++) 'big/$i'];
      final refs = <String, _MockRef>{};
      for (final p in paths) {
        final r = _MockRef();
        refs[p] = r;
        when(() => storage.ref(p)).thenReturn(r);
        whenGetData(r, () async => big);
      }

      for (final p in paths) {
        await loader.load(AppointmentImage(storagePath: p));
      }
      await disk.settled;

      // The oldest is gone from memory, but it is on disk — so it comes back
      // without a second fetch.
      expect(
        await loader.load(AppointmentImage(storagePath: paths.first)),
        big,
      );
      verify(() => refs[paths.first]!.getData(any())).called(1);
    });

    test('a REFUSAL is never written to disk', () async {
      // Empty is a refusal, and persisting one would outlive the entitlement
      // change that caused it — for every future session, not just this one.
      when(() => storage.ref(path)).thenReturn(ref);
      whenGetData(
        ref,
        () async => throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'permission-denied',
        ),
      );

      expect(await loader.load(image), isEmpty);
      await disk.settled;

      expect(await disk.read(path), isNull);
    });

    test(
      'clear() empties the disk too, so photos do not outlive a session',
      () async {
        // Disk bytes outlive the PROCESS, so a shared handset would otherwise
        // hand the next person every job photo the last one opened.
        when(() => storage.ref(path)).thenReturn(ref);
        whenGetData(ref, () async => photo);

        expect(await loader.load(image), photo);
        await disk.settled;
        await loader.clear();

        expect(await disk.read(path), isNull);
      },
    );
  });
}
