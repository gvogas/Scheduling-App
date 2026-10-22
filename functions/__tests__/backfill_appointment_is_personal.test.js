"use strict";

/** Tests for `scripts/backfill-appointment-is-personal.js`. */

const {
  assertKnownFlags,
  classifyAppointment,
  backfillIsPersonal,
  PAGE_SIZE,
} = require("../scripts/backfill-appointment-is-personal");

// Toronto wall-clock instants (EDT, UTC-4) keep `dayCountOf` on known days.
const at = (iso) => new Date(iso);

describe("assertKnownFlags", () => {
  test("a typo'd dry-run flag is a hard error", () => {
    expect(() => assertKnownFlags(["--dryrun"])).toThrow(/unknown argument/);
  });

  test("the two real flags are accepted", () => {
    expect(() => assertKnownFlags(["--dry-run", "--verbose"])).not.toThrow();
  });
});

describe("classifyAppointment", () => {
  test("a doc with no flag is stamped false, as the app reads it", () => {
    expect(classifyAppointment({status: "pending"}).patch)
        .toEqual({isPersonal: false});
  });

  test("a stored boolean is never rewritten, true or false", () => {
    expect(classifyAppointment({isPersonal: true}).patch).toBeNull();
    expect(classifyAppointment({isPersonal: false}).patch).toBeNull();
  });

  test("a non-boolean flag counts as missing", () => {
    expect(classifyAppointment({isPersonal: "true"}).patch)
        .toEqual({isPersonal: false});
  });

  test("a single-day client job is not a wide job", () => {
    const {wideJob, days} = classifyAppointment({
      startTime: at("2026-08-01T13:00:00Z"),
      endTime: at("2026-08-01T21:00:00Z"),
    });
    expect([wideJob, days]).toEqual([false, 1]);
  });

  test("an overnight single shift is still one work day", () => {
    const {wideJob} = classifyAppointment({
      startTime: at("2026-08-02T02:00:00Z"),
      endTime: at("2026-08-02T10:00:00Z"),
    });
    expect(wideJob).toBe(false);
  });

  test("a legacy multi-day client job is reported with its day count", () => {
    const {wideJob, days} = classifyAppointment({
      startTime: at("2026-08-01T13:00:00Z"),
      endTime: at("2026-08-05T21:00:00Z"),
      isPersonal: false,
    });
    expect([wideJob, days]).toEqual([true, 5]);
  });

  test("a wide PERSONAL block is not reported: the tail query serves it",
      () => {
        const {wideJob} = classifyAppointment({
          startTime: at("2026-08-01T13:00:00Z"),
          endTime: at("2026-08-05T21:00:00Z"),
          isPersonal: true,
        });
        expect(wideJob).toBe(false);
      });

  test("a doc with no times is neither stamped wrongly nor reported", () => {
    const {patch, wideJob} = classifyAppointment({});
    expect(patch).toEqual({isPersonal: false});
    expect(wideJob).toBe(false);
  });
});

/**
 * A Firestore stand-in over one in-memory `appointments` collection.
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

describe("backfillIsPersonal", () => {
  const seed = () => [
    {id: "a-flagged", data: {isPersonal: false, status: "done",
      startTime: at("2026-08-01T13:00:00Z"),
      endTime: at("2026-08-01T21:00:00Z")}},
    {id: "b-legacy", data: {status: "done",
      startTime: at("2026-07-01T13:00:00Z"),
      endTime: at("2026-07-01T21:00:00Z")}},
    {id: "c-wide-legacy", data: {status: "pending",
      startTime: at("2026-07-06T13:00:00Z"),
      endTime: at("2026-07-08T21:00:00Z")}},
    {id: "d-block", data: {isPersonal: true, isDayOff: true,
      startTime: at("2026-08-10T04:00:00Z"),
      endTime: at("2026-08-15T03:59:00Z")}},
  ];

  test("stamps only the docs missing the flag", async () => {
    const db = fakeDb(seed());
    const summary = await backfillIsPersonal(db, {dryRun: false});

    expect(summary.scanned).toBe(4);
    expect(summary.stamped).toBe(2);
    expect(summary.skipped).toBe(2);
    expect(db.committed).toEqual([
      {id: "b-legacy", patch: {isPersonal: false}},
      {id: "c-wide-legacy", patch: {isPersonal: false}},
    ]);
  });

  test("reports the wide client job and leaves it unmodified", async () => {
    const db = fakeDb(seed());
    const summary = await backfillIsPersonal(db, {dryRun: false});

    expect(summary.wideJobs).toEqual([{
      id: "c-wide-legacy", days: 3, status: "pending",
      startMs: at("2026-07-06T13:00:00Z").getTime(),
    }]);
    const wide = db.committed.find((c) => c.id === "c-wide-legacy");
    expect(wide.patch).toEqual({isPersonal: false});
  });

  test("--dry-run writes nothing while reporting the same counts", async () => {
    const db = fakeDb(seed());
    const summary = await backfillIsPersonal(db, {dryRun: true});

    expect(summary.stamped).toBe(2);
    expect(summary.wideJobs).toHaveLength(1);
    expect(db.committed).toHaveLength(0);
  });

  test("a second run over the written result patches nothing", async () => {
    const first = fakeDb(seed());
    await backfillIsPersonal(first, {dryRun: false});
    const merged = seed().map((doc) => {
      const write = first.committed.find((c) => c.id === doc.id);
      return write ? {id: doc.id, data: {...doc.data, ...write.patch}} : doc;
    });

    const second = fakeDb(merged);
    const summary = await backfillIsPersonal(second, {dryRun: false});

    expect(summary.stamped).toBe(0);
    expect(second.committed).toHaveLength(0);
  });

  test("the paging loop terminates past one full page", async () => {
    const many = Array.from({length: PAGE_SIZE + 7}, (_, i) => ({
      id: `a${String(i).padStart(4, "0")}`,
      data: {isPersonal: false},
    }));
    const db = fakeDb(many);
    const summary = await backfillIsPersonal(db, {dryRun: false});

    expect(summary.scanned).toBe(PAGE_SIZE + 7);
    expect(db.pages).toEqual([PAGE_SIZE, 7]);
  });
});
