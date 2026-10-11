# 0171. iOS 18.0 deployment floor; App Check through App Attest

**Date:** 2026-07-19 (floor raised from 15.0) · **Rules file:** `ios/CLAUDE.md`

## Context
The Siri App Intents extension needs iOS 16 and the Live Activity Directions button's returnable
`OpenURLIntent` needs iOS 18, so the whole app moved from 15.0 to an 18.0 floor, dropping iOS 15-17 users.
App Check uses App Attest (`AppleAppAttestProvider` in `main()`), which needs iOS 14+, the App Attest
entitlement and the provider enabled in the Firebase Console, and does not work on the Simulator.
`ios/Flutter/AppFrameworkInfo.plist` once pinned `MinimumOSVersion`; it never enforced the floor and the pin
is gone.

## Decision
The floor is 18.0, set on every Xcode target and only there. `com.apple.developer.devicecheck.appattest-environment`
is `production` for Release; the console provider is App Attest (no `.p8`, unlike DeviceCheck); debug builds
use `AppleDebugProvider` with a registered per-install debug token (`docs/IOS_MAC_BUILD.md` Phase E).

## Consequences
A console/code provider mismatch rejects attestation; a floor under 14 makes it fail silently on device. An
unregistered debug token fails writes and uncached reads with `permission-denied` while cached reads succeed,
so the failure looks collection-specific.
