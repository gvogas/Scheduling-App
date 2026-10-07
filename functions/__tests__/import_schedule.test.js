"use strict";

// This decides which customers an import is even allowed to see. Every wrong
// answer is silent: too narrow and changed customers are skipped forever, too
// wide and it merely costs a little more.

const importSchedule = require("../wave/import_schedule");

const {
  resolveImportWindow,
  watermarkPatch,
  FULL_RESYNC_INTERVAL_MS,
} = importSchedule;

const DAY_MS = 24 * 60 * 60 * 1000;

describe("import_schedule", () => {
  test("is the watermark half only — the cadence half is deleted", () => {
    // Wave Phase 4, Task 12. A cadence export coming back would mean a second
    // scheduled pull is being rebuilt on the pieces this file used to hold.
    expect(Object.keys(importSchedule).sort()).toEqual([
      "FULL_RESYNC_INTERVAL_MS",
      "resolveImportWindow",
      "watermarkPatch",
    ]);
  });

  test("forces a full pass every 7 days", () => {
    expect(FULL_RESYNC_INTERVAL_MS).toBe(7 * DAY_MS);
  });
});

describe("resolveImportWindow", () => {
  const DAY = DAY_MS;
  const NOW = 1_800_000_000_000;

  test("no watermark yet → full import", () => {
    expect(resolveImportWindow(
        {deltaSinceMs: null, lastFullMs: NOW, nowMs: NOW}))
        .toEqual({since: "", reason: "no-watermark"});
  });

  test("a stale full pass forces another one", () => {
    // The backstop for Wave not bumping modifiedAt on some change we map —
    // which we trust and cannot verify.
    expect(resolveImportWindow({
      deltaSinceMs: NOW - 60_000,
      lastFullMs: NOW - 8 * DAY,
      nowMs: NOW,
    })).toEqual({since: "", reason: "periodic-full-resync"});
  });

  test("a full pass exactly one interval old is already stale", () => {
    expect(resolveImportWindow({
      deltaSinceMs: NOW - 1000,
      lastFullMs: NOW - FULL_RESYNC_INTERVAL_MS,
      nowMs: NOW,
    }).reason).toBe("periodic-full-resync");
  });

  test("a watermark in the future is refused, not honoured", () => {
    // Honouring it would ask Wave for changes after a time that hasn't
    // happened — importing nothing, every run, forever.
    expect(resolveImportWindow({
      deltaSinceMs: NOW + DAY,
      lastFullMs: NOW - DAY,
      nowMs: NOW,
    })).toEqual({since: "", reason: "watermark-ahead"});
  });

  test("otherwise a delta from the stored instant", () => {
    const result = resolveImportWindow({
      deltaSinceMs: NOW - 60_000,
      lastFullMs: NOW - DAY,
      nowMs: NOW,
    });
    expect(result.reason).toBe("delta");
    expect(result.since).toBe(new Date(NOW - 60_000).toISOString());
  });
});

describe("watermarkPatch", () => {
  const NOW = 1_800_000_000_000;

  test("rewinds behind the run start", () => {
    // From the run's END it would drop anything edited while it was in
    // flight; with no overlap, anything edited in the same second the query
    // went out, and no slack for clock skew against Wave.
    const patch = watermarkPatch({startedAtMs: NOW, wasFull: false});
    expect(patch.customerDeltaSince.getTime()).toBeLessThan(NOW);
    expect(patch).not.toHaveProperty("lastFullImportAt");
  });

  test("a full run also restarts the resync clock", () => {
    const patch = watermarkPatch({startedAtMs: NOW, wasFull: true});
    expect(patch.lastFullImportAt.getTime()).toBe(NOW);
  });
});
