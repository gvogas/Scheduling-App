"use strict";

const {
  backfillClients,
  LEGACY_CREATED_AT,
} = require("../scripts/backfill-client-sort-fields");

/**
 * A Firestore stand-in over one in-memory clients collection.
 * @param {!Array<{id: string, data: !Object}>} docs Seed documents.
 * @return {!Object}
 */
function fakeDb(docs) {
  const committed = [];
  const makeDoc = (d) => ({id: d.id, ref: {id: d.id}, data: () => d.data});
  const chain = (after) => ({
    orderBy: () => chain(after),
    limit: () => chain(after),
    startAfter: (cursor) => chain(cursor),
    get: async () => {
      const start = after ? docs.findIndex((d) => d.id === after.id) + 1 : 0;
      const slice = docs.slice(start, start + 500).map(makeDoc);
      return {docs: slice, size: slice.length, empty: slice.length === 0};
    },
  });
  return {
    committed,
    collection: () => chain(null),
    batch: () => ({
      update: (ref, patch) => committed.push({id: ref.id, patch}),
      commit: async () => {},
    }),
  };
}

const docs = [
  {id: "a", data: {name: "A"}},
  {id: "b", data: {name: "B", jobCount: 3, createdAt: new Date()}},
];

describe("backfillClients", () => {
  test("--dry-run reports the counts and writes NOTHING", async () => {
    const db = fakeDb(docs);
    expect(await backfillClients(db, true)).toEqual({scanned: 2, patched: 1});
    expect(db.committed).toEqual([]);
  });

  test("a live run stamps only the doc missing the fields", async () => {
    const db = fakeDb(docs);
    expect(await backfillClients(db, false)).toEqual({scanned: 2, patched: 1});
    expect(db.committed).toEqual([
      {id: "a", patch: {jobCount: 0, createdAt: LEGACY_CREATED_AT}},
    ]);
  });
});
