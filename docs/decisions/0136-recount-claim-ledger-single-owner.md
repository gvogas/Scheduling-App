# 0136. `recount_claim.js` is the one owner of the recount claim ledger

**Date:** 2026-08-28 · **Rules file:** `functions/CLAUDE.md`

## Context
A booking batch lands up to 16 writes for one client (a multi-day run's day-documents, a repeat
series), and a photo batch many writes for one appointment, so both counters collapse N triggers into one
aggregate through a claim ledger. `appointment_images.js`'s `debouncedRecountPictures` carried a
byte-identical second copy of all six bodies until 2026-08-28 — the drift the module exists to prevent,
live in its own sibling. Unconditional debouncing also charged every ordinary single create/delete a 2 s
settle plus a claim `create()` and `delete()`, taking the common path from 2 writes to 4.

## Decision
`claimRecount`/`releaseRecount`/`debounceRecount` (`db` injected) serve both `recountClientJobs`
(`jobCount`) and `debouncedRecountPictures` (`pictureCount`). The client adapter gates the debounce on
`mayShareABatch` (`dayCount > 1` or a non-empty `seriesId`); the photo adapter always debounces, since a
photo write is always part of a batch. `claimSeriesNotice` (`notification_utils.js`) stays separate.

## Consequences
The release-BEFORE-aggregate order is the whole design and fails silently when wrong; never re-spell it
at a call site. `claimSeriesNotice` claims and HOLDS for dedupe — it looks similar because it is
deliberately different, so don't fold it in.
