# 0175. Every extension carries its own PrivacyInfo.xcprivacy

**Date:** 2026-08-05 · **Rules file:** `ios/CLAUDE.md`

## Context
Both extensions read `UserDefaults(suiteName:)`, a required-reason API (`CA92.1`); a missing declaration
draws ITMS-91053. `ScheduleWidget` is a `PBXFileSystemSynchronizedRootGroup` (Xcode 16 synchronized folder),
so a file in it is bundled automatically and its empty Resources phase is correct. `SiriIntents` is a plain
`PBXGroup`, so its manifest needed an explicit fileRef, build file and Resources-phase entry (2026-08-05).

## Decision
Each extension ships its own manifest; one in a non-synchronized group is added to the target by hand.

## Consequences
A third extension without a manifest draws ITMS-91053. Don't "fix" the widget's empty Resources phase.
