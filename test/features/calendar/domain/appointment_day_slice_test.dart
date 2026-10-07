// Mirrored value-for-value by functions/__tests__/day_slice_utils.test.js.
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

AppointmentRecord _record({
  required DateTime start,
  required DateTime end,
  bool isAllDay = false,
  String id = 'a1',
  String status = 'pending',
  bool isPersonal = false,
  bool isDayOff = false,
}) => AppointmentRecord(
  id: id,
  title: 'Repipe',
  startTime: start,
  endTime: end,
  isAllDay: isAllDay,
  status: status,
  isPersonal: isPersonal,
  isDayOff: isDayOff,
);

void main() {
  group('countsAsWork', () {
    AppointmentRecord at({
      String status = 'pending',
      bool isPersonal = false,
      bool isDayOff = false,
    }) => _record(
      start: DateTime(2026, 8, 1, 9),
      end: DateTime(2026, 8, 1, 17),
      status: status,
      isPersonal: isPersonal,
      isDayOff: isDayOff,
    );

    test('an open job is work', () {
      expect(countsAsWork(at()), isTrue);
    });

    test('a FINISHED job is still work — that work happened', () {
      expect(countsAsWork(at(status: 'done')), isTrue);
      expect(countsAsWork(at(status: 'completed')), isTrue);
    });

    test('a cancelled job is NOT work — it is not happening', () {
      expect(countsAsWork(at(status: 'cancelled')), isFalse);
    });

    test('time off is not work', () {
      expect(countsAsWork(at(isPersonal: true, isDayOff: true)), isFalse);
    });

    test('a stray isDayOff on a client visit does not erase it', () {
      // `isTimeOff` is `isPersonal && isDayOff`, never the stored flag alone.
      expect(countsAsWork(at(isDayOff: true)), isTrue);
    });

    test('an ordinary personal block is still work', () {
      expect(countsAsWork(at(isPersonal: true)), isTrue);
    });
  });

  group('sliceFor', () {
    test('a single-day job is day 1 of 1', () {
      final a = _record(
        start: DateTime(2026, 8, 1, 9),
        end: DateTime(2026, 8, 1, 17),
      );
      final slice = sliceFor(a, DateTime(2026, 8))!;
      expect(slice.dayIndex, 1);
      expect(slice.dayCount, 1);
      expect(slice.isMultiDay, isFalse);
    });

    test('a 5-day job reports the same daily window on every day', () {
      final a = _record(
        start: DateTime(2026, 8, 1, 9),
        end: DateTime(2026, 8, 5, 17),
      );
      final slice = sliceFor(a, DateTime(2026, 8, 3))!;
      expect(slice.dayIndex, 3);
      expect(slice.dayCount, 5);
      expect(slice.windowStart, DateTime(2026, 8, 3, 9));
      expect(slice.windowEnd, DateTime(2026, 8, 3, 17));
      expect(slice.isOvernight, isFalse);
    });

    test('a day outside the span has no slice', () {
      final a = _record(
        start: DateTime(2026, 8, 1, 9),
        end: DateTime(2026, 8, 5, 17),
      );
      expect(sliceFor(a, DateTime(2026, 7, 31)), isNull);
      expect(sliceFor(a, DateTime(2026, 8, 6)), isNull);
    });

    test('a night shift counts nights and ends the next morning', () {
      // Aug 1, 2, 3 at 10pm; the last window ends Aug 4 at 6am.
      final a = _record(
        start: DateTime(2026, 8, 1, 22),
        end: DateTime(2026, 8, 4, 6),
      );
      final slice = sliceFor(a, DateTime(2026, 8, 2))!;
      expect(slice.dayCount, 3);
      expect(slice.dayIndex, 2);
      expect(slice.isOvernight, isTrue);
      expect(slice.windowStart, DateTime(2026, 8, 2, 22));
      expect(slice.windowEnd, DateTime(2026, 8, 3, 6));
    });

    test('a night shift shows nothing on the morning it finishes', () {
      final a = _record(
        start: DateTime(2026, 8, 1, 22),
        end: DateTime(2026, 8, 4, 6),
      );
      expect(sliceFor(a, DateTime(2026, 8, 4)), isNull);
    });

    test('an all-day block is not overnight', () {
      final a = _record(
        start: DateTime(2026, 8, 10),
        end: DateTime(2026, 8, 14, 23, 59),
        isAllDay: true,
      );
      final slice = sliceFor(a, DateTime(2026, 8, 12))!;
      expect(slice.dayCount, 5);
      expect(slice.dayIndex, 3);
      expect(slice.isOvernight, isFalse);
    });
  });

  group('expandToDays', () {
    test('fans one record across every day it spans', () {
      final a = _record(
        start: DateTime(2026, 8, 1, 9),
        end: DateTime(2026, 8, 3, 17),
      );
      final index = expandToDays(
        [a],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 9),
        ),
      );
      expect(index.keys.toList(), [
        DateTime(2026, 8),
        DateTime(2026, 8, 2),
        DateTime(2026, 8, 3),
      ]);
    });

    test('drops days outside the requested range', () {
      final a = _record(
        start: DateTime(2026, 7, 30, 9),
        end: DateTime(2026, 8, 2, 17),
      );
      final index = expandToDays(
        [a],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 9),
        ),
      );
      expect(index.keys.toList(), [DateTime(2026, 8), DateTime(2026, 8, 2)]);
    });

    test('sorts all-day blocks above timed jobs, then by window start', () {
      final timedEarly = _record(
        start: DateTime(2026, 8, 3, 8, 30),
        end: DateTime(2026, 8, 3, 10),
        id: 'early',
      );
      final timedLate = _record(
        start: DateTime(2026, 8, 3, 13),
        end: DateTime(2026, 8, 3, 16),
        id: 'late',
      );
      final allDay = _record(
        start: DateTime(2026, 8, 3),
        end: DateTime(2026, 8, 3, 23, 59),
        isAllDay: true,
        id: 'allday',
      );

      final index = expandToDays(
        [timedLate, timedEarly, allDay],
        AppointmentDateRange(
          start: DateTime(2026, 8, 3),
          end: DateTime(2026, 8, 4),
        ),
      );
      expect(
        index[DateTime(2026, 8, 3)]!.map((s) => s.appointment.id).toList(),
        ['allday', 'early', 'late'],
      );
    });

    test("sinks closed jobs below the day's open work", () {
      final day = DateTime(2026, 8, 3);
      final range = AppointmentDateRange(start: day, end: DateTime(2026, 8, 4));

      final doneEarly = _record(
        start: DateTime(2026, 8, 3, 7),
        end: DateTime(2026, 8, 3, 8),
        id: 'done',
        status: 'done',
      );
      final cancelledMidday = _record(
        start: DateTime(2026, 8, 3, 11),
        end: DateTime(2026, 8, 3, 12),
        id: 'cancelled',
        status: 'cancelled',
      );
      final openLate = _record(
        start: DateTime(2026, 8, 3, 15),
        end: DateTime(2026, 8, 3, 16),
        id: 'open',
      );

      final index = expandToDays([
        doneEarly,
        cancelledMidday,
        openLate,
      ], range);

      expect(index[day]!.map((s) => s.appointment.id).toList(), [
        'open',
        'done',
        'cancelled',
      ]);
    });

    test('the all-day and clock tiers still apply inside the closed block', () {
      final day = DateTime(2026, 8, 3);
      final range = AppointmentDateRange(start: day, end: DateTime(2026, 8, 4));

      final closedTimedEarly = _record(
        start: DateTime(2026, 8, 3, 8),
        end: DateTime(2026, 8, 3, 9),
        id: 'closedEarly',
        status: 'done',
      );
      final closedTimedLate = _record(
        start: DateTime(2026, 8, 3, 14),
        end: DateTime(2026, 8, 3, 15),
        id: 'closedLate',
        status: 'cancelled',
      );
      final closedAllDay = _record(
        start: day,
        end: DateTime(2026, 8, 3, 23, 59),
        isAllDay: true,
        id: 'closedAllDay',
        status: 'done',
      );

      final index = expandToDays([
        closedTimedLate,
        closedTimedEarly,
        closedAllDay,
      ], range);

      expect(index[day]!.map((s) => s.appointment.id).toList(), [
        'closedAllDay',
        'closedEarly',
        'closedLate',
      ]);
    });

    test('the legacy `completed` spelling sinks too', () {
      final day = DateTime(2026, 8, 3);
      final legacy = _record(
        start: DateTime(2026, 8, 3, 7),
        end: DateTime(2026, 8, 3, 8),
        id: 'legacy',
        status: 'completed',
      );
      final open = _record(
        start: DateTime(2026, 8, 3, 15),
        end: DateTime(2026, 8, 3, 16),
        id: 'open',
      );

      final index = expandToDays([
        legacy,
        open,
      ], AppointmentDateRange(start: day, end: DateTime(2026, 8, 4)));

      expect(index[day]!.map((s) => s.appointment.id).toList(), [
        'open',
        'legacy',
      ]);
    });

    test('an in-progress job is open, so it keeps its clock slot', () {
      final day = DateTime(2026, 8, 3);
      final inProgress = _record(
        start: DateTime(2026, 8, 3, 9),
        end: DateTime(2026, 8, 3, 10),
        id: 'inProgress',
        status: 'in_progress',
      );
      final pendingLater = _record(
        start: DateTime(2026, 8, 3, 15),
        end: DateTime(2026, 8, 3, 16),
        id: 'pending',
      );

      final index = expandToDays([
        pendingLater,
        inProgress,
      ], AppointmentDateRange(start: day, end: DateTime(2026, 8, 4)));

      expect(index[day]!.map((s) => s.appointment.id).toList(), [
        'inProgress',
        'pending',
      ]);
    });

    test(
      'an overnight run files under the evening it starts, not the morning '
      'it ends',
      () {
        final overnight = _record(
          start: DateTime(2026, 8, 1, 22),
          end: DateTime(2026, 8, 3, 6),
        );
        final index = expandToDays(
          [overnight],
          AppointmentDateRange(
            start: DateTime(2026, 8),
            end: DateTime(2026, 8, 10),
          ),
        );
        expect(index.keys.toList(), [DateTime(2026, 8), DateTime(2026, 8, 2)]);
      },
    );

    test(
      'a clamped run reports the clamped count, so its final day is the '
      'last day',
      () {
        final corrupt = _record(
          start: DateTime(2026, 8, 1, 9),
          end: DateTime(2026, 9, 10, 17), // 41 days — past the 14-day cap
        );
        final clamped = <int>[];
        final index = expandToDays(
          [corrupt],
          AppointmentDateRange(
            start: DateTime(2026, 8),
            end: DateTime(2026, 10),
          ),
          onSpanClamped: (_, days) => clamped.add(days),
        );

        expect(index.length, maxAppointmentSpanDays);
        expect(clamped, [41]); // the REAL span is reported, not the clamped one

        final last = index[DateTime(2026, 8, 14)]!.single;
        expect(last.dayIndex, maxAppointmentSpanDays);
        expect(last.dayCount, maxAppointmentSpanDays);
        expect(last.isLastDay, isTrue);
      },
    );
  });

  group('runsOn', () {
    // The range streams query from `fetchStart`, 14 days before the range's
    // start, so every surface that wants ONE day has to re-scope through
    // here. Reading the stream raw showed a fortnight of jobs as "today".
    final run = _record(
      start: DateTime(2026, 8, 1, 9),
      end: DateTime(2026, 8, 5, 17),
    );

    test('is true on every day the run works', () {
      for (var d = 1; d <= 5; d++) {
        expect(runsOn(run, DateTime(2026, 8, d)), isTrue, reason: 'day $d');
      }
    });

    test('is false the day before and the day after', () {
      expect(runsOn(run, DateTime(2026, 7, 31)), isFalse);
      expect(runsOn(run, DateTime(2026, 8, 6)), isFalse);
    });

    test('excludes a job that started a fortnight before the day', () {
      final old = _record(
        start: DateTime(2026, 7, 22, 9),
        end: DateTime(2026, 7, 22, 17),
      );
      expect(runsOn(old, DateTime(2026, 8, 4)), isFalse);
    });
  });

  group('dailyWindowsOverlap', () {
    // The two stored instants are a DAILY window, so the raw instant test
    // (aStart < bEnd && aEnd > bStart) reports phantom clashes across a run.
    test('a 9-5 week does not clash with a 7pm job inside it', () {
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 1, 9),
          aEnd: DateTime(2026, 8, 5, 17),
          bStart: DateTime(2026, 8, 3, 19),
          bEnd: DateTime(2026, 8, 3, 20),
        ),
        isFalse,
      );
    });

    test('the same week DOES clash with a midday job inside it', () {
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 1, 9),
          aEnd: DateTime(2026, 8, 5, 17),
          bStart: DateTime(2026, 8, 3, 12),
          bEnd: DateTime(2026, 8, 3, 13),
        ),
        isTrue,
      );
    });

    test('runs that share no day never clash', () {
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 1, 9),
          aEnd: DateTime(2026, 8, 2, 17),
          bStart: DateTime(2026, 8, 4, 9),
          bEnd: DateTime(2026, 8, 5, 17),
        ),
        isFalse,
      );
    });

    test('touching windows on a shared day do not clash', () {
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 1, 9),
          aEnd: DateTime(2026, 8, 3, 12),
          bStart: DateTime(2026, 8, 2, 12),
          bEnd: DateTime(2026, 8, 2, 14),
        ),
        isFalse,
      );
    });

    test('an overnight shift clashes with a job in its small hours', () {
      // 22:00-06:00 crosses midnight, so day 1 runs into Aug 2 morning.
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 1, 22),
          aEnd: DateTime(2026, 8, 3, 6),
          bStart: DateTime(2026, 8, 2, 2),
          bEnd: DateTime(2026, 8, 2, 3),
        ),
        isTrue,
      );
    });

    test('a corrupt window whose end precedes its start never clashes', () {
      expect(
        dailyWindowsOverlap(
          aStart: DateTime(2026, 8, 10, 9),
          aEnd: DateTime(2026, 8, 1, 17),
          bStart: DateTime(2026, 8, 10, 9),
          bEnd: DateTime(2026, 8, 10, 17),
        ),
        isFalse,
      );
    });
  });

  group('the maxAppointmentSpanDays clamp', () {
    // firestore.rules bounds client writes to the cap, but the console and the
    // Admin SDK bypass rules — so a doc that exceeds it is still reachable and
    // this clamp still has to hold. When these owners disagree the drawer reads
    // "1 job today" every day for a year and a card reads "Day 400 of 900".
    final corrupt = _record(
      start: DateTime(2026, 8, 2, 9),
      end: DateTime(2028, 8, 2, 17),
    );

    test('sliceFor reports the clamped length, like expandToDays', () {
      final slice = sliceFor(corrupt, DateTime(2026, 8, 2));
      expect(slice, isNotNull);
      expect(slice!.dayCount, maxAppointmentSpanDays);
    });

    test('sliceFor stops at the clamped last day', () {
      // Day 14 is the last one it runs.
      expect(sliceFor(corrupt, DateTime(2026, 8, 15)), isNotNull);
      expect(sliceFor(corrupt, DateTime(2026, 8, 16)), isNull);
    });

    test('runsOn agrees with the calendar about the last day', () {
      expect(runsOn(corrupt, DateTime(2026, 8, 15)), isTrue);
      expect(runsOn(corrupt, DateTime(2026, 8, 16)), isFalse);
      // A year later would have been "still running" before the clamp.
      expect(runsOn(corrupt, DateTime(2027, 8, 3)), isFalse);
    });

    test('runsInRange stops at the clamped end too', () {
      expect(
        runsInRange(corrupt, DateTime(2026, 8, 10), DateTime(2026, 8, 18)),
        isTrue,
      );
      expect(
        runsInRange(corrupt, DateTime(2027, 1, 4), DateTime(2027, 1, 11)),
        isFalse,
      );
    });

    test('an ordinary run is untouched by the clamp', () {
      final normal = _record(
        start: DateTime(2026, 8, 2, 9),
        end: DateTime(2026, 8, 6, 17),
      );
      expect(sliceFor(normal, DateTime(2026, 8, 2))!.dayCount, 5);
    });
  });

  group('stored run label', () {
    AppointmentRecord dayThreeOfFive() => AppointmentRecord(
      id: 'd3',
      startTime: DateTime(2026, 8, 5, 9),
      endTime: DateTime(2026, 8, 5, 17),
      seriesId: 'd1',
      dayIndex: 3,
      dayCount: 5,
    );

    test('a split day reports its stored position', () {
      final slice = sliceFor(dayThreeOfFive(), DateTime(2026, 8, 5));
      expect(slice, isNotNull);
      expect(slice!.dayIndex, 3);
      expect(slice.dayCount, 5);
      expect(slice.isMultiDay, isTrue);
    });

    test('the stored pair does NOT widen which days it runs on', () {
      // The regression this guard exists for: reading dayCount 5 into the
      // range test would smear one document across five days, and runsOn is
      // the mandated re-scoping call on the drawer badge, the roster count and
      // the dashboard.
      final record = dayThreeOfFive();
      expect(runsOn(record, DateTime(2026, 8, 5)), isTrue);
      expect(runsOn(record, DateTime(2026, 8, 6)), isFalse);
      expect(runsOn(record, DateTime(2026, 8, 9)), isFalse);
      expect(sliceFor(record, DateTime(2026, 8, 6)), isNull);
    });

    test('the window stays this day only', () {
      final slice = sliceFor(dayThreeOfFive(), DateTime(2026, 8, 5))!;
      expect(slice.windowStart, DateTime(2026, 8, 5, 9));
      expect(slice.windowEnd, DateTime(2026, 8, 5, 17));
    });

    test('a legacy wide document still derives its pair', () {
      final wide = AppointmentRecord(
        id: 'w1',
        startTime: DateTime(2026, 8, 3, 9),
        endTime: DateTime(2026, 8, 7, 17),
      );
      final slice = sliceFor(wide, DateTime(2026, 8, 5))!;
      expect(slice.dayIndex, 3);
      expect(slice.dayCount, 5);
    });

    test('an incoherent stored pair falls back to the derived one', () {
      final broken = AppointmentRecord(
        id: 'b1',
        startTime: DateTime(2026, 8, 5, 9),
        endTime: DateTime(2026, 8, 5, 17),
        dayIndex: 9,
        dayCount: 5,
      );
      final slice = sliceFor(broken, DateTime(2026, 8, 5))!;
      expect(slice.dayIndex, 1);
      expect(slice.dayCount, 1);
    });

    test('expandToDays substitutes the stored label too', () {
      // The main calendar's agenda builds its slices through expandToDays, not
      // sliceFor. Without the substitution a split run day renders with
      // dayCount 1, so a 5-day run showed five unlabelled identical cards
      // while the day route, dashboard, widget and Siri all said "Day 3 of 5".
      final byDay = expandToDays(
        [dayThreeOfFive()],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 10),
        ),
      );
      final slices = byDay[DateTime(2026, 8, 5)]!;
      expect(slices, hasLength(1));
      expect(slices.single.dayIndex, 3);
      expect(slices.single.dayCount, 5);
      expect(slices.single.isMultiDay, isTrue);
    });

    test('expandToDays still emits the stored day ONLY', () {
      // Same guard as sliceFor: the stored pair labels, it never widens.
      final byDay = expandToDays(
        [dayThreeOfFive()],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 10),
        ),
      );
      expect(byDay.keys, [DateTime(2026, 8, 5)]);
    });

    test('expandToDays ignores an incoherent stored pair', () {
      final broken = AppointmentRecord(
        id: 'b2',
        startTime: DateTime(2026, 8, 5, 9),
        endTime: DateTime(2026, 8, 5, 17),
        dayIndex: 9,
        dayCount: 5,
      );
      final byDay = expandToDays(
        [broken],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 10),
        ),
      );
      final slice = byDay[DateTime(2026, 8, 5)]!.single;
      expect(slice.dayIndex, 1);
      expect(slice.dayCount, 1);
    });

    test('expandToDays keeps deriving the pair for a legacy WIDE record', () {
      final wide = AppointmentRecord(
        id: 'w3',
        startTime: DateTime(2026, 8, 3, 9),
        endTime: DateTime(2026, 8, 7, 17),
      );
      final byDay = expandToDays(
        [wide],
        AppointmentDateRange(
          start: DateTime(2026, 8),
          end: DateTime(2026, 8, 10),
        ),
      );
      expect(byDay[DateTime(2026, 8, 3)]!.single.dayIndex, 1);
      expect(byDay[DateTime(2026, 8, 5)]!.single.dayIndex, 3);
      expect(byDay[DateTime(2026, 8, 7)]!.single.dayCount, 5);
    });

    test('a stored pair on a WIDE document is ignored', () {
      // Only a console write can produce this. Honouring it would print the
      // same "Day 3 of 5" on all five days of the span.
      final wide = AppointmentRecord(
        id: 'w2',
        startTime: DateTime(2026, 8, 3, 9),
        endTime: DateTime(2026, 8, 7, 17),
        dayIndex: 3,
        dayCount: 5,
      );
      expect(sliceFor(wide, DateTime(2026, 8, 3))!.dayIndex, 1);
      expect(sliceFor(wide, DateTime(2026, 8, 5))!.dayIndex, 3);
    });
  });

  group('expandRunWindows', () {
    test('a one-day window yields one pair unchanged', () {
      final windows = expandRunWindows(
        DateTime(2026, 8, 3, 9),
        DateTime(2026, 8, 3, 17),
      );
      expect(windows, hasLength(1));
      expect(windows.single.start, DateTime(2026, 8, 3, 9));
      expect(windows.single.end, DateTime(2026, 8, 3, 17));
    });

    test('a 5-day 9-to-5 window yields five one-day windows', () {
      final windows = expandRunWindows(
        DateTime(2026, 8, 3, 9),
        DateTime(2026, 8, 7, 17),
      );
      expect(windows, hasLength(5));
      expect(windows.first.start, DateTime(2026, 8, 3, 9));
      expect(windows.first.end, DateTime(2026, 8, 3, 17));
      expect(windows.last.start, DateTime(2026, 8, 7, 9));
      expect(windows.last.end, DateTime(2026, 8, 7, 17));
    });

    test('a night shift yields one window per NIGHT, ending the morning after', () {
      // 22:00 Aug 3 -> 06:00 Aug 5 is two nights: the end date names the last
      // day the crew STARTS work, so the run is Aug 3 and Aug 4.
      final windows = expandRunWindows(
        DateTime(2026, 8, 3, 22),
        DateTime(2026, 8, 5, 6),
      );
      expect(windows, hasLength(2));
      expect(windows.first.start, DateTime(2026, 8, 3, 22));
      expect(windows.first.end, DateTime(2026, 8, 4, 6));
      expect(windows.last.start, DateTime(2026, 8, 4, 22));
      expect(windows.last.end, DateTime(2026, 8, 5, 6));
    });

    test('an all-day multi-day block yields a midnight-to-23:59 window a day', () {
      final windows = expandRunWindows(
        DateTime(2026, 8, 3),
        DateTime(2026, 8, 4, 23, 59),
      );
      expect(windows, hasLength(2));
      expect(windows.first.start, DateTime(2026, 8, 3));
      expect(windows.first.end, DateTime(2026, 8, 3, 23, 59));
      expect(windows.last.start, DateTime(2026, 8, 4));
      expect(windows.last.end, DateTime(2026, 8, 4, 23, 59));
    });

    test('a span past the cap clamps to maxAppointmentSpanDays', () {
      final windows = expandRunWindows(
        DateTime(2026, 8, 3, 9),
        DateTime(2027, 3, 12, 17),
      );
      expect(windows, hasLength(maxAppointmentSpanDays));
    });

    test('a corrupt pair whose end precedes its start yields one window', () {
      final windows = expandRunWindows(
        DateTime(2026, 8, 7, 9),
        DateTime(2026, 8, 3, 17),
      );
      expect(windows, hasLength(1));
      expect(windows.single.start, DateTime(2026, 8, 7, 9));
    });
  });
}
