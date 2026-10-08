# 0108. Presence writes: throttle, heartbeat, rollback, and teardown races

**Date:** 1.32.0 (denied stop), 2026-09-19 (resume gap, audit I4) · **Rules file:** `.claude/rules/notifications.md`

## Context
A deactivated user's stream logged a denied write every heartbeat until the app was killed (11-event
Crashlytics spam in 1.32.0). The stream's 250 m filter emits nothing for a phone reopened where it was
closed; the resume fix added for that powered the GPS up and threw the reading away when inside the
2-minute gap. Account-exit teardown runs BEFORE `signOut()`, so a sync body resuming mid-teardown still
held a credential and re-created `presence/location` for someone who just signed out. "Presence never
starts" left nothing saying why. A session that never reached `_start` left the previous launch's
`presence/location` (and its pin) behind, against the privacy policy.

## Decision
Write `users/{docId}/presence/location` (`{lat, lng, uid, updatedAt: serverTimestamp()}`, self-only,
`updatedAt == request.time`) at most every 2 min (`minPresenceUploadGap`) of 250 m movement, plus a
10-min heartbeat (`presenceHeartbeatEvery`, under `PRESENCE_STALE_MINUTES` = 25). `upsertLocation`
returns `PresenceWriteResult`; `failed` rolls the throttle clock back, `denied` also calls `_stop()`.
`_isExpectedLocationLoss` (incl. `kCLErrorDomain error 1` as `PositionUpdateException`) logs without an
error record. `PresenceSyncController._freshFixOnResume` checks the gap BEFORE `getCurrentPosition`
(`presence_resume_fix_test.dart`). `_syncGuarded` captures `syncGeneration` and re-checks `isSyncStale`
after every await; `LiveActivityRegistrationController._syncGuarded` does the same. A non-granted
permission leaves a `PRESENCE not tracking: <reason>` breadcrumb, never a user nag: the three reasons need
different remedies, and a breadcrumb rather than a warn because a declined permission is a choice, not a
defect. The resume fix runs only while the stream is running (`_positionSub != null`) and goes through
`_uploadThrottled`. `unregister()`
resolves the doc id through `resolveUserDocId` when `_start` never ran, as
`LiveActivityRegistrationController.unregister` does.

## Consequences
Both controllers get coalesce-not-drop reentrancy from `ReentrantSync`; don't re-inline `_busy` /
`_pendingResync`. The position stream is device-only verification (no geolocator channel tests).
