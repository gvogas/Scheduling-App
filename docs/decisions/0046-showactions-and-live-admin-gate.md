# 0046. Admin actions: explicit `showActions`, done-job edit slot, live `isActiveAdminProvider`

**Date:** 2026-08-08 (done-job edit button; History `isAdmin` restored), 2026-09-06 (`isActiveAdminProvider`), 2026-09-07 (empty-doc limitation reviewed; Settings consumer) · **Rules file:** `.claude/rules/appointments.md`

## Context
A `true` default on `showActions` showed employees Edit/Cancel/Delete that the rules then rejected with an
opaque `permission-denied`. On 2026-08-08 (owner call) a done job's edit moved from the top chip to the action
bar's bottom slot, where the inert "Complete" indicator sat dead. `AppointmentHistoryView` once hardcoded
`false` as "read-only", which made that edit unreachable from History, where done jobs live; a revert
dropped the `isAdmin` pass-through and it was restored the same day.
A route argument's `isAdmin` is a push-time snapshot: a stale back stack, an argless push or a deep link
can carry `isAdmin: true` for someone who no longer is one. `isActiveAdminProvider` (2026-09-06) asks
Firestore. Reviewed 2026-09-07: a settled empty doc is the bootstrap window of a fresh sign-in or cold
cache, so a real admin briefly reads as not-admin (`AdminOnly` shows `InvalidRouteScreen`, drawer drops
admin rows). It fails safe, self-heals, matches `readAccountGateInputs`, and a genuinely empty doc is
`SplashScreen`'s and `AccountExitListeners`' business. Holding the last settled answer was rejected: it
needs a uid to hold against (else one session's answer carries into the next person's), which makes the
provider depend on `authUidProvider` and drags Firebase auth into every widget test that overrides only
the doc provider.

## Decision
Default every appointment surface closed; edit a done job from `DetailsActionBar.onEdit`; gate live
admin UI on `isActiveAdminProvider`, resolved once per consumer, except tour wiring.

## Consequences
Filing the empty-doc flicker as a bug means reopening this decision with that cost named. The fail-closed
guarantee does not transfer to `_canRecordFieldWork`, a negative gate.
