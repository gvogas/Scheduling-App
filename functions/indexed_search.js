"use strict";

/**
 * @fileoverview Indexed search and conflict callables used by the mobile app.
 * These replace capped client-side scans for high-cardinality paths.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");

const {clientDisplayName} = require("./client_name_utils");
const {
  APP_CHECK,
  assertActiveCall,
  assertAdminCall,
  enforceDurableRateLimit,
  optionalString,
  requireNumberInRange,
  shortHash,
} = require("./security");
const {
  recordMatchesQuery,
  searchQueryTokens,
} = require("./search_tokens");
const {
  isTerminalStatus,
  toMillis,
} = require("./time_utils");
const {
  dailyWindowsOverlap,
  resolveWindow,
} = require("./day_slice_utils");

const SEARCH_QUERY_MAX = 80;
// Read wide, return narrow. A phone query tokenizes to every 3-12 digit
// substring, so a query like "514" matches most of the roster and the read cap
// decides the answer; at 50 the client being looked for was usually outside it.
const SEARCH_READ_LIMIT = 200;
const SEARCH_RESULT_LIMIT = 25;
const CONFLICT_READ_LIMIT = 500;
const CONFLICT_EMPLOYEE_LIMIT = 500;
const APPOINTMENT_ID_MAX = 128;
const SEARCH_RATE_MAX = 60;
const SEARCH_RATE_WINDOW_MS = 60_000;
const CONFLICT_RATE_MAX = 120;
const CONFLICT_RATE_WINDOW_MS = 60_000;
const MIN_SEARCHABLE_MILLIS = Date.UTC(2020, 0, 1);
const MAX_SEARCHABLE_MILLIS = Date.UTC(2100, 0, 1);

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

/**
 * @param {!Object} doc Query document.
 * @return {{id: string, data: !Object}}
 */
function callableRecord(doc) {
  return {id: doc.id, data: serializeValue(doc.data() || {})};
}

/**
 * Server-side client search, admin-only because clients are PII.
 */
const searchClients = onCall(APP_CHECK, async (req) => {
  const uid = await assertAdminCall(req, new Set([
    "query", "archived", "type", "buildingKey",
  ]));
  const query = optionalString(req.data, "query", SEARCH_QUERY_MAX);
  const type = optionalString(req.data, "type", 32);
  const buildingKey = optionalString(req.data, "buildingKey", 1000);
  const archived = req.data?.archived;
  if ((archived !== undefined && typeof archived !== "boolean") ||
      (type && !["residential", "commercial", "building"].includes(type)) ||
      (type && buildingKey)) {
    throw new HttpsError("invalid-argument", "invalid-client-filter");
  }
  const tokens = searchQueryTokens(query);
  if (tokens.length === 0) return {clients: []};
  await enforceDurableRateLimit(
      "searchClients", uid, SEARCH_RATE_MAX, SEARCH_RATE_WINDOW_MS);

  let source = getFirestore()
      .collection("clients")
      .where("searchTokens", "array-contains-any", tokens);
  if (archived !== undefined) source = source.where("archived", "==", archived);
  if (type) source = source.where("type", "==", type);
  if (buildingKey) source = source.where("buildingKey", "==", buildingKey);
  const snap = await source
      .orderBy("name")
      .limit(SEARCH_READ_LIMIT)
      .get();
  if (snap.docs.length >= SEARCH_READ_LIMIT) {
    // The window is `orderBy("name")`, so at the cap it is the alphabetically
    // FIRST N matches and everything past that point is invisible — the same
    // silent truncation the client-side scan had, which is why it must warn.
    logger.warn("searchClients: read cap hit", {
      uidHash: shortHash(uid),
      count: snap.docs.length,
    });
  }
  const scored = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (!recordMatchesQuery(data, query)) continue;
    scored.push({
      sortKey: clientDisplayName(data).toLowerCase(),
      record: callableRecord(doc),
    });
  }
  scored.sort((a, b) => a.sortKey.localeCompare(b.sortKey));
  return {
    clients: scored.slice(0, SEARCH_RESULT_LIMIT).map((e) => e.record),
  };
});

/**
 * Chooses the history-search token scope allowed for the caller.
 * @param {!Object} profile usersByUid row.
 * @param {string} requestedEmployeeId Optional employeeId payload.
 * @return {string}
 */
function historyScope(profile, requestedEmployeeId) {
  const callerDocId = String(profile.docId || "");
  if (profile.role === "admin") {
    return requestedEmployeeId ? `emp:${requestedEmployeeId}` : "all";
  }
  if (profile.role === "employee" && callerDocId) {
    if (requestedEmployeeId && requestedEmployeeId !== callerDocId) {
      throw new HttpsError("permission-denied", "scope-denied");
    }
    return `emp:${callerDocId}`;
  }
  throw new HttpsError("permission-denied", "role-denied");
}

/**
 * Whether this caller may see one history document.
 *
 * `historySearchScopes` is a denormalized mirror of `employeeIds` written by
 * the CLIENT app, so a doc whose scopes drift from `employeeIds` would be
 * readable by a technician `firestore.rules` would refuse. The module already
 * treats a token hit as a PREFILTER rather than the answer; this applies the
 * same rule to the scope. Deliberately NOT `mayRestore` from
 * `appointment_actions.js`: that one additionally requires `role === employee`
 * because it authorizes a WRITE. Reading your own job is assignment alone.
 * @param {!Object} profile usersByUid row.
 * @param {!Object} data Stored appointment.
 * @return {boolean}
 */
function mayReadHistoryDoc(profile, data) {
  if (profile.role === "admin") return true;
  const callerDocId = String(profile.docId || "");
  if (!callerDocId) return false;
  const assigned = Array.isArray(data.employeeIds) ? data.employeeIds : [];
  return assigned.map(String).includes(callerDocId);
}

/**
 * Server-side terminal-appointment search, scoped by caller role.
 */
const searchHistory = onCall(APP_CHECK, async (req) => {
  const profile = await assertActiveCall(
      req, new Set(["query", "employeeId"]));
  const query = optionalString(req.data, "query", SEARCH_QUERY_MAX);
  const employeeId = optionalString(req.data, "employeeId", APPOINTMENT_ID_MAX);
  const tokens = searchQueryTokens(query);
  if (tokens.length === 0) return {appointments: []};
  await enforceDurableRateLimit(
      "searchHistory", profile.uid, SEARCH_RATE_MAX, SEARCH_RATE_WINDOW_MS);

  const scope = historyScope(profile, employeeId);
  const scoped = tokens.map((token) => `${scope}:${token}`);
  const snap = await getFirestore()
      .collection("appointments")
      .where("historySearchScopes", "array-contains-any", scoped)
      // 10 tokens x 3 statuses = Firestore's 30-disjunction ceiling exactly.
      .where("status", "in", ["done", "completed", "cancelled"])
      .orderBy("startTime", "desc")
      .limit(SEARCH_READ_LIMIT)
      .get();
  if (snap.docs.length >= SEARCH_READ_LIMIT) {
    logger.warn("searchHistory: read cap hit", {
      uidHash: shortHash(profile.uid),
      count: snap.docs.length,
    });
  }
  const appointments = snap.docs
      .filter((doc) => {
        const data = doc.data() || {};
        return mayReadHistoryDoc(profile, data) &&
            recordMatchesQuery(data, query);
      })
      .slice(0, SEARCH_RESULT_LIMIT)
      .map(callableRecord);
  return {appointments};
});

/**
 * Validates employee id payloads.
 * @param {*} raw Raw payload value.
 * @return {!Array<string>}
 */
function readEmployeeIds(raw) {
  if (!Array.isArray(raw) || raw.length > CONFLICT_EMPLOYEE_LIMIT) {
    throw new HttpsError("invalid-argument", "invalid-employeeIds");
  }
  const out = [];
  const seen = new Set();
  for (const value of raw) {
    const id = String(value || "").trim();
    if (!id || id.includes("/") || id.length > APPOINTMENT_ID_MAX) {
      throw new HttpsError("invalid-argument", "invalid-employeeIds");
    }
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * True when a stored appointment blocks the proposed window.
 *
 * The clash rule is the shared DAILY-window overlap (`day_slice_utils`), not a
 * raw instant test — a 9-5 run across a week does not block a 7 pm job inside
 * it. A record whose stored times do not parse clashes UNCONDITIONALLY: a
 * legacy or console-written row with no usable window must never quietly
 * disappear from a booking check.
 * @param {!Object} data Stored appointment fields.
 * @param {!{startMs: number, endMs: number, overnight: boolean}} proposed
 * @return {boolean}
 */
function blocksProposedWindow(data, proposed) {
  if (toMillis(data.startTime) == null || toMillis(data.endTime) == null) {
    return true;
  }
  return dailyWindowsOverlap(resolveWindow(data), proposed);
}

/**
 * Server-side conflict validation for appointment writes.
 */
const findAppointmentConflicts = onCall(APP_CHECK, async (req) => {
  const profile = await assertActiveCall(req, new Set([
    "employeeIds",
    "startMillis",
    "endMillis",
    "excludeAppointmentId",
    "clientJobsOnly",
  ]));
  const startMillis = requireNumberInRange(
      req.data.startMillis, "startMillis",
      MIN_SEARCHABLE_MILLIS, MAX_SEARCHABLE_MILLIS);
  const endMillis = requireNumberInRange(
      req.data.endMillis, "endMillis",
      MIN_SEARCHABLE_MILLIS, MAX_SEARCHABLE_MILLIS);
  if (endMillis <= startMillis) {
    throw new HttpsError("invalid-argument", "invalid-endMillis");
  }
  const excludeId = optionalString(
      req.data, "excludeAppointmentId", APPOINTMENT_ID_MAX);
  const clientJobsOnly = req.data.clientJobsOnly === true;
  let employeeIds = readEmployeeIds(req.data.employeeIds);
  if (employeeIds.length === 0) return {appointments: []};
  await enforceDurableRateLimit(
      "findAppointmentConflicts", profile.uid,
      CONFLICT_RATE_MAX, CONFLICT_RATE_WINDOW_MS);

  if (profile.role !== "admin") {
    const callerDocId = String(profile.docId || "");
    if (!callerDocId || employeeIds.some((id) => id !== callerDocId)) {
      throw new HttpsError("permission-denied", "scope-denied");
    }
    employeeIds = [callerDocId];
  }

  const db = getFirestore();
  const chunks = [];
  for (let i = 0; i < employeeIds.length; i += 30) {
    const batch = employeeIds.slice(i, i + 30);
    chunks.push(db.collection("appointments")
        .where("employeeIds", "array-contains-any", batch)
        .where("startTime", "<", new Date(endMillis))
        .where("endTime", ">", new Date(startMillis))
        .limit(CONFLICT_READ_LIMIT)
        .get());
  }
  const found = new Map();
  for (const snap of await Promise.all(chunks)) {
    if (snap.docs.length >= CONFLICT_READ_LIMIT) {
      logger.warn("findAppointmentConflicts: read cap hit", {
        uidHash: shortHash(profile.uid),
        count: snap.docs.length,
      });
    }
    for (const doc of snap.docs) found.set(doc.id, doc);
  }
  const proposed = {
    startMs: startMillis,
    endMs: endMillis,
    overnight: resolveWindow({
      startTime: new Date(startMillis),
      endTime: new Date(endMillis),
    }).overnight,
  };

  const appointments = [...found.values()].filter((doc) => {
    const data = doc.data() || {};
    if (doc.id === excludeId) return false;
    if (isTerminalStatus(data.status)) return false;
    if (clientJobsOnly && data.isPersonal === true) return false;
    return blocksProposedWindow(data, proposed);
  }).map(callableRecord);

  return {appointments};
});

module.exports = {
  searchClients,
  searchHistory,
  findAppointmentConflicts,
  historyScope,
  mayReadHistoryDoc,
  blocksProposedWindow,
  serializeValue,
};
