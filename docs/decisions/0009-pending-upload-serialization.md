# 0009. One serialized drain path and serialized queue mutations

**Date:** not recorded in the old text (before 2026-08-19) · **Rules file:** `.claude/rules/images.md`

## Context
A save that uploaded its staged batch directly raced a listener-driven `drainPending()` that loaded
the just-added entry: `ImageStorageService` mints each file name from `DateTime.now()`, so the two
passes produced different storage paths, derived different doc ids, and the photo landed twice. No
dedupe of any kind catches that — they really are two different objects.

`PendingUploadStore`'s `add`/`remove`/`prune` are each `load()` → mutate → `_save()` over ONE
SharedPreferences key, so two overlapping mutations read the same list and the second save erased the
first's change: a save staging a batch while a drain removed a finished one wrote `[E1, E2]` then
`[]`, stranding E2's files with no queue entry and no failure notice.

Before the subcollection, re-linking a carried image rested on `arrayUnion`'s deep-equality dedupe,
which is why each carried image still serializes its exact `uploadedAt` (ISO-8601 in the JSON,
round-tripped by `AppointmentImage.fromMap`).

## Decision
Staging never uploads directly; staging and draining share `drainPending` (`_draining` +
`_pendingDrain`; coalesce, never drop). Store mutations run inside `_serialized`.

## Consequences
Don't "simplify" `_serialized` into call-site serialization — the requeue inside a drain is a caller
too.
