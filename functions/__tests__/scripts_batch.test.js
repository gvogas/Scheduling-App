"use strict";

/**
 * The shared batched-write loop behind every bulk backfill in
 * `functions/scripts/`.
 */

const {commitInBatches, MAX_BATCH_SIZE} = require("../scripts/_batch");
const {
  needsArchivedField,
  assertKnownFlags,
} = require("../scripts/backfill-clients-archived");

/**
 * Firestore stand-in recording every batch, its updates and its commits.
 * @return {!Object} `{db, batches, commits}`.
 */
function fakeDb() {
  const batches = [];
  const commits = [];
  const db = {
    batch() {
      const b = {
        updates: [],
        deletes: [],
        // Every staged op, in order, so a commit reports what it really carried
        // rather than only its updates.
        ops: [],
        update(ref, patch) {
          b.updates.push([ref, patch]);
          b.ops.push(ref);
        },
        delete(ref) {
          b.deletes.push(ref);
          b.ops.push(ref);
        },
        async commit() {
          commits.push([...b.ops]);
        },
      };
      batches.push(b);
      return b;
    },
  };
  return {db, batches, commits};
}

describe("commitInBatches", () => {
  test("commits once the batch fills, and again on flush", async () => {
    const {db, commits} = fakeDb();
    const writer = commitInBatches(db, {batchSize: 2});

    for (const id of ["a", "b", "c"]) await writer.stage(id, {x: 1});
    expect(commits).toEqual([["a", "b"]]);

    await writer.flush();
    expect(commits).toEqual([["a", "b"], ["c"]]);
  });

  test("a run that lands exactly on the boundary flushes nothing extra",
      async () => {
        const {db, commits} = fakeDb();
        const writer = commitInBatches(db, {batchSize: 2});

        await writer.stage("a", {});
        await writer.stage("b", {});
        await writer.flush();

        expect(commits).toEqual([["a", "b"]]);
      });

  test("flushing an empty writer commits nothing", async () => {
    const {db, batches, commits} = fakeDb();
    await commitInBatches(db, {}).flush();
    expect(batches).toEqual([]);
    expect(commits).toEqual([]);
  });

  test("DRY RUN writes nothing at all", async () => {
    // The safety property this module exists for: `--dry-run` is enforced here,
    // so a script cannot forget the guard at its call site.
    const {db, batches, commits} = fakeDb();
    const writer = commitInBatches(db, {dryRun: true, batchSize: 2});

    for (const id of ["a", "b", "c"]) await writer.stage(id, {x: 1});
    await writer.flush();

    expect(batches).toEqual([]);
    expect(commits).toEqual([]);
  });

  // `stageDelete` had ZERO test references — the only irreversible operation in
  // this directory, behind `backfill.js --prune-orphans`, and its own docstring
  // says "a delete is not re-runnable".
  describe("stageDelete", () => {
    test("DRY RUN deletes nothing, and opens no batch at all", async () => {
      const {db, batches, commits} = fakeDb();
      const writer = commitInBatches(db, {dryRun: true, batchSize: 2});

      for (const id of ["a", "b", "c"]) await writer.stageDelete(id);
      await writer.flush();

      expect(batches).toEqual([]);
      expect(commits).toEqual([]);
    });

    test("a live run queues one delete per ref and commits at the cap",
        async () => {
          const {db, batches, commits} = fakeDb();
          const writer = commitInBatches(db, {batchSize: 2});

          for (const id of ["a", "b", "c"]) await writer.stageDelete(id);
          expect(commits).toEqual([["a", "b"]]);

          await writer.flush();
          expect(commits).toEqual([["a", "b"], ["c"]]);
          expect(batches[0].deletes).toEqual(["a", "b"]);
        });

    test("it DELETES, never updates — the two are not interchangeable here",
        async () => {
          const {db, batches} = fakeDb();
          const writer = commitInBatches(db, {batchSize: 5});

          await writer.stageDelete("a");
          await writer.flush();

          expect(batches[0].deletes).toEqual(["a"]);
          expect(batches[0].updates).toEqual([]);
        });

    test("deletes and updates share one batch and one cap", async () => {
      // They are staged through the same `stageOp`, so a mixed run must not be
      // able to exceed the batch size by counting them separately.
      const {db, commits} = fakeDb();
      const writer = commitInBatches(db, {batchSize: 2});

      await writer.stage("a", {x: 1});
      await writer.stageDelete("b");

      expect(commits).toEqual([["a", "b"]]);
    });
  });

  test("a failed commit is not resent by the flush behind it", async () => {
    // The batch is cleared before the await, so a throw cannot leave a
    // half-committed batch that `flush()` would replay against prod.
    const failing = {
      batch: () => ({
        update() {},
        commit: async () => {
          throw new Error("unavailable");
        },
      }),
    };
    const writer = commitInBatches(failing, {batchSize: 1});

    await expect(writer.stage("a", {})).rejects.toThrow("unavailable");
    await expect(writer.flush()).resolves.toBeUndefined();
  });

  test("defaults to Firestore's cap and refuses anything past it", () => {
    expect(MAX_BATCH_SIZE).toBe(500);
    expect(() => commitInBatches(fakeDb().db, {batchSize: 501})).toThrow(
        RangeError);
    expect(() => commitInBatches(fakeDb().db, {batchSize: 0})).toThrow(
        RangeError);
    expect(() => commitInBatches(fakeDb().db, {batchSize: 1.5})).toThrow(
        RangeError);
  });
});

describe("backfill-clients-archived", () => {
  test("a doc with no archived field is patched", () => {
    expect(needsArchivedField({name: "Acme"})).toBe(true);
    expect(needsArchivedField({})).toBe(true);
    expect(needsArchivedField(null)).toBe(true);
  });

  test("an ARCHIVED client is left alone", () => {
    // Truthiness would reset this to false and un-archive them.
    expect(needsArchivedField({archived: true})).toBe(false);
  });

  test("a doc already carrying false is skipped, making re-runs free", () => {
    expect(needsArchivedField({archived: false})).toBe(false);
  });

  test("a non-boolean value is treated as missing", () => {
    // The list query filters `== false`, so a string never matches it.
    expect(needsArchivedField({archived: "false"})).toBe(true);
    expect(needsArchivedField({archived: 0})).toBe(true);
  });

  test("a near-miss flag is a hard error, not a silent live run", () => {
    expect(() => assertKnownFlags(["--dry-run"])).not.toThrow();
    expect(() => assertKnownFlags(["--dryrun"])).toThrow();
    expect(() => assertKnownFlags(["--dry_run"])).toThrow();
  });

  test("--verbose is accepted, alone and beside --dry-run", () => {
    expect(() => assertKnownFlags(["--verbose"])).not.toThrow();
    expect(() => assertKnownFlags(["--dry-run", "--verbose"])).not.toThrow();
    expect(() => assertKnownFlags(["--verbos"])).toThrow();
  });
});
