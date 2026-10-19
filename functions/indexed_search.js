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
  normalize,
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
const CLIENT_SEARCH_SCAN_LIMIT = 5000;
const CONFLICT_READ_LIMIT = 500;
const CONFLICT_SCAN_LIMIT = 5000;
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
  let cursor = source.orderBy("name");
  const candidates = [];
  let finished = false;
  while (!finished) {
    const limit = Math.min(SEARCH_READ_LIMIT,
        CLIENT_SEARCH_SCAN_LIMIT + 1 - candidates.length);
    const snap = await cursor.limit(limit).get();
    candidates.push(...snap.docs);
    if (candidates.length > CLIENT_SEARCH_SCAN_LIMIT) {
      logger.warn("searchClients: incomplete scan", {
        uidHash: shortHash(uid), count: candidates.length,
      });
      throw new HttpsError("resource-exhausted", "client-search-incomplete");
    }
    finished = snap.docs.length < limit;
    if (!finished) cursor = cursor.startAfter(snap.docs.at(-1));
  }
  const queryText = normalize(query);
  const queryDigits = query.replace(/\D/g, "");
  const scored = [];
  for (const doc of candidates) {
    const data = doc.data() || {};
    if (!recordMatchesQuery(data, query)) continue;
    const exactPhone = queryDigits && [data.phone, data.mobile].some((value) =>
      String(value || "").replace(/\D/g, "") === queryDigits);
    scored.push({
      score: exactPhone || normalize(clientDisplayName(data)) === queryText ?
        0 : 1,
      sortKey: clientDisplayName(data).toLowerCase(),
      record: callableRecord(doc),
    });
  }
  scored.sort((a, b) => a.score - b.score ||
    a.sortKey.localeCompare(b.sortKey));
  return {
    clients: scored.slice(0, SEARCH_RESULT_LIMIT).map((e) => e.record),
    examinedCount: candidates.length,
    matchedCount: scored.length,
    truncated: scored.length > SEARCH_RESULT_LIMIT,
  };
});

/**
 * Server-side terminal-appointment search over the business-wide archive.
 */
const searchHistory = onCall(APP_CHECK, async (req) => {
  const uid = await assertAdminCall(req, new Set([
    "query",
    "employeeId", // #compat-1.63.0
  ]));
  const query = optionalString(req.data, "query", SEARCH_QUERY_MAX);
  const tokens = searchQueryTokens(query);
  if (tokens.length === 0) return {appointments: []};
  await enforceDurableRateLimit(
      "searchHistory", uid, SEARCH_RATE_MAX, SEARCH_RATE_WINDOW_MS);

  const scoped = tokens.map((token) => `all:${token}`);
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
      uidHash: shortHash(uid),
      count: snap.docs.length,
    });
  }
  const appointments = snap.docs
      .filter((doc) => recordMatchesQuery(doc.data() || {}, query))
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
 * raw instant test â€” a 9-5 run across a week does not block a 7 pm job inside
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
const findAppointmentConflicts = onCall(
    {...APP_CHECK, timeoutSeconds: 120}, async (req) => {
      const profile = await assertActiveCall(req, new Set([
        "employeeIds",
        "startMillis",
        "endMillis",
        "excludeAppointmentId",
        "clientJobsOnly",
        "windows",
        "excludeAppointmentIds",
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
      let windows = null;
      if (req.data.windows !== undefined) {
        if (!Array.isArray(req.data.windows) || req.data.windows.length < 1 ||
        req.data.windows.length > 16) {
          throw new HttpsError("invalid-argument", "invalid-windows");
        }
        windows = req.data.windows.map((window) => {
          if (!window || typeof window !== "object" || Array.isArray(window) ||
          Object.keys(window).some((key) => !["startMillis", "endMillis",
            "excludeAppointmentId"].includes(key))) {
            throw new HttpsError("invalid-argument", "invalid-window");
          }
          const start = requireNumberInRange(window.startMillis, "startMillis",
              MIN_SEARCHABLE_MILLIS, MAX_SEARCHABLE_MILLIS);
          const end = requireNumberInRange(window.endMillis, "endMillis",
              MIN_SEARCHABLE_MILLIS, MAX_SEARCHABLE_MILLIS);
          if (end <= start) {
            throw new HttpsError("invalid-argument", "invalid-endMillis");
          }
          return {startMillis: start, endMillis: end,
            excludeId: optionalString(window, "excludeAppointmentId",
                APPOINTMENT_ID_MAX)};
        });
      }
      const exclusions = req.data.excludeAppointmentIds || [];
      if (!Array.isArray(exclusions) || exclusions.length > 100 ||
      exclusions.some((id) => typeof id !== "string" ||
        id.length > APPOINTMENT_ID_MAX || !id)) {
        throw new HttpsError("invalid-argument", "invalid-exclusions");
      }
      const excluded = new Set(exclusions);
      const clientJobsOnly = req.data.clientJobsOnly === true;
      let employeeIds = readEmployeeIds(req.data.employeeIds);
      if (employeeIds.length === 0) {
        return windows ?
    {windows: windows.map(() => ({busyEmployeeIds: []}))} : {appointments: []};
      }
      if (windows) {
        await enforceDurableRateLimit("findAppointmentConflicts", profile.uid,
            CONFLICT_RATE_MAX, CONFLICT_RATE_WINDOW_MS, "uid", windows.length);
      } else {
        await enforceDurableRateLimit("findAppointmentConflicts", profile.uid,
            CONFLICT_RATE_MAX, CONFLICT_RATE_WINDOW_MS);
      }

      if (profile.role !== "admin") {
        const callerDocId = String(profile.docId || "");
        if (!callerDocId || employeeIds.some((id) => id !== callerDocId)) {
          throw new HttpsError("permission-denied", "scope-denied");
        }
        employeeIds = [callerDocId];
      }

      const db = getFirestore();
      if (windows) {
        const results = await Promise.all(windows.map((window) =>
          readConflictWindow(db, {...window, employeeIds, clientJobsOnly,
            excluded, uid: profile.uid, minimal: true})));
        return {windows: results.map((result) => ({
          busyEmployeeIds: result.busyEmployeeIds,
        }))};
      }
      return readConflictWindow(db, {employeeIds, startMillis, endMillis,
        excludeId, clientJobsOnly, excluded, uid: profile.uid});
    });


/**
 * Reads one complete bounded window; batching projects only scheduling fields.
 * @param {!Object} db Firestore handle.
 * @param {!Object} options Validated window and viewer scope.
 * @return {!Promise<!Object>} Matching appointment records.
 */
async function readConflictWindow(db, options) {
  const {employeeIds, startMillis, endMillis, excludeId, clientJobsOnly,
    excluded, uid, minimal = false} = options;
  const found = new Map();
  const busy = new Set();
  const proposed = {
    startMs: startMillis, endMs: endMillis,
    overnight: resolveWindow({startTime: new Date(startMillis),
      endTime: new Date(endMillis)}).overnight,
  };
  let scanned = 0;
  for (let i = 0; i < employeeIds.length; i += 30) {
    const batch = employeeIds.slice(i, i + 30);
    let query = db.collection("appointments")
        .where("employeeIds", "array-contains-any", batch)
        .where("startTime", "<", new Date(endMillis))
        .where("endTime", ">", new Date(startMillis));
    if (minimal) {
      query = query.select("employeeIds", "status", "startTime",
          "endTime", "isPersonal", "isAllDay", "isDayOff");
    }
    let finished = false;
    while (!finished) {
      const limit = Math.min(CONFLICT_READ_LIMIT,
          CONFLICT_SCAN_LIMIT + 1 - scanned);
      const snap = await query.limit(limit).get();
      scanned += snap.docs.length;
      if (scanned > CONFLICT_SCAN_LIMIT) {
        logger.warn("findAppointmentConflicts: incomplete scan", {
          uidHash: shortHash(uid), count: scanned,
        });
        throw new HttpsError("resource-exhausted", "conflict-scan-incomplete");
      }
      for (const doc of snap.docs) {
        const data = doc.data() || {};
        if (doc.id === excludeId || excluded.has(doc.id) ||
            isTerminalStatus(data.status) ||
            (clientJobsOnly && data.isPersonal === true) ||
            !blocksProposedWindow(data, proposed)) continue;
        if (minimal) {
          for (const id of Array.isArray(data.employeeIds) ?
            data.employeeIds : []) {
            if (employeeIds.includes(id)) busy.add(id);
          }
        } else {
          found.set(doc.id, doc);
        }
      }
      if (minimal && busy.size === employeeIds.length) {
        return {busyEmployeeIds: [...busy]};
      }
      finished = snap.docs.length < limit;
      if (!finished) query = query.startAfter(snap.docs.at(-1));
    }
  }
  return minimal ? {busyEmployeeIds: [...busy]} :
    {appointments: [...found.values()].map(callableRecord)};
}

module.exports = {
  searchClients,
  searchHistory,
  findAppointmentConflicts,
  blocksProposedWindow,
  serializeValue,
};
