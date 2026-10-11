# 0186. `updateFieldNotes` deleted

**Date:** 2026-10-09 · **Rules file:** `.claude/rules/appointments.md` · **Amends:** ADR-0054, ADR-0022

## Context
ADR-0054 kept `AppointmentsRepository.updateFieldNotes` (no production caller since 2026-09-06) as an emergency
repair path while older builds still wrote the parent `fieldNotes` string. On 2026-10-09 the owner confirmed
every phone runs 1.63.0+93 or newer, none of which writes it.

## Decision
Delete the method from the interface and `FirebaseAppointmentsRepository`, and with it `_patchWindow`'s
`isRecordWrite` flag (its only `false` caller, ADR-0022). Crew notes are written only through
`AppointmentFieldNotesStore.append`.

## Consequences
The legacy string stays readable: old docs still carry it, and `DetailsFieldNotesView` renders it unattributed
atop the thread. The parent `fieldNotes` rules disjunct also stays, for the reason ADR-0054 gives (the photo
append's `updatedAt`-only parent update needs it), not for old builds.
