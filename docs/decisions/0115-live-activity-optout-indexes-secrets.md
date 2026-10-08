# 0115. Live Activity opt-out, registry indexes and secret binding

**Date:** 2026-07-19..20 · **Rules file:** `.claude/rules/notifications.md`

## Context
The first deploy produced only the plain push and no card: the registry indexes were missing, every
query failed `FAILED_PRECONDITION`, and the best-effort catch swallowed it. Reading a secret param a
function did not bind logs "No value found for secret parameter" on every invocation. The card is
push-started by the server, so a device-local preference cannot by itself stop it, and a cold start with
the preference already off returned before `_docId` was set.

## Decision
Deploy `firestore:indexes` with the functions: `liveActivityTokens` `(kind, employeeDocId)` at
COLLECTION_GROUP scope and `liveActivityCards` `(phase, startTime)`. `notifications.js` splits
`liveDeps()` (no `apnsAuth`) from `liveActivityDeps()`; only the two functions binding `APNS_SECRETS` use
the latter. `LiveActivityRegistrationController.canHostCards()` (never throws) is the one capability probe,
behind `_ensurePlugin()` and `liveActivitySupportedProvider`. `liveActivityEnabledProvider`
(SharedPreferences, default on) only stops re-registration; the Settings toggle calls `unregister()`,
which ends the card and deletes the push-to-start row by kind (`deleteTokensOfKind`), re-resolving the
doc id when `_docId` is unset. A cold-start `sync()` awaits the preference's `ready` future.

Push-to-start rows are written only by the registration controller, stamped `expiresAt` = now +
`liveActivityPushToStartTtl` (30 d; `firestore.rules` caps it at 31 d, raise both together). They are
deleted on a dead-token APNs reply (`result.gone`), by the daily `pruneExpiredActivityTokens` rider of
`sendDailyJobDigest`, or by opt-out; a kill-switch pause sends nothing and prunes nothing.

## Consequences
A pause that pruned tokens would strand devices: nothing re-emits push-to-start, so cards would not
return when the switch flips back. Without `ready`, the optimistic `true` default re-registers an opted-out device.
