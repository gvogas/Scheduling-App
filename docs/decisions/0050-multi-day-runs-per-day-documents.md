# 0050. A multi-day job is one document per day

**Date:** 2026-08-27 · **Rules file:** `.claude/rules/appointments.md`

## Context
One document carries one `status`, so a wide job closed entirely when the crew marked day 1 complete.
Designed in `docs/archive/2026-08-27-per-day-appointments.md`; the days share `seriesId` and store
`dayIndex`/`dayCount`. Feeding the stored pair into `_dayIndexOn` made day 3 claim the five days after its
start on the drawer badge, roster and dashboard at once. A console doc with `dayCount: 5` and no
`dayIndex` re-serialized as `dayIndex: 0` and was refused on every later edit (same asymmetry as
`appointmentSpanNotWidened`). Comparing `startTime` for "this and the following days" selected nothing once
day 1 was moved past its siblings, and swept the moved day up from day 4; `planPropagate` initially lacked
the `anchor`. The dialog's old count scanned terminal siblings that are never written. An edit could widen
a client job into the one wide document this design eliminates. A document count read a Monday–Friday
booking as five jobs; the `dayIndex > 1` subtraction needed no backfill (single-day docs lack the field;
day 1 stores 1), and the Job history window carries 10 docs of headroom for the Dart filter. No migration
was needed: prod held zero open multi-day jobs on 2026-08-27
(`functions/scripts/count-multi-day-appointments.js`, read-only — re-run before shipping); three wide
documents render through the derived branch. Each run day now gets its own Live Activity card, since every
split day is one day.

## Decision
Split jobs per day; keep personal blocks and time off wide; treat the stored pair as a label; select scope
by `dayIndex` with an anchor; fix run length at booking; count a run once.

## Consequences
Never reuse `seriesId` for repeating multi-day work. The overdue prompt and tomorrow digest now speak per
day — a real increase in message volume.
