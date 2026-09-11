const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

const {WAVE_FULL_ACCESS_TOKEN} = require("./auth");
const {whoami, listBusinesses} = require("./client");
const {
  drainQueue,
  countQueuedJobs,
  countDeadJobs,
  requeueDeadJobs,
  listOutstandingClientIds,
} = require("./worker");
const {classifyWaveError} = require("./errors");
const {SCHEDULE_SET} = require("./import_schedule");
// The sync-run primitives are shared with the `waveUpsertCustomer` trigger and
// the daily rider (`triggers.js`), so they live in their own module — these
// were hand-copied here once and the copies drifted.
const {
  readWaveBusinessId,
  readWaveConnection,
  connectionFieldsOf,
  importWithWatermark,
  drainForSync,
  SYNC_PUSH_BATCH_LIMIT,
  SYNC_PUSH_BUDGET_MS,
} = require("./sync_run");

const {
  assertAdminCall,
  enforceDurableRateLimit,
  shortHash,
} = require("../security");

// waveImportCustomers is a heavy one-shot admin op (~650 customers across ~7
// Wave pages), so a modest cap keeps a stuck/retried admin from hammering Wave.
const WAVE_IMPORT_RATE_MAX = 5;
const WAVE_IMPORT_RATE_WINDOW_MS = 60 * 60 * 1000;

// Cadence is a single enum field, so the cap is looser than the import's —
// generous enough that an admin toggling the picker never trips it.
const WAVE_SCHEDULE_RATE_MAX = 20;
const WAVE_SCHEDULE_RATE_WINDOW_MS = 60 * 60 * 1000;

// waveGetConnection is a read, but not a free one: it runs two count()
// aggregates on waveSyncQueue, which are billed per 1000 index entries. It was
// the one admin callable here with no durable cap, on the strength of a
// comment describing it as reading a single document — true when written, and
// not since the outbox counts were added. Sized well above the mount-and-
// refresh pattern Settings actually produces.
const WAVE_CONN_RATE_MAX = 60;
const WAVE_CONN_RATE_WINDOW_MS = 60 * 60 * 1000;
// Caps how many live Wave calls (whoami + listBusinesses) an admin can make.
// The already-connected short-circuit runs first and isn't rate-limited.
const WAVE_BOOTSTRAP_RATE_MAX = 10;

// The Wave business to connect, kept in Secret Manager so the name never
// ships in the app. waveBootstrap uses it whenever the client supplies no
// businessId/businessName.
const WAVE_BUSINESS_NAME = defineSecret("WAVE_BUSINESS_NAME");

// ----- Wave Accounting integration ------------------------------------------
//
// Wires the app's `clients` collection to Wave Accounting customers. The
// `wave/connection` doc holds the selected business id, `waveSyncQueue` is a
// durable outbox drained on a schedule, and these functions are just thin
// wrappers adding auth/admin/rate-limit guards around the `wave/*` modules.

/**
 * Selects the intended Wave business from the listed businesses — by name
 * when `wantName` is given, else the single business when exactly one exists,
 * never blindly taking the first of several.
 * @param {!Array<{id: string, name: string}>} businesses Listed businesses.
 * @param {string} wantName Configured business name ("" when not set).
 * @return {{id: string, name: string}} The selected business.
 * @throws {HttpsError} not-found when a given name has no match;
 *   failed-precondition when ambiguous (several businesses, no selector).
 */
function selectBusiness(businesses, wantName) {
  const list = Array.isArray(businesses) ? businesses : [];
  if (wantName) {
    // Name match is case-insensitive and whitespace-trimmed, so "acme co"
    // and "  Acme Co  " both match. Id match stays exact since ids are
    // opaque tokens.
    const want = wantName.trim().toLowerCase();
    // We guard `b.name` too — a business with no name would otherwise throw
    // a raw TypeError, which classifyWaveError would turn into a misleading
    // generic Wave failure instead of the intended wave/business-not-found.
    const match = list.find((b) => b && typeof b.name === "string" &&
        b.name.trim().toLowerCase() === want);
    if (!match) throw new HttpsError("not-found", "wave/business-not-found");
    return match;
  }
  if (list.length === 1) return list[0];
  throw new HttpsError("failed-precondition", "wave/business-ambiguous");
}

// waveBootstrap — admin-only, idempotent get-or-create of wave/connection.
const waveBootstrap = onCall(
    {
      secrets: [WAVE_FULL_ACCESS_TOKEN, WAVE_BUSINESS_NAME],
      enforceAppCheck: true,
    },
    async (req) => {
      const uid = await assertAdminCall(req, new Set());

      // Already-connected doc gets returned unchanged, so this call is safe
      // to make more than once.
      const {ref, businessId, businessName} = await readWaveConnection();
      if (businessId) {
        logger.info("WAVE-BOOT already connected",
            {uidHash: shortHash(uid), businessId});
        return {businessId, businessName};
      }

      // The target business is chosen server-side from the Secret Manager
      // value — the app never names it. The `|| ""` guards against an
      // unset/empty secret throwing on `.trim()`.
      const wantName = (WAVE_BUSINESS_NAME.value() || "").trim();

      // Only the not-yet-connected path (live Wave calls) is rate-limited.
      await enforceDurableRateLimit(
          "wave-bootstrap",
          uid,
          WAVE_BOOTSTRAP_RATE_MAX,
          WAVE_IMPORT_RATE_WINDOW_MS,
      );

      // Network calls run outside the transaction — transactions retry, and
      // a Wave mutation must never run twice. whoami() fast-fails a bad
      // token before we bother listing businesses.
      let selected;
      try {
        await whoami();
        const businesses = await listBusinesses();
        selected = selectBusiness(businesses, wantName);
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        const {code, message} = classifyWaveError(e);
        logger.warn("WAVE-BOOT failed",
            {uidHash: shortHash(uid), code, message});
        throw new HttpsError(code, message);
      }

      // Transaction set-if-absent so concurrent first calls converge on one
      // connection — the first writer wins, and later writers just return
      // its value.
      const result = await getFirestore().runTransaction(async (tx) => {
        const fresh = connectionFieldsOf(await tx.get(ref));
        if (fresh.businessId) {
          return {
            businessId: fresh.businessId,
            businessName: fresh.businessName,
          };
        }
        tx.set(ref, {
          businessId: selected.id,
          businessName: selected.name || "",
          bootstrappedAt: FieldValue.serverTimestamp(),
        });
        return {businessId: selected.id, businessName: selected.name || ""};
      });

      logger.info("WAVE-BOOT connected", {
        uidHash: shortHash(uid),
        businessId: result.businessId,
      });
      return result;
    },
);

const waveGetConnection = onCall(
    {enforceAppCheck: true},
    async (req) => {
      const uid = await assertAdminCall(req, new Set());
      await enforceDurableRateLimit(
          "wave-connection",
          uid,
          WAVE_CONN_RATE_MAX,
          WAVE_CONN_RATE_WINDOW_MS,
      );

      const {businessId, businessName, importSchedule} =
        await readWaveConnection();

      // Outbox depth, so Settings can say what is still waiting instead of
      // offering a Sync button over an invisible queue. Two `count()`
      // aggregates — billed per 1000 index entries, not per job.
      //
      // ADDITIVE fields: an older build parses this response by name and
      // ignores the rest, so adding to it is safe (the same contract the
      // two-way sync's five `pushed*` fields rely on).
      //
      // Best-effort and reported as `null`, never 0, when the read fails.
      // Zero means "the queue is empty", which is the one thing an admin
      // would act on by NOT pressing Sync — a failed read must not be able to
      // say that. Skipped entirely while disconnected: there is no queue to
      // describe and no reason to pay for two reads.
      let pendingCount = null;
      let failedCount = null;
      if (businessId) {
        try {
          [pendingCount, failedCount] = await Promise.all([
            countQueuedJobs(),
            countDeadJobs(),
          ]);
        } catch (e) {
          logger.warn("WAVE-CONN outbox count failed", {error: String(e)});
        }
      }

      return {
        connected: Boolean(businessId),
        businessId,
        businessName,
        importSchedule,
        pendingCount,
        failedCount,
      };
    },
);

// waveRetryFailedJobs — admin-only recovery for dead-lettered outbox jobs.
//
// A `dead` job is terminal: no drain picks it up again, so that client's data
// diverges from Wave permanently. Before this callable the only way back was
// editing the client again to mint a fresh job, which an admin would have to
// know to do — and would only think to do if they noticed the error badge.
//
// Deliberately a separate, explicit action rather than an automatic requeue:
// a job that died on a `WaveValidationError` will die again, so retrying on a
// timer would spin forever and re-report the same failure. The admin presses
// this once they have fixed the data or the outage has passed.
//
// Rate-limited like every other admin write callable. It drains afterwards so
// the press has a visible effect, best-effort — the requeue is the durable
// part and must be reported even if the push behind it fails.
const WAVE_RETRY_RATE_MAX = 10;
const WAVE_RETRY_RATE_WINDOW_MS = 60 * 60 * 1000;

const waveRetryFailedJobs = onCall(
    {enforceAppCheck: true, secrets: [WAVE_FULL_ACCESS_TOKEN]},
    async (req) => {
      const uid = await assertAdminCall(req, new Set());
      await enforceDurableRateLimit(
          "wave-retry", uid,
          WAVE_RETRY_RATE_MAX, WAVE_RETRY_RATE_WINDOW_MS);

      const businessId = await readWaveBusinessId();
      if (!businessId) {
        // Same state, same code as the other two connection gates. This threw
        // `wave/not-connected`, which no shipped Flutter mapper knows, so
        // "Retry failed" on a disconnected install read as a generic error.
        throw new HttpsError("failed-precondition", "wave/not-bootstrapped");
      }

      const {requeued, scanned, blocked} = await requeueDeadJobs();
      logger.info("WAVE-RETRY requeued dead jobs",
          {uidHash: shortHash(uid), requeued, scanned, blocked});

      // Push them now so the admin sees the result of the press rather than
      // waiting for their next client edit or the daily sweep. Best-effort:
      // the requeue already committed, and reporting it as a failure would be
      // wrong.
      //
      // `failed` is the whole reason this press can look broken. The shape
      // that dead-letters a job is usually non-retryable (Wave rejected the
      // customer's data), so the drain behind the requeue dead-letters it
      // AGAIN within the same call — the queue's dead count is unchanged and
      // the Settings row still reads "1 client failed to sync" while the app,
      // seeing only `requeued`, announced a success. Same null-is-unknown
      // contract as `pushed`: null means the drain threw or never ran, and the
      // app must not render that as "nothing failed".
      let pushed = null;
      let failed = null;
      if (requeued > 0) {
        try {
          const drained = await drainQueue({
            businessId,
            batchLimit: SYNC_PUSH_BATCH_LIMIT,
            deadlineMs: Date.now() + SYNC_PUSH_BUDGET_MS,
          });
          pushed = drained.done;
          failed = drained.dead;
        } catch (e) {
          logger.warn("WAVE-RETRY drain after requeue failed",
              {uidHash: shortHash(uid), error: String(e)});
        }
      }

      // `blocked` is additive and NOT a failure: those jobs were dropped
      // because the contract refuses their client, and the reason now sits on
      // the client where it can be fixed. Reporting them as `failed` would put
      // them back in a counter with no remedy, which is the experience this
      // whole phase removes.
      return {requeued, scanned, pushed, failed, blocked};
    },
);

// waveSetImportSchedule — admin-only setter for the auto-import cadence on
// the wave/connection doc. No secret, but rate-limited like every other admin
// write callable: defense-in-depth so a compromised admin session can't spin
// the doc. The limit sits AFTER the payload validation, so a burst of
// malformed submissions can't burn a legitimate caller's window.
const waveSetImportSchedule = onCall(
    {enforceAppCheck: true},
    async (req) => {
      const uid = await assertAdminCall(req, new Set(["schedule"]));

      // The VALUE check sits between the composed opening and the limiter, so
      // a burst of invalid cadences can't burn a legitimate admin's window.
      const schedule = req.data && req.data.schedule;
      if (typeof schedule !== "string" || !SCHEDULE_SET.has(schedule)) {
        throw new HttpsError("invalid-argument", "wave/invalid-schedule");
      }
      await enforceDurableRateLimit(
          "wave-schedule",
          uid,
          WAVE_SCHEDULE_RATE_MAX,
          WAVE_SCHEDULE_RATE_WINDOW_MS,
      );

      const {ref, businessId} = await readWaveConnection();
      if (!businessId) {
        throw new HttpsError("failed-precondition", "wave/not-bootstrapped");
      }

      await ref.update({importSchedule: schedule});
      logger.info("WAVE-SCHED set", {uidHash: shortHash(uid), schedule});
      return {schedule};
    },
);

// waveImportCustomers — admin-only two-way sync: push the outbox to Wave,
// then pull Wave customers back into `clients`.
//
// The name is inaccurate and stays anyway. It was first tagged #compat-1.37.1,
// but that tag was wrong about WHY: renaming a deployed callable deletes the
// old name, and EVERY shipped build calls this one — not just the 1.37.1 the
// shim was about. So retiring that shim (2026-08-08) did not unblock a rename,
// and a future one still needs the two-step: deploy the new name alongside,
// ship a build that calls it, then drop the old name once no build calls it.
// Same for wave_service.dart's caller.
const waveImportCustomers = onCall(
    {
      secrets: [WAVE_FULL_ACCESS_TOKEN],
      enforceAppCheck: true,
      timeoutSeconds: 300,
    },
    async (req) => {
      const uid = await assertAdminCall(req, new Set());
      await enforceDurableRateLimit(
          "wave-import",
          uid,
          WAVE_IMPORT_RATE_MAX,
          WAVE_IMPORT_RATE_WINDOW_MS,
      );

      const {ref: connectionRef, data, businessId} =
        await readWaveConnection();
      const connection = data || {};
      if (!businessId) {
        throw new HttpsError("failed-precondition", "wave/not-bootstrapped");
      }

      // Captured BEFORE any work: the watermark must cover everything edited
      // while this run was in flight, so it has to come from the start.
      const startedAtMs = Date.now();

      logger.info("WAVE-CUST sync starting",
          {uidHash: shortHash(uid), businessId});

      // Push BEFORE pulling. Local edits are the newer truth here — the
      // outbox holds writes the app already accepted — so importing first
      // would overwrite them with the Wave rows they are about to replace.
      const pushed = await drainForSync({businessId, uid});

      // Ordering is NOT sufficient on its own. The drain is bounded and only
      // takes jobs already due, so anything it left behind is still a live
      // local edit — and the import would overwrite it AND mark it synced.
      // Resolved after the drain so a job it completed isn't protected for
      // nothing. Best-effort: an empty set on failure means the import
      // behaves as it always did, which is the pre-existing risk, not a new
      // one — but it must be logged, since the cost is silent data loss.
      let skipClientIds = new Set();
      try {
        skipClientIds = await listOutstandingClientIds();
      } catch (e) {
        logger.error("WAVE-CUST outstanding-job read failed — import may " +
          "overwrite un-pushed client edits",
        {uidHash: shortHash(uid), error: String(e)});
      }

      let summary;
      let window;
      try {
        // Throwing leaves the watermark untouched, so the next run redoes
        // this window. Redoing is free (the import is idempotent); skipping
        // would drop every customer changed inside it, permanently.
        ({summary, window} = await importWithWatermark({
          connectionRef, connection, businessId, skipClientIds,
          nowMs: startedAtMs,
        }));
      } catch (e) {
        const {code, message} = classifyWaveError(e);
        logger.warn("WAVE-CUST import failed", {
          uidHash: shortHash(uid),
          code,
          message,
        });
        throw new HttpsError(code, message);
      }

      logger.info("WAVE-CUST sync done", {
        window: window.reason,
        uidHash: shortHash(uid),
        totalCount: summary.totalCount,
        imported: summary.imported,
        updated: summary.updated,
        skippedArchived: summary.skippedArchived,
        skippedPending: summary.skippedPending,
        skippedUnchanged: summary.skippedUnchanged,
        pages: summary.pages,
        delta: summary.delta,
        pushedCreated: pushed.created,
        pushedUpdated: pushed.updated,
        pushedPending: pushed.pending,
        pushedFailed: pushed.failed,
        pushIncomplete: pushed.incomplete,
      });
      // Additive fields only — the 1.37.1 build parses the import half of
      // this response by name and ignores the rest.
      return {
        ...summary,
        pushedCreated: pushed.created,
        pushedUpdated: pushed.updated,
        pushedPending: pushed.pending,
        pushedFailed: pushed.failed,
        pushIncomplete: pushed.incomplete,
      };
    },
);

module.exports = {
  selectBusiness,
  waveBootstrap,
  waveGetConnection,
  waveSetImportSchedule,
  waveImportCustomers,
  waveRetryFailedJobs,
};
