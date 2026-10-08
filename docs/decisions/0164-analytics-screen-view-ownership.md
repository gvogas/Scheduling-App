# 0164. Analytics screen views: one owner per screen, membership asserted

**Date:** 2026-09-07, 2026-09-10 (iOS automatic reporting off; `allScreens` asserted) · **Rules file:** `.claude/rules/analytics.md`

## Context
`HubTabRedirectRoute` pushes a NAMED route and then hands off to the live shell, so with the observer
seeing hub routes one arrival path counted twice and the other two once, and the four tabs read busier by
an amount that depends on the back stack. Below Flutter, Firebase's native automatic reporting fires on
`UIViewController` appearance: one anonymous `screen_view` per launch with
`ga_screen_class=FlutterViewController` and no `ga_screen`, inflating `screen_view` by one per session and
putting a nameless row in the Screens report. It hid on the first debug run because the event fires before
`setCollectionEnabled` settles and was dropped ("Analytics is disabled. Event not logged"); it appeared on
the next launch. A `showModalBottomSheet` route has no name, so the observer skips sheets. Until
2026-09-10 `logScreenView` checked only that a name was well-formed, so `allScreens` was a 20-entry list
with no production reader: a sheet passing an undeclared name compiled, passed and shipped an orphan row,
because the test walks the set, not the call sites.

## Decision
`analyticsScreenForRoute` returns null for `kShellOwnedRoutes`, so `FirebaseAnalyticsObserver` ignores
them, and `HubShellState` reports those tabs (`initState`; `select` on a real tab change).
`FirebaseAutomaticScreenReportingEnabled=false` in `Info.plist`. Every surface the observer can't see (unnamed sheets,
`EventDetailsView`, `ClientDetailView` including its two-pane pane, `OnboardingScreen` built inline by
`OnboardingGate`) calls `logScreenView` from its `initState`. `_log`, `_setUserProperty` and `logScreenView` assert membership (`isKnownEvent`,
`isKnownUserProperty`, `allScreens`).

## Consequences
Changing one half of the split alone silently double- or under-counts. Removing the plist key restores the
phantom screen. Without sheet views the create funnels have no entry step, only completions.
