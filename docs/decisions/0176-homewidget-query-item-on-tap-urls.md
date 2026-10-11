# 0176. Tap deep links keep the homeWidget query item

**Date:** 2026-07-29 · **Rules file:** `ios/CLAUDE.md`

## Context
`ScheduleWidget.swift`, `LiveActivitiesAppAttributes.swift` and `SiriIntents/ScheduleSnapshot.swift` emit
`esproschedule://appointment?id=…&homeWidget`. The `home_widget` plugin's `isWidgetUrl` claims a URL only
when the `homeWidget` item is present, and nothing else consumed the scheme (`FlutterDeepLinkingEnabled` is
`false`; `AppDelegate` has no `open url` override), so a URL without it became a plain app launch until the
2026-07-29 fix.

## Decision
Keep the item on all three producers. Retire it only together with the `home_widget` tap channel; the
`app_links` dispatcher (`lib/core/deep_links/`) skips URIs carrying the item, so one tap opens the sheet once.

## Consequences
In 2026-07 dropping the item turned widget, Live Activity and Siri taps into plain launches. `app_links` now
also receives these URLs and `classifyDeepLink` skips them only because of the item, so dropping it today
reroutes the tap through the dispatcher instead. Verification is
Swift-side, so Mac-only: a widget row or Live Activity tap must open the appointment sheet.
