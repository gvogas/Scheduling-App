# 0048. All-day blocks store real instants and reach every mirror

**Date:** 2026-07-31 (all-day, mirrors, schedule panel), 2026-08-03 (`setPersonal` keeps `isAllDay`) · **Rules file:** `.claude/rules/appointments.md`

## Context
`isAllDay` keeps midnight → 23:59 instants so no query changes. `setPersonal(value: false)` used to clear
it, because the switch was personal-only and a surviving flag saved a midnight–23:59 client visit with
nothing on screen to repair it; on 2026-08-03 all-day was offered on every job, so clearing it would discard
a deliberate choice. The repeat rule moved from a standalone dropdown into the schedule `SheetPanel`
(owner call, 2026-07-31). Each mirror needed the flag for its own reason: without it the travel sweep put
the midnight start inside its 90-minute window at ~23:30 the night before and fired "time to leave"; push
text printed "12:00 a.m."; the widget's `startTime.isAfter(now)` test dropped the block from today at
00:00, so it showed only under tomorrow and then vanished; Siri said "unnamed client" (snapshot v2 added
`isAllDay` and `title`). Siri's prefer-timed test was first applied across the 8-day flattened snapshot, so
it answered with Thursday's visit and never mentioned today's all-day block.

## Decision
Store real instants, resolve both save paths through `appointmentSpan`, keep the add/edit controller
asymmetry, and thread `isAllDay` through the travel sweep, push text, widget and Siri.

## Consequences
The snapshot schema has since moved on (Dart `scheduleSnapshotVersion` 4; Swift `supportedVersions`
`[3, 4]`). Don't collapse the two controllers' all-day behaviour into one.
