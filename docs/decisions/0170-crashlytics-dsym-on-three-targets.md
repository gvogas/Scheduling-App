# 0170. Crashlytics dSYM upload on all three code-bearing targets

**Date:** 2026-07-21 · **Rules file:** `ios/CLAUDE.md`

## Context
Only Runner uploaded dSYMs, so crashes in `ScheduleWidgetExtension` and `SiriIntents` could not be
symbolicated. The extensions are Firebase-free and bundle no `GoogleService-Info.plist`, and Xcode's
user-script sandbox stops the upload script reading outside the target, so that upload fails silently.

## Decision
Each of the three targets has a "Crashlytics dSYM upload" Run Script calling the SPM checkout's
`Crashlytics/run`; Runner reads its bundled plist, and the two extensions pass
`-gsp "${PROJECT_DIR}/GoogleService-Info.plist"` (the `ios/`-root plist). `ENABLE_USER_SCRIPT_SANDBOXING = NO`
is set project-wide and explicitly on the widget target. Release `DEBUG_INFORMATION_FORMAT` is
`dwarf-with-dsym` at the project level, which the extension targets inherit.

## Consequences
Re-enabling sandboxing, or a per-target `dwarf` override, silently stops that target's upload; the build
still succeeds.
