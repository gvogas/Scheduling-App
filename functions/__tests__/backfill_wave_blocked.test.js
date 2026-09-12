"use strict";

/** Tests for `scripts/backfill-wave-blocked.js`. */

const {
  assertKnownFlags,
  changeFor,
  sameProblems,
  backfillBlockedClients,
  PAGE_SIZE,
} = require("../scripts/backfill-wave-blocked");

const LONG_NAME = "x".repeat(201);

describe("assertKnownFlags", () => {
  test("a typo'd dry-run flag is a hard error", () => {
    expect(() => assertKnownFlags(["--dryrun"])).toThrow(/unknown argument/);
  });

  test("the two real flags are accepted", () => {
    expect(() => assertKnownFlags(["--dry-run", "--verbose"])).not.toThrow();
  });
});

describe("sameProblems", () => {
  test("an absent stored field equals a derived empty list", () => {
    expect(sameProblems(undefined, [])).toBe(true);
    expect(sameProblems(null, [])).toBe(true);
  });

  test("compares TOO_LONG detail, not just the code", () => {
    const a = [{field: "name", code: "TOO_LONG", severity: "blocking",
      detail: {length: 201, cap: 200}}];
    const b = [{field: "name", code: "TOO_LONG", severity: "blocking",
      detail: {length: 225, cap: 200}}];
    expect(sameProblems(a, b)).toBe(false);
  });

  test("a severity change alone is a change", () => {
    const a = [{field: "phone", code: "NOT_DIALABLE", severity: "blocking",
      detail: null}];
    const b = [{field: "phone", code: "NOT_DIALABLE", severity: "advisory",
      detail: null}];
    expect(sameProblems(a, b)).toBe(false);
  });
});

describe("changeFor", () => {
  test("a blocking client gets blocked + problems + a cleared error", () => {
    const {patch, blocked} = changeFor({name: ""});
    expect(blocked).toBe(true);
    expect(patch["wave.syncState"]).toBe("blocked");
    expect(patch["wave.syncError"]).toBeNull();
    expect(patch["wave.problems"]).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
  });

  test("an advisory-only client records the problem and NOT a state", () => {
    const {patch, blocked, advisory} =
      changeFor({name: "Acme", phone: "Contact Person"});
    expect(blocked).toBe(false);
    expect(advisory).toBe(true);
    expect(patch["wave.syncState"]).toBeUndefined();
    expect(patch["wave.problems"]).toEqual([
      {field: "phone", code: "NOT_DIALABLE", severity: "advisory",
        detail: null},
    ]);
  });

  test("a clean client with nothing stored is NOT a write", () => {
    expect(changeFor({name: "Acme"}).patch).toBeNull();
  });

  test("a client repaired since the last write has problems cleared", () => {
    const stored = {
      name: "Acme",
      wave: {syncState: "synced", problems: [
        {field: "name", code: "TOO_LONG", severity: "blocking",
          detail: {length: 201, cap: 200}},
      ]},
    };
    expect(changeFor(stored).patch).toEqual({"wave.problems": null});
  });

  test("a re-run over an already-recorded verdict writes nothing", () => {
    const first = changeFor({name: LONG_NAME});
    const stored = {
      name: LONG_NAME,
      wave: {
        syncState: first.patch["wave.syncState"],
        syncError: null,
        problems: first.patch["wave.problems"],
      },
    };
    expect(changeFor(stored).patch).toBeNull();
  });

  test("a stale blocked doc is reported and left completely alone", () => {
    const stored = {
      name: "Acme",
      wave: {syncState: "blocked", problems: [
        {field: "phone", code: "NOT_DIALABLE", severity: "blocking",
          detail: null},
      ]},
    };
    const {patch, staleBlocked} = changeFor(stored);
    expect(staleBlocked).toBe(true);
    expect(patch).toBeNull();
  });

  test("a stale syncError on a current blocked doc is cleared", () => {
    const stored = {
      name: "",
      wave: {
        syncState: "blocked",
        syncError: "Wave refused it",
        problems: [
          {field: "name", code: "EMPTY", severity: "blocking", detail: null},
        ],
      },
    };
    expect(changeFor(stored).patch["wave.syncError"]).toBeNull();
  });
});

/**
 * A Firestore stand-in over one in-memory `clients` collection.
 * @param {!Array<{id: string, data: !Object}>} docs Seed documents.
 * @return {!Object} The fake, with `committed` writes and `pages` sizes.
 */
function fakeDb(docs) {
  const committed = [];
  const pages = [];
  const makeDoc = (d) => ({id: d.id, ref: {id: d.id}, data: () => d.data});
  const query = (after) => {
    const start = after ? docs.findIndex((d) => d.id === after.id) + 1 : 0;
    const slice = docs.slice(start, start + PAGE_SIZE).map(makeDoc);
    pages.push(slice.length);
    return {docs: slice, size: slice.length, empty: slice.length === 0};
  };
  const chain = (after) => ({
    orderBy: () => chain(after),
    limit: () => chain(after),
    startAfter: (cursor) => chain(cursor),
    get: async () => query(after),
  });
  return {
    committed,
    pages,
    collection: () => chain(null),
    batch: () => ({
      update: (ref, patch) => committed.push({id: ref.id, patch}),
      commit: async () => {},
    }),
  };
}

describe("backfillBlockedClients", () => {
  const seed = () => [
    {id: "a-clean", data: {name: "Acme"}},
    {id: "b-advisory", data: {name: "Beta", phone: "Contact Person"}},
    {id: "c-blocked", data: {name: ""}},
    {id: "d-stale", data: {name: "Delta", wave: {syncState: "blocked",
      problems: [{field: "phone", code: "NOT_DIALABLE",
        severity: "blocking", detail: null}]}}},
  ];

  test("writes only the clients whose verdict is not recorded", async () => {
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: false});

    expect(summary.scanned).toBe(4);
    expect(summary.patched).toBe(2);
    expect(summary.blocked).toBe(1);
    expect(summary.advisory).toBe(1);
    expect(summary.staleBlocked).toBe(1);
    expect(db.committed.map((c) => c.id).sort())
        .toEqual(["b-advisory", "c-blocked"]);
  });

  test("--dry-run writes nothing while reporting the same counts", async () => {
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: true});

    expect(summary.patched).toBe(2);
    expect(db.committed).toHaveLength(0);
  });

  test("names the affected clients for --verbose", async () => {
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: true});

    expect(summary.changes.map((c) => c.id))
        .toEqual(["b-advisory", "c-blocked"]);
    expect(summary.staleBlockedIds).toEqual(["d-stale"]);
  });

  test("a second run over the written result patches nothing", async () => {
    const first = fakeDb(seed());
    await backfillBlockedClients(first, {dryRun: false});

    const merged = seed().map((doc) => {
      const write = first.committed.find((c) => c.id === doc.id);
      if (!write) return doc;
      const wave = {...(doc.data.wave || {})};
      for (const [key, value] of Object.entries(write.patch)) {
        wave[key.replace("wave.", "")] = value;
      }
      return {id: doc.id, data: {...doc.data, wave}};
    });

    const second = fakeDb(merged);
    const summary = await backfillBlockedClients(second, {dryRun: false});
    expect(summary.patched).toBe(0);
    expect(second.committed).toHaveLength(0);
  });

  test("the paging loop terminates past one full page", async () => {
    const many = Array.from({length: PAGE_SIZE + 7}, (_, i) => ({
      id: `c${String(i).padStart(4, "0")}`,
      data: {name: "Acme"},
    }));
    const db = fakeDb(many);
    const summary = await backfillBlockedClients(db, {dryRun: false});

    expect(summary.scanned).toBe(PAGE_SIZE + 7);
    expect(db.pages).toEqual([PAGE_SIZE, 7]);
  });
});
