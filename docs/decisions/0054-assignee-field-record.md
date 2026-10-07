# 0054. An assignee may record crew notes and photos

**Date:** 2026-09-01 (grants), 2026-09-03 (crew status removed), 2026-09-06 (notes subcollection) · **Rules file:** `.claude/rules/appointments.md`

## Context
Until 2026-09-01 a technician could read a job and mark it complete, nothing else: the photo pipeline,
offline queue and magic-byte validation were wired to the admin-only edit form, so for a trade where the
field record is the billable artifact it travelled by phone call. Three narrow grants followed. `fieldNotes`
became its own disjunct because the mark-done branch is the most security-sensitive write and its exact
key set is what makes it reasonable about. The crew-notes path carries no status gate: a note is often
the explanation for a job that went wrong. A flat length cap refused the `updatedAt`-only parent diff of a
photo add, so the crew could add the photo row and never the photo. Photo create is additive; removal is
not, and a field record must not be quietly deletable by the person whose work it documents.

A crew "On my way"/"Running late" signal was built 2026-09-01 and REMOVED 2026-09-03 (owner call) across
rules, Dart, `functions/` and both ARBs. On 2026-09-06 crew notes moved to `appointments/{id}/fieldNotes`,
which fixed admins being unable to see crew notes at all; the parent `fieldNotes` disjunct, the string and
`updateFieldNotes` survive because older builds still write the field and there was no backfill.
`updateFieldNotes` has had no production caller since 2026-09-06 (its only reference is
`firebase_appointments_repository_invalidation_test.dart`) and is kept as an emergency repair path; its
survival and the disjunct's share an answer for different reasons (a Dart method versus the server
contract).

## Decision
Exactly three assignee parent disjuncts (mark-done, legacy `fieldNotes`, Start job); notes and photos are
additive subcollection creates; update and delete stay admin-only.

## Consequences
The parent `fieldNotes` disjunct is not retirable when old builds age out: a current assignee photo
append (`AppointmentImagesStore.append`) batches a parent `updatedAt`-only update, and on an open job that
disjunct is the only one admitting the diff. Don't delete `updateFieldNotes` on a simplify pass without checking whether any build in the fleet still
calls it. A new disjunct is a deliberate edit to the count tests, never a silent widening.
