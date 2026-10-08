# 0183. Employee tours follow the employee drawer

**Date:** 2026-09-01 (History toured for technicians), 2026-09-06 (History admin-only) · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
History joined the employee tour set on 2026-09-01, when a technician got a History scoped to their own
jobs, so its catalog was left role-agnostic. On 2026-09-06 (`c9e5812e`) History became admin-only: it left
`drawerGroups(isAdmin: false)` and `/history` is wrapped in `AdminOnly`. The rules file and
`tour_definitions_test.dart`'s hand-written `employeeToured` set still listed History as employee-reachable.

## Decision
Employee tours exist for what `drawerGroups(isAdmin: false)` offers: Calendar, Day route and Settings.
The admin-only destinations' employee catalogs are empty, except History's, which is unreachable since History went admin-only; screens guard wraps on catalog membership. `tour_definitions_test.dart`'s hand-written `employeeToured` pins the set and changes with the catalog.

## Consequences
History's role-agnostic catalog is unreachable for an employee, so it is harmless, but `employeeToured` no
longer matches the drawer it claims to mirror; a test that compared against `drawerGroups` would catch drift.
