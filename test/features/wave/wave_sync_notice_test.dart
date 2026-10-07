import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/wave_sync_notice.dart';
import 'package:scheduling/l10n/l10n.dart';

WaveSyncSummary _summary({
  int imported = 0,
  int updated = 0,
  int pushedCreated = 0,
  int pushedUpdated = 0,
  int pushedPending = 0,
  int pushedFailed = 0,
  bool pushIncomplete = false,
}) => WaveSyncSummary(
  totalCount: 0,
  imported: imported,
  updated: updated,
  skippedArchived: 0,
  pages: 0,
  pushedCreated: pushedCreated,
  pushedUpdated: pushedUpdated,
  pushedPending: pushedPending,
  pushedFailed: pushedFailed,
  pushIncomplete: pushIncomplete,
);

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final fr = lookupAppLocalizations(const Locale('fr'));

  group('waveSyncNotice', () {
    test('names the destination of every count', () {
      expect(
        waveSyncNotice(
          en,
          _summary(
            pushedCreated: 2,
            pushedUpdated: 3,
            imported: 4,
            updated: 5,
          ),
        ),
        'Synced with Wave — 2 clients added to Wave, 3 clients updated in '
        'Wave, 4 clients added to the app, 5 clients updated in the app.',
      );
    });

    test('drops the parts that moved nothing', () {
      // A one-sided run must read as one clause, not a row of zeros.
      expect(
        waveSyncNotice(en, _summary(imported: 4)),
        'Synced with Wave — 4 clients added to the app.',
      );
    });

    test('a run that moved nothing says so instead of listing zeros', () {
      expect(waveSyncNotice(en, _summary()), en.wave_syncUpToDate);
    });

    test('reports the outbox backlog the interactive push did not reach', () {
      // Without this the admin reads "3 added to Wave" as a finished sync,
      // when 200 clients are still waiting on the scheduled worker.
      expect(
        waveSyncNotice(en, _summary(pushedCreated: 3, pushedPending: 200)),
        'Synced with Wave — 3 clients added to Wave, 200 more still syncing '
        'to Wave.',
      );
    });

    test('a failed push is never reported as up to date', () {
      // A push that threw leaves every counter at zero, exactly like a quiet
      // queue — saying "already up to date" there is an affirmative lie.
      final notice = waveSyncNotice(en, _summary(pushIncomplete: true));
      expect(notice, isNot(en.wave_syncUpToDate));
      expect(notice, contains("couldn't be sent to Wave this time"));
    });

    test('dead-lettered clients are called out, not silently dropped', () {
      // These are not queued and will never retry on their own, so they must
      // not vanish into an otherwise cheerful notice.
      expect(
        waveSyncNotice(en, _summary(imported: 4, pushedFailed: 2)),
        'Synced with Wave — 4 clients added to the app, 2 clients '
        "couldn't be sent to Wave.",
      );
    });

    test('singular and plural forms are both used', () {
      expect(
        waveSyncNotice(en, _summary(pushedCreated: 1, imported: 2)),
        'Synced with Wave — 1 client added to Wave, 2 clients added to the '
        'app.',
      );
    });

    test('a press that only DROPPED refused jobs does not say nothing happened',
        () {
      // The queue was cleared and the reasons moved onto the clients, where
      // they are fixable. "Nothing to retry" would be the same silence the
      // failed count was added to end.
      final notice = waveRetryNotice(
        en,
        const WaveRetryResult(
          requeued: 0,
          scanned: 2,
          pushed: 0,
          failed: 0,
          blocked: 2,
        ),
      );

      expect(notice, isNot(en.wave_retryNoneRecovered));
      expect(notice, contains('2 clients need fixing'));
    });

    test('reports refused jobs alongside a real requeue', () {
      final notice = waveRetryNotice(
        en,
        const WaveRetryResult(
          requeued: 1,
          scanned: 3,
          pushed: 1,
          failed: 0,
          blocked: 1,
        ),
      );

      expect(notice, contains('1 client needs fixing'));
    });

    test('composes in French too', () {
      expect(
        waveSyncNotice(fr, _summary(pushedCreated: 2, updated: 1)),
        'Synchronisé avec Wave — 2 clients ajoutés à Wave, 1 client mis à '
        'jour dans l’app.',
      );
    });
  });

  group('waveRetryNotice', () {
    test('a requeue that reached Wave names what landed', () {
      expect(
        waveRetryNotice(
          en,
          const WaveRetryResult(
            requeued: 2,
            scanned: 2,
            pushed: 2,
            failed: 0,
          ),
        ),
        '2 clients sent to Wave',
      );
    });

    test('a job that died again is never reported as a clean retry', () {
      // The whole bug: the push behind the requeue dead-letters a
      // non-retryable job inside the same call, so the outbox row still reads
      // "1 client failed to sync" — and the old branch, seeing only
      // `requeued`, announced "1 client queued for Wave again" as a success.
      final notice = waveRetryNotice(
        en,
        const WaveRetryResult(requeued: 1, scanned: 1, pushed: 0, failed: 1),
      );
      expect(notice, isNot(contains('queued for Wave again')));
      expect(notice, contains("1 client still couldn't be sent"));
    });

    test('a partial recovery reports both halves', () {
      expect(
        waveRetryNotice(
          en,
          const WaveRetryResult(
            requeued: 3,
            scanned: 3,
            pushed: 2,
            failed: 1,
          ),
        ),
        "2 clients sent to Wave, 1 client still couldn't be sent — open it to "
        'see the error',
      );
    });

    test('a requeue whose push never ran still reports the durable half', () {
      // Those jobs ARE back in the queue and will drain, so this stays the
      // success it was — null means "not known", not "nothing failed".
      expect(
        waveRetryNotice(
          en,
          const WaveRetryResult(
            requeued: 3,
            scanned: 3,
            pushed: null,
            failed: null,
          ),
        ),
        '3 clients queued for Wave again',
      );
    });

    test('nothing left to requeue says so', () {
      expect(
        waveRetryNotice(
          en,
          const WaveRetryResult(
            requeued: 0,
            scanned: 1,
            pushed: 0,
            failed: 0,
          ),
        ),
        en.wave_retryNoneRecovered,
      );
    });

    test('composes in French too', () {
      expect(
        waveRetryNotice(
          fr,
          const WaveRetryResult(requeued: 1, scanned: 1, pushed: 0, failed: 1),
        ),
        contains('n’a toujours pas pu être envoyé'),
      );
    });
  });
}
