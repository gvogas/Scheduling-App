# 0116. Off-app schedule mirrors: one identity, one window, locked-safe fields

**Date:** 2026-07-19 (Siri Phases 1-3), 2026-08-08 (shared window) · **Rules file:** `.claude/rules/notifications.md`

## Context
The `SiriIntents` extension (bundle id `net.vogas.scheduling.SiriIntents`, `SiriIntentsExtension.entitlements`
sharing the App Group, iOS 18.0) carries Phase-1 read intents, Phase-2 `TomorrowScheduleIntent` and
`DayScheduleIntent`, and Phase-3 `NthAppointmentIntent`; on-device phrase verification is pending (see
`ios/SiriIntents/README.md`). `ScheduleSnapshotService` writes a today + 7 days payload under the separate key `schedule_snapshot` in
the same App Group; the widget's `schedulePayload` is untouched and the snapshot never calls
`HomeWidget.updateWidget`. The widget and the snapshot asked `myAppointmentsProvider` (keyed by range
VALUE) for different windows, and `AppSyncListeners` holds both open all session: two permanent listeners
per employee, one a subset of the other. Their streams re-emit only on a write, so an app resident across
midnight published yesterday's buckets and Siri answered "no appointments today". An `AsyncError` or
`AsyncLoading` also carries a null value, so keying on null blanked the mirrors on a failed read.

## Decision
Both mirrors resolve who they are for through `activeUserIdentityProvider` (active gate,
`retryAsync` over `findUserByUid` for the post-sign-in token lag; returning null wipes both on sign-out, where
`scheduleSnapshotProvider` emits `data(null)`; employees use `myAppointmentsProvider`, admins `appointmentsInRangeProvider`), fetch
`AppointmentDateRange.forMirrors(today)` (`mirrorLookaheadDays`; `scheduleSnapshotLookaheadDays` is that
value), and watch `currentDayProvider`. Both skip any emission `AppSyncListeners.isUnsettled` flags.
`ScheduleSnapshotService.apply` owns "null clears, otherwise write"; `AppSyncListeners._snapshotSync`
calls `clearSnapshot()` through it, so there is no explicit sign-out clear. `buildScheduleSnapshot` and
`ScheduleSnapshot.swift` are hand-mirrored; bump `version` on both sides. Cancelled visits and records
with a null/empty `id` are dropped (Phase-4 write actions resolve their target by that id). The payload carries only what the intents speak (client name, times,
address, status), never notes, phone or pictures. Phases 1-3 keep the `SiriIntents` extension Firebase-
and network-free.

## Consequences
A `Date` or `Int` parameter cannot sit in a spoken App Shortcut phrase, so `DayScheduleIntent` and
`NthAppointmentIntent` rely on Siri's follow-up prompt; don't "fix" that into a phrase parameter. A new
`.swift` in `ios/SiriIntents/` must be hand-added to `project.pbxproj` (all four sections). Phase 4 breaks
the Firebase-free rule deliberately, as its own reviewed increment.
