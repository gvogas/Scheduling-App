"use strict";

/**
 * Tests for the ONLY unattended, irreversible deletion in the codebase.
 *
 * `purgeExpiredHistory` batch-deletes appointment docs AND their Storage
 * image prefixes on a quarterly cron, with nobody watching. Three rules keep
 * it safe, and each one deletes data (or orphans bytes) if it regresses:
 *   1. the status gate  — live work must never be purged, at any age
 *   2. the ordering     — images first, doc only if the images cleared
 *   3. the termination  — a stuck page must end the loop, not spin it
 */

const {
  HISTORY_RETENTION_YEARS,
  PURGE_STATUSES,
  PURGE_BATCH_SIZE,
  historyCutoff,
  isAppointmentImagePath,
  runHistoryPurge,
} = require("../maintenance_policy");
const {TERMINAL_STATUSES} = require("../time_utils");

const NOW = new Date("2026-08-04T12:00:00.000Z");

/**
 * A Firestore stub that serves fixed pages and records what was queried and
 * what was committed.
 * @param {!Array<!Array<!Object>>} pages Docs to return, one array per call.
 * @return {!Object}
 */
function fakeDb(pages) {
  const state = {
    constraints: [],
    deleted: [],
    commits: 0,
    queries: 0,
  };
  const query = {
    where(field, op, value) {
      state.constraints.push({field, op, value});
      return query;
    },
    orderBy() {
      return query;
    },
    limit(n) {
      state.limit = n;
      return query;
    },
    async get() {
      const docs = pages[state.queries] || [];
      state.queries += 1;
      return {docs, empty: docs.length === 0, size: docs.length};
    },
  };
  return {
    state,
    collection: () => query,
    batch: () => ({
      delete: (ref) => state.deleted.push(ref.id),
      commit: async () => {
        state.commits += 1;
      },
    }),
  };
}

/**
 * @param {string} id
 * @return {!Object} A doc snapshot whose ref carries its own id.
 */
const doc = (id) => ({id, ref: {id}});

const silentLogger = {warn: jest.fn(), info: jest.fn(), error: jest.fn()};

describe("historyCutoff", () => {
  test("is exactly the retention window before now", () => {
    const cutoff = historyCutoff(NOW);
    expect(cutoff.getUTCFullYear()).toBe(
        NOW.getUTCFullYear() - HISTORY_RETENTION_YEARS,
    );
    expect(cutoff.getUTCMonth()).toBe(NOW.getUTCMonth());
    expect(cutoff.getUTCDate()).toBe(NOW.getUTCDate());
  });

  test("does not mutate the instant it is given", () => {
    const before = NOW.getTime();
    historyCutoff(NOW);
    expect(NOW.getTime()).toBe(before);
  });
});

describe("the status gate", () => {
  test("purges terminal statuses ONLY — live work is never eligible", () => {
    // Widening this set is how an unfinished job gets deleted for being old,
    // so the assertion is on the whole set, not just a couple of absences.
    // It pinned ["done", "cancelled"] until 2026-08-11: this copy had dropped
    // the legacy `completed` alias the other copies carried, so such a doc was
    // never eligible at any age and outlived the retention policy in silence.
    // It now derives from TERMINAL_STATUSES and cannot drift again.
    expect(PURGE_STATUSES).toEqual([...TERMINAL_STATUSES]);
    expect(PURGE_STATUSES).toEqual(["done", "completed", "cancelled"]);
    expect(PURGE_STATUSES).not.toContain("pending");
    expect(PURGE_STATUSES).not.toContain("in_progress");
  });

  test("queries on that set and on the cutoff, nothing wider", async () => {
    const db = fakeDb([[]]);
    await runHistoryPurge({
      db, deleteImages: async () => true, logger: silentLogger, now: NOW,
    });
    expect(db.state.constraints).toEqual([
      {field: "status", op: "in", value: PURGE_STATUSES},
      {field: "startTime", op: "<", value: historyCutoff(NOW)},
    ]);
    expect(db.state.limit).toBe(PURGE_BATCH_SIZE);
  });
});

describe("images are deleted before the doc", () => {
  test("a doc whose images cleared is deleted", async () => {
    const db = fakeDb([[doc("a1"), doc("a2")], []]);
    const res = await runHistoryPurge({
      db, deleteImages: async () => true, logger: silentLogger, now: NOW,
    });
    expect(db.state.deleted).toEqual(["a1", "a2"]);
    expect(res).toMatchObject({purged: 2, imageFailures: 0});
  });

  test("a doc whose images FAILED is kept, so bytes never orphan", async () => {
    // The doc is the only pointer to the Storage prefix. Deleting it after a
    // failed cleanup loses those bytes forever.
    const db = fakeDb([[doc("ok"), doc("bad")], []]);
    const res = await runHistoryPurge({
      db,
      deleteImages: async (id) => id !== "bad",
      logger: silentLogger,
      now: NOW,
    });
    expect(db.state.deleted).toEqual(["ok"]);
    expect(db.state.deleted).not.toContain("bad");
    expect(res).toMatchObject({purged: 1, imageFailures: 1});
  });

  test("commits nothing when every image cleanup failed", async () => {
    const db = fakeDb([[doc("a1"), doc("a2")], []]);
    const res = await runHistoryPurge({
      db, deleteImages: async () => false, logger: silentLogger, now: NOW,
    });
    expect(db.state.commits).toBe(0);
    expect(res).toMatchObject({purged: 0, imageFailures: 2});
  });
});

describe("loop termination", () => {
  test("stops on an empty page", async () => {
    const db = fakeDb([[]]);
    await runHistoryPurge({
      db, deleteImages: async () => true, logger: silentLogger, now: NOW,
    });
    expect(db.state.queries).toBe(1);
  });

  test("stops on a short page rather than asking again", async () => {
    const db = fakeDb([[doc("a1")]]);
    await runHistoryPurge({
      db, deleteImages: async () => true, logger: silentLogger, now: NOW,
    });
    expect(db.state.queries).toBe(1);
  });

  test("stops on a FULL page that made no progress", async () => {
    // Without this the loop refetches the same stuck docs until the 1800s
    // timeout, since a failed cleanup leaves them in place.
    const full = Array.from({length: PURGE_BATCH_SIZE}, (_, i) =>
      doc(`a${i}`),
    );
    const db = fakeDb([full, full, full]);
    const res = await runHistoryPurge({
      db, deleteImages: async () => false, logger: silentLogger, now: NOW,
    });
    expect(db.state.queries).toBe(1);
    expect(res.purged).toBe(0);
  });

  test("keeps paging while a full page makes progress", async () => {
    const full = Array.from({length: PURGE_BATCH_SIZE}, (_, i) =>
      doc(`a${i}`),
    );
    const db = fakeDb([full, [doc("last")]]);
    const res = await runHistoryPurge({
      db, deleteImages: async () => true, logger: silentLogger, now: NOW,
    });
    expect(db.state.queries).toBe(2);
    expect(res.purged).toBe(PURGE_BATCH_SIZE + 1);
  });

  test("counts a stuck doc refetched on a later page once", async () => {
    const full = [doc("bad")].concat(
        Array.from({length: PURGE_BATCH_SIZE - 1}, (_, i) => doc(`a${i}`)),
    );
    const db = fakeDb([full, [doc("bad"), doc("last")]]);
    const res = await runHistoryPurge({
      db,
      deleteImages: async (id) => id !== "bad",
      logger: silentLogger,
      now: NOW,
    });
    expect(db.state.queries).toBe(2);
    expect(res).toMatchObject({purged: PURGE_BATCH_SIZE, imageFailures: 1});
  });
});

describe("isAppointmentImagePath", () => {
  test("matches an appointment image object", () => {
    expect(isAppointmentImagePath("appointments/a1/images/p.jpg")).toBe(true);
  });

  test.each([
    ["", "empty"],
    ["appointments/a1/notes.txt", "a non-image sibling"],
    ["clients/c1/images/p.jpg", "another collection"],
    ["appointments//images/p.jpg", "an empty appointment id"],
    ["appointments/a1/b2/images/p.jpg", "a nested id segment"],
  ])("does not match %s (%s)", (path) => {
    expect(isAppointmentImagePath(path)).toBe(false);
  });

  test("tolerates a missing name instead of throwing", () => {
    expect(isAppointmentImagePath(undefined)).toBe(false);
    expect(isAppointmentImagePath(null)).toBe(false);
  });
});
