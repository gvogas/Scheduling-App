"use strict";

// Pins `backfill.js`'s reconcile — the only script in `scripts/` that deletes.

const {reconcileBridges} = require("../scripts/backfill");

/**
 * A Firestore stand-in over `users` and `usersByUid`.
 * @param {!Object} seed `{users: {id: data}, usersByUid: {id: data}}`.
 * @return {!Object}
 */
function fakeDb(seed) {
  const ops = [];
  const snap = (name) => ({
    docs: Object.entries(seed[name] || {}).map(([id, data]) => ({
      id,
      data: () => data,
      ref: {path: `${name}/${id}`},
    })),
  });
  return {
    ops,
    collection: (name) => ({
      get: async () => snap(name),
      doc: (id) => ({path: `${name}/${id}`}),
    }),
    batch: () => ({
      set: (ref, body) => ops.push({op: "set", path: ref.path, body}),
      delete: (ref) => ops.push({op: "delete", path: ref.path}),
      commit: async () => {},
    }),
  };
}

const seed = () => ({
  users: {
    u1: {uid: "uid1", role: "employee", status: "active", name: "A"},
  },
  usersByUid: {orphan: {role: "admin", docId: "gone", status: "active"}},
});

describe("reconcileBridges", () => {
  let warn;
  beforeEach(() => {
    warn = jest.spyOn(console, "warn").mockImplementation(() => {});
  });
  afterEach(() => warn.mockRestore());

  test("a dry run writes and deletes nothing", async () => {
    const db = fakeDb(seed());
    const stats = await reconcileBridges(
        db, {dryRun: true, pruneOrphans: true});
    expect(db.ops).toEqual([]);
    expect(stats.created).toBe(1);
    expect(stats.orphansFound).toBe(1);
  });

  test("without --prune-orphans an orphan is reported, not deleted",
      async () => {
        const db = fakeDb(seed());
        const stats = await reconcileBridges(
            db, {dryRun: false, pruneOrphans: false});
        expect(stats.orphansFound).toBe(1);
        expect(stats.orphansDeleted).toBe(0);
        expect(db.ops.map((o) => o.op)).toEqual(["set"]);
      });

  test("--live --prune-orphans deletes the orphan", async () => {
    const db = fakeDb(seed());
    const stats = await reconcileBridges(
        db, {dryRun: false, pruneOrphans: true});
    expect(stats.orphansDeleted).toBe(1);
    expect(db.ops).toContainEqual({op: "delete", path: "usersByUid/orphan"});
  });

  test("a bridge claimed by a skipped users doc is retained", async () => {
    const data = seed();
    data.users.bad = {uid: "orphan", role: "weird", status: "active"};
    const db = fakeDb(data);
    const stats = await reconcileBridges(
        db, {dryRun: false, pruneOrphans: true});
    expect(stats.bridgesRetained).toBe(1);
    expect(db.ops.some((o) => o.op === "delete")).toBe(false);
  });
});
