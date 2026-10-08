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

const {handleAppointmentWrite} = require("./notification_utils");
const {
  runDailyDigest,
  runMonthEndOverdueReview,
  runOverduePromptSweep,
} = require("./notification_sweeps");
const {runTravelAwareReminderSweep} = require("./travel_utils");
// Sole owner of the business time zone; never re-inline the literal.
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
// WAVE_FULL_ACCESS_TOKEN is defined once in wave/auth.js; never re-define it.
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

// Assignment / reschedule / cancel / removal alerts; no retry (ADR-0103).
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

// 5-minute sweep: travel reminders then overdue prompts, isolated (ADR-0106).
const sendUpcomingJobReminders = onSchedule(
    {
      schedule: "every 5 minutes",
      timeZone: BUSINESS_TIME_ZONE,
      maxInstances: 1,
      secrets: [GOOGLE_MAP_API_KEY, ...APNS_SECRETS],
      // Covers both sweeps (ADR-0106).
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

      // liveDeps(): Firestore-only, so it must not read the APNs secrets.
      try {
        await runOverduePromptSweep(liveDeps());
      } catch (err) {
        // Label is the deleted export's name: a stable Crashlytics tag.
        logger.error("sendOverdueJobPrompts failed", {err});
      }
    },
);

// 18:00 digest plus riders, each in its own try below it (ADR-0106).
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
        // Log, don't rethrow: a rejected fan-out must not skip the riders.
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
        // Belt-and-braces: runWaveDaily already catches internally.
        logger.warn("runWaveDaily failed", {err});
      }
    },
);

module.exports = {
  notifyAppointmentChanges,
  sendUpcomingJobReminders,
  sendDailyJobDigest,
};
