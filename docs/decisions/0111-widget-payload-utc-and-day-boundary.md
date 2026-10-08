# 0111. Home-screen widget payload: UTC instants, hand-mirrored builders, Toronto days

**Date:** 2026-07 · **Rules file:** `.claude/rules/notifications.md`

## Context
`WidgetSyncService` writes a two-day payload (`todayJobs` non-terminal remaining, `tomorrowJobs`, and a
`rolloverAt` set only once today has no incomplete job) into the App Group `group.net.vogas.scheduling`,
so WidgetKit flips today to tomorrow with no app run. A bare local `toIso8601String()` has no zone
designator and the Swift `ISO8601DateFormatter` cannot parse it. The server builder resolves day
boundaries in `America/Toronto`; the Dart mirror uses device-local midnight.

## Decision
Every payload instant is `toUtc().toIso8601String()`. `buildWidgetPayload` (`widget_sync_service.dart`),
`functions/widget_payload_utils.js` and the Swift decoder change in lockstep. Widget and notification
taps use the `esproschedule://appointment?id=…` deep link.

## Consequences
On an off-Toronto device the app-written and push-written payloads can disagree on which day a job is
"today". A timed 2 p.m. job needs a ~10 h offset to move, but an all-day block starts AT midnight, so any
westward offset flips its bucket and the widget shows whichever writer went last. Accepted for a
single-timezone (Quebec) business; the first thing to fix if the app ships outside Quebec.
