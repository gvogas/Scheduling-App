"use strict";

/**
 * @fileoverview The delta-import window: which customers an import asks Wave
 * for, and how the watermark advances after it. Pure, so jest can require it.
 * @module wave/import_schedule
 */

const DAY_MS = 24 * 60 * 60 * 1000;

// Wave filters `customers(modifiedAtAfter:)` server-side, so an import can ask
// for only what changed. `wave/connection.customerDeltaSince` is that
// watermark and `lastFullImportAt` is when the last unfiltered pass ran.

// How far behind the run's start the watermark is set. Absorbs clock skew
// against Wave and anything edited in the same second the query went out.
const DELTA_OVERLAP_MS = 5 * 60 * 1000;

// How stale the last full pass may get before one is forced.
//
// NOT about deletes — the import has never deleted a local client, so a
// customer removed in Wave keeps its doc either way. It is the backstop for
// `modifiedAt` itself: we trust Wave to bump it for every field we map and
// cannot verify that, so a mapped change it misses would otherwise stay stale
// forever.
const FULL_RESYNC_INTERVAL_MS = 7 * DAY_MS;

/**
 * Decides whether an import runs as a delta, and from when.
 *
 * @param {{deltaSinceMs: ?number, lastFullMs: ?number, nowMs: number}} state
 *   The two `wave/connection` stamps as epoch ms (read them through
 *   `toMillis`), plus the run's start instant.
 * @return {{since: string, reason: string}} `since` is an ISO-8601 instant for
 *   a delta run, or "" for a full one.
 */
function resolveImportWindow({deltaSinceMs, lastFullMs, nowMs}) {
  if (!deltaSinceMs) return {since: "", reason: "no-watermark"};
  if (!lastFullMs || nowMs - lastFullMs >= FULL_RESYNC_INTERVAL_MS) {
    return {since: "", reason: "periodic-full-resync"};
  }
  // A watermark in the future is a clock or data fault, not a valid window —
  // honouring it would silently import nothing, forever.
  if (deltaSinceMs > nowMs) return {since: "", reason: "watermark-ahead"};
  return {since: new Date(deltaSinceMs).toISOString(), reason: "delta"};
}

/**
 * Builds the `wave/connection` patch that advances the watermark after a run.
 *
 * Only ever called after a FULLY SUCCESSFUL import: advancing past a window
 * that was never imported skips every customer changed inside it, permanently
 * and silently, whereas redoing a window is free (the import is idempotent).
 *
 * @param {{startedAtMs: number, wasFull: boolean}} run The run's START instant
 *   — not its end, which would drop anything edited while it was in flight.
 * @return {!Object} Firestore patch.
 */
function watermarkPatch({startedAtMs, wasFull}) {
  const patch = {
    customerDeltaSince: new Date(startedAtMs - DELTA_OVERLAP_MS),
  };
  if (wasFull) patch.lastFullImportAt = new Date(startedAtMs);
  return patch;
}

module.exports = {
  resolveImportWindow,
  watermarkPatch,
  FULL_RESYNC_INTERVAL_MS,
};
