# 0026. Account exit: listeners detect, a controller tears down

**Date:** 2026-08-19 (controller split out) · **Rules file:** `CLAUDE.md`

## Context
Teardown used to live in the `ref.listen` wire-ups, which made the order and the re-entry guard
untestable. `AccountExitController` (`core/app/`, a sibling of `AppSyncListeners`) was split out of
`AccountExitListeners`.

## Decision
The three listeners (disabled / role revoked / doc deleted) only call
`AccountExitController.exitAccount`, which owns the teardown, the navigation and the guard. Push,
presence and Live Activity de-register BEFORE `signOut()`, because each needs the credential sign-out
revokes. `_isHandlingAccountExit` is released by the post-frame callback on success and by the
`finally` only on failure, since three listeners can fire for one underlying event.

## Consequences
Don't put teardown back in a listener, and don't reorder de-registration after `signOut()`.
