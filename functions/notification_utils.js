"use strict";

/**
 * @fileoverview Push-notification logic for employee job alerts, 30-minute
 * reminders, and the nightly digest. Both the pure helpers and the
 * orchestration functions take injected `{db, messaging, now, logger}` so
 * jest can drive them with mocks.
 * `sendToEmployee` lives here (not in notifications.js) so it's unit-testable
 * with an injected Firestore + Messaging.
 * @module notification_utils
 */

const {
  buildWidgetPayload,
  torontoDayStartMs,
  WIDGET_LOOKAHEAD_DAYS,
} = require("./widget_payload_utils");
const {
  updateLiveActivity,
  endLiveActivity,
} = require("./live_activity_dispatch");
const {liveActivityCtx} = require("./live_activity_utils");
const {
  toMillis,
  MAX_APPOINTMENT_SPAN_MS,
  isCancelledStatus,
  isCompletedStatus,
} = require("./time_utils");
const {
  buildNotificationMessage,
  buildDigestMessage,
  buildJobCompletedMessage,
  buildOverdueReviewMessage,
} = require("./notification_messages");

const {
  DAY_MS,
  OVERDUE_LOOKBACK_MS,
  OVERDUE_SWEEP_MAX,
  DIGEST_SWEEP_MAX,
  MONTH_END_REVIEW_MAX,
  MONTH_END_SCAN_MAX,
  WIDGET_PAYLOAD_MAX_BYTES,
  OPEN_STATUSES,
  CHANGE_RECIPIENT_ROLES,
  TIMED_RECIPIENT_ROLES,
  ADMIN_RECIPIENT_ROLES,
  ledgerBody,
  toIdList,
  nowMillis,
  diffAppointmentForNotifications,
  selectOverdueCandidates,
  isLastDayOfBusinessMonth,
  selectMonthEndOverdue,
  groupTomorrowsJobsByEmployee,
  tomorrowWindowToronto,
  overduePromptLedgerId,
  isStaleTokenError,
  isAlreadyExists,
  isCrewCompletion,
  lifecycleStamps,
  recordOf: _record,
  contextFor: _contextFor,
} = require("./notification_policy");
const {scanAppointmentWindow} = require("./appointment_scan");

/**
 * Reads (and caches) one recipient's user doc plus their live token docs.
 * @param {!Object} deps `{db}`.
 * @param {string} employeeDocId users doc id.
 * @param {!Map<string, {user: ?Object, tokenDocs: ?Array<!Object>}>=} cache
 * @return {!Promise<{user: ?Object, tokenDocs: ?Array<!Object>}>}
 */
async function _loadRecipient(deps, employeeDocId, cache) {
  const {db} = deps;
  const userRef = db.collection("users").doc(employeeDocId);
  let entry = cache && cache.get(employeeDocId);
  if (!entry) {
    const userSnap = await userRef.get();
    const user = userSnap.exists ? (userSnap.data() || {}) : null;
    entry = {user, tokenDocs: null};
    if (cache) cache.set(employeeDocId, entry);
  }
  if (!entry.user) return entry;
  // Tokens are read lazily and then cached beside the user.
  if (entry.tokenDocs == null) {
    const tokensSnap = await userRef.collection("fcmTokens").get();
    entry.tokenDocs = (tokensSnap && tokensSnap.docs) || [];
  }
  return entry;
}

/**
 * Whether a push of `roles` can actually reach a loaded recipient — the
 * server-side filter to active accounts of an allowed role that hold at least
 * one live token.
 * @param {{user: ?Object, tokenDocs: ?Array<!Object>}} entry From
 * [_loadRecipient].
 * @param {!Set<string>=} roles Allowed recipient roles (default employees
 * only).
 * @return {boolean}
 */
function _canReachRecipient(entry, roles) {
  const {user, tokenDocs} = entry || {};
  if (!user) return false;
  const allowed = roles || CHANGE_RECIPIENT_ROLES;
  if (!allowed.has(user.role) || user.status !== "active") return false;
  return ((tokenDocs && tokenDocs.length) || 0) > 0;
}

/**
 * Sends one localized message to every live token of an active employee, then
 * deletes any token docs FCM reports as stale.
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {string} employeeDocId users doc id.
 * @param {!Object} data Data payload (string values); `kind` etc.
 * @param {function(string): {title: string, body: string}} buildMsg Localized
 * message builder keyed by 'en'|'fr'.
 * @param {!Set<string>=} roles Allowed recipient roles (default employees
 * only; time-based sweeps pass [TIMED_RECIPIENT_ROLES] to also reach an
 * assigned admin).
 * @param {!Map<string, {user: ?Object, tokenDocs: !Array<!Object>}>=} cache
 * Per-sweep read cache keyed by employee doc id, so an employee assigned to
 * several jobs in one sweep is fetched at most once. Stale-token pruning
 * still works fine with this cache, since deletes are idempotent and it's
 * the ledger, not the token list, that actually prevents duplicate pushes.
 * @param {function(string): !Object=} augmentData Optional per-token extra
 * data keyed by locale ('en'|'fr'), used to attach a locale-correct
 * `widgetPayload`. A non-empty payload also sets APNs `content-available`
 * so iOS applies it even with the app closed.
 * @return {!Promise<number>}
 */
async function sendToEmployee(deps, employeeDocId, data, buildMsg, roles,
    cache, augmentData) {
  const {messaging, logger} = deps;

  const entry = await _loadRecipient(deps, employeeDocId, cache);
  if (!_canReachRecipient(entry, roles)) return 0;
  const {tokenDocs} = entry;

  const messages = tokenDocs.map((doc) => {
    const locale = (doc.data() || {}).locale === "fr" ? "fr" : "en";
    const {title, body} = buildMsg(locale);
    let msgData = augmentData ? {...data, ...augmentData(locale)} : data;
    // Drop widgetPayload if it would push us over the 4 KB FCM data-map cap and
    // lose the whole message.
    if (typeof msgData.widgetPayload === "string" &&
        Buffer.byteLength(msgData.widgetPayload, "utf8") >
          WIDGET_PAYLOAD_MAX_BYTES) {
      msgData = {...msgData};
      delete msgData.widgetPayload;
    }
    const aps = {sound: "default"};
    // A fresh widget payload also sets APNs content-available, so iOS wakes the
    // app in the background to rewrite the widget.
    if (typeof msgData.widgetPayload === "string" && msgData.widgetPayload) {
      aps["content-available"] = 1;
    }
    // Marked time-sensitive so a departure alert isn't buried in a Focus-mode
    // summary.
    if (msgData.kind === "leaveNow") {
      aps["interruption-level"] = "time-sensitive";
    }
    return {
      token: doc.id,
      notification: {title, body},
      data: msgData,
      // Without these Android delivery can be doze-deferred and iOS alerts
      // arrive silent.
      android: {priority: "high"},
      apns: {payload: {aps}},
    };
  });

  const resp = await messaging.sendEach(messages);
  // Nothing below may throw. The caller treats a 0 return as "nothing sent" and
  // releases the idempotency claim, so a post-delivery throw here would cause a
  // resend of an already-delivered message.
  try {
    const responses = (resp && resp.responses) || [];
    let sent = 0;
    const deletions = [];
    responses.forEach((r, i) => {
      if (r && r.success) {
        sent += 1;
        return;
      }
      const code = r && r.error && r.error.code;
      if (isStaleTokenError(code)) {
        deletions.push(tokenDocs[i].ref.delete().catch((err) => {
          if (logger) logger.warn("fcm: stale-token delete failed", {err});
        }));
      } else if (logger) {
        logger.warn("fcm: send failed", {employeeDocId, code});
      }
    });
    if (deletions.length > 0) await Promise.all(deletions);
    return sent;
  } catch (err) {
    // Bookkeeping failed but the batch already went out, so report the batch
    // size to keep the claim.
    if (logger) {
      logger.warn("fcm: post-send bookkeeping failed", {employeeDocId, err});
    }
    return messages.length;
  }
}


/** Tail guard on the widget window. */
const WIDGET_WINDOW_MAX = 200;

/**
 * Reads an employee's appointments for the widget payload, so the change push
 * can carry a fresh one.
 * @param {!Object} db
 * @param {string} employeeDocId
 * @param {(Date|number)} now
 * @param {?Object=} logger
 * @return {!Promise<!Array<!Object>>}
 */
async function fetchEmployeeWidgetWindow(db, employeeDocId, now, logger) {
  try {
    const startMs = torontoDayStartMs(now);
    const start = new Date(startMs);
    const end = new Date(startMs + WIDGET_LOOKAHEAD_DAYS * DAY_MS);
    const snap = await db
        .collection("appointments")
        .where("employeeIds", "array-contains", employeeDocId)
        .where("endTime", ">=", start)
        .where("startTime", "<", end)
        .limit(WIDGET_WINDOW_MAX)
        .get();
    const docs = (snap && snap.docs) || [];
    if (docs.length >= WIDGET_WINDOW_MAX && logger) {
      // Same posture as TRAVEL_SWEEP_MAX / OVERDUE_SWEEP_MAX / DIGEST_SWEEP_MAX
      // beside it: this was the one sweep read left with no ceiling, and a
      // silent truncation here ships a PARTIAL home-screen widget payload.
      logger.warn("widget: window hit the scan cap", {
        employeeDocId,
        cap: WIDGET_WINDOW_MAX,
      });
    }
    return docs.map(_record);
  } catch (err) {
    if (logger) {
      logger.warn("widget: window query failed", {employeeDocId, err});
    }
    return [];
  }
}

/**
 * Ends any live card for a job that hit a terminal transition (done, cancelled,
 * deleted, or unassigned).
 * @param {string} id appointment doc id.
 * @param {?Object} before
 * @param {?Object} after
 * @param {!Object} deps
 * @param {!Date} now
 * @return {!Promise<void>}
 */
async function endCardOnTerminal(id, before, after, deps, now) {
  const statusOf = (d) => (d || {}).status;
  const targets = new Set();
  if (before && !after) {
    for (const e of toIdList(before.employeeIds)) targets.add(e);
  } else if (before && after) {
    // Through the shared owners rather than a literal "done": this tested `===
    // "done"` and so left the card running forever on a flip to the legacy
    // `completed` alias.
    const becameDone = !isCompletedStatus(statusOf(before)) &&
        isCompletedStatus(statusOf(after));
    const becameCancelled = !isCancelledStatus(statusOf(before)) &&
        isCancelledStatus(statusOf(after));
    if (becameDone || becameCancelled) {
      // Union both sides, since one save can change status and assignees at the
      // same time.
      for (const e of toIdList(before.employeeIds)) targets.add(e);
      for (const e of toIdList(after.employeeIds)) targets.add(e);
    } else {
      // Unassigned mid-flight.
      const kept = new Set(toIdList(after.employeeIds));
      for (const e of toIdList(before.employeeIds)) {
        if (!kept.has(e)) targets.add(e);
      }
    }
  }
  if (targets.size === 0) return;
  const src = after || before || {};
  for (const employeeDocId of targets) {
    try {
      await endLiveActivity(deps, {
        appointmentId: String(id),
        employeeDocId,
        ctx: liveActivityCtx(src),
        nowDate: now,
      });
    } catch (err) {
      if (deps.logger) {
        deps.logger.warn("liveActivity: end-on-terminal failed",
            {id, employeeDocId, err});
      }
    }
  }
}

/**
 * Orchestrates an appointment write: diff, then a per-employee localized send.
 * @param {string} id appointment doc id.
 * @param {?Object} before
 * @param {?Object} after
 * @param {!Object} deps
 * @return {!Promise<{events: number, sent: number}>}
 */
async function handleAppointmentWrite(id, before, after, deps) {
  const now = deps.now || new Date();
  // Every terminal transition ends the card here, server-side and
  // unconditionally.
  await endCardOnTerminal(id, before, after, deps, now);
  // Tell the dispatcher the work happened.
  await notifyAdminsOfCompletion(id, before, after, deps);
  // The job time record, same posture and same position as the completion
  // notice: best-effort, never throwing, and above the events early-return
  // because it produces no crew-facing event.
  await stampLifecycle(id, before, after, deps);
  const events = diffAppointmentForNotifications(before, after, now, id);
  if (events.length === 0) return {events: 0, sent: 0};
  let sent = 0;
  // A repeat-series batch rewrites up to ~15 sibling docs, each firing this
  // trigger, so without a claim one delete/reschedule would send ~15 pushes.
  const seriesId = String(((after || before) || {}).seriesId || "");
  // A fresh op-id is only trustworthy on a write, since after.seriesOpId was
  // minted by this operation.
  const freshOpId = after ? String(after.seriesOpId || "") : "";
  // One window read per distinct employee across this write's events.
  const windows = new Map();
  // One user + tokens read per distinct employee across this write's events —
  // the same per-sweep cache runOverduePromptSweep and the travel sweep use.
  const recipients = new Map();
  for (const {employeeDocId, kind} of events) {
    const ctx = _contextFor(kind, before, after);
    // A reschedule refreshes an existing Lock Screen card.
    if (kind === "rescheduled") {
      await updateLiveActivity(deps, {
        appointmentId: String(id),
        employeeDocId,
        // Spread, not a hand-picked field list: liveActivityCtx field-picks
        // already, and re-listing here reintroduces the silent-drop the helper
        // exists to prevent.
        ctx: liveActivityCtx(
            {...ctx, endTime: (after || before || {}).endTime}),
        nowDate: now,
      });
    }
    // Eligibility FIRST, and deliberately above the series claim as well as the
    // widget window: change-driven pushes are employees-only
    // (CHANGE_RECIPIENT_ROLES), so an assigned ADMIN — or anyone with no live
    // token — used to pay a widget-window query, a users read, a tokens read
    // and, in a series, a claim-ledger WRITE, for a push `sendToEmployee` then
    // refused at its role gate.
    try {
      const recipient = await _loadRecipient(deps, employeeDocId, recipients);
      if (!_canReachRecipient(recipient, CHANGE_RECIPIENT_ROLES)) continue;
      if (seriesId !== "") {
        const mine = await claimSeriesNotice(deps, {
          seriesId, seriesOpId: freshOpId, kind, employeeDocId, nowDate: now,
        });
        // A sibling in this same batch already claimed it and will send the
        // push for the series — the card was already refreshed per-occurrence
        // above.
        if (!mine) continue;
      }
      const data = {appointmentId: String(id), kind};
      if (!windows.has(employeeDocId)) {
        windows.set(
            employeeDocId,
            await fetchEmployeeWidgetWindow(
                deps.db, employeeDocId, now, deps.logger),
        );
      }
      const records = windows.get(employeeDocId);
      const delivered = await sendToEmployee(
          deps,
          employeeDocId,
          data,
          (locale) => buildNotificationMessage(kind, ctx, locale),
          CHANGE_RECIPIENT_ROLES,
          recipients,
          (locale) => ({
            widgetPayload: JSON.stringify(
                buildWidgetPayload(records, now, locale)),
          }),
      );
      sent += delivered;
    } catch (err) {
      if (deps.logger) {
        deps.logger.warn("appointment-write: recipient failed",
            {id: String(id), employeeDocId, kind, err});
      }
    }
  }
  return {events: events.length, sent};
}

/**
 * Claim, send, then release for one (occurrence, recipient) pair, via a
 * per-recipient ledger doc.
 * @param {!Object} deps `{db, messaging, now, logger}`.
 * @param {!Object} opts
 * @return {!Promise<number>}
 */
async function _deliverRecipientOnce(deps, opts) {
  const {db, logger} = deps;
  const {collection, ledgerId, appointmentId, employeeDocId, kind, buildMsg,
    nowDate, label, roles, cache} = opts;
  // Reachability BEFORE the claim, the same order [handleAppointmentWrite] and
  // the digest use.
  try {
    const recipient = await _loadRecipient(deps, employeeDocId, cache);
    if (!_canReachRecipient(recipient, roles)) return 0;
  } catch (err) {
    // This read used to sit inside `sendToEmployee`, under the catch below, so
    // a transient failure must still not abort the sweep for the remaining
    // recipients — and returning 0 unclaimed is what the release branch would
    // have left behind anyway.
    if (logger) {
      logger.warn(`${label}: recipient load failed`, {id: appointmentId, err});
    }
    return 0;
  }
  let ledgerRef;
  try {
    // Built INSIDE the try: .doc() throws synchronously on an id containing
    // "/", and rules only length-check employeeIds (they can't iterate a list),
    // so one poisoned element would otherwise kill the whole sweep.
    ledgerRef = db.collection(collection).doc(ledgerId);
    // create() fails if the doc exists -> fires at most once per recipient.
    await ledgerRef.create(ledgerBody(nowDate));
  } catch (err) {
    if (isAlreadyExists(err)) return 0;
    if (logger) {
      logger.warn(`${label}: ledger create failed`, {id: appointmentId, err});
    }
    return 0;
  }
  let sent = 0;
  try {
    sent = await sendToEmployee(
        deps,
        employeeDocId,
        {appointmentId, kind},
        buildMsg,
        roles,
        cache,
    );
  } catch (err) {
    // A transient send failure must not abort the sweep for the remaining
    // recipients/candidates.
    if (logger) logger.warn(`${label}: send failed`, {id: appointmentId, err});
  }
  if (sent === 0) {
    try {
      await ledgerRef.delete();
    } catch (err) {
      if (logger) {
        logger.warn(
            `${label}: ledger release failed`, {id: appointmentId, err});
      }
    }
  }
  return sent;
}

/** DELETE-fallback window (see [claimSeriesNotice]). */
const SERIES_CLAIM_WINDOW_MS = 45 * 1000;

const SERIES_CLAIM_COLLECTION = "appointmentSeriesNotices";

/**
 * Claims the right to notify `employeeDocId` about `kind` for one repeat-series
 * operation (first writer wins) so a batch rewriting N occurrences sends one
 * push instead of N — needed because `diffAppointmentForNotifications`'s
 * CREATE-only anchor dedupe can't cover delete/cancel/reschedule, where the
 * anchor doc is often absent from the batch.
 * @param {!Object} deps `{db, logger}`.
 * @param {{seriesId: string, seriesOpId: string, kind: string,
 * employeeDocId: string, nowDate: !Date}} opts `seriesOpId` is `""` for a
 * delete (fallback path).
 * @return {!Promise<boolean>} True when this invocation should send.
 */
async function claimSeriesNotice(deps, opts) {
  const {db, logger} = deps;
  const {seriesId, seriesOpId, kind, employeeDocId, nowDate} = opts;
  const nowMs = nowMillis(nowDate);
  let ref;
  try {
    // Built inside the try because `.doc()` throws synchronously on an id
    // containing "/", and seriesId's contents aren't constrained.
    const docId = seriesOpId !== "" ?
      `op_${seriesOpId}_${kind}_${employeeDocId}` :
      `${seriesId}_${kind}_${employeeDocId}`;
    ref = db.collection(SERIES_CLAIM_COLLECTION).doc(docId);
    await ref.create(ledgerBody(nowDate));
    return true;
  } catch (err) {
    if (!isAlreadyExists(err)) {
      if (logger) {
        logger.warn("series claim failed; sending anyway",
            {seriesId, kind, err});
      }
      return true;
    }
    // A claim already exists. With a fresh op-id that's definitive — only a
    // sibling of this batch could have written it — so we suppress the send
    // with no time window needed.
    if (seriesOpId !== "") return false;
  }
  // Fallback path, for deletes: take over a claim older than the window so a
  // later, genuinely separate delete still notifies.
  try {
    const snap = await ref.get();
    const createdMs = toMillis(snap.get("createdAt"));
    // A null createdMs means the doc vanished or carries no usable timestamp —
    // the opposite of a live claim — so we take it over and send.
    if (createdMs != null && nowMs - createdMs < SERIES_CLAIM_WINDOW_MS) {
      return false;
    }
    await ref.set(ledgerBody(nowDate));
    return true;
  } catch (err) {
    if (logger) {
      logger.warn("series claim refresh failed; sending anyway",
          {seriesId, kind, err});
    }
    return true;
  }
}

/**
 * Orchestrates the overdue "job finished?" sweep.
 * @param {!Object} deps
 * @return {!Promise<{prompted: number}>}
 */
async function runOverduePromptSweep(deps) {
  const {db, now} = deps;
  const nowDate = now || new Date();
  const nowMs = nowMillis(nowDate);
  const windowStart = new Date(nowMs - OVERDUE_LOOKBACK_MS);
  // Bounds mirror selectOverdueCandidates EXACTLY — `> floor`, `<= now` — so
  // the query is the rule rather than a superset of it.
  const candidates = selectOverdueCandidates(
      await scanAppointmentWindow(db, {
        statuses: OPEN_STATUSES,
        field: "endTime",
        lo: windowStart,
        loOp: ">",
        hi: nowDate,
        hiOp: "<=",
        descending: true,
        cap: OVERDUE_SWEEP_MAX,
        logger: deps.logger,
        label: "runOverduePromptSweep",
        consequence: "oldest jobs deferred to a later run",
      }),
      nowDate,
  );
  const cache = new Map();
  // One flat list of (candidate, assignee) pairs, delivered concurrently.
  const deliveries = [];
  for (const c of candidates) {
    const endMs = toMillis(c.endTime);
    const ctx = _contextFor("doneCheck", null, c);
    for (const employeeDocId of toIdList(c.employeeIds)) {
      deliveries.push({c, endMs, ctx, employeeDocId});
    }
  }
  const results = await Promise.all(deliveries.map(
      ({c, endMs, ctx, employeeDocId}) => _deliverRecipientOnce(deps, {
        collection: "appointmentOverduePrompts",
        ledgerId: overduePromptLedgerId(String(c.id), endMs, employeeDocId),
        appointmentId: String(c.id),
        employeeDocId,
        kind: "doneCheck",
        buildMsg: (locale) =>
          buildNotificationMessage("doneCheck", ctx, locale),
        nowDate,
        label: "overdue",
        roles: TIMED_RECIPIENT_ROLES,
        cache,
      }),
  ));
  // Count recipients actually prompted — a job with N assignees can prompt up
  // to N of them.
  const prompted = results.filter((delivered) => delivered > 0).length;
  return {prompted};
}

/**
 * Orchestrates the nightly digest.
 * @param {!Object} deps
 * @return {!Promise<{digests: number}>}
 */
async function runDailyDigest(deps) {
  const {db, now} = deps;
  const nowDate = now || new Date();
  const {start, end} = tomorrowWindowToronto(nowDate);
  // Widened by the max span: the query filters on startTime, so a run that
  // began days ago but is still on site tomorrow is only fetched if the floor
  // reaches back that far.
  const queryStart = new Date(start.getTime() - MAX_APPOINTMENT_SPAN_MS);
  // Bounded like the travel and overdue sweeps beside it — this was the last
  // one without a ceiling.
  const window = await scanAppointmentWindow(db, {
    statuses: OPEN_STATUSES,
    field: "startTime",
    lo: queryStart,
    loOp: ">=",
    hi: end,
    hiOp: "<",
    descending: true,
    cap: DIGEST_SWEEP_MAX,
    logger: deps.logger,
    label: "runDailyDigest",
    consequence: "some crews may not receive a digest",
  });
  // Back to ascending before grouping, so the per-employee job lists the digest
  // text renders stay in chronological order.
  const grouped = groupTomorrowsJobsByEmployee(window.reverse(), nowDate);
  const cache = new Map();
  // Concurrent per employee — see the note in runOverduePromptSweep.
  const sends = Object.keys(grouped)
      .filter((id) => grouped[id] && grouped[id].length > 0)
      .map(async (employeeDocId) => {
        const jobs = grouped[employeeDocId];
        try {
          // Reachability BEFORE the widget-window query, the order
          // [handleAppointmentWrite] already establishes: an inactive, wrong-
          // role or tokenless employee costs a 200-doc read and a whole payload
          // build/JSON encode, every day, for a send that returns 0.
          const recipient = await _loadRecipient(deps, employeeDocId, cache);
          if (!_canReachRecipient(recipient, TIMED_RECIPIENT_ROLES)) return 0;
          // The 18:00 digest also carries a fresh widget payload (+ content-
          // available) so the home-screen widget rolls forward to tomorrow with
          // the app closed, matching the digest text.
          const records = await fetchEmployeeWidgetWindow(
              db, employeeDocId, nowDate, deps.logger,
          );
          return await sendToEmployee(
              deps,
              employeeDocId,
              {kind: "digest"},
              (locale) => buildDigestMessage(jobs, locale),
              TIMED_RECIPIENT_ROLES,
              cache,
              (locale) => ({
                widgetPayload: JSON.stringify(
                    buildWidgetPayload(records, nowDate, locale)),
              }),
          );
        } catch (err) {
          // A transient read/send failure must not abort the digest for the
          // remaining employees.
          if (deps.logger) {
            deps.logger.warn("digest: send failed", {id: employeeDocId, err});
          }
          return 0;
        }
      });
  const sentCounts = await Promise.all(sends);
  const digests = sentCounts.filter((sent) => sent > 0).length;
  return {digests};
}

/**
 * On the business-local last day of the month, tells the admins who opted in
 * how many jobs ended without being closed.
 * @param {!Object} deps `{db, messaging, logger, now}`.
 * @param {{sendToEmployee: (!Function|undefined)}=} opts Test injection only.
 * @return {!Promise<{count: number, recipients: number}>}
 */
async function runMonthEndOverdueReview(deps, opts) {
  const {db, now, logger} = deps;
  const nowDate = now || new Date();
  if (!isLastDayOfBusinessMonth(nowDate)) return {count: 0, recipients: 0};
  const window = await scanAppointmentWindow(db, {
    statuses: OPEN_STATUSES,
    field: "endTime",
    lo: new Date(0),
    loOp: ">",
    hi: nowDate,
    hiOp: "<=",
    descending: true,
    cap: MONTH_END_SCAN_MAX,
    logger,
    label: "runMonthEndOverdueReview",
    consequence: "the month-end push reports N+ rather than the true count",
  });
  const found = selectMonthEndOverdue(window, nowDate).length;
  if (found === 0) return {count: 0, recipients: 0};
  const count = Math.min(found, MONTH_END_REVIEW_MAX);
  const capped =
    window.length >= MONTH_END_SCAN_MAX || found >= MONTH_END_REVIEW_MAX;
  const recipients = await sendToActiveAdmins(
      deps,
      {kind: "overdueReview", count: capped ? `${count}+` : String(count)},
      (locale) => buildOverdueReviewMessage(count, capped, nowDate, locale),
      {
        includeUser: (user) => user.monthEndReviewPush === true,
        sendToEmployee: (opts || {}).sendToEmployee,
      },
  );
  if (logger) logger.info("monthEndReview: sent", {count, recipients});
  return {count, recipients};
}

/**
 * Pushes "Marc finished Leak fix" to every active admin who is not on the job.
 * @param {string} id appointment doc id.
 * @param {?Object} before
 * @param {?Object} after
 * @param {!Object} deps `{db, messaging, logger}`.
 * @return {!Promise<void>}
 */
async function notifyAdminsOfCompletion(id, before, after, deps) {
  if (!isCrewCompletion(before, after)) return;
  try {
    const assignees = new Set(toIdList(after.employeeIds));
    const what = String(after.clientName || after.title || "").trim();
    // The crew member's name off the denormalized list, so this costs no read.
    const names = Array.isArray(after.employeeNames) ? after.employeeNames : [];
    const who = String(names.length === 1 ? names[0] || "" : "").trim();

    const snap = await deps.db.collection("users")
        .where("role", "==", "admin")
        .where("status", "==", "active")
        .limit(ADMIN_FANOUT_MAX)
        .get();
    const cache = new Map(snap.docs.map(
        (doc) => [doc.id, {user: doc.data() || {}, tokenDocs: null}]));
    await Promise.all(snap.docs
        .filter((doc) => !assignees.has(doc.id))
        .map((doc) => sendToEmployee(
            deps,
            doc.id,
            {kind: "jobCompleted", appointmentId: String(id)},
            (locale) => buildJobCompletedMessage(who, what, locale),
            ADMIN_RECIPIENT_ROLES,
            cache,
        ).catch(() => {})));
  } catch (e) {
    if (deps.logger) {
      deps.logger.warn("notifyAdminsOfCompletion failed",
          {appointmentId: String(id), err: String(e)});
    }
  }
}

/**
 * Ceiling on one admin fan-out, with the warn-at-cap posture the three sweep
 * ceilings use.
 */
const ADMIN_FANOUT_MAX = 100;

/**
 * Applies the `startedAt`/`completedAt` stamps `lifecycleStamps` decides for
 * this write — the ONE owner of the job time record.
 * @param {string} id appointment doc id.
 * @param {?Object} before
 * @param {?Object} after
 * @param {!Object} deps `{db, logger, now}`.
 * @return {!Promise<void>}
 */
async function stampLifecycle(id, before, after, deps) {
  const stamps = lifecycleStamps(before, after, deps.now || new Date());
  if (Object.keys(stamps).length === 0) return;
  try {
    await deps.db.collection("appointments").doc(String(id)).update(stamps);
  } catch (e) {
    if (deps.logger) {
      deps.logger.warn("stampLifecycle failed",
          {appointmentId: String(id), err: String(e)});
    }
  }
}

/**
 * Pushes one localized message to every ACTIVE ADMIN.
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {!Object} data Data payload (string values); `kind` etc.
 * @param {function(string): {title: string, body: string}} buildMsg Localized
 * message builder keyed by 'en'|'fr'.
 * @param {{excludeDocId: (string|undefined),
 * includeUser: (function(!Object): boolean|undefined),
 * sendToEmployee: (!Function|undefined)}=} opts `excludeDocId` skips
 * the person who caused the notice — they do not need telling what they just
 * did. `includeUser` narrows the already-read admin docs with no new query.
 * `sendToEmployee` is injectable for tests only.
 * @return {!Promise<number>} Admins targeted after filtering.
 */
async function sendToActiveAdmins(deps, data, buildMsg, opts) {
  const {db, logger} = deps;
  const options = opts || {};
  const send = options.sendToEmployee || sendToEmployee;
  const include = options.includeUser || (() => true);
  try {
    const snap = await db.collection("users")
        .where("role", "==", "admin")
        .where("status", "==", "active")
        .limit(ADMIN_FANOUT_MAX)
        .get();
    if (snap && snap.size === ADMIN_FANOUT_MAX && logger) {
      logger.warn(
          "sendToActiveAdmins: recipient cap hit; " +
          "some admins were not notified", {cap: ADMIN_FANOUT_MAX});
    }
    // Seeds the recipient cache from the docs just read, so `_loadRecipient`
    // doesn't re-`get()` a users doc already in hand — that was +1 redundant
    // read per active admin per notice.
    const cache = new Map(snap.docs.map(
        (doc) => [doc.id, {user: doc.data() || {}, tokenDocs: null}]));
    const targets = snap.docs
        .filter((doc) => doc.id !== options.excludeDocId)
        .filter((doc) => include(doc.data() || {}));
    await Promise.all(targets
        .map((doc) => send(
            deps, doc.id, data, buildMsg, ADMIN_RECIPIENT_ROLES, cache,
        ).catch((e) => {
          if (logger) {
            logger.warn("sendToActiveAdmins: recipient failed",
                {docId: doc.id, err: String(e)});
          }
        })));
    return targets.length;
  } catch (e) {
    if (logger) {
      logger.warn("sendToActiveAdmins: fan-out failed", {err: String(e)});
    }
    return 0;
  }
}

module.exports = {
  // Every notification_policy symbol is re-exported here under its original
  // name, so a call site never has to know which of the two modules a pure rule
  // ended up in.
  DAY_MS,
  OVERDUE_LOOKBACK_MS,
  OVERDUE_SWEEP_MAX,
  DIGEST_SWEEP_MAX,
  MONTH_END_REVIEW_MAX,
  MONTH_END_SCAN_MAX,
  WIDGET_PAYLOAD_MAX_BYTES,
  OPEN_STATUSES,
  CHANGE_RECIPIENT_ROLES,
  TIMED_RECIPIENT_ROLES,
  ADMIN_RECIPIENT_ROLES,
  ADMIN_FANOUT_MAX,
  ledgerBody,
  isAlreadyExists,
  isCrewCompletion,
  recordOf: _record,
  contextFor: _contextFor,
  SERIES_CLAIM_WINDOW_MS,
  toMillis,
  nowMillis,
  toIdList,
  diffAppointmentForNotifications,
  buildNotificationMessage,
  buildDigestMessage,
  selectOverdueCandidates,
  isLastDayOfBusinessMonth,
  selectMonthEndOverdue,
  buildOverdueReviewMessage,
  groupTomorrowsJobsByEmployee,
  tomorrowWindowToronto,
  overduePromptLedgerId,
  isStaleTokenError,
  // The one owner of "push to an employee's live tokens" — token fetch, role +
  // active gate, and stale-token pruning.
  sendToEmployee,
  sendToActiveAdmins,
  notifyAdminsOfCompletion,
  stampLifecycle,
  lifecycleStamps,
  deliverRecipientOnce: _deliverRecipientOnce,
  handleAppointmentWrite,
  runDailyDigest,
  runMonthEndOverdueReview,
  runOverduePromptSweep,
};
