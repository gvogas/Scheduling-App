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

// Lead cap; a >80-min drive fires at the first sweep in the window (accepted).
const MAX_LEAD_MINUTES = 90;

// Lead when there is no origin, no address or Routes failed.
const FALLBACK_LEAD_MINUTES = 30;

// An older presence doc means tracking died; fall back to the address chain.
const PRESENCE_STALE_MINUTES = 25;

// How far back a previous job's address still counts as where they were.
const PREV_APPOINTMENT_LOOKBACK_HOURS = 4;

// Context read cap; endTime ASC keeps the earliest-ending jobs it needs.
const CONTEXT_QUERY_MAX = 50;

// Longest single-day visit; deliberately NOT the span cap (ADR-0104).
const MAX_BOOKING_MS = 24 * 60 * MINUTE_MS;

// Candidate window: MAX_LEAD_MINUTES ahead, so the longest lead is in range.
const TRAVEL_WINDOW_MS = MAX_LEAD_MINUTES * MINUTE_MS;

// Candidate read cap; startTime ASC keeps the most imminent (ADR-0104).
const TRAVEL_SWEEP_MAX = 500;

// A cached estimate may only DEFER a Routes call, never trigger a send.
const ESTIMATE_TTL_MS = 10 * MINUTE_MS;
const SKIP_MARGIN_MS = 15 * MINUTE_MS;

// On-site flips per chunk, sized like PRUNE_CHUNK in live_activity_registry.js.
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

// Statuses expecting the visit; `confirmed` is the retired legacy alias.
const PENDING_LIKE = new Set(["pending", "confirmed"]);

// Array form for the candidate query; narrower than OPEN_STATUSES on purpose.
const PENDING_STATUSES = [...PENDING_LIKE];

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
 * All-day blocks are skipped (no departure time, ADR-0048); a timed personal
 * job keeps its reminder.
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
