# 0183. Employee tours follow the employee drawer

**Date:** 2026-09-01 (History toured for technicians), 2026-09-06 (History admin-only), 2026-10-07 (History employee catalog emptied) · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
History joined the employee tour set on 2026-09-01, when a technician got a History scoped to their own
jobs, so its catalog was left role-agnostic. On 2026-09-06 (`c9e5812e`) History became admin-only: it left
`drawerGroups(isAdmin: false)` and `/history` is wrapped in `AdminOnly`. The rules file and
`tour_definitions_test.dart`'s hand-written `employeeToured` set still listed History as employee-reachable.

## Decision
Employee tours exist for exactly what `drawerGroups(isAdmin: false)` offers: Calendar, Day route and Settings.
Every other destination's employee catalog is empty, History's included (gated on `isAdmin` 2026-10-07);
screens guard wraps on catalog membership. `tour_definitions_test.dart` derives the employee set from
`drawerGroups(isAdmin: false)` rather than hand-listing it.

## Consequences
A destination added to or removed from the employee drawer fails the test until its employee catalog follows,
so the drift that left History's catalog unreachable for a month cannot recur silently. An employee who
already saw History's steps keeps those seen flags; nothing replays.
