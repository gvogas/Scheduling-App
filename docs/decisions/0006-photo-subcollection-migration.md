# 0006. Photos moved to `appointments/{id}/images`; the `pictures` array retired

**Date:** 2026-08-13 (Phase 1), CONTRACT step, 2026-09-06 (verified complete), 2026-09-28 (scripts deleted) · **Rules file:** `.claude/rules/images.md`

## Context
Every appointment carried its whole photo array — a `url` alone was ~215 of a ~290-byte entry — while
the calendar reads up to 1000 appointments at a time and only the detail sheet shows a photo. Phase 1
wrote both stores; the array was retired once no device ran a build that read it (the same gate the
`#compat-1.37.1` shim waited on). The photo surface was split out of
`firebase_appointments_repository.dart` into `AppointmentImagesStore` so the CONTRACT step was a file
to open rather than a diff through a 900-line class.

The array form deduped through `arrayUnion`, which compares maps by deep equality and worked only
because every image serialized its exact `uploadedAt`; one field serialized a hair differently and it
silently stopped deduping. The derived doc id replaced it.

`pictureCount` briefly gated the detail sheet's subcollection read. The counter is debounced and a
parent `update()` that exhausts its retries leaves it wrong forever with only a server log, so the
gate made a just-added photo invisible on reopen and a failed recount invisible permanently — the
failure the migration was shaped to avoid.

The client used to enumerate `appointment.pictures` on delete to know which objects to remove; with no
array, a client-side cleanup would delete nothing while looking like cleanup.

The rules capped the array at 100 to keep the parent under its 1 MB ceiling; moving photos out made
that unreachable and rules cannot count subcollection documents, so no equivalent ceiling was
reinstated. `d.pictures.size() <= 100` is still in `firestore.rules` and still reachable: about 45
prod appointments carry an empty `pictures: []` that rides along in `request.resource.data` on every
edit. That residue is permanent — the clear script early-returns on `pictures.length === 0` before its
delete (verified 2026-09-06: no prod doc holds a non-empty array, so the clause guards only empty
lists).

Scripts (deleted 2026-09-28, in git history): `backfill-appointment-images.js` copied an array into
the subcollection (copy-only, `--dry-run`, atomic per appointment); `clear-appointment-picture-arrays.js`
deleted the array afterwards and re-stamped `pictureCount` from the subcollection on every document it
scanned, including ones with no array that it used to `continue` past (`needsRecount`, pinned). They
were deliberately separate: a copy-and-delete pass could not be dry-run meaningfully, since the dry
run would report coverage it was about to create. The clear script refused any appointment whose
subcollection did not cover every array entry, and any entry with no identity (no `storagePath`, no
url), since clearing it would destroy the only record it existed.

## Decision
Photos live only in the subcollection; the parent keeps `pictureCount` for the card indicator only.
Doc ids are derived from the photo.

## Consequences
Read "not reinstated" as "no equivalent on the SUBCOLLECTION", never as "the array clause was
deleted". Don't gate a photo read on `pictureCount`.
