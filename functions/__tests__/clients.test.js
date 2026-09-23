"use strict";

const {performDeleteClient} = require("../clients");

/**
 * Minimal Firestore fake: a clients doc that may or may not exist, and an
 * appointments count() aggregate that returns a fixed number.
 * @param {{count: number, exists: (boolean|undefined)}} opts Fake config.
 * @return {!Object} A db fake with a `deleted` log.
 */
function fakeDb({count, exists = true, duringCount}) {
  const deleted = [];
  let data = {};
  const db = {
    deleted,
    state: () => ({exists, ...data}),
    collection: (name) => ({
      doc: (id) => ({id, name}),
      where: () => ({
        count: () => ({get: async () => {
          if (duringCount) await duringCount(db);
          return {data: () => ({count})};
        }}),
      }),
    }),
    runTransaction: async (work) => work({
      get: async () => ({exists, data: () => data}),
      update: (_ref, patch) => {
        data = {...data, ...patch};
      },
      delete: (ref) => {
        exists = false;
        deleted.push({collection: ref.name, id: ref.id});
      },
    }),
  };
  return db;
}

describe("performDeleteClient", () => {
  test("refuses a client that has appointments", async () => {
    const db = fakeDb({count: 3});
    await expect(performDeleteClient(db, "c1"))
        .rejects.toThrow(/client-has-history/);
    expect(db.deleted).toHaveLength(0);
    expect(db.state().deletionToken).toBe("");
  });

  test("refuses on a single appointment, not just on many", async () => {
    const db = fakeDb({count: 1});
    await expect(performDeleteClient(db, "c1"))
        .rejects.toThrow(/client-has-history/);
    expect(db.deleted).toHaveLength(0);
    expect(db.state().deletionToken).toBe("");
  });

  test("deletes a client with no appointments", async () => {
    const db = fakeDb({count: 0});
    await performDeleteClient(db, "c1");
    expect(db.deleted).toEqual([{collection: "clients", id: "c1"}]);
  });

  test("refuses a client that does not exist", async () => {
    const db = fakeDb({count: 0, exists: false});
    await expect(performDeleteClient(db, "c1"))
        .rejects.toThrow(/client-not-found/);
  });
});

test("booking barrier is committed before counting history", async () => {
  const db = fakeDb({count: 0, duringCount: async (store) => {
    expect(store.state().deletionToken).toEqual(expect.any(String));
    expect(store.state().deletionToken).not.toBe("");
  }});
  await performDeleteClient(db, "c1");
});

test("failed count releases its barrier for a retry", async () => {
  const db = fakeDb({count: 0, duringCount: async () => {
    throw Error("offline");
  }});
  await expect(performDeleteClient(db, "c1")).rejects.toThrow("offline");
  expect(db.state().deletionToken).toBe("");
  expect(db.state().exists).toBe(true);
});

test("superseded delete cannot delete or release the current barrier",
    async () => {
      const db = fakeDb({count: 0, duringCount: async (store) => {
        await store.runTransaction(async (tx) => {
          tx.update({}, {deletionToken: "new"});
        });
      }});
      await expect(performDeleteClient(db, "c1")).rejects.toThrow("superseded");
      expect(db.state().deletionToken).toBe("new");
      expect(db.state().exists).toBe(true);
    });
