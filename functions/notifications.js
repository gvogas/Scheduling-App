"use strict";

/**
 * @fileoverview Push-notification trigger registrations (thin wrappers). All
 * logic lives in notification_utils.js, driven here with the real Firestore +
 * Messaging so notification_utils.js stays require()-able by jest without a
 * Storage/scheduler bucket resolving at load.
 *
 * @module notifications
 */

const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

const {
  handleAppointmentWrite,
  runDailyDigest,
  runMonthEndOverdueReview,
  runOverduePromptSweep,
} = require("./notification_utils");
const {runTravelAwareReminderSweep} = require("./travel_utils");
// The one owner of the business time zone. Never re-inline the literal here:
// these are the only three Cloud Scheduler jobs left, so a bare string would
// silently split every scheduled run from every time the app renders.
const {BUSINESS_TIME_ZONE} = require("./time_utils");
const {
  pruneExpiredActivityTokens,
  pruneExpiredCardMarkers,
} = require("./live_activity_registry");
const {
  GOOGLE_MAP_API_KEY,
  APNS_AUTH_KEY,
  APNS_KEY_ID,
  APNS_TEAM_ID,
} = require("./params");
// Rider 3 on the daily digest — see sendDailyJobDigest.
// `WAVE_FULL_ACCESS_TOKEN` comes from wave/auth.js rather than params.js
// because the Wave module owns it; a secret may only be defined once, so
// never re-`defineSecret` it here.
const {WAVE_FULL_ACCESS_TOKEN} = require("./wave/auth");
const {runWaveDaily} = require("./wave/triggers");

/**
 * Real injected deps for the orchestration functions. Carries NO APNs
 * credentials — a function that doesn't bind the secrets must not read them.
 * @return {{db: !Object, messaging: !Object, now: !Date, logger: !Object}}
 */
function liveDeps() {
  return {
    db: getFirestore(),
    messaging: getMessaging(),
    now: new Date(),
    logger,
  };
}

/**
 * [liveDeps] plus the APNs credentials, for the two functions that bind
 * [APNS_SECRETS] and actually push Live Activity cards.
 * @return {!Object}
 */
function liveActivityDeps() {
  return {...liveDeps(), apnsAuth: apnsAuth()};
}

/**
 * APNs provider credentials for the Live Activity path, or null when the
 * secrets aren't bound — every Live Activity verb just no-ops in that case.
 * Read lazily since `.value()` throws outside a secret-bound invocation.
 * @return {?{authKey: string, keyId: string, teamId: string}}
 */
function apnsAuth() {
  try {
    const authKey = APNS_AUTH_KEY.value();
    const keyId = APNS_KEY_ID.value();
    const teamId = APNS_TEAM_ID.value();
    if (!authKey || !keyId || !teamId) return null;
    return {authKey, keyId: keyId.trim(), teamId: teamId.trim()};
  } catch (err) {
    return null;
  }
}

// Secrets every Live-Activity-capable function must bind.
const APNS_SECRETS = [APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID];

// Assignment / reschedule / cancel / removal alerts. No `retry: true` — a
// duplicate push is worse than a rare missed one.
const notifyAppointmentChanges = onDocumentWritten(
    {
      document: "appointments/{appointmentId}",
      // Bound for the Live Activity update/end hooks in handleAppointmentWrite.
      secrets: APNS_SECRETS,
    },
    async (event) => {
      const before = event.data?.before?.exists ?
        event.data.before.data() : null;
      const after = event.data?.after?.exists ?
        event.data.after.data() : null;
      if (!before && !after) return;
      await handleAppointmentWrite(
          event.params.appointmentId,
          before,
          after,
          liveActivityDeps(),
      );
    },
);

// The 5-minute sweep. It carries BOTH timed push sweeps:
//
//   1. Travel-aware "time to leave" reminders. Drive time comes from the
//      Routes API, and every failure path degrades to a fixed 30-min
//      reminder. A per-recipient ledger makes sure each occurrence fires
//      exactly once, and a missed run just self-heals on the next sweep.
//   2. The overdue "job finished?" prompts, which used to be their own
//      `every 15 minutes` scheduler (`sendOverdueJobPrompts`, deleted
//      2026-08-13).
//
// **The merge is a COST change, not a behaviour change.** Cloud Scheduler
// bills per job beyond the first three, and this repo had six; folding the
// overdue sweep in here is one of the two merges that brought it to three, so
// the whole schedule is inside the free allowance. Running the overdue sweep
// three times as often is free of side effects because its per-recipient
// ledger (`appointmentOverduePrompts/{id}_{endMs}_{employeeDocId}`,
// create-fails-if-exists) is what guarantees at-most-once delivery — the
// cadence never did. It is also now genuinely cheap: since it began querying
// `endTime` over a 24 h window rather than `startTime` over ~15 days, a run
// reads the handful of jobs that actually just ended.
//
// The two sweeps are isolated from each other. The reminder half calls a
// billable Google Routes API and the overdue half is Firestore-only; a throw
// in either must not skip the other, exactly as the digest isolates its TTL
// prune. `timeoutSeconds` covers both, so it takes the larger of the two
// budgets the separate functions had (120 and 300) plus headroom.
const sendUpcomingJobReminders = onSchedule(
    {
      schedule: "every 5 minutes",
      timeZone: BUSINESS_TIME_ZONE,
      maxInstances: 1,
      secrets: [GOOGLE_MAP_API_KEY, ...APNS_SECRETS],
      // Pairs run concurrently, each with up to one Routes round-trip; the
      // overdue sweep then runs its own (job, assignee) fan-out.
      timeoutSeconds: 420,
    },
    async () => {
      try {
        await runTravelAwareReminderSweep({
          ...liveActivityDeps(),
          fetchImpl: fetch,
          apiKey: GOOGLE_MAP_API_KEY.value().trim(),
        });
      } catch (err) {
        // Log rather than rethrow — the next 5-min run self-heals anyway.
        logger.error("sendUpcomingJobReminders failed", {err});
      }

      // Rides this schedule rather than owning a fourth timer. `liveDeps()`,
      // not `liveActivityDeps()`: this half is Firestore-only and must not
      // read the APNs secrets, matching what the deleted standalone function
      // used.
      try {
        await runOverduePromptSweep(liveDeps());
      } catch (err) {
        // Deliberately still the DELETED export's name: it is a stable
        // Crashlytics search tag, and renaming it orphans every prior report
        // of this failure. The function is gone; the label is the label.
        logger.error("sendOverdueJobPrompts failed", {err});
      }
    },
);

// THE daily job, 18:00 America/Toronto. It is the digest plus two riders, and
// they run strictly in that order because only the first is time-sensitive:
//
//   1. The digest — one push per employee with >=1 job tomorrow. No ledger; it
//      runs once daily, so we accept the occasional rare duplicate.
//   2. The Live Activity TTL prune.
//   3. The month-end overdue review — last day of the month only, above Wave.
//   4. The daily Wave maintenance — drain the outbox, import if the cadence is
//      due. This was `waveScheduledImport`, its own `every 24 hours` timer,
//      until 2026-08-13.
//
// **The riders are a COST decision.** Cloud Scheduler bills per job beyond the
// first three and this repo had six; folding Wave in here is one of the two
// merges that brought it to three, i.e. inside the free allowance. The TTL
// prune had already established the pattern.
//
// EACH RIDER IS ISOLATED IN ITS OWN try/catch, and that is the whole safety
// argument for merging: the digest has already sent by the time any runs,
// so none can affect the push, and none can skip another. Add a fifth rider
// the same way — never above the digest, never sharing a try.
//
// `timeoutSeconds` now has to cover all four (the Wave import is ~650
// customers over ~7 pages and carried 540 s on its own), and the function
// binds `WAVE_FULL_ACCESS_TOKEN` because rider 4 pushes to Wave.
const sendDailyJobDigest = onSchedule(
    {
      schedule: "0 18 * * *",
      timeZone: BUSINESS_TIME_ZONE,
      maxInstances: 1,
      secrets: [WAVE_FULL_ACCESS_TOKEN],
      timeoutSeconds: 540,
    },
    async () => {
      const deps = liveDeps();
      try {
        await runDailyDigest(deps);
      } catch (err) {
        // Log rather than rethrow, matching the reminder sweep: the digest
        // fans out with Promise.all, so one bad appointment rejecting the
        // batch must not also skip the riders below it.
        logger.error("sendDailyJobDigest failed", {err});
      }
      try {
        const tokens = await pruneExpiredActivityTokens(deps);
        const cards = await pruneExpiredCardMarkers(deps);
        if (tokens.pruned > 0 || cards.pruned > 0) {
          logger.info("liveActivity: TTL prune", {
            tokens: tokens.pruned,
            cards: cards.pruned,
          });
        }
      } catch (err) {
        logger.warn("liveActivity: TTL prune failed", {err});
      }
      try {
        await runMonthEndOverdueReview(deps);
      } catch (err) {
        logger.warn("monthEndReview failed", {err});
      }
      try {
        await runWaveDaily();
      } catch (err) {
        // runWaveDaily catches internally; this is belt-and-braces so a
        // future edit there cannot take the digest's invocation down with it.
        logger.warn("runWaveDaily failed", {err});
      }
    },
);

module.exports = {
  notifyAppointmentChanges,
  sendUpcomingJobReminders,
  sendDailyJobDigest,
};
