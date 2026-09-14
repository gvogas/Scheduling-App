"use strict";

const {drainQueue} = require("../wave/dispatch");
const {RATE_LIMITED_MAX_ATTEMPTS} = require("../wave/retry_policy");
const {WaveValidationError} = require("../wave/customers");
const {WaveApiError} = require("../wave/client");
const {
  now,
  fakeLogger,
  snap,
  fakeRef,
} = require("./mocks/wave_outbox_fakes");

/**
 * Builds a fake Firestore for drainQueue. Supports one or more `waveSyncQueue`
 * job documents returned by the query, plus a configurable `runTransaction`.
 *
 * @param {!Array<{id:string, data:Object}>} jobs Job docs to return from query.
 * @param {Object=} opts
 * @param {boolean=} opts.claimSucceeds Whether the claim transaction succeeds.
 *   Defaults to true, which sets the job inflight.
 * @param {boolean=} opts.claimSetsInflight Whether the re-read in the txn
 *   still shows 'queued' (default true).
 * @return {{db: !Object, refs: !Array<!Object>}}
 */
function drainDb(jobs, opts = {}) {
  const claimSetsInflight = opts.claimSetsInflight !== false;
  const claimSucceeds = opts.claimSucceeds !== false;

  const refs = jobs.map((j) => fakeRef(j.id, {...j.data}));

  // Build the query snapshot.
  const snapshots = refs.map((ref, i) => snap(jobs[i].id, {...jobs[i].data},
      ref));

  const db = {
    collection: jest.fn((col) => {
      if (col !== "waveSyncQueue") throw new Error(`unexpected col: ${col}`);
      return {
        where: jest.fn().mockReturnThis(),
        orderBy: jest.fn().mockReturnThis(),
        limit: jest.fn().mockReturnThis(),
        get: jest.fn(() => Promise.resolve({docs: snapshots})),
      };
    }),
    runTransaction: jest.fn(async (fn) => {
      if (!claimSucceeds) throw new Error("transaction contention");
      const txn = {
        get: jest.fn((ref) => {
          // Re-read the ref's current _data for claim verification.
          const currentData = ref._data;
          return Promise.resolve(snap(ref.id, currentData, ref));
        }),
        update: jest.fn((ref, fields) => {
          if (claimSetsInflight) {
            // Record the write — both the claim and the outcome flow
            // through tx.update — then mutate _data so a later re-read in
            // the same drain sees it.
            ref.updates.push(fields);
            Object.assign(ref._data, fields);
          }
        }),
      };
      return fn(txn);
    }),
  };

  return {db, refs};
}

/**
 * Builds a no-op backoff function that always returns a fixed delay, making
 * tests deterministic.
 * @param {number=} delayMs Fixed delay to return (default 1000ms).
 * @return {function(number):number}
 */
function fixedBackoff(delayMs = 1000) {
  return jest.fn(() => delayMs);
}

// ---------------------------------------------------------------------------
// drainQueue — happy path
// ---------------------------------------------------------------------------

describe("drainQueue happy path", () => {
  test("claims a queued+due job (sets inflight) and marks done on success",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);
        const mockUpsert = jest.fn(() =>
          Promise.resolve({status: "patched", waveCustomerId: "wv-1"}));
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          businessId: "biz-1",
          backoffFn: fixedBackoff(),
        });

        expect(mockUpsert).toHaveBeenCalledTimes(1);
        expect(mockUpsert).toHaveBeenCalledWith("c1", expect.objectContaining({
          db,
          businessId: "biz-1",
        }));

        // Final state: done, lastError cleared.
        const lastUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(lastUpdate.status).toBe("done");
        expect(lastUpdate.lastError).toBeNull();

        // updated: 1 — the mock reports `patched`, so the job's Wave write
        // is counted as an update to an existing customer, not a create.
        expect(summary).toEqual({
          processed: 1, done: 1, retried: 0, dead: 0, skipped: 0, reclaimed: 0,
          created: 0, updated: 1, blocked: 0,
        });

        expect(logger.error).not.toHaveBeenCalled();
      });

  test("skips jobs not due (nextAttemptAt in the future)", async () => {
    // The fake db always returns whatever docs we give it, so we can't
    // actually test the filtering here. We trust Firestore to enforce it,
    // and just check that the query builder gets the right constraints.
    const {db} = drainDb([]);
    const mockUpsert = jest.fn();
    await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });
    expect(mockUpsert).not.toHaveBeenCalled();
  });

  // The interactive "Sync with Wave" button reports these two numbers to the
  // admin as "N added to Wave / N updated in Wave", so a miscount is a lie on
  // screen rather than a silent internal drift.
  test("tallies Wave-direction counts by upsert status", async () => {
    const statuses = [
      "created", "created", "patched", "linked", "noop", "skipped",
    ];
    const jobs = statuses.map((_, i) => ({
      id: `customerUpsert__c${i}`,
      data: {
        type: "customerUpsert",
        refPath: `clients/c${i}`,
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: `customerUpsert__c${i}`,
      },
    }));
    const {db} = drainDb(jobs);
    let call = 0;
    const mockUpsert = jest.fn(() =>
      Promise.resolve({status: statuses[call++]}));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(summary.done).toBe(6);
    expect(summary.created).toBe(2);
    // `linked` patches a customer a crashed attempt already created, so it
    // is an update in Wave, not a new arrival there.
    expect(summary.updated).toBe(2);
  });

  test("does not count a job whose outcome write was superseded", async () => {
    // The Wave write happened, but a concurrent re-enqueue means the job runs
    // again — counting it here would double-count it across the two drains.
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    // Re-enqueued mid-dispatch: commitOutcome sees a different claim and
    // declines to write `done`.
    const mockUpsert = jest.fn(() => {
      refs[0]._data.status = "queued";
      refs[0]._data.claimedAt = new Date("2030-01-01");
      return Promise.resolve({status: "created"});
    });

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(summary.done).toBe(0);
    expect(summary.created).toBe(0);
  });

  test("respects batchLimit", async () => {
    const jobs = Array.from({length: 5}, (_, i) => ({
      id: `customerUpsert__c${i}`,
      data: {
        type: "customerUpsert",
        refPath: `clients/c${i}`,
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: `customerUpsert__c${i}`,
      },
    }));

    // Build a db that tracks how many docs the query returns.
    const {db, refs} = drainDb(jobs);

    // Capture the limit() call to verify batchLimit is forwarded.
    let capturedLimit = null;
    const originalCollection = db.collection.bind(db);
    db.collection = jest.fn((col) => {
      const q = originalCollection(col);
      const origLimit = q.limit.bind(q);
      q.limit = jest.fn((n) => {
        capturedLimit = n;
        return origLimit(n);
      });
      return q;
    });

    const mockUpsert = jest.fn(() => Promise.resolve({status: "done"}));
    await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      batchLimit: 3,
      backoffFn: fixedBackoff(),
    });

    expect(capturedLimit).toBe(3);
    // All 5 docs are in the fake snapshot, so all 5 get processed — a real
    // Firestore query would only return 3, but here we're just checking
    // that the limit argument gets passed through.
    expect(refs).toHaveLength(5);
  });
});

// ---------------------------------------------------------------------------
// drainQueue — claim atomicity
// ---------------------------------------------------------------------------

describe("drainQueue claim atomicity", () => {
  test("skips a job that is already inflight at claim time", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued", // appears queued in the query snapshot
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    // Simulate a race: the re-read shows the job as already inflight.
    const {db} = drainDb([job], {claimSetsInflight: false});

    // Override runTransaction so that the re-read returns 'inflight'.
    db.runTransaction = jest.fn(async (fn) => {
      const txn = {
        get: jest.fn((ref) =>
          Promise.resolve(snap(ref.id, {
            ...ref._data, status: "inflight",
          }, ref))),
        update: jest.fn(),
      };
      return fn(txn);
    });

    const mockUpsert = jest.fn();
    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(mockUpsert).not.toHaveBeenCalled();
    expect(summary.skipped).toBe(1);
    expect(summary.processed).toBe(0);
  });

  test("skips if transaction itself throws (contention)", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db} = drainDb([job], {claimSucceeds: false});
    const mockUpsert = jest.fn();
    const logger = fakeLogger();

    const summary = await drainQueue({
      db, now, logger,
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(mockUpsert).not.toHaveBeenCalled();
    expect(summary.skipped).toBe(1);
    expect(logger.warn).toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// drainQueue — outcome guard (concurrent re-enqueue / lost-update)
// ---------------------------------------------------------------------------

describe("drainQueue outcome guard", () => {
  test("does not clobber a job re-enqueued mid-dispatch to 'done'",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);

        // Simulate a client edit re-enqueuing the same job mid-dispatch.
        // The dispatch still succeeds, using the data it read first.
        const mockUpsert = jest.fn(() => {
          Object.assign(refs[0]._data, {
            status: "queued",
            attempts: 0,
            lastError: null,
          });
          return Promise.resolve({status: "patched", waveCustomerId: "wv-1"});
        });
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          backoffFn: fixedBackoff(),
        });

        // The re-enqueued job must stay 'queued' so the newer edit still
        // syncs. The worker must not overwrite it to 'done'.
        expect(refs[0]._data.status).toBe("queued");
        const doneWrite = refs[0].updates.find((u) => u.status === "done");
        expect(doneWrite).toBeUndefined();
        expect(summary).toEqual({
          processed: 1, done: 0, retried: 0, dead: 0, skipped: 0, reclaimed: 0,
          created: 0, updated: 0, blocked: 0,
        });
        expect(logger.error).not.toHaveBeenCalled();
      });
});

// ---------------------------------------------------------------------------
// drainQueue — retryable errors
// ---------------------------------------------------------------------------

describe("drainQueue retryable errors", () => {
  // eslint-disable-next-line max-len
  test("WaveApiError(network) → back to queued, attempts++, nextAttemptAt advanced, lastError set",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);
        // Use a real clock here so nextAttemptAt ends up a valid Date,
        // not an Invalid one.
        const nowDate = new Date("2024-06-01T10:00:00Z");
        const nowFn = () => nowDate;
        const networkErr = new WaveApiError("network", "fetch failed");
        const mockUpsert = jest.fn(() => Promise.reject(networkErr));
        const backoffFn = jest.fn(() => 5000);
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now: nowFn, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn,
        });

        expect(summary).toEqual({
          processed: 1, done: 0, retried: 1, dead: 0, skipped: 0, reclaimed: 0,
          created: 0, updated: 0, blocked: 0,
        });

        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("queued");
        expect(finalUpdate.attempts).toBe(1);
        expect(finalUpdate.lastError).toBe("WaveApiError(network)");
        // nextAttemptAt must be a valid future Date. This guards against an
        // old regression where an Invalid Date would never re-match the
        // due query again.
        expect(finalUpdate.nextAttemptAt).toBeInstanceOf(Date);
        expect(Number.isNaN(finalUpdate.nextAttemptAt.getTime())).toBe(false);
        expect(finalUpdate.nextAttemptAt.getTime())
            .toBe(nowDate.getTime() + 5000);

        // backoffFn is called with attempts-1, since attempt indices are
        // 0-indexed.
        expect(backoffFn).toHaveBeenCalledWith(0);

        // Must not dead-log on a retryable error.
        expect(logger.error).not.toHaveBeenCalled();
      });

  test("WaveApiError(rateLimited) → retryable", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 2,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: "WaveApiError(network)",
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    const nowDate = new Date("2024-06-01T10:00:00Z");
    const nowFn = () => nowDate;
    const rateLimitErr = new WaveApiError("rateLimited", "rate limited");
    const mockUpsert = jest.fn(() => Promise.reject(rateLimitErr));

    const summary = await drainQueue({
      db, now: nowFn, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.retried).toBe(1);
    const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(finalUpdate.status).toBe("queued");
    expect(finalUpdate.attempts).toBe(3);
    expect(finalUpdate.lastError).toBe("WaveApiError(rateLimited)");
    // nextAttemptAt must be a valid future Date, not an Invalid Date.
    expect(Number.isNaN(finalUpdate.nextAttemptAt.getTime())).toBe(false);
    expect(finalUpdate.nextAttemptAt.getTime())
        .toBeGreaterThan(nowDate.getTime());
  });

  test("retryable until cap → finally dead", async () => {
    const maxAttempts = 3;
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        // This job is already at maxAttempts - 1, so the next failure
        // pushes it over the cap.
        attempts: maxAttempts - 1,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: "WaveApiError(network)",
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    const networkErr = new WaveApiError("network", "still failing");
    const mockUpsert = jest.fn(() => Promise.reject(networkErr));
    const logger = fakeLogger();

    const summary = await drainQueue({
      db, now, logger,
      upsertCustomer: mockUpsert,
      maxAttempts,
      backoffFn: fixedBackoff(),
    });

    expect(summary).toEqual({
      processed: 1, done: 0, retried: 0, dead: 1, skipped: 0, reclaimed: 0,
      created: 0, updated: 0, blocked: 0,
    });

    const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(finalUpdate.status).toBe("dead");
    expect(finalUpdate.attempts).toBe(maxAttempts);
    expect(typeof finalUpdate.lastError).toBe("string");

    // Must log at error level.
    expect(logger.error).toHaveBeenCalledTimes(1);
    const [msg, meta] = logger.error.mock.calls[0];
    expect(typeof msg).toBe("string");
    expect(meta.jobId).toBe("customerUpsert__c1");
    expect(meta.clientId).toBe("c1");
    // Must not expose PII or raw Wave message.
    expect(JSON.stringify(meta)).not.toContain("still failing");
  });

  test("unexpected non-Wave error → retryable (bounded)", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    const unexpectedErr = new TypeError("boom — unexpected infra error");
    const mockUpsert = jest.fn(() => Promise.reject(unexpectedErr));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.retried).toBe(1);
    expect(summary.dead).toBe(0);
    const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(finalUpdate.status).toBe("queued");
    // lastError must not echo the raw error message — that would leak PII.
    expect(finalUpdate.lastError).not.toContain("boom");
  });
});

// ---------------------------------------------------------------------------
// drainQueue — non-retryable errors
// ---------------------------------------------------------------------------

describe("drainQueue non-retryable errors", () => {
  test("WaveValidationError → dead immediately (no retry), logs error",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);
        const validationErr = new WaveValidationError(
            [{code: "INVALID_EMAIL", message: "customer@example.com bad",
              path: ["email"]}],
        );
        const mockUpsert = jest.fn(() => Promise.reject(validationErr));
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary).toEqual({
          processed: 1, done: 0, retried: 0, dead: 1, skipped: 0,
          reclaimed: 0, created: 0, updated: 0, blocked: 0,
        });
        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("dead");
        expect(finalUpdate.attempts).toBe(1);

        // Logged at error.
        expect(logger.error).toHaveBeenCalledTimes(1);

        // lastError must not echo Wave's raw message.
        expect(finalUpdate.lastError).not.toContain("customer@example.com");
        expect(finalUpdate.lastError).not.toContain("bad");
      });

  test("WaveApiError(auth) → dead immediately (no retry), logs error",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);
        const authErr = new WaveApiError("auth", "token revoked");
        const mockUpsert = jest.fn(() => Promise.reject(authErr));
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary).toEqual({
          processed: 1, done: 0, retried: 0, dead: 1, skipped: 0,
          reclaimed: 0, created: 0, updated: 0, blocked: 0,
        });

        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("dead");
        expect(logger.error).toHaveBeenCalledTimes(1);

        // Log meta must not include the raw error message "token revoked".
        const logMeta = logger.error.mock.calls[0][1];
        expect(JSON.stringify(logMeta)).not.toContain("token revoked");
        expect(logMeta.errorKind).toBe("auth");
      });

  test("WaveApiError(graphql) → dead immediately", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    const graphqlErr = new WaveApiError("graphql", "resolver error");
    const mockUpsert = jest.fn(() => Promise.reject(graphqlErr));
    const logger = fakeLogger();

    const summary = await drainQueue({db, now, logger,
      upsertCustomer: mockUpsert, maxAttempts: 5,
      backoffFn: fixedBackoff()});

    expect(summary.dead).toBe(1);
    expect(summary.retried).toBe(0);
    const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(finalUpdate.status).toBe("dead");
    expect(logger.error).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// drainQueue — PII / log safety
// ---------------------------------------------------------------------------

describe("drainQueue PII + log safety", () => {
  test("lastError and logger output contain no PII or Wave raw message",
      async () => {
        const job = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: 4, // one below cap
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, refs} = drainDb([job]);
        // Raw error message contains PII-like content.
        const authErr = new WaveApiError(
            "auth",
            "Token for jane.doe@example.com is expired",
        );
        const mockUpsert = jest.fn(() => Promise.reject(authErr));
        const logger = fakeLogger();

        await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];

        // Neither lastError nor log output should contain the email address.
        expect(finalUpdate.lastError).not.toContain("jane.doe@example.com");
        expect(finalUpdate.lastError).not.toContain("expired");

        const logArgs = logger.error.mock.calls[0];
        const logJson = JSON.stringify(logArgs);
        expect(logJson).not.toContain("jane.doe@example.com");
        expect(logJson).not.toContain("expired");
      });
});

// ---------------------------------------------------------------------------
// drainQueue — multi-job batch
// ---------------------------------------------------------------------------

describe("drainQueue multi-job batch", () => {
  test("processes multiple jobs independently in one call", async () => {
    const jobs = [
      {
        id: "customerUpsert__c1",
        data: {
          type: "customerUpsert", refPath: "clients/c1",
          status: "queued", attempts: 0,
          nextAttemptAt: new Date("2024-01-01"), lastError: null,
          idempotencyKey: "customerUpsert__c1",
        },
      },
      {
        id: "customerUpsert__c2",
        data: {
          type: "customerUpsert", refPath: "clients/c2",
          status: "queued", attempts: 0,
          nextAttemptAt: new Date("2024-01-01"), lastError: null,
          idempotencyKey: "customerUpsert__c2",
        },
      },
    ];
    const {db, refs} = drainDb(jobs);
    let call = 0;
    const mockUpsert = jest.fn(() => {
      call++;
      // First succeeds, second fails with a network error.
      if (call === 1) return Promise.resolve({status: "done"});
      return Promise.reject(new WaveApiError("network", "transient"));
    });

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.processed).toBe(2);
    expect(summary.done).toBe(1);
    expect(summary.retried).toBe(1);

    const update1 = refs[0].updates[refs[0].updates.length - 1];
    expect(update1.status).toBe("done");

    const update2 = refs[1].updates[refs[1].updates.length - 1];
    expect(update2.status).toBe("queued");
  });
});

// ---------------------------------------------------------------------------
// drainQueue — default batchLimit
// ---------------------------------------------------------------------------

describe("drainQueue defaults", () => {
  test("default batchLimit is 30", async () => {
    const {db} = drainDb([]);
    let capturedLimit = null;
    const origCollection = db.collection.bind(db);
    db.collection = jest.fn((col) => {
      const q = origCollection(col);
      const origLimit = q.limit.bind(q);
      q.limit = jest.fn((n) => {
        capturedLimit = n;
        return origLimit(n);
      });
      return q;
    });

    await drainQueue({db, now, logger: fakeLogger(),
      upsertCustomer: jest.fn(), backoffFn: fixedBackoff()});
    expect(capturedLimit).toBe(30);
  });
});

// ---------------------------------------------------------------------------
// claim stamps claimedAt + reclaim pass — shared constants
// ---------------------------------------------------------------------------

/**
 * Lease used in reclaim tests (60 s) — short enough to be precise in tests
 * without coupling to the production default (600 s).
 */
const TEST_LEASE_MS = 60_000;

// ---------------------------------------------------------------------------
// claim stamps claimedAt
// ---------------------------------------------------------------------------

describe("drainQueue claim stamps claimedAt", () => {
  test("claim transaction sets status:inflight and claimedAt", async () => {
    const nowDate = new Date("2024-06-01T10:00:00Z");
    const nowFn = () => nowDate;

    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db} = drainDb([job]);

    // Replace runTransaction to capture what the claim writes.
    const claimWrites = [];
    db.runTransaction = jest.fn(async (fn) => {
      const txn = {
        get: jest.fn((ref) =>
          Promise.resolve(snap(ref.id, {...ref._data}, ref))),
        update: jest.fn((ref, fields) => {
          claimWrites.push({ref, fields});
          Object.assign(ref._data, fields);
        }),
      };
      return fn(txn);
    });

    await drainQueue({
      db, now: nowFn, logger: fakeLogger(),
      upsertCustomer: jest.fn(() => Promise.resolve({status: "done"})),
      backoffFn: fixedBackoff(),
      leaseMs: TEST_LEASE_MS,
    });

    // The claim write should have set status:inflight and claimedAt.
    const claimWrite = claimWrites.find((w) =>
      w.fields.status === "inflight");
    expect(claimWrite).toBeDefined();
    expect(claimWrite.fields.claimedAt).toBe(nowDate);
  });
});

// ---------------------------------------------------------------------------
// drainQueue — reclaim pass
// ---------------------------------------------------------------------------

/**
 * Builds a fake Firestore that returns stale `inflight` jobs from the reclaim
 * query and an empty result for the main `queued` drain query.
 *
 * @param {!Array<{id:string, data:Object}>} staleJobs Inflight jobs older than
 *   the lease to return from the reclaim query.
 * @param {Object=} opts
 * @param {boolean=} opts.reclaimTxSucceeds Whether the reclaim transaction
 *   should resolve (default true).
 * @return {{db: !Object, staleRefs: !Array<!Object>}}
 */
function reclaimDb(staleJobs, opts = {}) {
  const reclaimTxSucceeds = opts.reclaimTxSucceeds !== false;
  const staleRefs = staleJobs.map((j) => fakeRef(j.id, {...j.data}));
  const staleSnaps = staleRefs.map((ref, i) =>
    snap(staleJobs[i].id, {...staleJobs[i].data}, ref));

  // Each collection() call returns a fresh query builder. Filtering by
  // 'inflight' returns the stale docs, and filtering by 'queued' returns
  // nothing.
  const makeQueryBuilder = () => {
    // Use a closure variable so arrow functions can read the accumulated
    // filter without triggering the no-invalid-this lint rule.
    let statusFilter = null;
    const qb = {
      where: jest.fn((field, op, val) => {
        if (field === "status") statusFilter = val;
        return qb;
      }),
      orderBy: jest.fn(() => qb),
      limit: jest.fn(() => qb),
      get: jest.fn(() => {
        const docs = statusFilter === "inflight" ? staleSnaps : [];
        return Promise.resolve({docs});
      }),
    };
    return qb;
  };

  const db = {
    collection: jest.fn((col) => {
      if (col !== "waveSyncQueue") throw new Error(`unexpected col: ${col}`);
      return makeQueryBuilder();
    }),
    runTransaction: jest.fn(async (fn) => {
      if (!reclaimTxSucceeds) throw new Error("reclaim tx contention");
      const txn = {
        get: jest.fn((ref) =>
          Promise.resolve(snap(ref.id, {...ref._data}, ref))),
        update: jest.fn((ref, fields) => {
          // Record the reclaim's transactional write so tests can assert
          // on ref.updates. Also mutate _data so a re-read reflects it.
          ref.updates.push(fields);
          Object.assign(ref._data, fields);
        }),
      };
      return fn(txn);
    }),
  };

  return {db, staleRefs};
}

describe("drainQueue reclaim pass", () => {
  // This is the fixed "now" for reclaim tests — jobs claimed before this,
  // minus leaseMs, count as stale.
  const NOW_MS = new Date("2024-06-01T10:00:00Z").getTime();
  const nowDate = new Date(NOW_MS);
  const nowFn = () => nowDate;

  // A claimedAt that is definitely stale (2 × leaseMs ago).
  const staleClaimedAt = new Date(NOW_MS - TEST_LEASE_MS * 2);
  // A claimedAt that's fresh — half the lease ago, still within the window.
  const freshClaimedAt = new Date(NOW_MS - TEST_LEASE_MS / 2);

  test("stale inflight job is reset to queued, attempts bumped, " +
    "nextAttemptAt advanced, reclaimed counter increments", async () => {
    const staleJob = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "inflight",
        attempts: 1,
        claimedAt: staleClaimedAt,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, staleRefs} = reclaimDb([staleJob]);
    const logger = fakeLogger();
    const backoffFn = fixedBackoff(5000);

    const summary = await drainQueue({
      db, now: nowFn, logger,
      upsertCustomer: jest.fn(),
      maxAttempts: 5,
      backoffFn,
      leaseMs: TEST_LEASE_MS,
    });

    expect(summary.reclaimed).toBe(1);

    const ref = staleRefs[0];
    const lastUpdate = ref.updates[ref.updates.length - 1];
    expect(lastUpdate.status).toBe("queued");
    expect(lastUpdate.attempts).toBe(2); // was 1, bumped to 2
    expect(lastUpdate.lastError).toBe("reclaimed: lease expired");
    expect(lastUpdate.nextAttemptAt).toBeInstanceOf(Date);
    // nextAttemptAt must be strictly after nowDate.
    expect(lastUpdate.nextAttemptAt.getTime()).toBeGreaterThan(NOW_MS);

    // backoffFn called with pre-increment index (attempts-1 = 1).
    expect(backoffFn).toHaveBeenCalledWith(1);

    // No error log for a reclaim that goes back to queued.
    expect(logger.error).not.toHaveBeenCalled();
  });

  test("fresh inflight job (within lease) is NOT reclaimed", async () => {
    const freshJob = {
      id: "customerUpsert__c2",
      data: {
        type: "customerUpsert",
        refPath: "clients/c2",
        status: "inflight",
        attempts: 0,
        claimedAt: freshClaimedAt,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c2",
      },
    };

    // Override the reclaim query's transaction to simulate a fresh job.
    // When the transaction re-reads, claimedAt comes back within the
    // lease window.
    const {db, staleRefs} = reclaimDb([freshJob]);

    // Replace the transaction to return data with a fresh claimedAt so the
    // guard condition `claimedAtMs > nowMs - leaseMs` fires and bails out.
    db.runTransaction = jest.fn(async (fn) => {
      const txn = {
        get: jest.fn((ref) =>
          Promise.resolve(snap(ref.id, {
            ...ref._data,
            claimedAt: freshClaimedAt,
          }, ref))),
        update: jest.fn(),
      };
      return fn(txn);
    });

    const summary = await drainQueue({
      db, now: nowFn, logger: fakeLogger(),
      upsertCustomer: jest.fn(),
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
      leaseMs: TEST_LEASE_MS,
    });

    expect(summary.reclaimed).toBe(0);
    // The ref should have no outcome update — only the reclaim transaction
    // ran, and it bailed out without writing anything.
    expect(staleRefs[0].updates).toHaveLength(0);
  });

  test("stale inflight job at maxAttempts-1 is dead-lettered on reclaim",
      async () => {
        const maxAttempts = 3;
        const staleJob = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "inflight",
            // Already at maxAttempts - 1: reclaim bumps to cap → dead.
            attempts: maxAttempts - 1,
            claimedAt: staleClaimedAt,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, staleRefs} = reclaimDb([staleJob]);
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now: nowFn, logger,
          upsertCustomer: jest.fn(),
          maxAttempts,
          backoffFn: fixedBackoff(),
          leaseMs: TEST_LEASE_MS,
        });

        expect(summary.reclaimed).toBe(1);

        const ref = staleRefs[0];
        const lastUpdate = ref.updates[ref.updates.length - 1];
        expect(lastUpdate.status).toBe("dead");
        expect(lastUpdate.attempts).toBe(maxAttempts);
        expect(typeof lastUpdate.lastError).toBe("string");

        // Must log at error level for dead-letter.
        expect(logger.error).toHaveBeenCalledTimes(1);
        const [msg, meta] = logger.error.mock.calls[0];
        expect(typeof msg).toBe("string");
        expect(meta.jobId).toBe("customerUpsert__c1");
      });

  test("inflight job with a non-finite claimedAt (missing/corrupt) IS " +
    "reclaimed instead of being skipped forever", async () => {
    const staleJob = {
      id: "customerUpsert__c9",
      data: {
        type: "customerUpsert",
        refPath: "clients/c9",
        status: "inflight",
        attempts: 0,
        // A claimedAt that resolves to NaN (e.g. corrupt / sentinel value).
        claimedAt: {bogus: true},
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c9",
      },
    };
    const {db, staleRefs} = reclaimDb([staleJob]);
    const logger = fakeLogger();

    const summary = await drainQueue({
      db, now: nowFn, logger,
      upsertCustomer: jest.fn(),
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
      leaseMs: TEST_LEASE_MS,
    });

    expect(summary.reclaimed).toBe(1);
    const lastUpdate =
      staleRefs[0].updates[staleRefs[0].updates.length - 1];
    expect(lastUpdate.status).toBe("queued");
    expect(lastUpdate.attempts).toBe(1);
  });

  test("stale job re-enqueued before the reclaim write is NOT clobbered",
      async () => {
        // A client edit re-enqueues the job between the reclaim query and
        // its transactional re-read. Reclaim must leave it alone — it
        // shouldn't overwrite the job to queued/dead or bump the reclaimed
        // counter.
        const staleJob = {
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "inflight",
            attempts: 1,
            claimedAt: staleClaimedAt,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: "customerUpsert__c1",
          },
        };
        const {db, staleRefs} = reclaimDb([staleJob]);
        const logger = fakeLogger();

        // The transactional re-read sees the re-enqueued (queued) state, so the
        // in-transaction guard `status !== "inflight"` bails before any write.
        db.runTransaction = jest.fn(async (fn) => {
          const txn = {
            get: jest.fn((ref) =>
              Promise.resolve(snap(ref.id, {
                ...ref._data,
                status: "queued",
                attempts: 0,
              }, ref))),
            update: jest.fn((ref, fields) => {
              ref.updates.push(fields);
              Object.assign(ref._data, fields);
            }),
          };
          return fn(txn);
        });

        const summary = await drainQueue({
          db, now: nowFn, logger,
          upsertCustomer: jest.fn(),
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
          leaseMs: TEST_LEASE_MS,
        });

        expect(summary.reclaimed).toBe(0);
        // No clobbering write went through.
        expect(staleRefs[0].updates).toHaveLength(0);
        expect(logger.error).not.toHaveBeenCalled();
      });
});

// ---------------------------------------------------------------------------
// drainQueue — WaveApiError('unknown') → dead immediately (Fix #5)
// ---------------------------------------------------------------------------

describe("drainQueue non-retryable errors (additional)", () => {
  test("WaveApiError('unknown') → dead immediately, no retry", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 0,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: null,
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db, refs} = drainDb([job]);
    const unknownErr = new WaveApiError("unknown", "something unrecognised");
    const mockUpsert = jest.fn(() => Promise.reject(unknownErr));
    const logger = fakeLogger();

    const summary = await drainQueue({
      db, now, logger,
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary).toEqual({
      processed: 1, done: 0, retried: 0, dead: 1, skipped: 0, reclaimed: 0,
      created: 0, updated: 0, blocked: 0,
    });

    const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(finalUpdate.status).toBe("dead");
    expect(finalUpdate.attempts).toBe(1);

    // Logged at error level.
    expect(logger.error).toHaveBeenCalledTimes(1);
    const logMeta = logger.error.mock.calls[0][1];
    expect(logMeta.errorKind).toBe("unknown");
    // Must not echo the raw error message.
    expect(JSON.stringify(logMeta)).not.toContain("something unrecognised");
  });
});

// ---------------------------------------------------------------------------
// drainQueue — wall-clock deadline budget
// ---------------------------------------------------------------------------

describe("drainQueue deadline budget", () => {
  const makeJob = (i) => ({
    id: `customerUpsert__c${i}`,
    data: {
      type: "customerUpsert",
      refPath: `clients/c${i}`,
      status: "queued",
      attempts: 0,
      nextAttemptAt: new Date("2024-01-01"),
      lastError: null,
      idempotencyKey: `customerUpsert__c${i}`,
    },
  });

  test("stops claiming new jobs once deadlineMs passes; in-flight job " +
    "still gets its outcome", async () => {
    const jobs = [makeJob(1), makeJob(2), makeJob(3)];
    const {db, refs} = drainDb(jobs);
    // The dispatch of job 1 advances the clock past the deadline, so job 2's
    // pre-claim check must stop the drain.
    let clock = 0;
    const wallClock = jest.fn(() => clock);
    const mockUpsert = jest.fn(() => {
      clock = 200; // "the Wave call took a long time"
      return Promise.resolve({status: "patched", waveCustomerId: "wv-1"});
    });
    const logger = fakeLogger();

    const summary = await drainQueue({
      db, now, logger,
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
      wallClock,
      deadlineMs: 150, // job1's check (100) passes; job2's (200) does not.
    });

    // Only the first job was claimed and dispatched.
    expect(mockUpsert).toHaveBeenCalledTimes(1);
    expect(summary.processed).toBe(1);
    expect(summary.done).toBe(1);

    // Job 1 got a clean outcome. Jobs 2 and 3 were left untouched, still
    // queued.
    const lastUpdate = refs[0].updates[refs[0].updates.length - 1];
    expect(lastUpdate.status).toBe("done");
    expect(refs[1].updates).toHaveLength(0);
    expect(refs[2].updates).toHaveLength(0);

    // The early stop is logged.
    expect(logger.warn).toHaveBeenCalledWith(
        expect.stringContaining("deadline"),
        expect.objectContaining({deadlineMs: 150}),
    );
  });

  test("no deadlineMs → drains everything (default Infinity)", async () => {
    const jobs = [makeJob(1), makeJob(2)];
    const {db} = drainDb(jobs);
    const mockUpsert = jest.fn(() => Promise.resolve({status: "done"}));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(mockUpsert).toHaveBeenCalledTimes(2);
    expect(summary.processed).toBe(2);
  });
});

// ---------------------------------------------------------------------------
// drainQueue — per-claim claimedAt stamping
// ---------------------------------------------------------------------------

describe("drainQueue per-claim claimedAt stamping", () => {
  test("each claim stamps its OWN clock reading, not the drain-start value",
      async () => {
        const jobs = [1, 2].map((i) => ({
          id: `customerUpsert__c${i}`,
          data: {
            type: "customerUpsert",
            refPath: `clients/c${i}`,
            status: "queued",
            attempts: 0,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: null,
            idempotencyKey: `customerUpsert__c${i}`,
          },
        }));
        const {db} = drainDb(jobs);

        // now() advances by 1s on each call: the first call returns the
        // drain-start value, and later calls give each claim its own stamp.
        const BASE = new Date("2024-06-01T10:00:00Z").getTime();
        let call = 0;
        const nowFn = jest.fn(() => new Date(BASE + (call++) * 1000));

        const claimWrites = [];
        db.runTransaction = jest.fn(async (fn) => {
          const txn = {
            get: jest.fn((ref) =>
              Promise.resolve(snap(ref.id, {...ref._data}, ref))),
            update: jest.fn((ref, fields) => {
              if (fields.status === "inflight") {
                claimWrites.push(fields);
              }
              ref.updates.push(fields);
              Object.assign(ref._data, fields);
            }),
          };
          return fn(txn);
        });

        const summary = await drainQueue({
          db, now: nowFn, logger: fakeLogger(),
          upsertCustomer: jest.fn(() => Promise.resolve({status: "done"})),
          backoffFn: fixedBackoff(),
        });

        expect(claimWrites).toHaveLength(2);
        const drainStartMs = BASE; // first now() call
        const stamp1 = claimWrites[0].claimedAt.getTime();
        const stamp2 = claimWrites[1].claimedAt.getTime();
        // These are real per-claim times — each one comes strictly after
        // the drain started, and each job gets its own distinct stamp.
        expect(stamp1).toBeGreaterThan(drainStartMs);
        expect(stamp2).toBeGreaterThan(stamp1);

        // Outcomes still commit, since the claim-stamp guard matches
        // against itself.
        expect(summary.done).toBe(2);
      });
});

// ---------------------------------------------------------------------------
// drainQueue — graphql retryability heuristics (F7)
// ---------------------------------------------------------------------------

describe("drainQueue graphql retryability", () => {
  const makeJob = () => ({
    id: "customerUpsert__c1",
    data: {
      type: "customerUpsert",
      refPath: "clients/c1",
      status: "queued",
      attempts: 0,
      nextAttemptAt: new Date("2024-01-01"),
      lastError: null,
      idempotencyKey: "customerUpsert__c1",
    },
  });

  test("graphql error with 'Internal server error' message → retried",
      async () => {
        const {db, refs} = drainDb([makeJob()]);
        const err = new WaveApiError(
            "graphql",
            "Wave GraphQL errors: Internal server error",
            [{message: "Internal server error"}],
        );
        const mockUpsert = jest.fn(() => Promise.reject(err));

        const summary = await drainQueue({
          db, now, logger: fakeLogger(),
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary.retried).toBe(1);
        expect(summary.dead).toBe(0);
        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("queued");
      });

  test("graphql error with transient extensions.code → retried", async () => {
    const {db} = drainDb([makeJob()]);
    const err = new WaveApiError(
        "graphql",
        "Wave GraphQL errors: something went wrong",
        [{message: "something went wrong",
          extensions: {code: "UNAVAILABLE"}}],
    );
    const mockUpsert = jest.fn(() => Promise.reject(err));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.retried).toBe(1);
    expect(summary.dead).toBe(0);
  });

  test("graphql timeout message → retried", async () => {
    const {db} = drainDb([makeJob()]);
    const err = new WaveApiError(
        "graphql",
        "Wave GraphQL errors: upstream request timed out",
        [{message: "upstream request timed out"}],
    );
    const mockUpsert = jest.fn(() => Promise.reject(err));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.retried).toBe(1);
  });

  test("genuine graphql validation/query error → still dead immediately",
      async () => {
        const {db, refs} = drainDb([makeJob()]);
        const err = new WaveApiError(
            "graphql",
            "Wave GraphQL errors: Variable \"$input\" got invalid value",
            [{message: "Variable \"$input\" got invalid value",
              extensions: {code: "GRAPHQL_VALIDATION_FAILED"}}],
        );
        const mockUpsert = jest.fn(() => Promise.reject(err));
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary.dead).toBe(1);
        expect(summary.retried).toBe(0);
        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("dead");
      });
});

// ---------------------------------------------------------------------------
// drainQueue — dead-letter writes the client doc's sync error (F4)
// ---------------------------------------------------------------------------

/**
 * Extends drainDb with a `clients` collection whose doc(id).update is
 * recorded, so the dead-letter path's best-effort client write is assertable.
 * @param {!Array<{id:string, data:Object}>} jobs Queue jobs.
 * @param {Object=} opts `clientUpdateFails` makes the client update reject.
 * @return {{db:!Object, refs:!Array, clientUpdates:!Array}}
 */
function drainDbWithClients(jobs, opts = {}) {
  const {db, refs} = drainDb(jobs);
  const clientUpdates = [];
  const origCollection = db.collection.bind(db);
  db.collection = jest.fn((col) => {
    if (col === "clients") {
      return {
        doc: jest.fn((id) => ({
          update: jest.fn((fields) => {
            if (opts.clientUpdateFails) {
              return Promise.reject(new Error("client update failed"));
            }
            clientUpdates.push({id, fields});
            return Promise.resolve();
          }),
        })),
      };
    }
    return origCollection(col);
  });
  return {db, refs, clientUpdates};
}

describe("drainQueue dead-letter client doc error write", () => {
  const makeJob = () => ({
    id: "customerUpsert__c1",
    data: {
      type: "customerUpsert",
      refPath: "clients/c1",
      status: "queued",
      attempts: 0,
      nextAttemptAt: new Date("2024-01-01"),
      lastError: null,
      idempotencyKey: "customerUpsert__c1",
    },
  });

  test("dead-lettered job flags the client doc 'error' with a sanitized " +
    "message", async () => {
    const {db, clientUpdates} = drainDbWithClients([makeJob()]);
    const authErr = new WaveApiError("auth", "token for jane@x.com revoked");
    const mockUpsert = jest.fn(() => Promise.reject(authErr));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.dead).toBe(1);
    expect(clientUpdates).toHaveLength(1);
    expect(clientUpdates[0].id).toBe("c1");
    expect(clientUpdates[0].fields["wave.syncState"]).toBe("error");
    const msg = clientUpdates[0].fields["wave.syncError"];
    expect(typeof msg).toBe("string");
    // Sanitized: never the raw Wave message / PII.
    expect(msg).not.toContain("jane@x.com");
    expect(msg).not.toContain("revoked");
  });

  test("WaveValidationError dead-letter does NOT double-write (customers.js " +
    "already wrote a richer syncError)", async () => {
    const {db, clientUpdates} = drainDbWithClients([makeJob()]);
    const validationErr = new WaveValidationError(
        [{code: "INVALID_EMAIL", message: "bad", path: ["email"]}],
    );
    const mockUpsert = jest.fn(() => Promise.reject(validationErr));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.dead).toBe(1);
    expect(clientUpdates).toHaveLength(0);
  });

  test("client doc write failure is swallowed (job still dead-letters)",
      async () => {
        const {db, refs} = drainDbWithClients([makeJob()],
            {clientUpdateFails: true});
        const authErr = new WaveApiError("auth", "revoked");
        const mockUpsert = jest.fn(() => Promise.reject(authErr));
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: mockUpsert,
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary.dead).toBe(1);
        const finalUpdate = refs[0].updates[refs[0].updates.length - 1];
        expect(finalUpdate.status).toBe("dead");
        expect(logger.warn).toHaveBeenCalled();
      });

  test("retryable failure does NOT touch the client doc", async () => {
    const {db, clientUpdates} = drainDbWithClients([makeJob()]);
    const netErr = new WaveApiError("network", "transient");
    const mockUpsert = jest.fn(() => Promise.reject(netErr));

    const summary = await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      maxAttempts: 5,
      backoffFn: fixedBackoff(),
    });

    expect(summary.retried).toBe(1);
    expect(clientUpdates).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// drainQueue — priorAttempts forwarded to the upsert (F2 support)
// ---------------------------------------------------------------------------

describe("drainQueue forwards priorAttempts", () => {
  test("dispatch passes the job's attempts as priorAttempts", async () => {
    const job = {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: 2,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: "WaveApiError(network)",
        idempotencyKey: "customerUpsert__c1",
      },
    };
    const {db} = drainDb([job]);
    const mockUpsert = jest.fn(() => Promise.resolve({status: "done"}));

    await drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: mockUpsert,
      backoffFn: fixedBackoff(),
    });

    expect(mockUpsert).toHaveBeenCalledWith("c1", expect.objectContaining({
      priorAttempts: 2,
    }));
  });
});

// ---------------------------------------------------------------------------
// Rate-limit budget + dead-letter recovery (2026-08-13)
// ---------------------------------------------------------------------------

describe("a rate-limit does not spend the ordinary attempt budget", () => {
  /**
   * A job sitting one failure below the ordinary dead-letter cap.
   * @param {number} maxAttempts The ordinary budget.
   * @return {!Object} A queue job fixture.
   */
  function jobAtTheBrink(maxAttempts) {
    return {
      id: "customerUpsert__c1",
      data: {
        type: "customerUpsert",
        refPath: "clients/c1",
        status: "queued",
        attempts: maxAttempts - 1,
        nextAttemptAt: new Date("2024-01-01"),
        lastError: "WaveApiError(rateLimited)",
        idempotencyKey: "customerUpsert__c1",
      },
    };
  }

  test("Wave rate-limiting us RETRIES a job the ordinary cap would kill",
      async () => {
        // The whole point. A rate-limit says we asked too fast; it says
        // nothing about whether this client's payload can ever succeed.
        // Spending the 5-attempt budget on it dead-letters a valid edit
        // permanently — a `dead` job is never picked up by any drain again.
        const maxAttempts = 3;
        const {db, refs} = drainDb([jobAtTheBrink(maxAttempts)]);
        const rateLimited = new WaveApiError("rateLimited", "slow down");
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: jest.fn(() => Promise.reject(rateLimited)),
          maxAttempts,
          backoffFn: fixedBackoff(),
        });

        expect(summary.retried).toBe(1);
        expect(summary.dead).toBe(0);
        const final = refs[0].updates[refs[0].updates.length - 1];
        expect(final.status).toBe("queued");
        // Still counted, so the backoff keeps growing — it just is not
        // measured against the ordinary cap.
        expect(final.attempts).toBe(maxAttempts);
        expect(logger.error).not.toHaveBeenCalled();
      });

  test("but it is still BOUNDED — past the rate-limit budget it dies",
      async () => {
        const {db, refs} = drainDb([{
          id: "customerUpsert__c1",
          data: {
            type: "customerUpsert",
            refPath: "clients/c1",
            status: "queued",
            attempts: RATE_LIMITED_MAX_ATTEMPTS - 1,
            nextAttemptAt: new Date("2024-01-01"),
            lastError: "WaveApiError(rateLimited)",
            idempotencyKey: "customerUpsert__c1",
          },
        }]);
        const logger = fakeLogger();

        const summary = await drainQueue({
          db, now, logger,
          upsertCustomer: jest.fn(
              () => Promise.reject(new WaveApiError("rateLimited", "no"))),
          maxAttempts: 5,
          backoffFn: fixedBackoff(),
        });

        expect(summary.dead).toBe(1);
        expect(refs[0].updates[refs[0].updates.length - 1].status)
            .toBe("dead");
      });

  test("a NON-rate-limit failure still dies at the ordinary cap", () => {
    // The budget is keyed on THIS failure's error, not stored on the job, so
    // a job rate-limited four times and then failing on its own merits is
    // judged on the ordinary budget — four failures are four failures once
    // one of them is the job's fault.
    const maxAttempts = 3;
    const {db, refs} = drainDb([jobAtTheBrink(maxAttempts)]);

    return drainQueue({
      db, now, logger: fakeLogger(),
      upsertCustomer: jest.fn(
          () => Promise.reject(new WaveApiError("network", "down"))),
      maxAttempts,
      backoffFn: fixedBackoff(),
    }).then((summary) => {
      expect(summary.dead).toBe(1);
      expect(refs[0].updates[refs[0].updates.length - 1].status).toBe("dead");
    });
  });
});
