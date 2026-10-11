# 0119. Crew status pushes removed; name people by the raw id index

**Date:** 2026-09-01 to 2026-09-03 · **Rules file:** `.claude/rules/notifications.md`

## Context
Two admin-only push kinds, `crewOnMyWay` / `crewRunningLate`, existed for three days and were removed
with the rest of the crew signal (owner call): `notifyAdminsOfCrewStatus`, `crewStatusSignal`,
`crewStatusSenderName`, `buildCrewStatusMessage`. They named the sender through `toIdList`, which FILTERS
(non-strings, blanks, over-long, slash-bearing), while `firestore.rules` bounds `employeeIds` only by type
and size, so one droppable entry ahead of the subject shifted ids out of step with `employeeNames`.

## Decision
Don't restore those symbols from an older copy. Any fan-out that names a person resolves the name by
index against the RAW `employeeIds`; the RECIPIENT set is filtered, a positional name index is not.

## Consequences
A filtered index names the wrong person, silently.
