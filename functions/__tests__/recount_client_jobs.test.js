"use strict";

// Pins `recount-client-jobs.js`, the backfill that corrects every client's
// `jobCount` once cancelled visits stop counting.
//
// The properties that matter are the ones that make a bulk write over the
// whole client collection safe: it writes only the docs that actually moved,
// a re-run writes nothing, and `--dry-run` writes nothing at all.

const {
  assertKnownFlags,
  recountClients,
  storedCountOf,
} = require("../scripts/recount-client-jobs");

/**
 * A Firestore fake holding clients and their appointments.
 *
 * The appointment side applies the real filters rather than stubbing counts,
 * so the script is measured against the same inclusion-exclusion the trigger
 * performs instead of against a number the test chose.
 * @param {{clients: !Object, appointments: !Array<!Object>}} data Seed.
 * @return {!Object} `{db, writes}`
 */
function fakeDb({clients, appointments}) {
  const writes = [];
  const matches = (row, filters) =>
    filters.every(({field, op, value}) => {
      const actual = row[field];
      if (op === "==") return actual === value;
      if (op === ">") return typeof actual === "number" && actual > value;
      throw new Error(`unmodelled operator ${op}`);
    });
  const apptNode = (filters) => ({
    where: (field, op, value) => apptNode([...filters, {field, op, value}]),
    count: () => ({
      get: async () => ({
        data: () => ({
          count: appointments.filter((a) => matches(a, filters)).length,
        }),
      }),
    }),
  });
  const clientDoc = (id) => ({
    id,
    ref: {id, path: `clients/${id}`},
    data: () => clients[id],
  });
  const clientsNode = {
    orderBy: () => clientsNode,
    startAfter: (cursor) => ({
      limit: (n) => ({
        get: async () => {
          const ids = Object.keys(clients).sort();
          const from = cursor ? ids.indexOf(cursor) + 1 : 0;
          const page = ids.slice(from, from + n).map(clientDoc);
          return {docs: page, empty: page.length === 0, size: page.length};
        },
      }),
    }),
    limit: (n) => ({
      get: async () => {
        const page = Object.keys(clients).sort().slice(0, n).map(clientDoc);
        return {docs: page, empty: page.length === 0, size: page.length};
      },
    }),
  };
  const db = {
    collection: (name) =>
      name === "appointments" ? apptNode([]) : clientsNode,
    batch: () => ({
      update(ref, data) {
        writes.push({id: ref.id, data});
      },
      set(ref, data) {
        writes.push({id: ref.id, data});
      },
      async commit() {},
    }),
  };
  return {db, writes};
}

const job = (clientId, extra = {}) => ({
  clientId,
  status: "done",
  ...extra,
});

describe("storedCountOf", () => {
  test("reads a real number", () => {
    expect(storedCountOf({jobCount: 4})).toBe(4);
    expect(storedCountOf({jobCount: 0})).toBe(0);
  });

  test("an ABSENT count is null, not zero", () => {
    // A client the trigger never stamped renders no count at all. Reading it
    // as 0 would make every such doc look already-correct and skip it.
    expect(storedCountOf({})).toBeNull();
  });

  test("junk is null rather than trusted", () => {
    expect(storedCountOf({jobCount: "3"})).toBeNull();
    expect(storedCountOf({jobCount: NaN})).toBeNull();
    expect(storedCountOf({jobCount: null})).toBeNull();
  });
});

describe("recountClients", () => {
  test("corrects a count inflated by a cancelled visit", async () => {
    const {db, writes} = fakeDb({
      clients: {c1: {jobCount: 3}},
      appointments: [
        job("c1"),
        job("c1"),
        job("c1", {status: "cancelled"}),
      ],
    });

    const result = await recountClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 1});
    expect(writes).toEqual([{id: "c1", data: {jobCount: 2}}]);
  });

  test("IDEMPOTENT — a client already correct is skipped", async () => {
    // What makes a second run free, and the dry run's number honest.
    const {db, writes} = fakeDb({
      clients: {c1: {jobCount: 2}},
      appointments: [job("c1"), job("c1"), job("c1", {status: "cancelled"})],
    });

    const result = await recountClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 0});
    expect(writes).toEqual([]);
  });

  test("stamps a client that has NO stored count", async () => {
    const {db, writes} = fakeDb({
      clients: {c1: {}},
      appointments: [job("c1")],
    });

    const result = await recountClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 1});
    expect(writes).toEqual([{id: "c1", data: {jobCount: 1}}]);
  });

  test("a client whose every visit was cancelled reads 0, not unset",
      async () => {
        const {db, writes} = fakeDb({
          clients: {c1: {jobCount: 2}},
          appointments: [
            job("c1", {status: "cancelled"}),
            job("c1", {status: "cancelled"}),
          ],
        });

        await recountClients(db, {dryRun: false, verbose: false});

        // The field still exists, so the doc does not vanish from the
        // Most jobs sort — Firestore's orderBy drops a MISSING field.
        expect(writes).toEqual([{id: "c1", data: {jobCount: 0}}]);
      });

  test("a multi-day run still counts as one job", async () => {
    const {db, writes} = fakeDb({
      clients: {c1: {jobCount: 5}},
      appointments: [1, 2, 3, 4, 5].map((d) => job("c1", {dayIndex: d})),
    });

    await recountClients(db, {dryRun: false, verbose: false});

    expect(writes).toEqual([{id: "c1", data: {jobCount: 1}}]);
  });

  test("--dry-run reports the work and writes NOTHING", async () => {
    const {db, writes} = fakeDb({
      clients: {c1: {jobCount: 9}},
      appointments: [job("c1")],
    });

    const result = await recountClients(db, {dryRun: true, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 1});
    expect(writes).toEqual([]);
  });

  test("scans every client, patching only the ones that moved", async () => {
    const {db, writes} = fakeDb({
      clients: {c1: {jobCount: 1}, c2: {jobCount: 7}, c3: {jobCount: 0}},
      appointments: [job("c1"), job("c2"), job("c2", {status: "cancelled"})],
    });

    const result = await recountClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 3, patched: 1});
    expect(writes).toEqual([{id: "c2", data: {jobCount: 1}}]);
  });
});

describe("assertKnownFlags", () => {
  test("accepts the flags it documents", () => {
    expect(() => assertKnownFlags([])).not.toThrow();
    expect(() => assertKnownFlags(["--dry-run"])).not.toThrow();
    expect(() => assertKnownFlags(["--dry-run", "--verbose"])).not.toThrow();
  });

  test("rejects a typo rather than reading it as false", () => {
    // The failure this exists for: `--dryrun` would otherwise parse as absent,
    // and absent means LIVE.
    expect(() => assertKnownFlags(["--dryrun"])).toThrow(/unknown argument/);
    expect(() => assertKnownFlags(["--since=2026-01-01"]))
        .toThrow(/unknown argument/);
  });
});
