"use strict";

/**
 * @fileoverview Orchestrates the iOS "time to leave" Live Activity: registry
 * lookup, then payload build, then a direct APNs send, then pruning any dead
 * rows. This is the only surface `travel_utils.js`/`notification_utils.js`
 * call, so neither of them touches APNs or the registry directly.
 *
 * Talks to APNs directly (see apns_client.js) because FCM cannot send
 * `apns-push-type: liveactivity`.
 *
 * Every export here is best-effort and never throws. No token, no APNs
 * credentials, iOS < 17.2, or Live Activities turned off — any of those just
 * make it degrade silently to the existing, independently-firing `leaveNow`
 * push.
 *
 * @module live_activity_dispatch
 */

const {
  buildContentState,
  buildStartPayload,
  buildUpdatePayload,
  buildEndPayload,
  liveActivityStrings,
  phaseFor,
} = require("./live_activity_utils");
const {
  listPushToStartTokens,
  listUpdateTokens,
  deleteActivityToken,
  writeCardMarker,
  readCardMarker,
  setCardStart,
  clearCardMarker,
} = require("./live_activity_registry");
const {sendLiveActivityPush} = require("./apns_client");
const {toMillis} = require("./time_utils");
const {getFeatureFlags} = require("./feature_flags");

// Local rather than imported from travel_utils: that module requires this one
// (travel_utils -> live_activity_dispatch), so reaching back would close a
// cycle.
const MINUTE_MS = 60 * 1000;

/**
 * The ActivityKit `attributes` a push-to-start carries — kept in lockstep with
 * the `ActivityAttributes` struct in
 * `ios/ScheduleWidget/LiveActivitiesAppAttributes.swift` (plugin-fixed name;
 * change one, change both).
 * @param {{appointmentId: string, employeeDocId: string,
 *   employeeColorValue: (number|undefined)}} args
 * @return {!Object}
 */
function buildAttributes({appointmentId, employeeDocId, employeeColorValue}) {
  return {
    appointmentId: String(appointmentId || ""),
    employeeDocId: String(employeeDocId || ""),
    employeeColorValue: typeof employeeColorValue === "number" ?
        employeeColorValue : 0,
  };
}

/**
 * The assignee's `colorValue`, which drives the card's colour rail (mirroring
 * `AppointmentCard`). A failed read just yields 0 — the Swift side's amber
 * fallback is fine, so that's never a reason to skip the card.
 *
 * `colorValue` is stored as a NUMERIC STRING everywhere — `firestore.rules`
 * requires `s.matches('^-?[0-9]+$')` and both Dart write paths send
 * `.toARGB32().toString()` — so parsing is the live path, not the fallback.
 * Reading only the `number` shape made this return 0 every time, which the
 * Swift side turns into an orange rail on every push-started card.
 * @param {!Object} deps `{db, logger}`.
 * @param {string} employeeDocId
 * @return {!Promise<number>}
 */
async function _employeeColorValue(deps, employeeDocId) {
  try {
    const snap = await deps.db.collection("users").doc(employeeDocId).get();
    const value = snap && snap.exists ? (snap.data() || {}).colorValue : null;
    if (typeof value === "number") return Number.isFinite(value) ? value : 0;
    const parsed = Number.parseInt(String(value ?? ""), 10);
    return Number.isFinite(parsed) ? parsed : 0;
  } catch (err) {
    if (deps.logger) {
      deps.logger.warn("liveActivity: colorValue read failed", {err});
    }
    return 0;
  }
}

/**
 * This employee's live update-token rows, but only when the card marker
 * confirms the live card is actually showing `appointmentId` (`[]`
 * otherwise). That marker check is load-bearing: rows are keyed by employee
 * only, and a push-started activity's id can never be stamped back onto its
 * own row.
 * @param {!Object} deps
 * @param {{appointmentId: string, employeeDocId: string}} args
 * @return {!Promise<{rows: !Array<!Object>, marker: ?Object}>}
 */
async function _liveRowsFor(deps, {appointmentId, employeeDocId}) {
  if (!employeeDocId) return {rows: [], marker: null};
  const marker = await readCardMarker(deps, {employeeDocId});
  if (!marker || marker.appointmentId !== String(appointmentId)) {
    return {rows: [], marker: null};
  }
  const rows = await listUpdateTokens(deps, {employeeDocId});
  return {rows: rows.filter((row) => row && row.token), marker};
}

/**
 * Fills in a `leaveAt` (and drive line) from the card marker's stored lead
 * when the caller has none. Returns `ctx` untouched when it already carries
 * one, when no lead was ever recorded, or when the start is unreadable — the
 * content builder then labels the time "Starts at" rather than "Leave at".
 * @param {!Object} ctx
 * @param {?Object} marker
 * @return {!Object}
 */
function _withLeaveAt(ctx, marker) {
  if (!ctx || ctx.leaveAt != null) return ctx;
  if (!marker || typeof marker.leadMinutes !== "number") return ctx;
  const startMs = toMillis(ctx.startTime);
  if (startMs == null) return ctx;
  return {
    ...ctx,
    leaveAt: new Date(startMs - marker.leadMinutes * MINUTE_MS),
    travelMinutes: ctx.travelMinutes ?? marker.travelMinutes ?? null,
  };
}

/**
 * `{authKey, keyId, teamId}` for APNs, or null when the secrets aren't
 * configured — every verb here just no-ops in that case. Read lazily so a
 * module load outside a secret-bound function can't throw.
 * @param {!Object} deps
 * @return {?Object}
 */
function _authOf(deps) {
  const auth = deps && deps.apnsAuth;
  if (!auth || !auth.authKey || !auth.keyId || !auth.teamId) return null;
  return auth;
}

/**
 * Sends one payload to one registry row, pruning it when APNs says the
 * activity is gone. Returns 1 on a delivered push, else 0.
 * Skips the send, and never prunes, while `feature_live_activities` is off.
 * @param {!Object} deps `{logger, apnsAuth, featureFlags}`; `featureFlags`
 *   is an optional async loader, defaulting to `getFeatureFlags`.
 * @param {!Object} row A row from the registry.
 * @param {!Object} payload
 * @param {string} label For the warn line.
 * @return {!Promise<number>}
 */
async function _sendToRow(deps, row, payload, label) {
  const auth = _authOf(deps);
  if (!auth || !row || !row.token) return 0;
  const flags = await (deps.featureFlags || getFeatureFlags)();
  if (flags.feature_live_activities === false) {
    // Skipped, NOT gone: a paused send must never prune the token.
    return 0;
  }
  const result = await sendLiveActivityPush({
    token: row.token,
    payload,
    auth,
    collapseId: row.collapseId || undefined,
    logger: deps.logger,
  });
  if (result.gone) {
    await deleteActivityToken(deps, {ref: row.ref});
    return 0;
  }
  if (!result.ok && deps.logger) {
    deps.logger.warn(`liveActivity: ${label} push rejected`, {
      status: result.status,
      reason: result.reason,
    });
  }
  return result.ok ? 1 : 0;
}

/**
 * Content state for a row's locale. Card text is built server-side using the
 * per-token `locale` already stored, the same rule the notification bodies
 * follow.
 * @param {!Object} row
 * @param {!Object} ctx `{clientName, address, startTime, endTime, leaveAt,
 *   travelMinutes}`.
 * @param {*} nowDate
 * @return {!Object}
 */
function _stateFor(row, ctx, nowDate) {
  return buildContentState({
    clientName: ctx.clientName,
    // Carried so a personal job's card names it by title rather than "Client".
    title: ctx.title,
    address: ctx.address,
    startTime: ctx.startTime,
    endTime: ctx.endTime,
    leaveAt: ctx.leaveAt,
    travelMinutes: ctx.travelMinutes,
    phase: phaseFor({startTime: ctx.startTime, now: nowDate}),
    locale: row.locale,
  });
}

/**
 * Starts the Lock Screen card for one (job, assignee) pair via push-to-start,
 * called right after the reminder's ledger claim succeeds so it inherits that
 * claim's exactly-once guarantee rather than adding a second one.
 * @param {!Object} deps `{db, logger, apnsAuth}`.
 * @param {!Object} args `{appointmentId, employeeDocId, ctx, nowDate}`.
 * @return {!Promise<number>} Cards started.
 */
async function startLiveActivity(deps, args) {
  const {appointmentId, employeeDocId, ctx, nowDate} = args;
  if (!_authOf(deps)) return 0;
  try {
    const rows = await listPushToStartTokens(deps, {
      employeeDocIds: [employeeDocId],
    });
    if (rows.length === 0) return 0;
    const attributes = buildAttributes({
      appointmentId,
      employeeDocId,
      employeeColorValue: await _employeeColorValue(deps, employeeDocId),
    });
    let started = 0;
    for (const row of rows) {
      const state = _stateFor(row, ctx, nowDate);
      const strings = liveActivityStrings(row.locale);
      const payload = buildStartPayload({
        contentState: state,
        attributes,
        now: nowDate,
        // The alert body IS the drive line, so it's omitted without one.
        alert: typeof ctx.travelMinutes === "number" ?
            strings.startAlert(ctx, state.clientName) : null,
        // The card is meaningless once the visit has started; ActivityKit
        // greys it out rather than showing a stale "leave at".
        staleDate: ctx.startTime,
      });
      started += await _sendToRow(deps, row, payload, "start");
    }
    // Records which appointment this tech's card is showing, so the update and
    // end hooks can resolve it — see [_liveRowsFor].
    if (started > 0) {
      await writeCardMarker(deps, {
        employeeDocId,
        appointmentId: String(appointmentId),
        startTime: ctx.startTime,
        phase: phaseFor({startTime: ctx.startTime, now: nowDate}),
        leadMinutes: ctx.leadMinutes,
        travelMinutes: ctx.travelMinutes,
      });
    }
    return started;
  } catch (err) {
    if (deps.logger) {
      deps.logger.warn("liveActivity: start failed", {id: appointmentId, err});
    }
    return 0;
  }
}

/**
 * Pushes a fresh content state to this employee's live card (the reschedule
 * hook and the on-site phase-flip backstop both land here); a no-op when the
 * employee has no card, or one for a different appointment.
 * @param {!Object} deps `{db, logger, apnsAuth}`.
 * @param {!Object} args `{appointmentId, employeeDocId, ctx, nowDate}`.
 * @return {!Promise<number>} Cards updated.
 */
async function updateLiveActivity(deps, args) {
  const {appointmentId, employeeDocId, ctx, nowDate} = args;
  if (!_authOf(deps)) return 0;
  try {
    const {rows, marker} = await _liveRowsFor(
        deps, {appointmentId, employeeDocId});
    if (rows.length === 0) return 0;
    const phase = phaseFor({startTime: ctx.startTime, now: nowDate});
    // A reschedule hook has no drive estimate of its own, so rebuild `leaveAt`
    // off the NEW start using the lead the sweep already measured for this
    // card. Without this the card falls back to the appointment time and
    // labels it "Leave at", sending the tech off a whole drive-time late.
    const effectiveCtx = _withLeaveAt(ctx, marker);
    let updated = 0;
    for (const row of rows) {
      const payload = buildUpdatePayload({
        contentState: _stateFor(row, effectiveCtx, nowDate),
        now: nowDate,
        staleDate: ctx.startTime,
      });
      updated += await _sendToRow(deps, row, payload, "update");
    }
    // Keeps the marker's startTime/phase authoritative on reschedule.
    // `listCardsDueForOnSite`'s flip is keyed off marker.startTime, so this
    // is what makes it fire at the right time and exactly once.
    if (updated > 0) {
      await setCardStart(
          deps, {employeeDocId, startTime: ctx.startTime, phase});
    }
    return updated;
  } catch (err) {
    if (deps.logger) {
      deps.logger.warn("liveActivity: update failed", {id: appointmentId, err});
    }
    return 0;
  }
}

/**
 * Ends this employee's live card — the cancel/remove hook. Drops its
 * registry rows and card marker, and sets `dismissal-date: now` so the card
 * clears the Lock Screen immediately instead of lingering up to four hours.
 * @param {!Object} deps `{db, logger, apnsAuth}`.
 * @param {!Object} args `{appointmentId, employeeDocId, ctx, nowDate}`.
 * @return {!Promise<number>} Cards ended.
 */
async function endLiveActivity(deps, args) {
  const {appointmentId, employeeDocId, ctx, nowDate} = args;
  if (!_authOf(deps)) return 0;
  try {
    const flags = await (deps.featureFlags || getFeatureFlags)();
    if (flags.feature_live_activities === false) return 0;
    const {rows} = await _liveRowsFor(deps, {appointmentId, employeeDocId});
    if (rows.length === 0) return 0;
    let ended = 0;
    for (const row of rows) {
      const payload = buildEndPayload({
        contentState: _stateFor(row, ctx || {}, nowDate),
        now: nowDate,
        dismissalDate: nowDate,
      });
      ended += await _sendToRow(deps, row, payload, "end");
      // The activity is over either way — a row kept here would be pruned
      // only by the TTL sweep days later.
      await deleteActivityToken(deps, {ref: row.ref});
    }
    await clearCardMarker(deps, {employeeDocId});
    return ended;
  } catch (err) {
    if (deps.logger) {
      deps.logger.warn("liveActivity: end failed", {id: appointmentId, err});
    }
    return 0;
  }
}

module.exports = {
  buildAttributes,
  startLiveActivity,
  updateLiveActivity,
  endLiveActivity,
};
