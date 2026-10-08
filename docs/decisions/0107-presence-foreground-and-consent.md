# 0107. Presence is foreground-only, opt-in, and asks once

**Date:** 2026-07-27 (background mode removed), 2026-09-04 (sharing gate), 2026-09-07 (one save path) · **Rules file:** `.claude/rules/notifications.md`

## Context
The App Store rejected the build under guideline 2.5.4 ("using the location background mode for the sole
purpose of tracking employees is not appropriate"), so the `location` `UIBackgroundModes` entry was
removed; `AppleSettings.showBackgroundLocationIndicator` went with it, and `geolocator` gates
`allowsBackgroundLocationUpdates` on the plist key (`GeolocationHandler.shouldEnableBackgroundLocationUpdates`),
so the removal degrades cleanly. A second, escalating `requestPermission()` was removed too. Tracking also
used to start at sign-in with nothing in Settings saying so: an OS grant is consent to a feature, not
standing consent to be tracked by an employer. Later the Settings row and the Location sharing screen each
spelled their own save, and a write that skipped the presence half left the phone uploading after the
switch read off.

## Decision
iOS suspends the stream in the background, by design. `LocationPermissionService.ensureLocation` issues
exactly one prompt and never asks for Always (a pre-existing Always grant is honored). Tracking is gated on
`locationSharingEnabled`, absent = OFF (the opposite of `travelAlertsEnabled`). `applyLocationSharing`
owns the flip (field AND presence); `saveLocationSharing` wraps it with the offline guard, the
`ME-SAVE location sharing failed` tag and the notice. `NSLocationAlwaysAndWhenInUseUsageDescription` stays
declared on purpose: App Store Connect's ITMS-90683 static scan fires on `geolocator_apple` compiling
`requestAlwaysAuthorization` in, and the key cannot itself trigger an Always prompt (see `ios/CLAUDE.md`).
Otherwise iOS needs only `NSLocationWhenInUseUsageDescription` in `Info.plist`; the Time Sensitive
Notifications entitlement (for `leaveNow`) is Mac-side.

## Consequences
A backgrounded device's presence goes stale within `PRESENCE_STALE_MINUTES`, so the travel sweep's
address or 30-minute fallback is the normal path, not an error; `decideOrigin`'s presence prong still fires
whenever a tech has the app open. An earlier version of this rule told readers to remove the Always key,
which cost a security reviewer a false finding.
