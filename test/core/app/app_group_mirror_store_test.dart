import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';

void main() {
  late Map<String, String> saved;
  late AppGroupMirrorStore store;
  Map<String, dynamic> owner() =>
      (jsonDecode(saved[mirrorOwnerKey]!) as Map).cast<String, dynamic>();
  Map<String, dynamic> payload([int delta = 0]) => {
    'generatedAt': DateTime.now()
        .add(Duration(seconds: delta))
        .toUtc()
        .toIso8601String(),
    'todayJobs': <Object>[],
  };
  setUp(() {
    saved = {};
    store = AppGroupMirrorStore(
      read: (key) async => saved[key],
      save: (key, value) async {
        if (value == null) {
          saved.remove(key);
        } else {
          saved[key] = value;
        }
      },
    );
  });

  test('clear invalidates durable ownership and both mirrors', () async {
    await store.foreground(mirrorWidgetKey, payload(), 'A', () => true);
    await store.foreground(
      mirrorSnapshotKey,
      {'generatedAt': DateTime.now().millisecondsSinceEpoch},
      'A',
      () => true,
    );
    final epoch = owner()['epoch'];
    await store.foreground(mirrorWidgetKey, null, null, () => true);
    expect(owner()['ownerUid'], isNull);
    expect(saved[mirrorWidgetKey], isNull);
    expect(saved[mirrorSnapshotKey], isNull);
    await store.foreground(mirrorWidgetKey, payload(), 'A', () => true);
    expect(owner()['epoch'], isNot(epoch));
  });

  test(
    'wrong owner, old session, older revision and ownerless pushes are refused',
    () async {
      await store.foreground(mirrorWidgetKey, payload(2), 'A', () => true);
      final current = owner();
      final valid = {
        ...payload(3),
        'ownerUid': 'A',
        'sessionEpoch': current['epoch'],
      };
      expect(
        await store.backgroundWidget(jsonEncode({...valid, 'ownerUid': 'B'})),
        isFalse,
      );
      expect(
        await store.backgroundWidget(
          jsonEncode({...valid, 'sessionEpoch': 'old'}),
        ),
        isFalse,
      );
      expect(
        await store.backgroundWidget(jsonEncode({...valid, ...payload(1)})),
        isFalse,
      );
      expect(await store.backgroundWidget(jsonEncode(payload(3))), isFalse);
      expect(await store.backgroundWidget(jsonEncode(valid)), isTrue);
    },
  );

  test(
    'a held old foreground write cannot follow the replacement owner',
    () async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      final entered = Completer<void>();
      final release = Completer<void>();
      var held = false;
      store = AppGroupMirrorStore(
        read: (key) async {
          if (!held) {
            held = true;
            entered.complete();
            await release.future;
          }
          return saved[key];
        },
        save: (key, value) async {
          if (value == null) {
            saved.remove(key);
          } else {
            saved[key] = value;
          }
        },
      );
      final lease = session.capture()!;
      final old = store.foreground(
        mirrorSnapshotKey,
        payload(),
        'A',
        () => lease.isCurrent,
      );
      await entered.future;
      uid = 'B';
      final replacement = session.capture()!;
      final next = store.foreground(
        mirrorSnapshotKey,
        payload(),
        'B',
        () => replacement.isCurrent,
      );
      release.complete();
      await Future.wait([old, next]);
      expect(owner()['ownerUid'], 'B');
      expect((jsonDecode(saved[mirrorSnapshotKey]!) as Map)['ownerUid'], 'B');
    },
  );

  test(
    'a stale logout clear cannot erase replacement-session content',
    () async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      final oldClear = session.captureBoundary();
      uid = 'B';
      await store.foreground(mirrorWidgetKey, payload(), 'B', () => true);
      await store.foreground(mirrorWidgetKey, null, null, oldClear);
      expect(owner()['ownerUid'], 'B');
      expect(saved[mirrorWidgetKey], isNotNull);
    },
  );
}
