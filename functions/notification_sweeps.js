"use strict";

/**
 * @fileoverview The three scheduled push sweeps (overdue prompt, nightly
 * digest, month-end review), split out of notification_utils.js. They take
 * injected
 * `{db, messaging, now, logger}` like the delivery core they call into.
 * @module notification_sweeps
 */

const {buildWidgetPayload} = require("./widget_payload_utils");
const {toMillis, MAX_APPOINTMENT_SPAN_MS} = require("./time_utils");
const {
  buildNotificationMessage,
  buildDigestMessage,
  buildOverdueReviewMessage,
} = require("./notification_messages");
const {
  OVERDUE_LOOKBACK_MS,
  OVERDUE_SWEEP_MAX,
  DIGEST_SWEEP_MAX,
  MONTH_END_REVIEW_MAX,
  MONTH_END_SCAN_MAX,
  OPEN_STATUSES,
  TIMED_RECIPIENT_ROLES,
  toIdList,
  nowMillis,
  selectOverdueCandidates,
  isLastDayOfBusinessMonth,
  selectMonthEndOverdue,
  groupTomorrowsJobsByEmployee,
  tomorrowWindowToronto,
  overduePromptLedgerId,
  contextFor: _contextFor,
} = require("./notification_policy");
const {scanAppointmentWindow} = require("./appointment_scan");
const {
  sendToEmployee,
  sendToActiveAdmins,
  deliverRecipientOnce,
  loadRecipient: _loadRecipient,
  canReachRecipient: _canReachRecipient,
  fetchEmployeeWidgetWindow,
} = require("./notification_utils");

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
      ({c, endMs, ctx, employeeDocId}) => deliverRecipientOnce(deps, {
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

module.exports = {
  runOverduePromptSweep,
  runDailyDigest,
  runMonthEndOverdueReview,
};
