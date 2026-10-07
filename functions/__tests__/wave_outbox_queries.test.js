"use strict";

const {
  requeueDeadJobs,
  listOutstandingClientIds,
} = require("../wave/outbox_queries");
const {fakeLogger, snap, fakeRef} = require("./mocks/wave_outbox_fakes");

describe("requeueDeadJobs", () => {
  /**
   * A Firestore double holding a fixed set of dead-lettered jobs.
   * @param {!Array<!Object>} jobs `{id, data}` fixtures.
   * @param {!Object=} clientDocs Client docs keyed by `refPath`, for the
   * contract check. An absent path reads as a missing document.
   * @return {!Object} `{db, refs, clientRefs, deletes}`.
   */
  function deadDb(jobs, clientDocs = {}) {
    const refs = jobs.map((j) => fakeRef(j.id, {...j.data}));
    const snapshots = refs.map((ref, i) => snap(jobs[i].id,
        {...jobs[i].data}, ref));
    // Client docs the requeue reads to ask the contract about each job.
    // Absent means "no such client", which must not be mistaken for refused.
    const clientRefs = {};
    for (const [path, data] of Object.entries(clientDocs)) {
      clientRefs[path] = fakeRef(path, {...data});
    }
    const deletes = [];
    const db = {
      collection: jest.fn(() => ({
        where: jest.fn().mockReturnThis(),
        limit: jest.fn().mockReturnThis(),
        get: jest.fn(() => Promise.resolve({docs: snapshots})),
      })),
      doc: jest.fn((path) => {
        if (!clientRefs[path]) clientRefs[path] = fakeRef(path, null);
        return clientRefs[path];
      }),
      runTransaction: jest.fn(async (fn) => fn({
        get: jest.fn((ref) => Promise.resolve(
            snap(ref.id, ref._data, ref))),
        update: jest.fn((ref, fields) => {
          ref.updates.push(fields);
          Object.assign(ref._data, fields);
        }),
        delete: jest.fn((ref) => deletes.push(ref.id)),
      })),
    };
    return {db, refs, clientRefs, deletes};
  }

  /**
   * A dead-lettered job fixture.
   * @param {string} clientId The client it belongs to.
   * @return {!Object}
   */
  function deadJob(clientId) {
    return {
      id: `customerUpsert__${clientId}`,
      data: {
        type: "customerUpsert",
        refPath: `clients/${clientId}`,
        status: "dead",
        attempts: 5,
        lastError: "WaveApiError(graphql)",
        idempotencyKey: `customerUpsert__${clientId}`,
      },
    };
  }

  test("returns dead jobs to the queue with a fresh budget", async () => {
    const {db, refs} = deadDb([deadJob("c1"), deadJob("c2")]);
    const nowDate = new Date("2026-08-13T12:00:00Z");

    const out = await requeueDeadJobs({db, now: () => nowDate});

    expect(out).toEqual({requeued: 2, scanned: 2, blocked: 0});
    for (const ref of refs) {
      const patch = ref.updates[ref.updates.length - 1];
      expect(patch.status).toBe("queued");
      // A full budget and immediate eligibility: the backoff that killed it
      // must not be inherited, or the admin's press does nothing visible.
      expect(patch.attempts).toBe(0);
      expect(patch.nextAttemptAt).toBe(nowDate);
      expect(patch.lastError).toBeNull();
    }
  });

  test("leaves a job a client edit already re-enqueued alone", async () => {
    // The deterministic job id means a concurrent edit rewrites this very
    // doc with the CURRENT payload hash. Resetting the old dead job over it
    // would throw that newer job away.
    const {db, refs} = deadDb([deadJob("c1")]);
    refs[0]._data.status = "queued";

    const out = await requeueDeadJobs({db, now: () => new Date()});

    expect(out).toEqual({requeued: 0, scanned: 1, blocked: 0});
    expect(refs[0].updates).toHaveLength(0);
  });

  test("one stubborn job does not abort the rest of the recovery",
      async () => {
        const {db, refs} = deadDb([deadJob("c1"), deadJob("c2")]);
        const logger = fakeLogger();
        let call = 0;
        const realTxn = db.runTransaction;
        db.runTransaction = jest.fn(async (fn) => {
          call += 1;
          if (call === 1) throw new Error("contention");
          return realTxn(fn);
        });

        const out = await requeueDeadJobs({db, logger, now: () => new Date()});

        expect(out).toEqual({requeued: 1, scanned: 2, blocked: 0});
        expect(logger.warn).toHaveBeenCalledTimes(1);
        expect(refs[1].updates[0].status).toBe("queued");
      });

  test("a dead job whose client the contract REFUSES is dropped, not requeued",
      async () => {
        // "Retry failed" used to requeue everything, and the drain behind it
        // dead-lettered the validation failures again inside the same call —
        // so the count never moved and the button appeared to do nothing.
        const {db, refs, clientRefs, deletes} = deadDb(
            [deadJob("c1")],
            {"clients/c1": {type: "business", name: "", phone: "5145554321"}},
        );

        const out = await requeueDeadJobs({db, now: () => new Date()});

        expect(out).toEqual({requeued: 0, scanned: 1, blocked: 1});
        expect(deletes).toEqual(["customerUpsert__c1"]);
        expect(refs[0].updates).toHaveLength(0);
        // The reason moves onto the client, where it is fixable.
        const patch = clientRefs["clients/c1"].updates[0];
        expect(patch["wave.syncState"]).toBe("blocked");
        expect(patch["wave.problems"]).toEqual([
          {field: "name", code: "EMPTY", severity: "blocking", detail: null},
        ]);
      });

  test("a dead job whose client is fine still requeues", async () => {
    const {db, refs, deletes} = deadDb(
        [deadJob("c1")],
        {"clients/c1": {type: "business", name: "Acme", phone: "5145554321"}},
    );

    const out = await requeueDeadJobs({db, now: () => new Date()});

    expect(out).toEqual({requeued: 1, scanned: 1, blocked: 0});
    expect(deletes).toEqual([]);
    expect(refs[0].updates[0].status).toBe("queued");
  });

  test("a MISSING client doc is requeued, never treated as refused",
      async () => {
        // An absent doc is not a contract refusal — the worker already treats
        // a missing doc as a clean skip, and blocking it would put a reason on
        // a client that does not exist.
        const {db, refs} = deadDb([deadJob("c1")]);

        const out = await requeueDeadJobs({db, now: () => new Date()});

        expect(out).toEqual({requeued: 1, scanned: 1, blocked: 0});
        expect(refs[0].updates[0].status).toBe("queued");
      });

  test("an empty dead set is a clean no-op", async () => {
    const {db} = deadDb([]);
    expect(await requeueDeadJobs({db, now: () => new Date()}))
        .toEqual({requeued: 0, scanned: 0, blocked: 0});
  });
});

// ---------------------------------------------------------------------------
// listOutstandingClientIds — the import's protect list
// ---------------------------------------------------------------------------

describe("listOutstandingClientIds", () => {
  /**
   * A fake queue collection that records the status filter it was handed.
   * @param {!Array<{status: string, clientId: string}>} jobs Queue rows.
   * @return {{db: !Object, filters: !Array<*>}}
   */
  function queueDb(jobs) {
    const filters = [];
    const docs = jobs.map((j, i) => ({
      id: `customerUpsert__${j.clientId}`,
      data: () => ({
        type: "customerUpsert",
        refPath: `clients/${j.clientId}`,
        status: j.status,
      }),
      _i: i,
    }));
    const db = {
      collection: jest.fn(() => ({
        where: jest.fn((field, op, value) => {
          filters.push({field, op, value});
          return {
            limit: jest.fn(() => ({
              get: jest.fn(() => Promise.resolve({docs})),
            })),
          };
        }),
      })),
    };
    return {db, filters};
  }

  test("protects DEAD jobs as well as queued and inflight", async () => {
    // The load-bearing case. A dead job's edit never reached Wave and nothing
    // retries it on its own, so letting the import overwrite that client
    // stamps lastSyncedHash from Wave's pre-edit values — after which
    // waveRetryFailedJobs requeues it, hashes the clobbered doc, matches, and
    // returns `noop`. The admin's change is gone with the row reading synced.
    const {db, filters} = queueDb([
      {status: "queued", clientId: "c1"},
      {status: "inflight", clientId: "c2"},
      {status: "dead", clientId: "c3"},
    ]);

    const ids = await listOutstandingClientIds({db});

    expect(filters[0]).toEqual({
      field: "status",
      op: "in",
      value: ["queued", "inflight", "dead"],
    });
    expect([...ids].sort()).toEqual(["c1", "c2", "c3"]);
  });

  test("warns when the read comes back at the cap", async () => {
    // A truncation is no longer a data loss — the import's own transaction
    // re-checks every write — but it must still be visible.
    const {db} = queueDb([
      {status: "queued", clientId: "c1"},
      {status: "dead", clientId: "c2"},
    ]);
    const logger = fakeLogger();

    await listOutstandingClientIds({db, limit: 2, logger});

    expect(logger.warn).toHaveBeenCalledTimes(1);
  });

  test("an empty queue protects nothing", async () => {
    const {db} = queueDb([]);
    expect((await listOutstandingClientIds({db})).size).toBe(0);
  });
});
