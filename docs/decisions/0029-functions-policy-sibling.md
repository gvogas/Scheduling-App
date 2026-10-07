# 0029. Decisions of a bucket-at-load module live in a pure `*_policy.js`

**Date:** 2026-08-04 · **Rules file:** `CLAUDE.md`

## Context
`maintenance.js` throws on `require()` outside the emulator, but NOT from an admin `getStorage()` handle —
both of its calls resolve lazily inside the function bodies. The throw is `onObjectFinalized`'s own
bucket-name resolution at trigger registration ("Missing bucket name",
`firebase-functions/lib/v2/providers/storage.js`), which happens the moment the module is evaluated.
That untestability is why `purgeExpiredHistory` — the only unattended, irreversible deletion in the repo
— had ZERO tests until 2026-08-04. Its orchestration moved to `maintenance_policy.js`, taking
`db`/`deleteImages`/`now` injected, the same split `notification_policy.js` ↔ `notification_utils.js`
uses.

## Decision
Three rules there destroy data if they regress and are each pinned: the status gate (only
`done`/`cancelled` are ever purged — live work survives at any age), the ordering (images FIRST; a doc
whose image cleanup failed is kept, or its Storage bytes orphan), and loop termination (a full page that
made no progress ends the loop rather than respinning to the 1800 s timeout).

## Consequences
Don't go looking for a load-time `getStorage()` that isn't there, and don't "fix" it by making the
handles lazier — they already are. A new unattended-deletion decision goes in the policy module, never
the trigger module.
