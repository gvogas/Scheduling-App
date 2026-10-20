import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart';

import '../../support/fake_app_group.dart';

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

void main() {
  group('WidgetSyncService.signatureForTesting', () {
    test('ignores generatedAt so the same schedule dedupes', () {
      final a = {
        'generatedAt': '2026-07-08T12:00:00Z',
        'rolloverAt': null,
        'todayJobs': [
          {'id': 'j1', 'clientName': 'Ada'},
        ],
        'tomorrowJobs': const <Object>[],
      };
      final b = {
        'generatedAt': '2026-07-08T12:05:00Z',
        'rolloverAt': null,
        'todayJobs': [
          {'id': 'j1', 'clientName': 'Ada'},
        ],
        'tomorrowJobs': const <Object>[],
      };

      expect(
        WidgetSyncService.signatureForTesting(a),
        WidgetSyncService.signatureForTesting(b),
      );
    });

    test('a changed rollover instant produces a different signature', () {
      final a = {
        'generatedAt': '2026-07-08T12:00:00Z',
        'rolloverAt': null,
        'todayJobs': [
          {'id': 'j1', 'clientName': 'Ada'},
        ],
        'tomorrowJobs': const <Object>[],
      };
      final b = {
        'generatedAt': '2026-07-08T12:00:00Z',
        'rolloverAt': '2026-07-08T17:00:00Z',
        'todayJobs': const <Object>[],
        'tomorrowJobs': [
          {'id': 'j2', 'clientName': 'Grace'},
        ],
      };

      expect(
        WidgetSyncService.signatureForTesting(a),
        isNot(WidgetSyncService.signatureForTesting(b)),
      );
    });
  });

  group('sync / clear', () {
    late FakeAppGroup group;
    late _RecordingLogger logger;
    late int reloads;
    late bool failNextReload;
    String? uid;

    Map<String, dynamic> payload([
      String generatedAt = '2026-07-08T12:00:00Z',
    ]) => {
      'generatedAt': generatedAt,
      'todayJobs': [
        {'id': 'j1'},
      ],
    };

    WidgetSyncService service({bool isIos = true}) => WidgetSyncService(
      session: SessionFence(readUid: () => uid),
      logger: logger,
      isIosPlatform: () => isIos,
      store: group.store,
      reloadWidget: () async {
        if (failNextReload) {
          failNextReload = false;
          throw StateError('reload failed');
        }
        reloads++;
      },
    );

    setUp(() {
      group = FakeAppGroup();
      logger = _RecordingLogger();
      reloads = 0;
      failNextReload = false;
      uid = 'A';
    });

    test('writes an owner-bound payload, then reloads the widget', () async {
      await service().sync(payload());

      final written = group.decoded(mirrorWidgetKey)!;
      expect(written['ownerUid'], 'A');
      expect(written['sessionEpoch'], group.decoded(mirrorOwnerKey)!['epoch']);
      expect(
        jsonEncode(written['todayJobs']),
        jsonEncode(payload()['todayJobs']),
      );
      expect(reloads, 1);
      expect(logger.warnings, isEmpty);
    });

    test('an unchanged schedule is neither rewritten nor reloaded', () async {
      final s = service();
      await s.sync(payload());
      await s.sync(payload('2026-07-08T12:05:00Z'));

      expect(group.savesOf(mirrorWidgetKey), 1);
      expect(reloads, 1);
    });

    test('a change deep inside one job is rewritten', () async {
      final s = service();
      await s.sync(payload());
      await s.sync({
        ...payload(),
        'todayJobs': [
          {'id': 'j1', 'status': 'done'},
        ],
      });

      expect(group.savesOf(mirrorWidgetKey), 2);
      expect(reloads, 2);
    });

    test('a changed schedule is rewritten', () async {
      final s = service();
      await s.sync(payload());
      await s.sync({...payload(), 'todayJobs': const <Object>[]});

      expect(group.savesOf(mirrorWidgetKey), 2);
      expect(reloads, 2);
    });

    test(
      'an unchanged schedule is republished after an external write',
      () async {
        final s = service();
        await s.sync(payload());
        group.values[mirrorWidgetKey] = '{"ownerUid":"A"}';
        await s.sync(payload());

        expect(group.decoded(mirrorWidgetKey)!['todayJobs'], isNotEmpty);
        expect(reloads, 2);
      },
    );

    test('a new owner is written even with the same schedule', () async {
      final s = service();
      await s.sync(payload());
      uid = 'B';
      await s.sync(payload());

      expect(group.decoded(mirrorWidgetKey)!['ownerUid'], 'B');
      expect(reloads, 2);
    });

    test(
      'a FAILED write is not remembered, so the next sync retries',
      () async {
        final s = service();
        group.failNextSaveOf = mirrorWidgetKey;
        await s.sync(payload());
        await s.sync(payload());

        expect(group.savesOf(mirrorWidgetKey), 2);
        expect(reloads, 1);
        expect(logger.warnings.single, startsWith('WIDGET sync failed'));
      },
    );

    test('a FAILED reload is not remembered either', () async {
      final s = service();
      failNextReload = true;
      await s.sync(payload());
      await s.sync(payload());

      expect(group.savesOf(mirrorWidgetKey), 2);
      expect(reloads, 1);
      expect(logger.warnings.single, startsWith('WIDGET sync failed'));
    });

    test('a lease gone stale mid-write neither saves nor reloads', () async {
      final s = service();
      final hold = group.holdNextRead = Completer<void>();
      final pending = s.sync(payload());
      await Future<void>.delayed(Duration.zero);
      uid = 'B';
      hold.complete();
      await pending;

      expect(group.values[mirrorWidgetKey], isNull);
      expect(reloads, 0);
    });

    test('the next owner writes after a stale attempt', () async {
      final s = service();
      final hold = group.holdNextRead = Completer<void>();
      final pending = s.sync(payload());
      await Future<void>.delayed(Duration.zero);
      uid = 'B';
      hold.complete();
      await pending;
      await s.sync(payload());

      expect(group.decoded(mirrorWidgetKey)!['ownerUid'], 'B');
      expect(reloads, 1);
    });

    test('nothing is written while signed out', () async {
      uid = null;
      await service().sync(payload());

      expect(group.saves, isEmpty);
    });

    test('clear wipes the mirror and drops ownership', () async {
      final s = service();
      await s.sync(payload());
      await s.clear();

      expect(group.values[mirrorWidgetKey], isNull);
      expect(group.decoded(mirrorOwnerKey)!['ownerUid'], isNull);
      expect(reloads, 2);
    });

    test(
      'clear forgets the dedup, so the same schedule is rewritten',
      () async {
        final s = service();
        await s.sync(payload());
        await s.clear();
        await s.sync(payload());

        expect(group.decoded(mirrorWidgetKey)!['ownerUid'], 'A');
        expect(reloads, 3);
      },
    );

    test('a FAILED clear is logged and the next clear retries', () async {
      final s = service();
      group.failNextSaveOf = mirrorOwnerKey;
      await s.clear();
      await s.clear();

      expect(group.savesOf(mirrorOwnerKey), 2);
      expect(logger.warnings.single, startsWith('WIDGET clear failed'));
    });

    test(
      'a clear superseded by a new session neither wipes nor reloads',
      () async {
        final s = service();
        final hold = group.holdNextRead = Completer<void>();
        final write = s.sync(payload());
        await Future<void>.delayed(Duration.zero);
        final clear = s.clear();
        uid = 'B';
        hold.complete();
        await Future.wait([write, clear]);

        expect(group.saves, isEmpty);
        expect(reloads, 0);
      },
    );

    test('nothing is written off iOS', () async {
      final s = service(isIos: false);
      await s.sync(payload());
      await s.clear();

      expect(group.saves, isEmpty);
      expect(reloads, 0);
    });
  });
}
