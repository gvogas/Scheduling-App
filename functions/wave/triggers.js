"use strict";

/**
 * @fileoverview The two Wave sync entry points that are NOT callables.
 *
 * `waveUpsertCustomer` is the `clients/{clientId}` write trigger and the
 * PRIMARY push path; `runWaveDaily` is the daily rider `sendDailyJobDigest`
 * calls. Both lived in `callables.js` only because the callables happened to be
 * the first callers of `importWithWatermark`/`drainForSync`/
 * `readWaveBusinessIdCached` — which now live in `sync_run.js`, so there is
 * nothing left tying either of these to a file named for callables. Anyone
 * looking for "the Wave trigger" should find it here.
 *
 * Neither export was RENAMED by the move — `index.js` still exports
 * `waveUpsertCustomer` under that name, and `notifications.js` still calls
 * `runWaveDaily`. A renamed deployed function deletes the one every shipped
 * build calls; only the `require` targets moved.
 *
 * @module wave/triggers
 */

const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");

const {WAVE_FULL_ACCESS_TOKEN} = require("./auth");
const {
  enqueueCustomerUpsert,
  cancelCustomerUpsert,
  drainQueue,
  shouldEnqueueClientWrite,
} = require("./worker");
const {mappedFieldsHash} = require("./mappers");
const {buildCustomerPayload, verdictPatch} = require("./customer_contract");
const {
  readWaveBusinessIdCached,
  readWaveConnection,
} = require("./sync_run");

// waveUpsertCustomer — enqueues a Wave write-back when a client doc's mapped
// fields change, AND pushes it (see the inline drain at the bottom).
// `retry: true` is safe here since the handler is idempotent and hash-guarded:
// `enqueueCustomerUpsert` writes a deterministic `customerUpsert__<clientId>`
// job id with `merge: true`, so a re-run rewrites the same doc.
//
// This is the PRIMARY push path as of 2026-08-13, replacing the deleted
// `waveSyncWorker` scheduler. Draining here rather than on a 5-minute poll is
// both cheaper and faster: an idle day costs nothing instead of 288
// invocations, and an edit reaches Wave in seconds instead of up to five
// minutes. The daily safety net for what an event-driven push structurally
// cannot catch — a job that failed and backed off, and a lease left stale by a
// dead instance, since neither produces a new client write to ride on — is
// `runWaveDaily` below, which rides `sendDailyJobDigest`. (It was the
// standalone `waveScheduledImport` export until 2026-08-13; naming that here
// in the present tense sent readers grepping for a function that no longer
// exists.)
//
// `timeoutSeconds` is raised off the 60 s default because the drain can sleep
// on Wave's Retry-After; the drain's own budget is a fraction of it so the
// handler always has room to return cleanly.
const TRIGGER_TIMEOUT_SECONDS = 300;
const TRIGGER_DRAIN_BUDGET_MS = 180 * 1000;

// WAVE'S 60-CALLS/MIN CEILING IS PACED BY THESE TWO NUMBERS, and they are the
// only thing pacing it. `dispatchQueuedJobs` dispatches SEQUENTIALLY (claim txn
// → Wave round trip → outcome txn, ~1 s/job), so a single invocation is
// self-limiting at roughly 60 calls/min — which is exactly how the deleted
// `waveSyncWorker` stayed inside the ceiling: `maxInstances: 1` meant one drain
// in flight, ever. A trigger inherits `setGlobalOptions({maxInstances: 10})`
// instead, so without the cap below, ten concurrent client writes each running
// a 20-job drain would burst to ~600 calls/min. That is not hypothetical — a
// bulk backfill (`scripts/backfill-client-phone-from-name.js` warns about a few
// hundred jobs) is precisely the shape that produces it.
//
// Two instances is the compromise: it bounds a burst near Wave's ceiling while
// keeping the ENQUEUE responsive, which `maxInstances: 1` would not — that
// serializes every client write behind whatever drain is in flight, and the
// enqueue is inside the same invocation, so a slow drain would delay the
// durability of the next edit rather than just its push.
//
// This only bounds concurrency because an EVENT-DRIVEN v2 function processes
// one event per instance (`concurrency` is left at the platform default, which
// is 1 for Eventarc triggers). Setting `concurrency` above 1 here would let a
// single instance run several drains at once and silently void the cap.
const TRIGGER_MAX_INSTANCES = 2;
// Small on purpose. This drain runs per client edit; its job is "push THIS
// edit now, and help a little with the backlog", not "clear the queue" — the
// old worker's 30 was sized for a 5-minute cadence, not for one drain per
// write. A backlog is finished by the next edit, the Sync button, or the daily
// sweep, none of which are on a deadline.
const TRIGGER_DRAIN_BATCH_LIMIT = 5;

const waveUpsertCustomer = onDocumentWritten(
    {
      document: "clients/{clientId}",
      retry: true,
      secrets: [WAVE_FULL_ACCESS_TOKEN],
      timeoutSeconds: TRIGGER_TIMEOUT_SECONDS,
      maxInstances: TRIGGER_MAX_INSTANCES,
    },
    async (event) => {
      const beforeSnap = event.data?.before;
      const afterSnap = event.data?.after;
      const after = afterSnap?.exists ? afterSnap.data() : null;

      // On delete, the local doc is just dropped and Wave is left intact —
      // nothing to enqueue.
      if (!after) return;

      const before = beforeSnap?.exists ? beforeSnap.data() : null;
      if (!shouldEnqueueClientWrite(before, after)) return;

      // The mark-pending write below only touches wave.* fields, so when
      // the trigger re-fires on it, mappedFieldsHash is unchanged and
      // shouldEnqueueClientWrite returns false — no second pending-write,
      // no loop.
      const clientId = event.params.clientId;
      const db = getFirestore();

      // We compute the hash once here. shouldEnqueueClientWrite also hashes
      // internally but doesn't expose its result, so this is the one
      // explicit hash computed at the enqueue site.
      const hash = mappedFieldsHash(after);

      // The contract decides BEFORE anything is queued. A payload Wave would
      // refuse must never become a job: the push dead-letters permanently and
      // "Retry failed" re-sends the identical payload into the identical
      // refusal, so the client is stranded with a counter and no reason.
      const contract = buildCustomerPayload(after);
      const verdict = verdictPatch(contract);
      if (!contract.ok) {
        // Different documents, neither depending on the other's result. The
        // second is why this branch exists: an earlier edit may have left a job
        // queued, and the worker re-reads the LIVE doc — so that job would push
        // what was just refused.
        //
        // Best-effort, like the mark-pending write below: the client can be
        // deleted between this event and the write, and an uncaught NOT_FOUND
        // here re-runs the whole handler under `retry: true` against the same
        // missing doc until the retry window expires.
        try {
          await Promise.all([
            db.doc("clients/" + clientId).update(verdict),
            cancelCustomerUpsert(clientId),
          ]);
        } catch (e) {
          logger.warn("waveUpsertCustomer: recording the refusal failed",
              {clientId, err: e.message});
        }
        logger.debug("waveUpsertCustomer: blocked by contract", {clientId});
        return;
      }

      // Mark-pending + enqueue land in ONE WriteBatch so a crash between the
      // two can't leave the doc stuck at 'pending' with no queued job (or a
      // queued job with no visible pending state).
      const batch = db.batch();
      // `wave.problems` rides the batch that was already updating this doc, so
      // recording it costs no extra write. It is NOT a mapped field, so the
      // hash is unchanged and `shouldEnqueueClientWrite` returns false when
      // the trigger re-fires on this write — the same protection the
      // mark-pending update above already relies on, and the reason this
      // cannot loop.
      batch.update(db.doc("clients/" + clientId), {
        "wave.syncState": "pending",
        "wave.syncError": null,
        ...verdict,
      });
      // payloadHash is diagnostic only — the worker re-reads the live doc
      // and recomputes the hash before writing, since the doc is the real
      // source of truth.
      await enqueueCustomerUpsert(clientId, {batch, payloadHash: hash});
      try {
        await batch.commit();
      } catch (e) {
        // The batch fails atomically when the doc was deleted before
        // commit, so we fall back to enqueue-only. The worker treats a
        // missing doc as a clean skip, and any other failure just retries
        // via retry:true's idempotent re-run.
        logger.warn("waveUpsertCustomer: batched mark-pending failed; " +
            "enqueueing without it", {clientId, err: e.message});
        await enqueueCustomerUpsert(clientId, {payloadHash: hash});
        // Best-effort: the doc changed, so the record of what is wrong with it
        // has to change too. The batch above failed atomically, which takes
        // the verdict with it.
        try {
          await db.doc("clients/" + clientId).update(verdict);
        } catch (patchErr) {
          logger.warn("waveUpsertCustomer: verdict patch failed",
              {clientId, err: patchErr.message});
        }
      }
      logger.debug("waveUpsertCustomer: enqueued", {clientId});

      // Push it now. Everything below is best-effort and MUST NOT throw: the
      // job is already durably queued, so a drain failure is a delay, not a
      // loss — and throwing would re-run the whole handler under `retry: true`
      // for something the retry cannot fix.
      //
      // This cannot loop. `upsertCustomer` writes `wave.*` back onto the
      // client doc, which re-fires this trigger, but `mappedFieldsHash` is
      // unchanged by that write so `shouldEnqueueClientWrite` returns false at
      // the top and the re-fire never reaches here.
      try {
        const businessId = await readWaveBusinessIdCached();
        if (!businessId) {
          logger.debug("waveUpsertCustomer: not connected — queued only",
              {clientId});
          return;
        }
        const summary = await drainQueue({
          businessId,
          batchLimit: TRIGGER_DRAIN_BATCH_LIMIT,
          deadlineMs: Date.now() + TRIGGER_DRAIN_BUDGET_MS,
        });
        logger.info("waveUpsertCustomer: drain done", {
          clientId,
          processed: summary.processed,
          done: summary.done,
          retried: summary.retried,
          dead: summary.dead,
          skipped: summary.skipped,
          reclaimed: summary.reclaimed,
        });
      } catch (e) {
        // Logged at warn, not error: the daily sweep and the Sync button both
        // pick this job up, so the outcome is a late push rather than a lost
        // one.
        logger.warn("waveUpsertCustomer: inline drain failed — job stays " +
            "queued for the daily sweep", {clientId, err: String(e)});
      }
    },
);

// runWaveDaily — the daily Wave job: drain the outbox (app → Wave).
//
// This is the safety net under the event-driven push in `waveUpsertCustomer`,
// and it exists because two states cannot produce a client write to ride on:
// a job that failed and is sitting on its `nextAttemptAt` backoff, and a job
// left `inflight` by an instance that died mid-dispatch (reclaimed by
// `drainQueue`'s lease pass). Without this they would wait for the next
// unrelated client edit or for an admin to press Sync.
//
// Its weekly/monthly pull was deleted in Wave Phase 4 (Task 12).
//
// **It is NOT its own scheduler.** It used to be `waveScheduledImport`, an
// `every 24 hours` `onSchedule`; it now rides `sendDailyJobDigest`
// (`notifications.js`), which was already a daily 18:00 timer carrying the
// Live Activity TTL prune as a rider. Cloud Scheduler bills per job past the
// first three, and this repo had six — this merge is one of the two that
// brought it to three, i.e. inside the free allowance. Exported as a plain
// async function so the digest can call it; keep it that way rather than
// re-promoting it to a timer, and note the caller isolates it in its own
// try/catch so a Wave failure cannot affect the push that already went out.
//
// The drain takes a bounded slice of the caller's budget.
const SWEEP_DRAIN_BUDGET_MS = 180 * 1000;

/**
 * Runs the daily Wave maintenance: drain the outbox.
 *
 * Never throws — every failure path inside is caught and logged, because the
 * caller is a user-facing push function whose own work has already completed
 * by the time this runs.
 *
 * @return {!Promise<void>}
 */
async function runWaveDaily() {
  // The connection read was the ONE await here outside a try, so the JSDoc's
  // "never throws" was a promise this function did not keep: a transient
  // `unavailable` on it rejected out of a rider whose host had already done
  // its real work. The caller's catch is belt-and-braces and stays; a
  // contract stated in a docstring should hold on its own terms.
  let connection;
  try {
    connection = await readWaveConnection();
  } catch (err) {
    logger.warn("WAVE-BOOT runWaveDaily: connection read failed", {err});
    return;
  }
  const {businessId} = connection;
  if (!businessId) {
    logger.debug("runWaveDaily: not connected — nothing to do");
    return;
  }

  try {
    const drained = await drainQueue({
      businessId,
      deadlineMs: Date.now() + SWEEP_DRAIN_BUDGET_MS,
    });
    if (drained.processed > 0 || drained.reclaimed > 0) {
      logger.info("WAVE-SCHED drain done", {
        processed: drained.processed,
        done: drained.done,
        retried: drained.retried,
        dead: drained.dead,
        skipped: drained.skipped,
        reclaimed: drained.reclaimed,
      });
    }
  } catch (e) {
    // Warn, not throw: the jobs stay queued for the next sweep or edit.
    logger.warn("WAVE-SCHED drain failed", {error: String(e)});
  }
}

module.exports = {
  waveUpsertCustomer,
  runWaveDaily,
};
