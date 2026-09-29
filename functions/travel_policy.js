"use strict";

/**
 * @fileoverview Pure travel-reminder decisions (origin choice, candidate
 * filter, lead time, due check, Routes request/response shapes) and their
 * tuning constants, split out of travel_utils.js so they are testable with
 * no I/O, mirroring notification_policy.js.
 *
 * @module travel_policy
 */

const {
  toMillis,
  nowMillis,
  isTerminalStatus,
  isCancelledStatus,
} = require("./time_utils");

const MINUTE_MS = 60 * 1000;

// Extra lead on top of the computed drive time.
const BUFFER_MINUTES = 10;

// Lead cap; a >80-min drive fires at the first sweep inside the 90-min
// window (accepted).
const MAX_LEAD_MINUTES = 90;

// Lead when no origin / no address / Routes failed — matches the push plan's
// original fixed reminder.
const FALLBACK_LEAD_MINUTES = 30;

// A presence doc older than this means tracking died (force-quit, permission
// revoked); fall back to the address chain.
const PRESENCE_STALE_MINUTES = 25;

// How far back a previous appointment's address still counts as "where the
// employee just was".
const PREV_APPOINTMENT_LOOKBACK_HOURS = 4;

// Caps the per-employee context read. Ordered by endTime ASC, so the cap
// keeps the earliest-ending jobs decideOrigin actually needs, instead of
// every future appointment in a pre-booked series.
const CONTEXT_QUERY_MAX = 50;

// Longest single-day visit. The context query's upper bound has to clear the
// travel window plus one full visit, or a long intervening job drops out of
// decideOrigin.
//
// Deliberately NOT widened to MAX_APPOINTMENT_SPAN_MS (tried and reverted
// 2026-08-04). Widening it does pull a multi-day run into the context — but
// `decideOrigin`'s intervening prong tests the RAW instants
// (`startMs < candidateStartMs && endMs > nowMs`), which a 10-day run
// satisfies at every hour of every one of its days. A tech with an 08:00
// one-off during an Aug 1-10 run then departs "from" that run's address at
// 07:00, when they are at home and its window doesn't open until 09:00 —
// a NEW wrong origin, traded for an old missing one.
// Scoping that prong needs the daily-window model, which Plan 2 has since
// mirrored into JS (`./day_slice_utils`, 2026-08-10) — so the blocker is now
// that nobody has applied it here, not that the mirror is missing. Until then
// a long run stays out of the context, exactly as before multi-day booking
// existed — a known gap, not a regression.
const MAX_BOOKING_MS = 24 * 60 * MINUTE_MS;

// Sweep candidate window: MAX_LEAD_MINUTES ahead, so the longest computable
// lead is already in range when it becomes due.
const TRAVEL_WINDOW_MS = MAX_LEAD_MINUTES * MINUTE_MS;

// Caps the candidate read, mirroring OVERDUE_SWEEP_MAX on the sweep that runs
// beside this one. The 90-minute window keeps this small in practice, so the
// cap is a tail guard, not a steady-state bound: a bulk import or a wide
// series landing in one window is otherwise an unbounded fan-out that then
// makes a BILLABLE Routes call per candidate assignee. Ordered `startTime`
// ASC — which is the order Firestore already returns for this query, since it
// is the inequality field — so the cap keeps the most imminent departures,
// i.e. the ones that would be wrong to defer. A deferred candidate self-heals
// on the next 5-minute run; its ledger claim is what keeps that from
// double-sending.
const TRAVEL_SWEEP_MAX = 500;

// A recent cached estimate lets a clearly-not-due pair skip the metered
// Routes call. This can only DEFER a send, never trigger one — the fire
// decision always uses a fresh Routes response.
const ESTIMATE_TTL_MS = 10 * MINUTE_MS;
const SKIP_MARGIN_MS = 15 * MINUTE_MS;

// On-site flips run at once. Sized like `PRUNE_CHUNK` in
// `live_activity_registry.js`, against the same `PRUNE_MAX` (400) ceiling on
// the marker list — each flip is a read + a token query + an APNs push, so
// the flat fan-out this replaced was the heaviest one in the push stack.
const ON_SITE_FLIP_CHUNK = 25;

/**
 * Drops every expired entry. Read-triggered eviction alone can't reclaim a
 * pair that stopped being swept, so the sweep also prunes the whole map
 * once per run to keep the warm instance bounded.
 * @param {!Map} cache
 * @param {number} nowMs
 * @return {void}
 */
function pruneEstimates(cache, nowMs) {
  for (const [key, hit] of cache) {
    if (nowMs - hit.atMs > ESTIMATE_TTL_MS) cache.delete(key);
  }
}

/**
 * Cached drive-time estimate for a (candidate, employee) pair, or null when
 * absent/stale; expired entries are dropped on read so the map self-prunes.
 * @param {!Map} cache
 * @param {string} key
 * @param {number} nowMs
 * @return {?number} seconds, or null.
 */
function readEstimate(cache, key, nowMs) {
  const hit = cache.get(key);
  if (!hit) return null;
  if (nowMs - hit.atMs > ESTIMATE_TTL_MS) {
    cache.delete(key);
    return null;
  }
  return hit.seconds;
}

/**
 * True when a cached estimate conservatively (by SKIP_MARGIN_MS) proves the
 * pair cannot be due yet, so the Routes call can be skipped this sweep.
 * @param {{seconds: ?number, startTimeMillis: number, nowMillis: number}} args
 * @return {boolean}
 */
function canDeferRoutes({seconds, startTimeMillis, nowMillis}) {
  if (seconds == null) return false;
  const leadMs = computeLeadMinutes(seconds) * MINUTE_MS;
  return nowMillis < startTimeMillis - leadMs - SKIP_MARGIN_MS;
}

// Statuses that still expect the visit to happen. `confirmed` is the
// retired legacy alias, kept so pre-retirement docs still earn reminders.
const PENDING_LIKE = new Set(["pending", "confirmed"]);

// Same allowlist as an array for the candidate query's `where("status", "in",
// ...)`; deliberately narrower than notification_utils' OPEN_STATUSES since
// `in_progress` has no "time to leave" left to remind about.
const PENDING_STATUSES = [...PENDING_LIKE];

// "No longer occupies the employee" comes from `time_utils`' one owner — see
// isTerminalStatus. This module used to carry its own copy of the set.

/**
 * Trimmed address or "".
 * @param {*} record
 * @return {string}
 */
function _address(record) {
  return String((record && record.address) || "").trim();
}

/**
 * Decides where the employee will depart from. Pure — unit-testable.
 *
 * @param {{presence: ?Object, employeeAppointments: !Array<!Object>,
 *   candidate: !Object, now: (Date|number)}} args `presence` is the
 *   `users/{docId}/presence/location` doc data (or null);
 *   `employeeAppointments` is this employee's context-query result (endTime
 *   within the lookback or in the future).
 * @return {?{kind: string, lat: (number|undefined), lng: (number|undefined),
 *   address: (string|undefined)}} `{kind:'gps'}` | `{kind:'address'}` | null.
 */
function decideOrigin({presence, employeeAppointments, candidate, now}) {
  const nowMs = nowMillis(now);
  const candidateStartMs = toMillis(candidate && candidate.startTime);
  const apps = employeeAppointments || [];

  // Intervening appointment — they'll depart from THAT job's address, not
  // from wherever they are now. Marking it done promotes GPS below.
  let intervening = null;
  for (const r of apps) {
    if (candidate && r.id === candidate.id) continue;
    if (isTerminalStatus(r.status)) continue;
    const startMs = toMillis(r.startTime);
    const endMs = toMillis(r.endTime);
    if (startMs == null || endMs == null) continue;
    if (candidateStartMs != null && startMs >= candidateStartMs) continue;
    if (endMs <= nowMs) continue;
    if (_address(r) === "") continue;
    // Latest-starting current job wins (the one they're actually at).
    if (!intervening || startMs > toMillis(intervening.startTime)) {
      intervening = r;
    }
  }
  if (intervening) return {kind: "address", address: _address(intervening)};

  // Fresh background-GPS fix.
  if (presence) {
    const updatedMs = toMillis(presence.updatedAt);
    const lat = presence.lat;
    const lng = presence.lng;
    const fresh = updatedMs != null &&
        nowMs - updatedMs <= PRESENCE_STALE_MINUTES * MINUTE_MS;
    if (fresh && typeof lat === "number" && typeof lng === "number") {
      return {kind: "gps", lat, lng};
    }
  }

  // Recently-ended previous appointment, any status except cancelled since
  // a cancelled visit never happened. Newest endTime wins.
  let previous = null;
  const floorMs = nowMs - PREV_APPOINTMENT_LOOKBACK_HOURS * 60 * MINUTE_MS;
  for (const r of apps) {
    if (candidate && r.id === candidate.id) continue;
    if (isCancelledStatus(r.status)) continue;
    const endMs = toMillis(r.endTime);
    if (endMs == null || endMs > nowMs || endMs <= floorMs) continue;
    if (_address(r) === "") continue;
    if (!previous || endMs > toMillis(previous.endTime)) previous = r;
  }
  if (previous) return {kind: "address", address: _address(previous)};

  return null;
}

/**
 * Filters appointment records to travel-reminder candidates: pending-like and
 * starting within (now, now + TRAVEL_WINDOW_MS]. `in_progress` is excluded
 * (visit already started). Pure — unit-testable.
 *
 * All-day blocks are skipped: they store a real midnight start, so the sweep
 * would fire a "time to leave" push around 23:30 the night before for a block
 * that has no departure time at all. A *timed* personal job keeps its reminder
 * — that one is genuinely useful. Same class of skip as `isPersonal` in
 * `selectOverdueCandidates` (notification_utils.js).
 * @param {!Array<!Object>} records
 * @param {(Date|number)} now
 * @return {!Array<!Object>}
 */
function selectTravelCandidates(records, now) {
  const nowMs = nowMillis(now);
  const cutoff = nowMs + TRAVEL_WINDOW_MS;
  return (records || []).filter((r) => {
    if (!PENDING_LIKE.has(String(r.status || "").toLowerCase())) return false;
    if (r.isAllDay === true) return false;
    const ms = toMillis(r.startTime);
    return ms != null && ms > nowMs && ms <= cutoff;
  });
}

/**
 * Lead minutes for a computed drive time; the fixed fallback when null.
 * Pure — unit-testable.
 * @param {?number} travelSeconds
 * @return {number}
 */
function computeLeadMinutes(travelSeconds) {
  if (travelSeconds == null || !isFinite(travelSeconds) ||
      travelSeconds < 0) {
    return FALLBACK_LEAD_MINUTES;
  }
  return Math.min(
      Math.ceil(travelSeconds / 60) + BUFFER_MINUTES,
      MAX_LEAD_MINUTES,
  );
}

/**
 * True once `now` has reached the leave-now instant. Pure — unit-testable.
 * @param {{startTimeMillis: number, leadMinutes: number, nowMillis: number}}
 *   args
 * @return {boolean}
 */
function isDue(args) {
  return args.nowMillis >= args.startTimeMillis -
      args.leadMinutes * MINUTE_MS;
}

/**
 * Routes API computeRoutes request body — Routes accepts raw address strings
 * as waypoints, so no geocoding is needed. Pure — unit-testable.
 * @param {{origin: !Object, destinationAddress: string,
 *   departureTimeIso: string}} args
 * @return {!Object}
 */
function buildRoutesRequestBody({origin, destinationAddress,
  departureTimeIso}) {
  const originWaypoint = origin.kind === "gps" ?
      {location: {latLng: {latitude: origin.lat, longitude: origin.lng}}} :
      {address: origin.address};
  return {
    origin: originWaypoint,
    destination: {address: destinationAddress},
    travelMode: "DRIVE",
    routingPreference: "TRAFFIC_AWARE",
    departureTime: departureTimeIso,
  };
}

/**
 * Parses `routes[0].duration` ("1234s") out of a computeRoutes response;
 * null on any malformed shape. Pure — unit-testable.
 * @param {*} json
 * @return {?number}
 */
function parseRoutesDurationSeconds(json) {
  const route = json && Array.isArray(json.routes) ? json.routes[0] : null;
  const duration = route && route.duration;
  if (typeof duration !== "string") return null;
  const match = /^(\d+(?:\.\d+)?)s$/.exec(duration.trim());
  if (!match) return null;
  return Math.round(Number(match[1]));
}

module.exports = {
  MINUTE_MS,
  MAX_BOOKING_MS,
  TRAVEL_WINDOW_MS,
  TRAVEL_SWEEP_MAX,
  CONTEXT_QUERY_MAX,
  PREV_APPOINTMENT_LOOKBACK_HOURS,
  ON_SITE_FLIP_CHUNK,
  PENDING_STATUSES,
  address: _address,
  pruneEstimates,
  readEstimate,
  canDeferRoutes,
  decideOrigin,
  selectTravelCandidates,
  computeLeadMinutes,
  isDue,
  buildRoutesRequestBody,
  parseRoutesDurationSeconds,
};
