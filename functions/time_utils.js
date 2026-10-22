"use strict";

/**
 * @fileoverview Instant + Toronto-local formatting primitives shared by every
 * pure payload module. It deliberately requires nothing else, so it can sit
 * under `notification_utils` -> `live_activity_dispatch` ->
 * `live_activity_utils` without closing a require cycle.
 * @module time_utils
 */

/**
 * The one business time zone (Quebec) — every user-facing time renders here.
 */
const BUSINESS_TIME_ZONE = "America/Toronto";

/**
 * Hoisted because both take CONSTANT options and both sit in a hot loop:
 * `day_slice_utils.js` reaches them ~18 times per `sliceForDay`, and the widget
 * payload probes every record against every day.
 */
const YMD_FORMAT = new Intl.DateTimeFormat("en-CA", {
  timeZone: BUSINESS_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

const OFFSET_FORMAT = new Intl.DateTimeFormat("en-US", {
  timeZone: BUSINESS_TIME_ZONE,
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

/** The longest span a job may be booked for, in days. */
const MAX_APPOINTMENT_SPAN_DAYS = 14;

/** The same cap in milliseconds — the usual form for widening a query floor. */
const MAX_APPOINTMENT_SPAN_MS = MAX_APPOINTMENT_SPAN_DAYS * 24 * 60 * 60 * 1000;

/** A job in one of these is finished with, so it no longer occupies anyone. */
const TERMINAL_STATUSES = new Set(["done", "completed", "cancelled"]);

/**
 * Lower-cased status of a raw appointment field, or "".
 * @param {*} status Raw stored value.
 * @return {string}
 */
function normalizedStatus(status) {
  return String(status || "").toLowerCase();
}

/**
 * True when a status means the job is finished with, in either sense.
 * @param {*} status Raw stored value.
 * @return {boolean}
 */
function isTerminalStatus(status) {
  return TERMINAL_STATUSES.has(normalizedStatus(status));
}

/**
 * True when a status means the visit was called off.
 * @param {*} status Raw stored value.
 * @return {boolean}
 */
function isCancelledStatus(status) {
  return normalizedStatus(status) === "cancelled";
}

/**
 * True when a status means the job was seen through to the end.
 * @param {*} status Raw stored value.
 * @return {boolean}
 */
function isCompletedStatus(status) {
  return isTerminalStatus(status) && !isCancelledStatus(status);
}

/**
 * Minutes past business-local midnight for an instant, or null.
 * @param {*} value Timestamp/Date/number.
 * @return {?number}
 */
function businessMinutesOfDay(value) {
  const ms = toMillis(value);
  if (ms == null) return null;
  const local = ms + businessOffsetMs(new Date(ms));
  const dayMs = 24 * 60 * 60 * 1000;
  return Math.floor((((local % dayMs) + dayMs) % dayMs) / 60000);
}

/**
 * Milliseconds since epoch for a Firestore Timestamp / Date / number, else
 * null.
 * @param {*} value
 * @return {?number}
 */
function toMillis(value) {
  if (value == null) return null;
  if (typeof value.toMillis === "function") {
    const ms = value.toMillis();
    return typeof ms === "number" && Number.isFinite(ms) ? ms : null;
  }
  if (value instanceof Date) {
    const ms = value.getTime();
    return Number.isFinite(ms) ? ms : null;
  }
  // A DocumentSnapshot field read through some admin-SDK paths exposes
  // `toDate()` without `toMillis()`.
  if (typeof value.toDate === "function") {
    const d = value.toDate();
    const ms = d instanceof Date ? d.getTime() : NaN;
    return Number.isFinite(ms) ? ms : null;
  }
  // Finite-checked so NaN/Infinity degrade to "" like every other bad input
  // here, instead of throwing RangeError out of Intl/new Date() and taking down
  // a notification build in a best-effort consumer.
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  return null;
}

/**
 * True when an appointment still has work left at `nowMs` — NOT "does it start
 * in the future".
 * @param {*} record Appointment data; null/undefined reads as no work left.
 * @param {number} nowMs Reference instant, ms since epoch.
 * @return {boolean}
 */
function hasWorkLeft(record, nowMs) {
  if (!record) return false;
  const ms = toMillis(record.endTime) ?? toMillis(record.startTime);
  return ms != null && ms >= nowMs;
}

/**
 * Formats an instant in the business time zone, or "" when it isn't one.
 * @param {string} locale 'en' | 'fr'.
 * @param {*} value Timestamp/Date/number.
 * @param {!Object} opts Intl.DateTimeFormat options (time zone is added).
 * @return {string}
 */
function formatBusinessTime(locale, value, opts) {
  const ms = toMillis(value);
  if (ms == null) return "";
  return new Intl.DateTimeFormat(locale === "fr" ? "fr-CA" : "en-CA", {
    timeZone: BUSINESS_TIME_ZONE,
    ...opts,
  }).format(new Date(ms));
}

/**
 * Localized time of day ("7:54"), the one form the card and the push must agree
 * on.
 * @param {string} locale 'en' | 'fr'.
 * @param {*} value
 * @return {string}
 */
function formatTimeOfDay(locale, value) {
  return formatBusinessTime(locale, value, {
    hour: "numeric",
    minute: "2-digit",
  });
}

/**
 * The business-local year/month/day of an instant, as numbers.
 * @param {!Date} date
 * @return {!Array<number>} `[year, month, day]` (month is 1-based).
 */
function businessYmd(date) {
  return YMD_FORMAT
      .format(date)
      .split("-")
      .map(Number);
}

/**
 * Business-zone UTC offset (ms to add to a UTC instant to get local wall time)
 * at `date`.
 * @param {!Date} date
 * @return {number}
 */
function businessOffsetMs(date) {
  const parts = OFFSET_FORMAT.formatToParts(date).reduce((acc, p) => {
    acc[p.type] = p.value;
    return acc;
  }, {});
  const asUtc = Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
      Number(parts.second),
  );
  return asUtc - date.getTime();
}

/**
 * Business-local midnight of a calendar date as a UTC Date.
 * @param {number} year
 * @param {number} month 1-based.
 * @param {number} day May overflow (day + 1 rolls the month).
 * @return {!Date}
 */
function businessMidnight(year, month, day) {
  const guess = Date.UTC(year, month - 1, day, 0, 0, 0);
  return new Date(guess - businessOffsetMs(new Date(guess)));
}

/**
 * Business-local midnight `offsetDays` days from the day containing `instant`,
 * as epoch ms.
 * @param {(Date|number)} instant Any instant inside the reference day.
 * @param {number} [offsetDays] Whole days to move; defaults to 0.
 * @return {number} Epoch ms of that Toronto midnight.
 */
function businessDayStartMs(instant, offsetDays = 0) {
  const date = instant instanceof Date ? instant : new Date(Number(instant));
  const [y, m, d] = businessYmd(date);
  return businessMidnight(y, m, d + offsetDays).getTime();
}

/**
 * Epoch ms for a `now` that may be a Date, a number or a Firestore Timestamp.
 * @param {(Date|number|Object)} now
 * @return {number}
 */
function nowMillis(now) {
  return toMillis(now) ?? NaN;
}

/**
 * Converts Firestore values to JSON values the Flutter callable SDK can parse.
 * @param {*} value Raw Firestore/Admin SDK value.
 * @return {*}
 */
function serializeValue(value) {
  if (value == null) return value;
  if (typeof value.toMillis === "function") {
    return {millisecondsSinceEpoch: value.toMillis()};
  }
  if (value instanceof Date) {
    return {millisecondsSinceEpoch: value.getTime()};
  }
  if (Array.isArray(value)) return value.map(serializeValue);
  if (typeof value === "object") {
    return Object.fromEntries(
        Object.entries(value).map(([k, v]) => [k, serializeValue(v)]),
    );
  }
  return value;
}

module.exports = {
  BUSINESS_TIME_ZONE,
  MAX_APPOINTMENT_SPAN_DAYS,
  MAX_APPOINTMENT_SPAN_MS,
  TERMINAL_STATUSES,
  normalizedStatus,
  isTerminalStatus,
  isCancelledStatus,
  isCompletedStatus,
  businessMinutesOfDay,
  toMillis,
  nowMillis,
  hasWorkLeft,
  formatBusinessTime,
  formatTimeOfDay,
  businessYmd,
  businessOffsetMs,
  businessMidnight,
  businessDayStartMs,
  serializeValue,
};
