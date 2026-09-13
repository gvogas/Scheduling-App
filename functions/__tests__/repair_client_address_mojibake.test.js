"use strict";

// Pins `repair-client-address-mojibake.js`: it repairs only corrupt address
// fields, rebuilds the search index with them, and a re-run or dry run writes
// nothing.

const {
  assertKnownFlags,
  repairClients,
  repairPatchFor,
} = require("../scripts/repair-client-address-mojibake");
const {clientSearchTokens} = require("../search_tokens");

/**
 * A Firestore fake holding only /clients.
 * @param {!Object} clients Seed docs by id.
 * @return {!Object} `{db, writes}`
 */
function fakeDb(clients) {
  const writes = [];
  const clientDoc = (id) => ({
    id,
    ref: {id, path: `clients/${id}`},
    data: () => clients[id],
  });
  const page = (from, n) => {
    const docs = Object.keys(clients).sort().slice(from, from + n)
        .map(clientDoc);
    return {docs, empty: docs.length === 0, size: docs.length};
  };
  const clientsNode = {
    orderBy: () => clientsNode,
    startAfter: (cursor) => ({
      limit: (n) => ({
        get: async () => {
          const ids = Object.keys(clients).sort();
          return page(cursor ? ids.indexOf(cursor) + 1 : 0, n);
        },
      }),
    }),
    limit: (n) => ({get: async () => page(0, n)}),
  };
  const db = {
    collection: () => clientsNode,
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

const corrupt = {
  name: "5145550000",
  address: "12 Rue Principale",
  city: "Calixa-Lavallã©E",
  province: "QC",
};

describe("repairPatchFor", () => {
  test("repairs the corrupt field and rebuilds searchTokens", () => {
    const patch = repairPatchFor(corrupt);

    expect(patch.city).toBe("Calixa-Lavallée");
    expect(patch).not.toHaveProperty("address");
    expect(patch.searchTokens)
        .toEqual(clientSearchTokens({...corrupt, city: "Calixa-Lavallée"}));
  });

  test("a clean client needs no patch", () => {
    expect(repairPatchFor({...corrupt, city: "Calixa-Lavallée"})).toBeNull();
    expect(repairPatchFor({})).toBeNull();
    expect(repairPatchFor(null)).toBeNull();
  });

  test("never rewrites a name, even one that looks corrupt", () => {
    expect(repairPatchFor({name: "Lavallã©E", city: "Montréal"})).toBeNull();
  });

  test("ignores non-string address fields", () => {
    expect(repairPatchFor({address: null, city: 42})).toBeNull();
  });
});

describe("repairClients", () => {
  test("patches only the corrupt clients", async () => {
    const {db, writes} = fakeDb({
      c1: corrupt,
      c2: {city: "Montréal"},
    });

    const result = await repairClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 2, patched: 1});
    expect(writes.map((w) => w.id)).toEqual(["c1"]);
    expect(writes[0].data.city).toBe("Calixa-Lavallée");
  });

  test("IDEMPOTENT — a repaired client is skipped on re-run", async () => {
    const {db, writes} = fakeDb({
      c1: {...corrupt, ...repairPatchFor(corrupt)},
    });

    const result = await repairClients(db, {dryRun: false, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 0});
    expect(writes).toEqual([]);
  });

  test("--dry-run reports the work and writes NOTHING", async () => {
    const {db, writes} = fakeDb({c1: corrupt});

    const result = await repairClients(db, {dryRun: true, verbose: false});

    expect(result).toEqual({scanned: 1, patched: 1});
    expect(writes).toEqual([]);
  });
});

describe("assertKnownFlags", () => {
  test("accepts the flags it documents", () => {
    expect(() => assertKnownFlags([])).not.toThrow();
    expect(() => assertKnownFlags(["--dry-run", "--verbose"])).not.toThrow();
  });

  test("rejects a typo rather than reading it as false", () => {
    expect(() => assertKnownFlags(["--dryrun"])).toThrow(/unknown argument/);
  });
});
