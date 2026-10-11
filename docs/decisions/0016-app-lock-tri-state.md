# 0016. The app-lock flag is tri-state at both lifecycle gates

**Date:** 2026-08-04 (rule recorded with both gates, `07131173`) · **Rules file:** `CLAUDE.md`

## Context
`AppLockController` (`app_lock_provider.dart`) holds `false` until a read actually settles, so "off" and
"we could not find out" were the same value. Reading the bare bool meant ONE transient keychain error
(the pre-first-unlock -25308 window, ADR-0015) disabled biometrics for the whole session with no sign
anything was wrong. `isResolved` now tells the two apart and `retryIfUnresolved()` re-reads. The first
fix covered only resume; the background/`inactive` gate was missed, and that is the gate the OS grabs
its app-switcher snapshot behind, where "we don't know yet" must not read as "no lock".

## Decision
`AppLock` (`core/security/app_lock.dart`) retries BEFORE deciding on resume and locks on
background/`inactive` while UNRESOLVED. `_afterRetry` releases a defensive lock once the retry settles,
and a persistent read failure still degrades to unlocked on purpose — someone who never enabled
biometrics must never be trapped behind a prompt they cannot satisfy. Pinned by
`test/core/security/app_lock_test.dart`.

## Consequences
The win is the switcher window, not a hard guarantee; don't write it up as one. Don't simplify either
gate back to a plain `ref.read(appLockEnabledProvider)`.
