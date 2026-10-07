# 0056. Assignee-retaining edit merge, the offer list and the picker's dimming

**Date:** 2026-08-24 (dimming), 2026-09-19 (only time off dims; availability text removed) · **Rules file:** `.claude/rules/appointments.md`

## Context
The picker never shows a disabled person, so an edit save must re-append them or they are silently
unassigned. `offerableAssignees` keeps an active dispatcher already on a job (assigned before the title
rule existed) so they can be taken off; keyed on the live selection, deselecting them removed their own chip
next rebuild, so the toggle was one-way. This file once described a two-tier "cached value falling back to a
fresh read" for the active set that the code never had; the single awaited `watchEmployees().first` is
simpler and strictly safer. `assigneeNameAt` replaced five re-spelled bounds checks.

The 2026-08-24 rule dimmed anyone with any clash, which made deliberate double-booking unreachable from the
picker; the owner reversed it on 2026-09-19 so only time off dims, and removed the per-person "is off" / "is
on another job" lines, their collapse row, "Nobody is free", `AssigneeAvailabilityNotes` and
`AssigneeAvailability.whenLabel`. Without the `findClashingAppointments` fallback a date past the open range
made every clash invisible and the picker reported everyone free. Dimming on a personal block made the
absence unbookable and the clash alert unreachable. `forWeekBucketOf` and `forMirrors` carry long comments
against forking a span-keyed listener.

## Decision
Merge through `mergeRetainedAssignees`, offer through `offerableAssignees`, resolve the active set by an
awaited read, and dim only `unavailable` from `assigneeOfferState`.

## Consequences
Don't restore the availability lines from an older diff. A clash is never a reason to refuse time off.
