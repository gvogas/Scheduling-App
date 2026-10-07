"use strict";

const {
  sendToActiveAdmins,
  ADMIN_FANOUT_MAX,
} = require("../notification_utils");

/**
 * Minimal Firestore stand-in: `.collection().where().where().limit().get()`.
 *
 * @param {!Array<!Object>} docs Docs the query resolves to.
 * @param {!Array<!Object>} calls Collected `.where()` arguments.
 * @param {!Array<number>=} limits Collected `.limit()` arguments.
 * @return {!Object}
 */
function fakeDb(docs, calls, limits) {
  const query = {
    where: (field, op, value) => {
      calls.push([field, op, value]);
      return query;
    },
    limit: (n) => {
      if (limits) limits.push(n);
      return query;
    },
    get: async () => ({docs, size: docs.length}),
  };
  return {collection: () => query};
}

/**
 * @param {string} id Doc id.
 * @return {!Object}
 */
function adminDoc(id) {
  return {id, data: () => ({role: "admin", status: "active"})};
}

describe("sendToActiveAdmins", () => {
  let deps;
  let logged;

  beforeEach(() => {
    logged = [];
    deps = {
      messaging: {},
      logger: {warn: (msg, meta) => logged.push([msg, meta])},
    };
  });

  test("sends one message per active admin", async () => {
    const sent = [];
    deps.db = fakeDb([adminDoc("a1"), adminDoc("a2")], []);

    await sendToActiveAdmins(
        deps, {kind: "x"}, () => ({title: "t", body: "b"}),
        {sendToEmployee: async (_d, id) => {
          sent.push(id);
          return 1;
        }},
    );

    expect(sent).toEqual(["a1", "a2"]);
  });

  test("constrains the query to active admins", async () => {
    // The role/status filter has to be in the QUERY, not a post-filter: this
    // runs on the Admin SDK so rules are bypassed, but an unfiltered scan of
    // /users would grow with the roster for no reason.
    const calls = [];
    deps.db = fakeDb([], calls);

    await sendToActiveAdmins(
        deps, {kind: "x"}, () => ({title: "t", body: "b"}),
        {sendToEmployee: async () => 1},
    );

    expect(calls).toEqual([
      ["role", "==", "admin"],
      ["status", "==", "active"],
    ]);
  });

  test("excludes the person who caused the notice", async () => {
    const sent = [];
    deps.db = fakeDb([adminDoc("a1"), adminDoc("a2")], []);

    await sendToActiveAdmins(
        deps, {kind: "x"}, () => ({title: "t", body: "b"}),
        {
          excludeDocId: "a1",
          sendToEmployee: async (_d, id) => {
            sent.push(id);
            return 1;
          },
        },
    );

    expect(sent).toEqual(["a2"]);
  });

  test("one bad recipient does not stop the rest", async () => {
    // Best-effort: whatever prompted the notice already committed, so a push
    // failure must never surface as a failed operation.
    const sent = [];
    deps.db = fakeDb([adminDoc("a1"), adminDoc("a2")], []);

    await expect(
        sendToActiveAdmins(deps, {kind: "x"}, () => ({title: "t", body: "b"}), {
          sendToEmployee: async (_d, id) => {
            if (id === "a1") throw new Error("boom");
            sent.push(id);
            return 1;
          },
        }),
    ).resolves.toEqual(expect.any(Number));

    expect(sent).toEqual(["a2"]);
    expect(logged.length).toBe(1);
  });

  test("a failed query resolves instead of throwing", async () => {
    deps.db = {
      collection: () => ({
        where: () => ({
          where: () => ({
            limit: () => ({
              get: async () => {
                throw new Error("unavailable");
              },
            }),
          }),
        }),
      }),
    };

    await expect(
        sendToActiveAdmins(deps, {kind: "x"}, () => ({title: "t", body: "b"}), {
          sendToEmployee: async () => 1,
        }),
    ).resolves.toEqual(expect.any(Number));

    expect(logged.length).toBe(1);
  });

  test("bounds the query and warns at the cap", async () => {
    // The last unbounded collection query in the push stack. Understating who
    // was notified has to be visible, the same posture the three sweep
    // ceilings take.
    const limits = [];
    const docs = Array.from({length: ADMIN_FANOUT_MAX}, (_, i) =>
      adminDoc(`a${i}`));
    deps.db = fakeDb(docs, [], limits);

    await sendToActiveAdmins(
        deps, {kind: "x"}, () => ({title: "t", body: "b"}),
        {sendToEmployee: async () => 1},
    );

    expect(limits).toEqual([ADMIN_FANOUT_MAX]);
    expect(logged.map(([msg]) => msg)).toEqual([
      "sendToActiveAdmins: recipient cap hit; some admins were not notified",
    ]);
  });

  test("seeds the recipient cache from the docs it just read", async () => {
    // `_loadRecipient` would otherwise re-`get()` a users doc already in hand
    // — +1 redundant read per active admin per notice.
    const caches = [];
    deps.db = fakeDb([adminDoc("a1"), adminDoc("a2")], []);

    await sendToActiveAdmins(
        deps, {kind: "x"}, () => ({title: "t", body: "b"}),
        {sendToEmployee: async (_d, _id, _data, _msg, _roles, cache) => {
          caches.push(cache);
          return 1;
        }},
    );

    expect(caches).toHaveLength(2);
    expect(caches[0]).toBe(caches[1]);
    expect(caches[0].get("a1")).toEqual({
      user: {role: "admin", status: "active"},
      tokenDocs: null,
    });
  });

  test("works with no options at all", async () => {
    deps.db = fakeDb([], []);

    await expect(
        sendToActiveAdmins(deps, {kind: "x"}, () => ({title: "t", body: "b"})),
    ).resolves.toEqual(expect.any(Number));
  });
});
