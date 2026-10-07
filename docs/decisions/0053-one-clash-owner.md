# 0053. One owner of "what stands in the way"

**Date:** 2026-09-04 (server-side check) · **Rules file:** `.claude/rules/appointments.md`

## Context
`findClashingAppointments` answers with clashing RECORDS, and `findBusyEmployees` is expressed through it.
It briefly was not: the query was shared (`_conflictSnapshots`, since gone) while `findBusyEmployees` kept
the rule hand-spelled in its own doc loop. Testing raw instants instead of daily windows reported a 9-5 run
across a week as clashing with a 7 pm job inside it, a phantom clash the admin forced through on every
evening job. `AppointmentRecord` substitutes a placeholder instant for unparseable times, which silently
failed the overlap and dropped the row (pinned by "a doc with unparseable times is kept, not silently
dropped"). On 2026-09-04 the check moved to the `findAppointmentConflicts` callable because the client
query was capped at 1000 docs per 30-id chunk and silently reported no clash past it (server twin:
ADR-0020); the Dart path is now the injected-`FirebaseFunctions`-absent fallback, tests only.

## Decision
`clashingAppointments` is the one pure rule; the repository passes `windowUnknownIds` in; the server
refuses a non-admin's `employeeIds` naming anyone else.

## Consequences
If the picker and the busy check ever disagree, the bug is a second copy of the rule. A personal block
overlapping only another personal block raises no alert under `clientJobsOnly` — correct.
