# 0043. Every callable enforces App Check through the shared `APP_CHECK`

**Date:** 2026-08-25 (shared constant) · **Rules file:** `.claude/rules/security.md`

## Context
A temporary pre-ship `enforceAppCheck: false` carve-out, for Firebase App Distribution sideload testers
whose builds could not mint verified tokens, was retired in 1.25.1. `invites.js` was deleted 2026-08-08
with the `#compat-1.37.1` shim. `{enforceAppCheck: true}` was an identical private const in two modules
before `APP_CHECK` moved into `functions/security.js`.

## Decision
A new callable enforces App Check, never defaults it off, and spreads `APP_CHECK`. A callable whose
options also set a region, a timeout or a secret writes `enforceAppCheck: true` inline beside them,
because spreading a one-key constant into a larger options object reads as less explicit on a
security-critical line. Enforcement activates on `firebase deploy --only functions`.

## Consequences
Until 2026-10-07, `account.js` (`deleteAccount`) and `wave/callables.js` (`waveGetConnection`,
`waveSetImportSchedule`) passed a bare inline `{enforceAppCheck: true}` with no other option. They
enforced App Check all along; they now spread `APP_CHECK`, so every bare-literal site is gone. A
re-declared literal drifts silently, since nothing compares it to the shared constant.
