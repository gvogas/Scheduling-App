# 0169. iOS is Swift Package Manager only; no Podfile, ever

**Date:** 2026-06-21 (Podfile removed), 2026-07-14 (`saver_gallery`), 2026-07-17 (Maps override) · **Rules file:** `ios/CLAUDE.md`

## Context
The iOS project moved to SPM when the iOS config was set up (2026-06-21) and the Podfile was deleted.
Older notes still mention `pod install` and `${PODS_ROOT}`. Two popular plugins are CocoaPods-only:
the default `google_maps_flutter_ios` and `gal`; either would force a Podfile back in.

## Decision
No Podfile. Xcode resolves `firebase-ios-sdk` from `Package.resolved` on first open. Maps uses the endorsed
SPM implementation `google_maps_flutter_ios_sdk9` (Maps SDK 9.x, iOS 15+) as a direct dependency; Save to
Photos uses `saver_gallery` (ships a `Package.swift`), not `gal`. Vet every new iOS plugin for SPM first.

## Consequences
A CocoaPods-only plugin reintroduces a Podfile and `${PODS_ROOT}` build paths. Ignore any doc that says to
run `pod install`.
