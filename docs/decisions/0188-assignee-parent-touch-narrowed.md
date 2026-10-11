# 0188. The assignee `fieldNotes` disjunct narrowed to an `updatedAt`-only touch

**Date:** 2026-10-09 · **Rules file:** `.claude/rules/appointments.md` · **Amends:** ADR-0054

## Context
ADR-0054 kept the assignee parent disjunct `hasOnly(['fieldNotes', 'updatedAt'])` (length cap only when
`fieldNotes` is present) because `AppointmentImagesStore.append` batches a parent update of
`updatedAt: serverTimestamp()` alone, and on an open job no other assignee disjunct admits that diff. Crew
notes live in `appointments/{id}/fieldNotes` since 2026-09-06, `updateFieldNotes` is deleted (ADR-0186), and
1.63.0+93 (`cc38be5d`, the oldest build in the fleet on 2026-10-09) writes the parent `fieldNotes` from no
assignee path.

## Decision
The disjunct admits only `hasOnly(['updatedAt'])` with `updatedAt == request.time`. An assignee write that
carries `fieldNotes` is refused. It is still one of exactly three assignee parent disjuncts.

## Consequences
Don't delete the disjunct: without it the crew adds the photo row and never the photo. The legacy string on
old docs still renders; only the admin path (`isValidAppointmentData`'s cap) can write the field now.
