# 0167. Analytics build posture: off in debug, no ad id, SPM only

**Date:** 2026-09-07 · **Rules file:** `.claude/rules/analytics.md`

## Context
Every `flutter run` would file events against the production property, indistinguishable from real usage
because it comes from a real device doing real-looking things. DebugView is gated separately from
collection. The app sells no ads and has no attribution need, so the advertising id buys nothing and costs
a heavier App Store privacy disclosure and a potential ATT prompt. The iOS build has no Podfile.

## Decision
`kAnalyticsCollectionEnabled` is off in debug unless `ANALYTICS_DEBUG=true` (the posture `main()` takes for
Crashlytics); `build_env` is a user property. The define decides whether events are collected; the
`-FIRDebugEnabled` Xcode-scheme launch argument decides whether they stream to DebugView; both are needed
to watch live. Shipping builds set `FIREBASE_ANALYTICS_WITHOUT_ADID=true`, which swaps `FirebaseAnalytics`
for `FirebaseAnalyticsCore` in the plugin's `Package.swift`. The plugin is SPM-safe, a precondition.

## Consequences
Dropping the env var re-adds IDFA collection. Any future analytics dependency must be vetted for SPM.
