"use strict";

/**
 * Direct tests for the two decisions `importCustomers`' page loop delegates.
 *
 * `customers_import.js` exports them under a comment saying they are "exported
 * so the two decisions the page loop delegates can be driven directly from a
 * unit test" — and no such test existed. They were covered only indirectly,
 * through `importCustomers`, which reaches each branch a couple at a time
 * behind a GraphQL mock. What they decide is destructive: `importOneCustomer`
 * chooses between overwriting a client that has a LOCAL EDIT still queued for
 * Wave (which would destroy that edit permanently) and leaving it alone, and
 * `buildWaveIdIndex` produces the shape that decision is made against.
 */

const {
  importOneCustomer,
  commitGuardedUpdates,
  buildWaveIdIndex,
} = require("../wave/customers_import");

/**
 * A Wave customer node, with only the fields these decisions read.
 * @param {!Object=} over Fields to replace.
 * @return {!Object} A customer node.
 */
const node = (over) => ({
  id: "wave-1",
  name: "Acme Plumbing",
  isArchived: false,
  ...over,
});

/**
 * A fresh summary in the shape `importCustomers` keeps.
 * @return {!Object} A zeroed summary.
 */
const newSummary = () => ({
  totalCount: 0,
  imported: 0,
  updated: 0,
  skippedArchived: 0,
  skippedPending: 0,
  skippedUnchanged: 0,
  pages: 0,
  delta: false,
});

/**
 * A batch that records writes instead of committing them.
 * @return {!Object} A recording batch.
 */
function fakeBatch() {
  const sets = [];
  return {
    sets,
    set: (ref, data, options) => sets.push({ref, data, options}),
  };
}

/**
 * A db whose `clients` collection mints predictable auto ids.
 * @return {!Object} A db handle.
 */
function fakeDb() {
  let n = 0;
  return {
    collection: () => ({doc: () => ({id: `auto-${++n}`})}),
  };
}

/**
 * The context `importCustomers` hands the delegate, with overrides.
 * @param {!Object=} over Fields to replace.
 * @return {!Object} A fresh context.
 */
function ctxFor(over) {
  return {
    db: fakeDb(),
    batch: fakeBatch(),
    now: () => "SERVER_TS",
    summary: newSummary(),
    skipClientIds: new Set(),
    existingByWaveId: new Map(),
    guarded: [],
    ...(over || {}),
  };
}

describe("importOneCustomer", () => {
  test("a missing node writes nothing and counts nothing", () => {
    const ctx = ctxFor();
    expect(importOneCustomer(null, ctx)).toBe(false);
    expect(ctx.batch.sets).toHaveLength(0);
    expect(ctx.summary).toEqual(newSummary());
  });

  test("an archived customer is skipped, not imported as archived", () => {
    // Wave archiving is how a customer is retired there; importing one would
    // put a dead client back in the app's list.
    const ctx = ctxFor();
    expect(importOneCustomer(node({isArchived: true}), ctx)).toBe(false);
    expect(ctx.summary.skippedArchived).toBe(1);
    expect(ctx.batch.sets).toHaveLength(0);
  });

  test("a new customer is created with archived/createdAt/updatedAt", () => {
    // All three are required: the clients list ORDERS by createdAt and FILTERS
    // on archived, and Firestore excludes a document missing an orderBy
    // field — so omitting either makes the client invisible in the list while
    // still turning up in search.
    const ctx = ctxFor();
    expect(importOneCustomer(node(), ctx)).toBe(true);
    expect(ctx.summary.imported).toBe(1);
    expect(ctx.batch.sets).toHaveLength(1);
    const written = ctx.batch.sets[0].data;
    expect(written.archived).toBe(false);
    expect(written.createdAt).toBe("SERVER_TS");
    expect(written.updatedAt).toBe("SERVER_TS");
    expect(written.wave.syncState).toBe("synced");
    expect(written.wave.syncError).toBeNull();
    expect(typeof written.wave.lastSyncedHash).toBe("string");
    expect(written.wave.lastSyncedHash).not.toBe("");
  });

  test("a duplicate Wave id inside one run collapses to one document", () => {
    // The index is seeded from the doc just created, so the second edge
    // UPDATES rather than creating a second client for the same Wave customer.
    const ctx = ctxFor();
    importOneCustomer(node(), ctx);
    importOneCustomer(node({name: "Acme Plumbing Ltd"}), ctx);
    expect(ctx.summary.imported).toBe(1);
    expect(ctx.summary.updated).toBe(1);
    expect(ctx.batch.sets).toHaveLength(2);
    expect(ctx.batch.sets[1].ref.id).toBe(ctx.batch.sets[0].ref.id);
  });

  test("a duplicate after its create's batch COMMITTED is guarded", () => {
    // Once flushed, an admin edit can enqueue a job for the new client.
    const ctx = ctxFor();
    importOneCustomer(node(), ctx);
    const later = {...ctx, batch: fakeBatch()};
    expect(importOneCustomer(node({name: "Acme Plumbing Ltd"}), later))
        .toBe(false);
    expect(later.batch.sets).toHaveLength(0);
    expect(later.guarded).toHaveLength(1);
    expect(later.guarded[0].ref.id).toBe(ctx.batch.sets[0].ref.id);
  });

  test("an existing client's write is HELD for the guarded commit", () => {
    // Never batched: the outbox check has to share a transaction with the
    // write, so the counter moves only when that commit decides.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    expect(importOneCustomer(node(), ctx)).toBe(false);
    expect(ctx.batch.sets).toHaveLength(0);
    expect(ctx.guarded).toHaveLength(1);
    expect(ctx.guarded[0].ref.id).toBe("c1");
    expect(ctx.summary.updated).toBe(0);
  });

  test("a client with an un-pushed local edit is left alone", () => {
    // THE ONE THAT DESTROYS DATA. Writing here would also stamp
    // lastSyncedHash from Wave's values, which turns the queued push into a
    // no-op — so the local edit is lost with nothing anywhere reporting it.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
      skipClientIds: new Set(["c1"]),
    });
    expect(importOneCustomer(node(), ctx)).toBe(false);
    expect(ctx.summary.skippedPending).toBe(1);
    expect(ctx.batch.sets).toHaveLength(0);
  });

  test("the update branch merges the wave map per LEAF", () => {
    // `set(..., {merge: true})` masks a nested plain object at its leaves
    // (`wave.syncState`, `wave.problems`, ...), so it merges per key and
    // cannot erase a sibling. It also does not parse a dot as a path, so the
    // dotted spelling would write a literal "wave.syncState" field instead.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    expect(importOneCustomer(node(), ctx)).toBe(false);
    const written = ctx.guarded[0].update;
    expect(written["wave.syncState"]).toBeUndefined();
    expect(written.wave.syncState).toBe("synced");
    expect(written.wave.syncError).toBeNull();
    expect(typeof written.wave.lastSyncedHash).toBe("string");
  });

  test("the update branch re-runs the contract over the merged fields", () => {
    // The import has just written Wave's values over the doc, so the stored
    // problems may no longer describe it — and a client Wave sends back with
    // a blank name must not come out reading `synced`.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    expect(importOneCustomer(node({name: ""}), ctx)).toBe(false);
    const written = ctx.guarded[0].update;
    expect(written.wave.syncState).toBe("blocked");
    expect(written.wave.problems).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
  });

  test("a clean update clears any stale problems", () => {
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    importOneCustomer(node(), ctx);
    expect(ctx.guarded[0].update.wave.problems).toBeNull();
  });

  test("the update branch writes a NESTED wave map, never dotted keys", () => {
    // `set(..., {merge: true})` does NOT parse a dot as a field path —
    // `DocumentMask.fromObject` builds `new FieldPath(key)` from the whole
    // key, so a dotted key here creates a literal top-level field called
    // "wave.syncState" and leaves the real one untouched. That silently made
    // the import's enforcement inert AND stopped `wave.lastSyncedHash` from
    // advancing, which re-enters every imported client into the outbox.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    importOneCustomer(node({name: ""}), ctx);
    const data = ctx.guarded[0].update;
    expect(Object.keys(data).some((k) => k.includes("."))).toBe(false);
    expect(data.wave.syncState).toBe("blocked");
    expect(typeof data.wave.lastSyncedHash).toBe("string");
  });

  test("the create branch records the contract verdict too", () => {
    const ctx = ctxFor();
    importOneCustomer(node({name: ""}), ctx);
    const written = ctx.batch.sets[0].data;
    expect(written.wave.syncState).toBe("blocked");
    expect(written.wave.problems).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
  });

  test("an unchanged customer is skipped, not counted as updated", () => {
    // `updated` used to count every existing customer written, so a sync over
    // an untouched roster told the admin "650 clients updated".
    const ctx = ctxFor();
    importOneCustomer(node(), ctx);
    const hash = ctx.batch.sets[0].data.wave.lastSyncedHash;

    const rerun = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: hash}],
      ]),
    });
    expect(importOneCustomer(node(), rerun)).toBe(false);
    expect(rerun.summary.skippedUnchanged).toBe(1);
    expect(rerun.summary.updated).toBe(0);
    expect(rerun.batch.sets).toHaveLength(0);
  });

  test("a matching hash still writes when createdAt is missing", () => {
    // `hasCreatedAt` is NOT optional in that skip. The clients list orders by
    // createdAt, so a legacy doc without one stays permanently invisible there
    // unless this backfill runs.
    const ctx = ctxFor();
    importOneCustomer(node(), ctx);
    const hash = ctx.batch.sets[0].data.wave.lastSyncedHash;

    const rerun = ctxFor({
      existingByWaveId: new Map([
        [
          "wave-1",
          {ref: {id: "c1"}, hasCreatedAt: false, lastSyncedHash: hash},
        ],
      ]),
    });
    expect(importOneCustomer(node(), rerun)).toBe(false);
    expect(rerun.summary.skippedUnchanged).toBe(0);
    expect(rerun.guarded).toHaveLength(1);
    expect(rerun.guarded[0].update.createdAt).toBe("SERVER_TS");
  });

  test("an update preserves createdAt and never re-stamps archived", () => {
    // Setting `archived: false` on the update branch would un-archive every
    // archived client on every scheduled import.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        [
          "wave-1",
          {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "old"},
        ],
      ]),
    });
    expect(importOneCustomer(node(), ctx)).toBe(false);
    const data = ctx.guarded[0].update;
    expect(data.createdAt).toBeUndefined();
    expect(data).not.toHaveProperty("archived");
    expect(data.updatedAt).toBe("SERVER_TS");
  });
});

describe("commitGuardedUpdates", () => {
  /**
   * A db whose transactions read one fake queue and record their writes.
   * @param {!Object=} jobs Job docs keyed by job id.
   * @param {!Set<string>=} throwFor Job ids whose read throws.
   * @return {!Object} `{db, sets, reads}`.
   */
  function txDb(jobs = {}, throwFor = new Set()) {
    const sets = [];
    const reads = [];
    const db = {
      collection: (name) => ({doc: (id) => ({path: `${name}/${id}`, id})}),
      runTransaction: async (fn) => fn({
        get: async (ref) => {
          reads.push(ref.path);
          if (throwFor.has(ref.id)) throw new Error("contention");
          const data = jobs[ref.id];
          return {exists: data !== undefined, data: () => data};
        },
        set: (ref, data, options) => sets.push({ref, data, options}),
      }),
    };
    return {db, sets, reads};
  }

  const held = (id) => ({ref: {id}, update: {name: `n-${id}`}});
  const logger = () => ({warn: jest.fn()});

  test("writes the update when the client has no outbox job", async () => {
    const {db, sets} = txDb();
    const summary = newSummary();

    await commitGuardedUpdates(db, [held("c1")], summary, logger());

    expect(sets).toEqual([
      {ref: {id: "c1"}, data: {name: "n-c1"}, options: {merge: true}},
    ]);
    expect(summary.updated).toBe(1);
    expect(summary.skippedPending).toBe(0);
  });

  test("reads that client's own job inside the writing transaction",
      async () => {
        // The whole point: a protect-list read before the run cannot see a
        // job enqueued mid-import. Reading the job in the same transaction
        // as the write makes a concurrent enqueue abort and retry it.
        const {db, reads} = txDb();

        await commitGuardedUpdates(
            db, [held("c1")], newSummary(), logger());

        expect(reads).toEqual(["waveSyncQueue/customerUpsert__c1"]);
      });

  test.each(["queued", "inflight", "dead"])(
      "a %s job holds the write back and counts as pending",
      async (status) => {
        const {db, sets} = txDb({customerUpsert__c1: {status}});
        const summary = newSummary();

        await commitGuardedUpdates(db, [held("c1")], summary, logger());

        expect(sets).toHaveLength(0);
        expect(summary.skippedPending).toBe(1);
        expect(summary.updated).toBe(0);
      });

  test("a job that already reached Wave does not hold it back", async () => {
    const {db, sets} = txDb({customerUpsert__c1: {status: "done"}});
    const summary = newSummary();

    await commitGuardedUpdates(db, [held("c1")], summary, logger());

    expect(sets).toHaveLength(1);
    expect(summary.updated).toBe(1);
  });

  test("a failed transaction is held for the next run and logged",
      async () => {
        // Counted as pending so the watermark is held and the next run
        // retries that customer; one failure must not abort the others.
        const {db, sets} = txDb({}, new Set(["customerUpsert__c1"]));
        const summary = newSummary();
        const log = logger();

        await commitGuardedUpdates(
            db, [held("c1"), held("c2")], summary, log);

        expect(summary.skippedPending).toBe(1);
        expect(summary.updated).toBe(1);
        expect(sets.map((s) => s.ref.id)).toEqual(["c2"]);
        expect(log.warn).toHaveBeenCalledTimes(1);
      });

  test("commits every update when there are more than one chunk",
      async () => {
        const {db, sets} = txDb();
        const summary = newSummary();
        const many = Array.from({length: 60}, (_, i) => held(`c${i}`));

        await commitGuardedUpdates(db, many, summary, logger());

        expect(sets).toHaveLength(60);
        expect(summary.updated).toBe(60);
      });
});

describe("buildWaveIdIndex", () => {
  /**
   * A clients collection returning `docs`, honouring the select() projection.
   * @param {!Array<!Object>} docs Fake client snapshots.
   * @return {!Object} A db handle.
   */
  const dbWith = (docs) => {
    const coll = {
      select: () => coll,
      get: () => Promise.resolve({docs}),
    };
    return {collection: () => coll};
  };

  /**
   * One fake client snapshot.
   * @param {string} id Document id.
   * @param {!Object} data Stored fields.
   * @return {!Object} A snapshot.
   */
  const clientDoc = (id, data) => ({id, ref: {id}, data: () => data});

  test("keys by waveCustomerId and carries both decision inputs", async () => {
    const index = await buildWaveIdIndex(dbWith([
      clientDoc("c1", {
        waveCustomerId: "wave-1",
        createdAt: "ts",
        wave: {lastSyncedHash: "h1"},
      }),
    ]));

    expect(index.size).toBe(1);
    expect(index.get("wave-1")).toEqual({
      ref: {id: "c1"},
      hasCreatedAt: true,
      lastSyncedHash: "h1",
    });
  });

  test("skips a client that is not linked to Wave", async () => {
    // An app-created client has no waveCustomerId, and indexing it under ""
    // would make every unlinked client collide on one key.
    const index = await buildWaveIdIndex(dbWith([
      clientDoc("c1", {}),
      clientDoc("c2", {waveCustomerId: ""}),
      clientDoc("c3", {waveCustomerId: 42}),
    ]));
    expect(index.size).toBe(0);
  });

  test("a missing createdAt reads as false, not as absent", async () => {
    // This is what makes the backfill branch in importOneCustomer reachable.
    const index = await buildWaveIdIndex(dbWith([
      clientDoc("c1", {waveCustomerId: "wave-1"}),
    ]));
    expect(index.get("wave-1").hasCreatedAt).toBe(false);
  });

  test("a missing or malformed wave map reads as an empty hash", async () => {
    // An empty hash can never equal a real one, so the unchanged-skip is never
    // taken on a doc whose sync state is unknown — fail toward writing.
    const index = await buildWaveIdIndex(dbWith([
      clientDoc("c1", {waveCustomerId: "wave-1"}),
      clientDoc("c2", {waveCustomerId: "wave-2", wave: "not-a-map"}),
      clientDoc("c3", {waveCustomerId: "wave-3", wave: {lastSyncedHash: 7}}),
    ]));
    expect(index.get("wave-1").lastSyncedHash).toBe("");
    expect(index.get("wave-2").lastSyncedHash).toBe("");
    expect(index.get("wave-3").lastSyncedHash).toBe("");
  });

  test("an empty snapshot is an empty index, not a throw", async () => {
    const coll = {select: () => coll, get: () => Promise.resolve({})};
    const index = await buildWaveIdIndex({collection: () => coll});
    expect(index.size).toBe(0);
  });
});
