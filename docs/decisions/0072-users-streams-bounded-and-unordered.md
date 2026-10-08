# 0072. The `users` streams are bounded, warned and sorted in Dart

**Date:** 2026-08-08 (`employeesStreamProvider` autoDispose), 2026-08-19 (ceilings removed and restored) · **Rules file:** `.claude/rules/employees.md`

## Context
The 2026-08-19 cleanup commits removed the stream ceilings, and they were restored the same day at higher numbers
(`_userStreamLimit` 500 → 1000; the appointment range streams at `_rangeStreamLimit` 3000). The paging that
replaced them fixed silent truncation correctly, but an unbounded live `snapshots()` — held open at once by the
calendar, the day route, the drawer badge, the roster reducer and the dashboard, and re-established per month page
— is a different risk class from an unbounded one-shot `.get()`, and every warn had gone with them. An
`orderBy('name')` makes Firestore exclude docs missing `name`, which would drop an unnamed active employee out of
the picker and silently change who can see a visit. Before 2026-08-08, opening the add-appointment sheet once
pinned a second live `users` listener for the session beside the always-on `watchAllUsers()`.

## Decision
Bounded-and-loud, never unbounded and never bounded-and-silent. `watchEmployees` filters to active; `watchAllUsers` returns every status. No `users` stream orders server-side; all three
sort in Dart through `_toSortedEmployeeRecords`, which holds the cap warn. `employeesStreamProvider` (consumers:
the two transient appointment sheets plus the Dashboard) is `autoDispose` and not derived from
`allUsersStreamProvider`, which includes invited and disabled accounts.

## Consequences
A new stream without both the bound and the warn reintroduces either an unbounded live snapshot or a silent
prefix.
