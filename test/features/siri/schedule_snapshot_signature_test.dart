import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/app_group_mirror_store.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_service.dart';

import '../../support/fake_app_group.dart';

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

void main() {
  group('ScheduleSnapshotService.signatureForTesting', () {
    test('ignores generatedAt so an unchanged schedule dedupes', () {
      final a = {
        'version': 1,
        'generatedAt': 1791234567890,
        'role': 'employee',
        'days': [
          {
            'date': '2026-07-19',
            'appointments': [
              {'id': 'j1', 'clientName': 'Ada'},
            ],
          },
        ],
      };
      final b = {...a, 'generatedAt': 1791234599999};

      expect(
        ScheduleSnapshotService.signatureForTesting(a),
        ScheduleSnapshotService.signatureForTesting(b),
      );
    });

    test('a changed schedule produces a different signature', () {
      final a = {
        'version': 1,
        'generatedAt': 1791234567890,
        'role': 'employee',
        'days': [
          {
            'date': '2026-07-19',
            'appointments': [
              {'id': 'j1', 'clientName': 'Ada'},
            ],
          },
        ],
      };
      final b = {
        ...a,
        'days': [
          {
            'date': '2026-07-19',
            'appointments': [
              {'id': 'j2', 'clientName': 'Grace'},
            ],
          },
        ],
      };

      expect(
        ScheduleSnapshotService.signatureForTesting(a),
        isNot(ScheduleSnapshotService.signatureForTesting(b)),
      );
    });

    test('a role change produces a different signature', () {
      final a = {
        'version': 1,
        'generatedAt': 1791234567890,
        'role': 'employee',
        'days': const <Object>[],
      };
      final b = {...a, 'role': 'admin'};

      expect(
        ScheduleSnapshotService.signatureForTesting(a),
        isNot(ScheduleSnapshotService.signatureForTesting(b)),
      );
    });
  });

  group('writeSnapshot / clearSnapshot', () {
    late FakeAppGroup group;
    late _RecordingLogger logger;
    String? uid;

    Map<String, dynamic> snapshot([int generatedAt = 1791234567890]) => {
      'version': 4,
      'generatedAt': generatedAt,
      'role': 'employee',
      'days': const <Object>[],
    };

    ScheduleSnapshotService service({bool isIos = true}) =>
        ScheduleSnapshotService(
          session: SessionFence(readUid: () => uid),
          logger: logger,
          isIosPlatform: () => isIos,
          store: group.store,
        );

    setUp(() {
      group = FakeAppGroup();
      logger = _RecordingLogger();
      uid = 'A';
    });

    test('writes an owner-bound snapshot', () async {
      await service().writeSnapshot(snapshot());

      final written = group.decoded(mirrorSnapshotKey)!;
      expect(written['ownerUid'], 'A');
      expect(written['sessionEpoch'], group.decoded(mirrorOwnerKey)!['epoch']);
      expect(logger.warnings, isEmpty);
    });

    test('an unchanged schedule is not rewritten', () async {
      final s = service();
      await s.writeSnapshot(snapshot());
      await s.writeSnapshot(snapshot(1791234599999));

      expect(group.savesOf(mirrorSnapshotKey), 1);
    });

    test('a change deep inside one day is rewritten', () async {
      final s = service();
      final day = {
        'date': '2026-07-19',
        'appointments': [
          {'id': 'j1', 'status': 'pending'},
        ],
      };
      await s.writeSnapshot({
        ...snapshot(),
        'days': [day],
      });
      await s.writeSnapshot({
        ...snapshot(),
        'days': [
          {
            ...day,
            'appointments': [
              {'id': 'j1', 'status': 'done'},
            ],
          },
        ],
      });

      expect(group.savesOf(mirrorSnapshotKey), 2);
    });

    test(
      'an unchanged schedule is republished after an external write',
      () async {
        final s = service();
        await s.writeSnapshot(snapshot());
        group.values.remove(mirrorSnapshotKey);
        await s.writeSnapshot(snapshot());

        expect(group.decoded(mirrorSnapshotKey)!['ownerUid'], 'A');
      },
    );

    test('a FAILED write is not remembered, so the next one retries', () async {
      final s = service();
      group.failNextSaveOf = mirrorSnapshotKey;
      await s.writeSnapshot(snapshot());
      await s.writeSnapshot(snapshot());

      expect(group.savesOf(mirrorSnapshotKey), 2);
      expect(logger.warnings.single, startsWith('SIRI snapshot write failed'));
    });

    test('a lease gone stale mid-write saves nothing', () async {
      final s = service();
      final hold = group.holdNextRead = Completer<void>();
      final pending = s.writeSnapshot(snapshot());
      await Future<void>.delayed(Duration.zero);
      uid = 'B';
      hold.complete();
      await pending;

      expect(group.values[mirrorSnapshotKey], isNull);
    });

    test('clear wipes the snapshot and forgets the dedup', () async {
      final s = service();
      await s.writeSnapshot(snapshot());
      await s.clearSnapshot();
      expect(group.values[mirrorSnapshotKey], isNull);

      await s.writeSnapshot(snapshot());
      expect(group.savesOf(mirrorSnapshotKey), 3);
    });

    test('nothing is written off iOS', () async {
      final s = service(isIos: false);
      await s.writeSnapshot(snapshot());
      await s.clearSnapshot();

      expect(group.saves, isEmpty);
    });
  });
}
