"use strict";

/**
 * @fileoverview Server-side mirror of the Flutter widget payload builder
 * (`lib/features/home_widget/application/widget_sync_service.dart`). A
 * change-driven push carries the fresh payload so the iOS home-screen widget
 * can rewrite itself from a background isolate even with the app closed.
 * It's kept pure and dependency-free so jest can load it directly, and its
 * JSON shape stays in lockstep with the Dart builder and the Swift decoder
 * (`ios/ScheduleWidget/ScheduleWidget.swift`).
 *
 * Day boundaries use America/Toronto (`BUSINESS_TIME_ZONE`), so a
 * Toronto-based device computes the same local midnight and server- and
 * app-written payloads agree.
 *
 * @module widget_payload_utils
 */

const {
  nowMillis,
  businessDayStartMs,
  isTerminalStatus,
  isCancelledStatus,
} = require("./time_utils");
const {sliceForDay} = require("./day_slice_utils");

// The terminal/cancelled vocabulary comes from `time_utils`' one owner and is
// NOT re-exported from here — importing it from this module would make the
// widget path look like a second owner of a set that had already drifted in
// two of its four former copies. Require it from `time_utils` directly.

// How many days past today the "next job" lookahead spans, for the query the
// push path builds. Its FLOOR reaches MAX_APPOINTMENT_SPAN_MS behind today
// (see fetchEmployeeWidgetWindow) so a job that started earlier and is still
// running today is fetched; this constant is the forward half alone. The Dart
// mirrors deliberately read a WIDER window (AppointmentDateRange.forMirrors,
// 8 days, shared by the widget and the Siri snapshot so they can't fork a
// second listener); both builders re-scope to today/tomorrow, so the two
// windows are allowed to differ.
const WIDGET_LOOKAHEAD_DAYS = 3;


/**
 * Start of the current Toronto day (00:00) as an epoch-ms UTC instant.
 * @param {(Date|number)} now
 * @return {number}
 */
function torontoDayStartMs(now) {
  return torontoDayStartOffsetMs(now, 0);
}

/**
 * Serializes one day-slice into the widget's job JSON, mirroring `_job` in
 * widget_sync_service.dart. `startTime` is THIS day's window start (not the
 * run's first morning) as an absolute UTC instant with milliseconds so Swift's
 * ISO8601DateFormatter can parse it, and every other field must be a plain
 * non-null string or the Swift decode fails. `dayIndex`/`dayCount` are omitted
 * for a single-day job — Swift reads them as `Int?`, so a payload without them
 * still decodes.
 * @param {!Object} slice A slice from `day_slice_utils.sliceForDay`.
 * @return {!Object}
 */
function serializeWidgetJob(slice) {
  const r = slice.record;
  const job = {
    id: String(r.id == null ? "" : r.id),
    startTime: new Date(slice.windowStartMs).toISOString(),
    endTime: new Date(slice.windowEndMs).toISOString(),
    clientName: String(r.clientName == null ? "" : r.clientName),
    title: String(r.title == null ? "" : r.title),
    address: String(r.address == null ? "" : r.address),
    status: String(r.status == null ? "pending" : r.status),
    // The widget speaks "All day" instead of the stored midnight–23:59 pair.
    isAllDay: r.isAllDay === true,
  };
  if (slice.isMultiDay) {
    job.dayIndex = slice.dayIndex;
    job.dayCount = slice.dayCount;
  }
  return job;
}

/**
 * Start of the Toronto day `n` days from `now` (n=0 today, 1 tomorrow, ...) as
 * an epoch-ms UTC instant.
 * @param {(Date|number)} now
 * @param {number} n
 * @return {number}
 */
function torontoDayStartOffsetMs(now, n) {
  return businessDayStartMs(now, n);
}

// How long after the last job of the day is finished the widget keeps showing
// today before rolling forward to tomorrow (mirrors widgetRolloverGrace in
// widget_sync_service.dart).
const ROLLOVER_GRACE_MS = 60 * 60 * 1000;

/**
 * Builds the widget payload for one employee. It carries both days plus a
 * `rolloverAt` instant so the WidgetKit timeline can flip from today to
 * tomorrow on-device with no app run or push — set once today has no
 * incomplete job left, else null. This is a pure mirror of
 * `buildWidgetPayload` (widget_sync_service.dart) — keep it and the Swift
 * decoder in lockstep.
 * @param {!Array<!Object>} records The employee's appointments in the lookahead
 *   window.
 * @param {(Date|number)} now
 * @param {string=} locale 'en' | 'fr'.
 * @return {!Object}
 */
function buildWidgetPayload(records, now, locale) {
  const loc = locale === "fr" ? "fr" : "en";
  const nowMs = nowMillis(now);
  const startTodayMs = torontoDayStartOffsetMs(now, 0);
  const startTomorrowMs = torontoDayStartOffsetMs(now, 1);
  // A job is "on" a day when it WORKS that day — not when its stored startTime
  // happens to fall in it. Without this a run that began yesterday is invisible
  // today, which is the whole point of multi-day support.
  const slicesOn = (dayMs) => (records || [])
      .map((r) => sliceForDay(r, dayMs))
      .filter((s) => s != null);
  const sortByWindow = (a, b) => a.windowStartMs - b.windowStartMs;

  const todayAll = slicesOn(startTodayMs);
  const todayIncomplete =
      todayAll.filter((s) => !isTerminalStatus(s.record.status));
  // "Still ahead of you today", judged against THIS day's window. An all-day
  // block starts at midnight, so a start test would drop it the moment the day
  // began — it stays listed until its 23:59 end passes.
  const stillAhead = (s) => s.record.isAllDay === true ?
      s.windowEndMs > nowMs : s.windowStartMs > nowMs;
  const todayJobs = todayIncomplete
      .filter(stillAhead)
      .sort(sortByWindow);
  const tomorrowJobs = slicesOn(startTomorrowMs)
      .filter((s) => !isTerminalStatus(s.record.status))
      .sort(sortByWindow);

  let rolloverMs = null;
  if (todayIncomplete.length === 0) {
    const finished =
        todayAll.filter((s) => !isCancelledStatus(s.record.status));
    if (finished.length === 0) {
      rolloverMs = startTodayMs;
    } else {
      // TODAY's window end, not the record's — a run rolls the widget over at
      // the end of today's work, not at the end of the whole run.
      const lastEnd = finished.reduce(
          (mx, s) => (s.windowEndMs > mx ? s.windowEndMs : mx), -Infinity);
      rolloverMs = lastEnd === -Infinity ?
        startTodayMs : lastEnd + ROLLOVER_GRACE_MS;
    }
  }

  const iso = (ms) => new Date(ms).toISOString();
  return {
    locale: loc,
    generatedAt: iso(nowMs),
    todayDate: iso(startTodayMs),
    tomorrowDate: iso(startTomorrowMs),
    rolloverAt: rolloverMs == null ? null : iso(rolloverMs),
    todayJobs: todayJobs.map(serializeWidgetJob),
    tomorrowJobs: tomorrowJobs.map(serializeWidgetJob),
  };
}

module.exports = {
  WIDGET_LOOKAHEAD_DAYS,
  torontoDayStartMs,
  serializeWidgetJob,
  buildWidgetPayload,
};
