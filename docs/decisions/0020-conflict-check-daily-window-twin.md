# 0020. The server conflict check is a daily-window overlap

**Date:** 2026-09-04 · **Rules file:** `.claude/rules/search.md`

## Context
`findAppointmentConflicts` shipped with a raw instant test and immediately reported a 9-5 run across a
week as clashing with a 7 pm job inside it. The Dart rule it replaced (`appointment_day_slice.dart`) had
always compared DAILY windows.

## Decision
The callable filters through `dailyWindowsOverlap` in `functions/day_slice_utils.js`, hand-mirrored from
`appointment_day_slice.dart` and pinned by `functions/__tests__/indexed_search_conflicts.test.js`. It
keeps the fail-closed half: a doc whose stored times don't parse clashes unconditionally.

## Consequences
Change the Dart original and the JS twin in one commit. More conflict-check rules (the non-admin
`employeeIds` refusal, the clash owner) are in `.claude/rules/appointments.md`; the old client cap is in
ADR-0053.
