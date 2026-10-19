"use strict";

const {scanOverduePage} = require("../overdue_scan");

const now = new Date("2026-10-18T16:00:00Z");

/**
 * Ordered query fixture with a durable cursor across separate sweep calls.
 * @param {number} count Number of equally timed jobs.
 * @param {!Object=} initial Initial cursor.
 * @return {!Object} Database and observations.
 */
function fixture(count, initial = {}) {
  let saved = initial;
  const reads = [];
  const rows = Array.from({length: count}, (_, i) => ({
    id: `job-${String(i).padStart(4, "0")}`,
    data: () => ({status: "pending", endTime: new Date(now - 60000)}),
  }));
  const cursor = {
    get: async () => ({exists: true, data: () => saved}),
    set: async (data) => {
      saved = data;
    },
  };
  const query = (after = null, limit = 500) => ({
    where: () => query(after, limit),
    orderBy: () => query(after, limit),
    startAfter: (date, id) => query({date, id}, limit),
    limit: (size) => query(after, size),
    get: async () => {
      const docs = rows.filter((row) => !after ||
        row.data().endTime > after.date ||
        (+row.data().endTime === +after.date && row.id > after.id))
          .slice(0, limit);
      reads.push(docs.length);
      return {docs};
    },
  });
  return {
    db: {collection: (name) => name === "appointments" ?
      query() : {doc: () => cursor}},
    saved: () => saved, reads,
  };
}

test("501 equally timed jobs reach the tail on the second run", async () => {
  const f = fixture(501);
  const first = await scanOverduePage(f.db, now);
  expect(first.records).toHaveLength(500);
  expect(f.saved()).toEqual({});
  await first.commit();
  expect(f.saved().id).toBe("job-0499");
  const second = await scanOverduePage(f.db, now);
  expect(second.records.map((row) => row.id)).toEqual(["job-0500"]);
  await second.commit();
  expect(f.saved().id).toBeNull();
  expect(f.reads).toEqual([500, 1]);
});

test("a delivery failure before commit repeats the same page", async () => {
  const f = fixture(501);
  const first = await scanOverduePage(f.db, now);
  const retry = await scanOverduePage(f.db, now);
  expect(retry.records).toEqual(first.records);
});

test("a deleted tail wraps without spending an empty sweep", async () => {
  const f = fixture(2, {endMillis: +now - 60000, id: "zz-deleted"});
  const page = await scanOverduePage(f.db, now);
  expect(page.records).toHaveLength(2);
  expect(f.reads).toEqual([0, 2]);
});

test.each([
  {endMillis: +now + 60000, id: "job-0001"},
  {endMillis: +now - 3 * 3600000, id: "job-0001"},
  {endMillis: +now - 60000, id: "invalid/path"},
  {endMillis: "yesterday", id: "job-0001"},
])("expired or invalid cursor restarts safely: %j", async (cursor) => {
  const f = fixture(2, cursor);
  expect((await scanOverduePage(f.db, now)).records).toHaveLength(2);
  expect(f.reads).toEqual([2]);
});
