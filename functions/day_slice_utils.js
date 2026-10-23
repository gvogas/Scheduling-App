"use strict";

/**
 * @fileoverview Server-side mirror of the Dart day-slice rule
 * (`lib/features/calendar/domain/appointment_day_slice.dart`). An appointment's
 * two stored times describe a DAILY WINDOW — 9:00-17:00 means 9-to-5 on each
 * day of the run, not one unbroken stretch through the nights.
 *
 * Keep this and the Dart original in lockstep: the jest cases in
 * `__tests__/day_slice_utils.test.js` use the same worked examples as the Dart
 * tests, so a divergence fails rather than ships.
 *
 * Day boundaries use `America/Toronto` (`BUSINESS_TIME_ZONE`) like every other
 * server-side day computation, so this and `widget_payload_utils` agree.
 *
 * @module day_slice_utils
 */

const {
  MAX_APPOINTMENT_SPAN_DAYS,
  toMillis,
  businessYmd,
  businessMinutesOfDay,
  businessDayStartMs,
  businessOffsetMs,
} = require("./time_utils");

/**
 * Toronto midnight of the day containing an instant, as epoch ms.
 * @param {number} msValue
 * @return {number}
 */
function dayStartMs(msValue) {
  return businessDayStartMs(msValue, 0);
}

/**
 * Toronto midnight `n` days from the day containing an instant, as epoch ms.
 * @param {number} msValue
 * @param {number} n
 * @return {number}
 */
function addDaysMs(msValue, n) {
  return businessDayStartMs(msValue, n);
}

/**
 * The instant at `minutes` past midnight, Toronto WALL CLOCK, on the day
 * containing `dayMs`.
 *
 * Deliberately not `dayStartMs(dayMs) + minutes * 60000`: on the two DST shift
 * days an hour is skipped or repeated, so adding elapsed minutes to midnight
 * lands an hour off the wall clock. The crew works 9-to-5 by the clock, not by
 * elapsed hours — which is also what the Dart original's
 * `DateTime(y, m, d, hour, minute)` produces.
 * @param {number} dayMs Any instant inside the target Toronto day.
 * @param {number} minutes Minutes past local midnight; may exceed a day.
 * @return {number}
 */
function businessWallInstantMs(dayMs, minutes) {
  const [y, m, d] = businessYmd(new Date(dayMs));
  const guess = Date.UTC(y, m - 1, d, 0, minutes);
  // Re-read the offset AT the first answer: the guess sits 4-5 h early, so
  // between it and the target a DST switch picks the wrong offset.
  const first = guess - businessOffsetMs(new Date(guess));
  return guess - businessOffsetMs(new Date(first));
}

/**
 * Whole calendar days between two instants' Toronto days.
 * @param {number} fromMs
 * @param {number} toMs
 * @return {number}
 */
function calendarDaysBetween(fromMs, toMs) {
  const [fy, fm, fd] = businessYmd(new Date(fromMs));
  const [ty, tm, td] = businessYmd(new Date(toMs));
  return Math.round(
      (Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86400000);
}

/**
 * The record's daily window resolved to plain numbers, or null when it carries
 * no usable start.
 *
 * Equal start/end times count as OVERNIGHT: a booking at the same clock time on
 * consecutive days is a run of continuous 24-hour windows, and a strict `<`
 * would collapse each of them to zero length.
 *
 * A record with **no** `endTime` is a different case and must not take that
 * branch. Legacy and console-written docs exist without one, and the Dart model
 * never emits it as null, so the server is the only side that sees it. It is
 * treated as a single-day job whose window collapses onto its start — the same
 * fallback `hasWorkLeft` uses. Reading it as overnight instead would count the
 * run backwards to zero days and drop the job out of every mirror silently.
 * @param {!Object} r
 * @return {?{startMs: number, endMs: number, overnight: boolean}}
 */
function resolveWindow(r) {
  const startMs = toMillis(r.startTime);
  if (startMs == null) return null;
  const endMs = toMillis(r.endTime);
  if (endMs == null) return {startMs, endMs: startMs, overnight: false};
  return {
    startMs,
    endMs,
    overnight: businessMinutesOfDay(endMs) <= businessMinutesOfDay(startMs),
  };
}

/**
 * The window-taking forms. Every public helper below resolves the window ONCE
 * and threads it down: `resolveWindow` runs `businessMinutesOfDay` twice and
 * each of those formats through `Intl`, so the old record-taking chain
 * (`sliceForDay` → `dayCountOf` → `lastWorkDayMs`) resolved the same window
 * three times per probe. Keep new internals on this form.
 * @param {!{startMs: number, endMs: number, overnight: boolean}} w
 * @return {number}
 */
function lastWorkDayOfWindow(w) {
  return w.overnight ? addDaysMs(w.endMs, -1) : dayStartMs(w.endMs);
}

/**
 * @param {?{startMs: number, endMs: number, overnight: boolean}} w
 * @return {number}
 */
function dayCountOfWindow(w) {
  if (w == null) return 0;
  return calendarDaysBetween(w.startMs, lastWorkDayOfWindow(w)) + 1;
}

/**
 * Toronto midnight of the last day the crew STARTS work — never the morning an
 * overnight run finishes.
 * @param {!Object} r
 * @return {?number}
 */
function lastWorkDayMs(r) {
  const w = resolveWindow(r);
  if (w == null) return null;
  return lastWorkDayOfWindow(w);
}

/**
 * How many days (or nights) the record runs, UNCLAMPED. Can come back below 1
 * on a corrupt record whose end precedes its start — callers must guard.
 * @param {!Object} r
 * @return {number}
 */
function dayCountOf(r) {
  return dayCountOfWindow(resolveWindow(r));
}

/**
 * `lastWorkDayMs`, clamped to `MAX_APPOINTMENT_SPAN_DAYS` from the start day.
 *
 * The clamped form for anything that RENDERS the run's tail. `lastWorkDayMs`
 * is deliberately raw, and `sliceForDay`/`dayCountOf` clamp on the way out — so
 * the push text was the one day-scoping consumer reading a corrupt doc's real
 * end, printing "Wed, Aug 1, 9:00 a.m. – Sun, Mar 12 2028" while the widget
 * counter, the Siri snapshot and the card all said "Day n of 14". Only the
 * console and the Admin SDK can write such a doc, since `firestore.rules`
 * bounds client writes to the same cap.
 * @param {!Object} r
 * @return {?number}
 */
function clampedLastWorkDayMs(r) {
  const w = resolveWindow(r);
  if (w == null) return null;
  const last = lastWorkDayOfWindow(w);
  const cap = addDaysMs(w.startMs, MAX_APPOINTMENT_SPAN_DAYS - 1);
  return last > cap ? cap : last;
}

/**
 * The run position a SPLIT day carries on the document itself, or null when the
 * derived pair should be used instead.
 *
 * A multi-day JOB is N documents of one day each, sharing a `seriesId`; the
 * stored pair is the only thing that knows the run is longer than the document.
 * A legacy WIDE document stores nothing and is derived as it always was.
 *
 * Hand-mirror of `_storedRunLabel` in
 * `lib/features/calendar/domain/appointment_day_slice.dart` — change both
 * together; the jest cases reuse that suite's worked examples, so a divergence
 * fails rather than ships.
 *
 * **This is the LABEL only.** The index/range test in `sliceForDay` stays
 * derived: reading a stored `dayCount: 5` into it would make one document claim
 * to run on the five days after its own start, and `buildWidgetPayload` probes
 * every record against every day of its window.
 *
 * @param {!Object} r
 * @param {!{startMs: number, endMs: number, overnight: boolean}} w The
 *   already-resolved window, threaded in rather than re-resolved — see the
 *   window-taking rule above.
 * @return {?{dayIndex: number, dayCount: number}}
 */
function storedRunLabel(r, w) {
  const index = Number(r.dayIndex);
  const count = Number(r.dayCount);
  if (!Number.isInteger(index) || !Number.isInteger(count)) return null;
  if (count < 2 || count > MAX_APPOINTMENT_SPAN_DAYS) return null;
  if (index < 1 || index > count) return null;
  // A wide document is a legacy or console-written run whose SPAN is the truth;
  // honouring a stored pair there prints one day's label on all of them.
  if (dayCountOfWindow(w) !== 1) return null;
  return {dayIndex: index, dayCount: count};
}

/**
 * The record as it appears on the Toronto day containing `dayMs`, or null when
 * it doesn't run that day.
 *
 * Slices are generated per WORK day — each day the window BEGINS — not per
 * calendar day the stored span touches. That is what keeps a night shift off
 * the morning it ends.
 *
 * The count is clamped to `MAX_APPOINTMENT_SPAN_DAYS` like every day-scoping
 * answer on the Dart side. `firestore.rules` bounds client writes to the same
 * cap, but the console and the Admin SDK bypass rules, so a doc can still
 * exceed it; left unclamped this would report "Day 400 of 900" on a corrupt
 * record.
 * @param {!Object} r
 * @param {number} dayMs Any instant inside the target Toronto day.
 * @return {?{dayIndex: number, dayCount: number, windowStartMs: number,
 *   windowEndMs: number, isOvernight: boolean, isMultiDay: boolean,
 *   record: !Object}}
 */
function sliceForDay(r, dayMs) {
  const w = resolveWindow(r);
  if (w == null) return null;
  const rawCount = dayCountOfWindow(w);
  if (rawCount < 1) return null;
  const count = Math.min(rawCount, MAX_APPOINTMENT_SPAN_DAYS);
  const index = calendarDaysBetween(w.startMs, dayMs) + 1;
  if (index < 1 || index > count) return null;
  // Substituted AFTER the range test above, never into it.
  const label = storedRunLabel(r, w) || {dayIndex: index, dayCount: count};

  return {
    record: r,
    dayIndex: label.dayIndex,
    dayCount: label.dayCount,
    windowStartMs: businessWallInstantMs(
        dayMs, businessMinutesOfDay(w.startMs)),
    windowEndMs: businessWallInstantMs(
        w.overnight ? addDaysMs(dayMs, 1) : dayMs,
        businessMinutesOfDay(w.endMs)),
    isOvernight: w.overnight,
    isMultiDay: label.dayCount > 1,
  };
}

/**
 * The concrete local-time windows a run occupies, one per work day.
 *
 * Mirrors the Dart `expandRunWindows`: the windows a run is BOOKED with and
 * the windows it is CHECKED against for clashes must be the same arithmetic.
 * @param {!{startMs: number, endMs: number, overnight: boolean}} w
 * @return {!Array<!{startMs: number, endMs: number}>}
 */
function expandRunWindows(w) {
  const count = Math.min(dayCountOfWindow(w), MAX_APPOINTMENT_SPAN_DAYS);
  const days = count < 1 ? 1 : count;
  const startMinutes = businessMinutesOfDay(w.startMs);
  const endMinutes = businessMinutesOfDay(w.endMs);
  const out = [];
  for (let i = 0; i < days; i++) {
    const dayMs = addDaysMs(w.startMs, i);
    out.push({
      startMs: businessWallInstantMs(dayMs, startMinutes),
      endMs: businessWallInstantMs(
          w.overnight ? addDaysMs(dayMs, 1) : dayMs, endMinutes),
    });
  }
  return out;
}

/**
 * True when two daily windows overlap on any day they both run.
 *
 * A conflict check is a DAILY-window overlap, not an instant overlap: testing
 * the raw instants reports a 9-5 run across a week as clashing with a 7 pm job
 * inside it. All window pairs are compared rather than matching day indices,
 * because an overnight window runs into the following calendar day.
 * @param {?{startMs: number, endMs: number, overnight: boolean}} a
 * @param {?{startMs: number, endMs: number, overnight: boolean}} b
 * @return {boolean}
 */
function dailyWindowsOverlap(a, b) {
  if (a == null || b == null) return false;
  const aWindows = dayCountOfWindow(a) < 1 ? [] : expandRunWindows(a);
  const bWindows = dayCountOfWindow(b) < 1 ? [] : expandRunWindows(b);
  return aWindows.some((x) =>
    bWindows.some((y) => x.startMs < y.endMs && y.startMs < x.endMs));
}

module.exports = {
  // Re-exported rather than restated: `time_utils` already owns the JS copy of
  // the Dart `maxAppointmentSpanDays`, and a second copy here would be a third
  // owner of a constant this module exists to keep in lockstep.
  MAX_APPOINTMENT_SPAN_DAYS,
  calendarDaysBetween,
  resolveWindow,
  expandRunWindows,
  dailyWindowsOverlap,
  lastWorkDayMs,
  clampedLastWorkDayMs,
  dayCountOf,
  sliceForDay,
};
