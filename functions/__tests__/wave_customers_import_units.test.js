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

  test("the update branch never writes a nested wave map", () => {
    // A nested object under `merge: true` REPLACES the whole map, which is how
    // the import erased `wave.problems` and reset a blocked client to synced.
    // Dotted keys leave sibling keys alone.
    const ctx = ctxFor({
      existingByWaveId: new Map([
        ["wave-1", {ref: {id: "c1"}, hasCreatedAt: true, lastSyncedHash: "x"}],
      ]),
    });
    expect(importOneCustomer(node(), ctx)).toBe(true);
    const written = ctx.batch.sets[0].data;
    expect(written.wave).toBeUndefined();
    expect(written["wave.syncState"]).toBe("synced");
    expect(written["wave.syncError"]).toBeNull();
    expect(typeof written["wave.lastSyncedHash"]).toBe("string");
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
    expect(importOneCustomer(node({name: ""}), ctx)).toBe(true);
    const written = ctx.batch.sets[0].data;
    expect(written["wave.syncState"]).toBe("blocked");
    expect(written["wave.problems"]).toEqual([
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
    expect(ctx.batch.sets[0].data["wave.problems"]).toBeNull();
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
    expect(importOneCustomer(node(), rerun)).toBe(true);
    expect(rerun.summary.skippedUnchanged).toBe(0);
    expect(rerun.summary.updated).toBe(1);
    expect(rerun.batch.sets[0].data.createdAt).toBe("SERVER_TS");
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
    expect(importOneCustomer(node(), ctx)).toBe(true);
    expect(ctx.summary.updated).toBe(1);
    const {data, options} = ctx.batch.sets[0];
    expect(options).toEqual({merge: true});
    expect(data.createdAt).toBeUndefined();
    expect(data).not.toHaveProperty("archived");
    expect(data.updatedAt).toBe("SERVER_TS");
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
