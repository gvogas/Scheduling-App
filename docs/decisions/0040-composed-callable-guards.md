# 0040. Callables open with a composed guard: `assertAdminCall` / `assertActiveCall`

**Date:** 2026-09-01 (admin) / 2026-09-05 (self-service) · **Rules file:** `.claude/rules/security.md`

## Context
On 2026-09-01 three `assertAdmin` gates turned out to be DELETABLE with all 1636 tests green, on the
callables that mint and delete real Firebase Auth accounts. Tests close that only for the gates somebody
looked at. Once a composer holds a module-internal reference to `assertAdmin`, stubbing `assertAdmin`
alone intercepts nothing, so every gate assertion passes vacuously — the same shape that hid the
original gap. The self-service opening was then hand-written twice in one week (`indexed_search.js`,
`appointment_actions.js`), and the two copies had already drifted on their logging, so it got its own
composer, `assertActiveCall`.

## Decision
`assertAdminCall(req, allowedKeys)` (`functions/security.js`) fixes auth → `assertAdmin` → payload shape
and returns the uid for the limiter; `assertActiveCall` fixes auth → payload shape → the active
`usersByUid/{uid}` row and returns the profile. Composition and order are proved against the real
`assertAdmin` in `assert_admin.test.js`; callable suites stub the COMPOSER. `assertActiveCall` returns
`{...data, uid: req.auth.uid}`: the Firestore-writable bridge row first, the Auth-verified uid on top.

## Consequences
A composed opening closes the deletable-gate hole for the callables nobody has looked at. The other
spread order would let a `uid` field on the bridge row shadow the proved one, and every scoping on
`profile.uid` (the rate limiter included) would key on writable data. Nothing writes that field today,
so it is latent; the ORDER is what makes it unreachable, not the absence of a writer.
