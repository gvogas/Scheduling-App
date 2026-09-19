"use strict";

/** `wave/triggers.js` had no test file of its own. */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../wave/worker", () => ({
  enqueueCustomerUpsert: jest.fn(),
  cancelCustomerUpsert: jest.fn(),
  drainQueue: jest.fn(),
  shouldEnqueueClientWrite: jest.fn(),
  isBlockedRevertToSynced: jest.fn(),
}));
jest.mock("../wave/sync_run", () => ({
  importWithWatermark: jest.fn(),
  readWaveBusinessIdCached: jest.fn(),
  readWaveConnection: jest.fn(),
}));

const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const worker = require("../wave/worker");
const syncRun = require("../wave/sync_run");
const {statePatch} = require("../wave/customer_contract");
const {mappedFieldsHash} = require("../wave/mappers");
const realEnqueue = jest.requireActual("../wave/enqueue");
const {waveUpsertCustomer, runWaveDaily} = require("../wave/triggers");

const snapOf = (data) => ({exists: data !== null, data: () => data});

const makeEvent = (clientId, before, after) => ({
  params: {clientId},
  data: {before: snapOf(before), after: snapOf(after)},
});

/**
 * Firestore double recording the batch this trigger builds.
 * @param {!Object=} opts `connection` doc data, `connectionError` to throw on
 * the read, or `commitError` to throw on commit.
 * @return {!Object} `{db, batchUpdates, commits}`
 */
function makeDb(opts = {}) {
  const batchUpdates = [];
  const commits = [];
  const docUpdates = [];
  const db = {
    batch: () => ({
      update: (ref, patch) => batchUpdates.push({ref, patch}),
      commit: async () => {
        commits.push(batchUpdates.length);
        if (opts.commitError) throw opts.commitError;
      },
    }),
    doc: (p) => ({
      __path: p,
      update: async (patch) => {
        docUpdates.push({path: p, patch});
      },
    }),
    collection: () => ({
      doc: () => ({
        get: async () => {
          if (opts.connectionError) throw opts.connectionError;
          return snapOf(
              opts.connection === undefined ? null : opts.connection);
        },
      }),
    }),
  };
  return {db, batchUpdates, commits, docUpdates};
}

const IDLE_DRAIN = {
  processed: 0, done: 0, retried: 0, dead: 0, skipped: 0, reclaimed: 0,
};

beforeEach(() => {
  jest.clearAllMocks();
  FieldValue.serverTimestamp = jest.fn(() => "TS");
  worker.shouldEnqueueClientWrite.mockReturnValue(true);
  worker.isBlockedRevertToSynced.mockReturnValue(false);
  worker.enqueueCustomerUpsert.mockResolvedValue(undefined);
  worker.cancelCustomerUpsert.mockResolvedValue(false);
  worker.drainQueue.mockResolvedValue(IDLE_DRAIN);
  syncRun.readWaveBusinessIdCached.mockResolvedValue("");
  // Stands in for the shared connection read so `makeDb`'s `connection` /
  // `connectionError` options still drive these tests. The COERCION itself is
  // proved against the real `sync_run` in `wave_callables.test.js`; all this
  // double owes the rider is the shape and the throw.
  syncRun.readWaveConnection.mockImplementation(async () => {
    const ref = getFirestore().collection("wave").doc("connection");
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : null;
    return {
      ref,
      data,
      businessId: (data && data.businessId) || "",
      businessName: (data && data.businessName) || "",
    };
  });
});

describe("waveUpsertCustomer mark-pending batch", () => {
  // A business named only by its own phone number is the shape that produced
  // the 2026-08-30 dead letter, so it is the one worth carrying here.
  const CLIENT = {
    type: "business",
    name: "5145554321",
    phone: "5145554321",
    email: "shop@example.com",
  };

  test("carries the contract's wave.problems patch, not just syncState",
      async () => {
        const {db, batchUpdates} = makeDb();
        getFirestore.mockReturnValue(db);

        await waveUpsertCustomer.run(makeEvent("c1", null, CLIENT));

        expect(batchUpdates).toHaveLength(1);
        const {patch} = batchUpdates[0];
        expect(patch["wave.syncState"]).toBe("pending");
        expect(patch["wave.syncError"]).toBeNull();

        const expected = statePatch(CLIENT);
        expect(Object.keys(expected).length).toBeGreaterThan(0);
        for (const [k, v] of Object.entries(expected)) {
          expect(patch[k]).toEqual(v);
        }
      });

  test("rides the SAME batch as the enqueue, so neither can land alone",
      async () => {
        const {db, commits} = makeDb();
        getFirestore.mockReturnValue(db);

        await waveUpsertCustomer.run(makeEvent("c1", null, CLIENT));

        expect(worker.enqueueCustomerUpsert).toHaveBeenCalledWith(
            "c1",
            expect.objectContaining({batch: expect.anything()}),
        );
        expect(commits).toEqual([1]);
      });

  test("a REFUSED client is never enqueued and never drained", async () => {
    // The whole point of enforcement: a payload Wave would refuse must not
    // become a queued job, because the push dead-letters permanently and
    // "Retry failed" re-sends the identical payload into the identical
    // refusal.
    const {db, batchUpdates, docUpdates} = makeDb();
    getFirestore.mockReturnValue(db);

    await waveUpsertCustomer.run(makeEvent("c1", null, {...CLIENT, name: ""}));

    // A refused client never enters the mark-pending batch — that batch exists
    // to pair the pending state with an enqueue, and there is no enqueue.
    expect(batchUpdates).toHaveLength(0);
    expect(docUpdates).toHaveLength(1);
    const {patch} = docUpdates[0];
    expect(patch["wave.syncState"]).toBe("blocked");
    expect(patch["wave.problems"]).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
    expect(worker.drainQueue).not.toHaveBeenCalled();
  });

  test("a refused client cancels a job an earlier edit left queued",
      async () => {
        // The worker re-reads the LIVE doc, so a job queued before the edit
        // would push the now-invalid document.
        const {db} = makeDb();
        getFirestore.mockReturnValue(db);

        await waveUpsertCustomer.run(
            makeEvent("c1", CLIENT, {...CLIENT, name: ""}));

        expect(worker.cancelCustomerUpsert).toHaveBeenCalledWith("c1");
      });

  test("an ADVISORY problem still enqueues", async () => {
    // Wave accepts it. Blocking here would strand a client that syncs fine —
    // the failure the severity split exists to prevent.
    const {db, batchUpdates} = makeDb();
    getFirestore.mockReturnValue(db);

    await waveUpsertCustomer.run(
        makeEvent("c1", null, {...CLIENT, phone: "Contact Person"}));

    const {patch} = batchUpdates[0];
    expect(patch["wave.syncState"]).toBe("pending");
    expect(patch["wave.problems"]).toEqual([
      {field: "phone", code: "NOT_DIALABLE", severity: "advisory",
        detail: null},
    ]);
    expect(worker.enqueueCustomerUpsert).toHaveBeenCalled();
  });

  test("a client edited OUT of a blocking state re-enqueues by itself",
      async () => {
        // Auto-heal, with no button press: every blocking problem is on a
        // MAPPED field, so the fix changes the hash and the trigger fires.
        const {db, batchUpdates} = makeDb();
        getFirestore.mockReturnValue(db);

        await waveUpsertCustomer.run(
            makeEvent("c1", {...CLIENT, name: ""}, CLIENT));

        const {patch} = batchUpdates[0];
        expect(patch["wave.syncState"]).toBe("pending");
        expect(patch["wave.problems"]).toBeNull();
        expect(worker.enqueueCustomerUpsert).toHaveBeenCalled();
      });

  test("the batch-commit fallback still records the contract verdict",
      async () => {
        // The fallback used to re-enqueue with NO problems patch, so the doc
        // changed and the record of what is wrong with it did not.
        const {db, docUpdates} = makeDb(
            {commitError: new Error("doc deleted")});
        getFirestore.mockReturnValue(db);

        await waveUpsertCustomer.run(makeEvent("c1", null, CLIENT));

        expect(worker.enqueueCustomerUpsert).toHaveBeenCalledTimes(2);
        expect(worker.enqueueCustomerUpsert).toHaveBeenLastCalledWith(
            "c1", expect.objectContaining({payloadHash: expect.any(String)}));
        expect(docUpdates).toHaveLength(1);
        // Bracketed: Jest reads a dotted string as a PATH, and this key
        // literally contains a dot.
        expect(docUpdates[0].patch).toHaveProperty(["wave.problems"]);
      });

  test("a deleted client enqueues nothing", async () => {
    const {db, batchUpdates} = makeDb();
    getFirestore.mockReturnValue(db);

    await waveUpsertCustomer.run(makeEvent("c1", CLIENT, null));

    expect(batchUpdates).toEqual([]);
    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
  });

  test("a failed batch commit still enqueues, without the patch", async () => {
    const {db} = makeDb({commitError: new Error("doc gone")});
    getFirestore.mockReturnValue(db);

    await waveUpsertCustomer.run(makeEvent("c1", null, CLIENT));

    // Second call is the fallback: enqueue-only, no batch.
    expect(worker.enqueueCustomerUpsert).toHaveBeenCalledTimes(2);
    const last = worker.enqueueCustomerUpsert.mock.calls[1][1];
    expect(last.batch).toBeUndefined();
  });
});

describe("waveUpsertCustomer stale block on a revert to last-synced", () => {
  const CLIENT = {
    type: "business",
    name: "Plomberie Nord",
    phone: "5145554321",
    email: "shop@example.com",
  };

  /**
   * Applies a doc update's dotted `wave.*` keys, as Firestore would.
   * @param {!Object} doc Client document data.
   * @param {!Object} patch Dotted-key patch.
   * @return {!Object} The updated document data.
   */
  function applyPatch(doc, patch) {
    const wave = {...(doc.wave || {})};
    for (const [k, v] of Object.entries(patch)) wave[k.slice(5)] = v;
    return {...doc, wave};
  }

  beforeEach(() => {
    worker.shouldEnqueueClientWrite.mockImplementation(
        realEnqueue.shouldEnqueueClientWrite);
    worker.isBlockedRevertToSynced.mockImplementation(
        realEnqueue.isBlockedRevertToSynced);
  });

  test("synced -> blocked -> reverted clears the block to synced", async () => {
    const {db, docUpdates} = makeDb();
    getFirestore.mockReturnValue(db);
    const synced = {
      ...CLIENT,
      wave: {syncState: "synced", lastSyncedHash: mappedFieldsHash(CLIENT)},
    };

    const broken = {...synced, name: ""};
    await waveUpsertCustomer.run(makeEvent("c1", synced, broken));
    expect(docUpdates).toHaveLength(1);
    const blocked = applyPatch(broken, docUpdates[0].patch);
    expect(blocked.wave.syncState).toBe("blocked");

    await waveUpsertCustomer.run(makeEvent("c1", broken, blocked));
    expect(docUpdates).toHaveLength(1);

    const reverted = {...blocked, name: CLIENT.name};
    await waveUpsertCustomer.run(makeEvent("c1", blocked, reverted));
    expect(docUpdates).toHaveLength(2);
    expect(docUpdates[1].patch).toEqual({
      "wave.syncState": "synced",
      "wave.syncError": null,
      "wave.problems": null,
    });
    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();

    const cleared = applyPatch(reverted, docUpdates[1].patch);
    await waveUpsertCustomer.run(makeEvent("c1", reverted, cleared));
    expect(docUpdates).toHaveLength(2);
    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
  });

  test("a revert to last-synced values that still fail stays blocked",
      async () => {
        const {db, docUpdates} = makeDb();
        getFirestore.mockReturnValue(db);
        const stale = {...CLIENT, name: ""};
        const problems = statePatch(stale)["wave.problems"];
        const blocked = {
          ...stale,
          phone: "5145559999",
          wave: {
            syncState: "blocked",
            problems,
            lastSyncedHash: mappedFieldsHash(stale),
          },
        };
        const reverted = {...blocked, phone: CLIENT.phone};

        await waveUpsertCustomer.run(makeEvent("c1", blocked, reverted));

        expect(docUpdates).toEqual([]);
        expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
      });

  test("an unmapped edit on a blocked doc does not re-evaluate", async () => {
    const {db, docUpdates} = makeDb();
    getFirestore.mockReturnValue(db);
    const blocked = {
      ...CLIENT,
      wave: {syncState: "blocked", lastSyncedHash: mappedFieldsHash(CLIENT)},
    };
    const edited = {...blocked, contacts: [{name: "A"}]};

    await waveUpsertCustomer.run(makeEvent("c1", blocked, edited));

    expect(docUpdates).toEqual([]);
  });
});

describe("runWaveDaily connection read", () => {
  test("a THROWING connection read returns quietly, never rejects",
      async () => {
        // The JSDoc says "never throws", and the caller is a rider on a
        // user-facing push whose real work has already completed.
        const {db} = makeDb({connectionError: new Error("unavailable")});
        getFirestore.mockReturnValue(db);

        await expect(runWaveDaily()).resolves.toBeUndefined();

        expect(logger.warn).toHaveBeenCalledWith(
            expect.stringContaining("connection read failed"),
            expect.anything(),
        );
        expect(worker.drainQueue).not.toHaveBeenCalled();
      });

  test("no connection doc means nothing to do", async () => {
    const {db} = makeDb();
    getFirestore.mockReturnValue(db);

    await expect(runWaveDaily()).resolves.toBeUndefined();
    expect(worker.drainQueue).not.toHaveBeenCalled();
  });

  test("drains the outbox, and never imports", async () => {
    // The scheduled pull was deleted in Wave Phase 4; a connection doc still
    // carrying the old cadence field must not bring it back.
    const {db} = makeDb({
      connection: {businessId: "biz-1", importSchedule: "weekly"},
    });
    getFirestore.mockReturnValue(db);

    await runWaveDaily();

    expect(worker.drainQueue).toHaveBeenCalledTimes(1);
    expect(syncRun.importWithWatermark).not.toHaveBeenCalled();
  });

  test("a failing drain resolves quietly and is logged", async () => {
    worker.drainQueue.mockRejectedValueOnce(new Error("drain boom"));
    const {db} = makeDb({connection: {businessId: "biz-1"}});
    getFirestore.mockReturnValue(db);

    await expect(runWaveDaily()).resolves.toBeUndefined();

    expect(logger.warn).toHaveBeenCalledWith(
        expect.stringContaining("drain failed"), expect.anything());
  });
});
