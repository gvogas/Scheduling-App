# 0052. The time-off clash alert is advisory, after the save, and replaces the busy prompt

**Date:** 2026-08-24 (alert; personal save skips the prompt), 2026-09-07 (`replaceAssignee` moved) · **Rules file:** `.claude/rules/appointments.md`

## Context
Booking a day off over Marc's jobs used to pop "Schedule Conflict — Marc is already booked / Book anyway";
adding the alert (designed in `docs/archive/2026-08-24-timeoff-clash-alert.md`) on top gave two dialogs
about one clash back to back. The alert names the jobs and offers a swap on each, where the prompt only
named the person, so a personal save now skips the prompt (pinned on both controllers by a test that it no
longer returns the busy outcome).

A second swap built from the dialog-open snapshot dropped the first replacement AND put the person who is
off back on the job; keying per row had the same hole, since two rows can be one document (pinned by "a
SECOND swap on the same job builds on the first"). Undo by writing a snapshot back silently reverted the
other row's swap; `_undo` takes the whole `_ClashGroup` because a transposed id/name pair still compiles on
a method that writes. A loading row's completion is dropped by the `_openKey != key` staleness guard, so a
row left loading spun forever. An error notice for a failed lookup would read as the save having failed.
`replaceAssignee` was a private function in the dialog that no test could reach until 2026-09-07.

## Decision
Time off is a fact about a person and the schedule does not get to veto it: the alert runs after the
write, dismisses as "Leave them", swaps one occurrence by replacement, tracks live records by doc id, and
inverts swaps for Undo.

## Consequences
Routing a swap through the series editor would take the person off every Wednesday; removing instead of
replacing writes an empty crew the form forbids.
