# 0060. History scoping by `employeeIds`; the UI is admin-only

**Date:** 2026-09-01 (technician History), 2026-09-06 (History admin-only) · **Rules file:** `.claude/rules/appointments.md`

## Context
The 2026-09-01 audit found a technician had no search. History became the same terminal archive narrowed by
`employeeIds`, with one scan window per scope; the `(employeeIds CONTAINS, status ASC, startTime DESC)`
composite had to be deployed and READY before the app build shipped. No rules change was needed: the list is
constrained by `arrayContains` on the caller's own doc id, the shape `watchForEmployeeInRange` already uses.
On 2026-09-06 (owner call) History became admin-only — an employee's copy had no filter control, and a
technician reaches a finished job through the calendar's closed-job sink — so the drawer row and
`AppointmentHistoryView`'s `scopeEmployeeId` were removed.

## Decision
`_historyQuery(employeeId)` owns the narrowing; the repository keeps per-scope windows; the UI is admin-only.

## Consequences
The repository scoping, per-scope windows, server `historyScope` guard and `emp:<id>:` token scopes mirror a
DEPLOYED contract older builds still call; removing any of them is a breaking backend change, not dead-code
tidying.
