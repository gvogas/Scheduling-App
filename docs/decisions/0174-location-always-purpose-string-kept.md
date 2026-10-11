# 0174. Keep NSLocationAlwaysAndWhenInUseUsageDescription declared

**Date:** 2026-08-05 · **Rules file:** `ios/CLAUDE.md`

## Context
The app asks only for when-in-use (`Geolocator.requestPermission()`) and `UIBackgroundModes` holds only
`remote-notification`, so the Always key reads as dead. But `geolocator_apple` compiles
`requestAlwaysAuthorization` into the binary (`PermissionHandler.m:68,77`), and App Store Connect's static
scan emails ITMS-90683 "Missing purpose string" on every upload without it. A security reviewer once filed a
false finding after a rules file wrongly called the key dead. Earlier text said the plist carried a comment
explaining this; it never did (`Info.plist` has no comments), so the rules file is the record.

## Decision
Keep the key. The plugin checks `NSLocationWhenInUseUsageDescription` FIRST and reaches Always only as an
`else if`, so with both present the Always branch is unreachable, which keeps the privacy policy's "only ever
asks for 'While Using the App'" true. The purpose string says location is used only while the app is open.

## Consequences
Removing it buys nothing and costs a warning email per build. It is separate from the bans on a `location`
background mode and on requesting Always (`.claude/rules/notifications.md`).
