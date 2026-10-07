"use strict";

/**
 * Unit tests for the server-side day-slice mirror. These are deliberately the
 * SAME worked examples as
 * `test/features/calendar/domain/appointment_day_slice_test.dart`, so a
 * divergence between the Dart original and this hand-mirror fails a test
 * instead of shipping.
 *
 * Instants are written as explicit UTC so the suite is timezone-independent
 * (the neighbouring widget-payload suite does the same). August is EDT, so
 * Toronto is UTC-4 throughout.
 */

const {
  MAX_APPOINTMENT_SPAN_DAYS,
  sliceForDay,
  dayCountOf,
  lastWorkDayMs,
  clampedLastWorkDayMs,
  calendarDaysBetween,
  resolveWindow,
  expandRunWindows,
  dailyWindowsOverlap,
} = require("../day_slice_utils");

// Epoch ms of a Toronto wall-clock instant given its UTC ISO form.
const at = (iso) => new Date(iso).getTime();

// Toronto midnights, used as the `dayMs` argument.
const JUL31 = at("2026-07-31T04:00:00.000Z");
const AUG1 = at("2026-08-01T04:00:00.000Z");
const AUG2 = at("2026-08-02T04:00:00.000Z");
const AUG3 = at("2026-08-03T04:00:00.000Z");
const AUG4 = at("2026-08-04T04:00:00.000Z");
const AUG6 = at("2026-08-06T04:00:00.000Z");
const AUG12 = at("2026-08-12T04:00:00.000Z");

// Aug 1 09:00 -> Aug 5 17:00 Toronto: a five-day 9-to-5 run.
const dayJob = {
  startTime: at("2026-08-01T13:00:00.000Z"),
  endTime: at("2026-08-05T21:00:00.000Z"),
};

// Aug 1 22:00 -> Aug 4 06:00 Toronto: three NIGHTS, the last starting Aug 3.
const nightShift = {
  startTime: at("2026-08-02T02:00:00.000Z"),
  endTime: at("2026-08-04T10:00:00.000Z"),
};

describe("day_slice_utils", () => {
  test("the cap matches the Dart constant", () => {
    expect(MAX_APPOINTMENT_SPAN_DAYS).toBe(14);
  });

  test("a single-day job is day 1 of 1", () => {
    const r = {
      startTime: at("2026-08-01T13:00:00.000Z"),
      endTime: at("2026-08-01T21:00:00.000Z"),
    };
    expect(dayCountOf(r)).toBe(1);
    const s = sliceForDay(r, AUG1);
    expect(s.dayIndex).toBe(1);
    expect(s.dayCount).toBe(1);
    expect(s.isMultiDay).toBe(false);
  });

  test("a 5-day job reports the same daily window on every day", () => {
    const s = sliceForDay(dayJob, AUG3);
    expect(s.dayIndex).toBe(3);
    expect(s.dayCount).toBe(5);
    expect(s.isMultiDay).toBe(true);
    expect(s.windowStartMs).toBe(at("2026-08-03T13:00:00.000Z"));
    expect(s.windowEndMs).toBe(at("2026-08-03T21:00:00.000Z"));
    expect(s.isOvernight).toBe(false);
  });

  test("a day outside the run has no slice", () => {
    expect(sliceForDay(dayJob, JUL31)).toBeNull();
    expect(sliceForDay(dayJob, AUG6)).toBeNull();
  });

  test("a night shift counts nights and ends the next morning", () => {
    expect(dayCountOf(nightShift)).toBe(3);
    expect(lastWorkDayMs(nightShift)).toBe(AUG3);
    const s = sliceForDay(nightShift, AUG2);
    expect(s.dayIndex).toBe(2);
    expect(s.isOvernight).toBe(true);
    expect(s.windowStartMs).toBe(at("2026-08-03T02:00:00.000Z"));
    expect(s.windowEndMs).toBe(at("2026-08-03T10:00:00.000Z"));
  });

  test("a night shift has no slice on the morning it finishes", () => {
    expect(sliceForDay(nightShift, AUG4)).toBeNull();
  });

  test("an all-day run is not overnight", () => {
    const r = {
      startTime: at("2026-08-10T04:00:00.000Z"),
      endTime: at("2026-08-15T03:59:00.000Z"),
    };
    expect(dayCountOf(r)).toBe(5);
    expect(sliceForDay(r, AUG12).isOvernight).toBe(false);
  });

  test("an over-long window is clamped to the cap", () => {
    // Written by the console or another build — the rules constrain neither
    // instant, so the clamp is the only thing keeping a day counter sane.
    const corrupt = {
      startTime: at("2026-08-01T13:00:00.000Z"),
      endTime: at("2026-09-30T21:00:00.000Z"),
    };
    expect(dayCountOf(corrupt)).toBe(61);
    expect(sliceForDay(corrupt, AUG3).dayCount).toBe(MAX_APPOINTMENT_SPAN_DAYS);
    // Day 15 of the raw run is past the clamp, so it renders nowhere.
    expect(sliceForDay(corrupt, at("2026-08-15T04:00:00.000Z"))).toBeNull();
  });

  test("a corrupt pair whose end precedes its start has no slice", () => {
    const backwards = {
      startTime: at("2026-08-05T13:00:00.000Z"),
      endTime: at("2026-08-01T21:00:00.000Z"),
    };
    expect(sliceForDay(backwards, AUG3)).toBeNull();
  });

  test("a missing instant has no slice", () => {
    expect(sliceForDay({startTime: null, endTime: null}, AUG3)).toBeNull();
    expect(dayCountOf({})).toBe(0);
  });

  test("a record with no endTime is a single-day job, not a vanished one",
      () => {
        // Legacy and console-written docs exist without one. Reading the
        // absent end as "equal times" would make it overnight, count the run
        // backwards to zero days, and drop the job out of every mirror.
        const r = {startTime: at("2026-08-03T13:00:00.000Z")};
        expect(dayCountOf(r)).toBe(1);
        const s = sliceForDay(r, AUG3);
        expect(s.dayIndex).toBe(1);
        expect(s.dayCount).toBe(1);
        expect(s.windowStartMs).toBe(at("2026-08-03T13:00:00.000Z"));
        expect(s.windowEndMs).toBe(at("2026-08-03T13:00:00.000Z"));
      });

  test("a window on a DST shift day keeps its wall clock", () => {
    // Mar 8 2026 springs forward at 02:00, so that Toronto day is 23 hours
    // long. A 9-to-5 crew still starts at 9 by the clock — computing the
    // window as midnight plus 540 ELAPSED minutes would land it at 10:00.
    const r = {
      startTime: at("2026-03-06T14:00:00.000Z"), // Mar 6 09:00 EST
      endTime: at("2026-03-10T21:00:00.000Z"), // Mar 10 17:00 EDT
    };
    const s = sliceForDay(r, at("2026-03-08T05:00:00.000Z"));
    expect(s.dayIndex).toBe(3);
    expect(s.windowStartMs).toBe(at("2026-03-08T13:00:00.000Z")); // 09:00 EDT
    expect(s.windowEndMs).toBe(at("2026-03-08T21:00:00.000Z")); // 17:00 EDT
  });

  test("calendarDaysBetween counts whole Toronto days", () => {
    expect(calendarDaysBetween(AUG1, AUG3)).toBe(2);
    expect(calendarDaysBetween(AUG3, AUG1)).toBe(-2);
    expect(calendarDaysBetween(dayJob.startTime, AUG1)).toBe(0);
  });
});

describe("clampedLastWorkDayMs", () => {
  // The clamped form for anything that RENDERS the run's tail. `lastWorkDayMs`
  // is deliberately raw and `sliceForDay`/`dayCountOf` clamp on the way out, so
  // the push text was the one day-scoping consumer printing a corrupt doc's
  // real end while the widget, Siri and the card all said "Day n of 14".
  const AUG14 = at("2026-08-14T04:00:00.000Z");

  test("an in-range run is unclamped and matches the raw last work day", () => {
    // The normal case must not be perturbed by the cap.
    expect(clampedLastWorkDayMs(dayJob)).toBe(at("2026-08-05T04:00:00.000Z"));
    expect(clampedLastWorkDayMs(dayJob)).toBe(lastWorkDayMs(dayJob));
  });

  test("an over-long run is clamped to the 14-day cap", () => {
    // Only the console and the Admin SDK can write this — `firestore.rules`
    // bounds client writes to the same cap.
    const corrupt = {
      startTime: at("2026-08-01T13:00:00.000Z"),
      endTime: at("2026-09-30T21:00:00.000Z"),
    };
    expect(lastWorkDayMs(corrupt)).toBe(at("2026-09-30T04:00:00.000Z"));
    expect(clampedLastWorkDayMs(corrupt)).toBe(AUG14);
  });

  test("the cap is start + (MAX - 1) days, so day 14 is the LAST day", () => {
    // The off-by-one that matters: `addDaysMs(startMs, MAX)` would allow a
    // 15th day, and the push text would then name a day the card's
    // "Day n of 14" counter cannot reach.
    const corrupt = {
      startTime: at("2026-08-01T13:00:00.000Z"),
      endTime: at("2026-09-30T21:00:00.000Z"),
    };
    const clamped = clampedLastWorkDayMs(corrupt);
    expect(calendarDaysBetween(corrupt.startTime, clamped) + 1)
        .toBe(MAX_APPOINTMENT_SPAN_DAYS);
    // And it agrees with the counter every other mirror renders.
    expect(sliceForDay(corrupt, AUG3).dayCount).toBe(MAX_APPOINTMENT_SPAN_DAYS);
  });

  test("a run exactly at the cap is returned untouched", () => {
    // 14 days inclusive is legal — the boundary must not be clipped to 13.
    const exact = {
      startTime: at("2026-08-01T13:00:00.000Z"),
      endTime: at("2026-08-14T21:00:00.000Z"),
    };
    expect(dayCountOf(exact)).toBe(MAX_APPOINTMENT_SPAN_DAYS);
    expect(clampedLastWorkDayMs(exact)).toBe(AUG14);
    expect(clampedLastWorkDayMs(exact)).toBe(lastWorkDayMs(exact));
  });

  test("an overnight run still ends on the last day work BEGINS", () => {
    // The clamp must not undo the night-shift rule: the end date names the
    // last day the crew starts, never the morning the run finishes.
    expect(clampedLastWorkDayMs(nightShift)).toBe(AUG3);
    expect(clampedLastWorkDayMs(nightShift)).toBe(lastWorkDayMs(nightShift));
  });

  test("a record with no usable start has no clamped last day", () => {
    // Callers render this into text, so a NaN or 0 here would print an epoch
    // date rather than omitting the tail.
    expect(clampedLastWorkDayMs({})).toBeNull();
    expect(clampedLastWorkDayMs({startTime: null})).toBeNull();
  });

  test("a record with no endTime collapses onto its own start day", () => {
    // Legacy/console docs exist without an end; treating it as overnight
    // would count the run backwards and drop the tail entirely.
    const noEnd = {startTime: at("2026-08-03T13:00:00.000Z")};
    expect(clampedLastWorkDayMs(noEnd)).toBe(AUG3);
  });
});

describe("stored run label", () => {
  // A multi-day JOB is N one-day documents sharing a seriesId; the stored pair
  // is the only thing that knows the run is longer than the document. Same
  // worked examples as the Dart `stored run label` group.
  const dayThreeOfFive = () => ({
    startTime: new Date("2026-08-05T13:00:00Z"), // 09:00 Toronto
    endTime: new Date("2026-08-05T21:00:00Z"), // 17:00 Toronto
    seriesId: "d1",
    dayIndex: 3,
    dayCount: 5,
  });
  const aug5 = new Date("2026-08-05T16:00:00Z").getTime();
  const aug6 = new Date("2026-08-06T16:00:00Z").getTime();

  test("a split day reports its stored position", () => {
    const slice = sliceForDay(dayThreeOfFive(), aug5);
    expect(slice.dayIndex).toBe(3);
    expect(slice.dayCount).toBe(5);
    expect(slice.isMultiDay).toBe(true);
  });

  test("the stored pair does NOT widen which days it runs on", () => {
    expect(sliceForDay(dayThreeOfFive(), aug6)).toBeNull();
  });

  test("the window stays this day only", () => {
    const slice = sliceForDay(dayThreeOfFive(), aug5);
    expect(slice.windowStartMs)
        .toBe(new Date("2026-08-05T13:00:00Z").getTime());
    expect(slice.windowEndMs).toBe(new Date("2026-08-05T21:00:00Z").getTime());
  });

  test("dayCountOf still reports the document's OWN length", () => {
    // travel_utils gates the Live Activity on this being 1, so a split day has
    // to read as a one-day job and get its own Lock Screen card.
    expect(dayCountOf(dayThreeOfFive())).toBe(1);
  });

  test("a legacy wide document still derives its pair", () => {
    const wide = {
      startTime: new Date("2026-08-03T13:00:00Z"),
      endTime: new Date("2026-08-07T21:00:00Z"),
    };
    const slice = sliceForDay(wide, aug5);
    expect(slice.dayIndex).toBe(3);
    expect(slice.dayCount).toBe(5);
  });

  test("an incoherent stored pair falls back to the derived one", () => {
    const broken = {...dayThreeOfFive(), dayIndex: 9};
    const slice = sliceForDay(broken, aug5);
    expect(slice.dayIndex).toBe(1);
    expect(slice.dayCount).toBe(1);
  });

  test("a stored pair on a WIDE document is ignored", () => {
    // Only a console write produces this. Honouring it would print the same
    // "Day 3 of 5" on all five days of the span.
    const wide = {
      startTime: new Date("2026-08-03T13:00:00Z"),
      endTime: new Date("2026-08-07T21:00:00Z"),
      dayIndex: 3,
      dayCount: 5,
    };
    const aug3 = new Date("2026-08-03T16:00:00Z").getTime();
    expect(sliceForDay(wide, aug3).dayIndex).toBe(1);
  });

  test("a count past the cap is ignored", () => {
    const overCap = {...dayThreeOfFive(), dayIndex: 1, dayCount: 40};
    expect(sliceForDay(overCap, aug5).dayCount).toBe(1);
  });
});

// The resolved daily window of a Toronto start/end pair given in UTC ISO form.
const win = (startIso, endIso) =>
  resolveWindow({startTime: at(startIso), endTime: at(endIso)});

describe("dailyWindowsOverlap", () => {
  test("a 9-5 week does not clash with a 7pm job inside it", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-01T13:00:00.000Z", "2026-08-05T21:00:00.000Z"),
        win("2026-08-03T23:00:00.000Z", "2026-08-04T00:00:00.000Z"),
    )).toBe(false);
  });

  test("the same week DOES clash with a midday job inside it", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-01T13:00:00.000Z", "2026-08-05T21:00:00.000Z"),
        win("2026-08-03T16:00:00.000Z", "2026-08-03T17:00:00.000Z"),
    )).toBe(true);
  });

  test("runs that share no day never clash", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-01T13:00:00.000Z", "2026-08-02T21:00:00.000Z"),
        win("2026-08-04T13:00:00.000Z", "2026-08-05T21:00:00.000Z"),
    )).toBe(false);
  });

  test("touching windows on a shared day do not clash", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-01T13:00:00.000Z", "2026-08-03T16:00:00.000Z"),
        win("2026-08-02T16:00:00.000Z", "2026-08-02T18:00:00.000Z"),
    )).toBe(false);
  });

  test("an overnight shift clashes with a job in its small hours", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-02T02:00:00.000Z", "2026-08-03T10:00:00.000Z"),
        win("2026-08-02T06:00:00.000Z", "2026-08-02T07:00:00.000Z"),
    )).toBe(true);
  });

  test("a corrupt window whose end precedes its start never clashes", () => {
    expect(dailyWindowsOverlap(
        win("2026-08-10T13:00:00.000Z", "2026-08-01T21:00:00.000Z"),
        win("2026-08-10T13:00:00.000Z", "2026-08-10T21:00:00.000Z"),
    )).toBe(false);
  });
});

describe("expandRunWindows", () => {
  test("a one-day window yields one pair unchanged", () => {
    const windows = expandRunWindows(
        win("2026-08-03T13:00:00.000Z", "2026-08-03T21:00:00.000Z"));
    expect(windows).toEqual([{
      startMs: at("2026-08-03T13:00:00.000Z"),
      endMs: at("2026-08-03T21:00:00.000Z"),
    }]);
  });

  test("a 5-day 9-to-5 window yields five one-day windows", () => {
    const windows = expandRunWindows(
        win("2026-08-03T13:00:00.000Z", "2026-08-07T21:00:00.000Z"));
    expect(windows).toHaveLength(5);
    expect(windows[0]).toEqual({
      startMs: at("2026-08-03T13:00:00.000Z"),
      endMs: at("2026-08-03T21:00:00.000Z"),
    });
    expect(windows[4]).toEqual({
      startMs: at("2026-08-07T13:00:00.000Z"),
      endMs: at("2026-08-07T21:00:00.000Z"),
    });
  });

  test("a night shift yields one window per NIGHT, ending the morning after",
      () => {
        const windows = expandRunWindows(
            win("2026-08-04T02:00:00.000Z", "2026-08-05T10:00:00.000Z"));
        expect(windows).toEqual([
          {
            startMs: at("2026-08-04T02:00:00.000Z"),
            endMs: at("2026-08-04T10:00:00.000Z"),
          },
          {
            startMs: at("2026-08-05T02:00:00.000Z"),
            endMs: at("2026-08-05T10:00:00.000Z"),
          },
        ]);
      });

  test("an all-day multi-day block yields a midnight-to-23:59 window a day",
      () => {
        const windows = expandRunWindows(
            win("2026-08-03T04:00:00.000Z", "2026-08-05T03:59:00.000Z"));
        expect(windows).toEqual([
          {
            startMs: at("2026-08-03T04:00:00.000Z"),
            endMs: at("2026-08-04T03:59:00.000Z"),
          },
          {
            startMs: at("2026-08-04T04:00:00.000Z"),
            endMs: at("2026-08-05T03:59:00.000Z"),
          },
        ]);
      });

  test("a span past the cap clamps to MAX_APPOINTMENT_SPAN_DAYS", () => {
    const windows = expandRunWindows(
        win("2026-08-03T13:00:00.000Z", "2027-03-12T22:00:00.000Z"));
    expect(windows).toHaveLength(MAX_APPOINTMENT_SPAN_DAYS);
  });

  test("a corrupt pair whose end precedes its start yields one window", () => {
    const windows = expandRunWindows(
        win("2026-08-07T13:00:00.000Z", "2026-08-03T21:00:00.000Z"));
    expect(windows).toHaveLength(1);
    expect(windows[0].startMs).toBe(at("2026-08-07T13:00:00.000Z"));
  });
});
