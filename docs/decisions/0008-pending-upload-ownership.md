# 0008. Offline upload queue entries are owned

**Date:** 2026-09-04 (ownership), 2026-09-05 (`_currentOwner` `StateError`, owner call) · **Rules file:** `.claude/rules/images.md`

## Context
A queue keyed on nothing survived sign-out with the staged JPEGs still on disk, and the next account
to sign in on that phone drained it — someone else's photos, published under their name, onto a job
they may not even be on. Shared and handed-over devices are the normal case here, not the edge one.
Each drain also resolved the owner per entry: `_employeeIdForUid` is a Firestore read and both
`_attempt` and `_publishPending` ask, so N entries cost 2N+1 reads for an answer that cannot change
mid-pass.

Rejecting a pre-upgrade (ownerless) entry in `fromJson` looked like the safe reading and was the
opposite: it stranded those JPEGs on disk with nothing pointing at them. Adopting it for whoever is
signed in is the other wrong answer, and exactly the incident the owner field exists to prevent.

`_currentOwner`'s two failures ("signed out", "no users doc for uid") are internal preconditions on a
background drain with no surface to fail on; wrapping them in `ImageUploadFailure` (the family for
what a USER sees) would add two sealed `Failure` members no `toLocalizedMessage` branch can reach.

## Decision
Every `PendingUpload` carries the `uid` and employee doc id that staged it and drains only for that
owner; ownerless entries are parsed and kept so `prune` can reach them; `_currentOwner` throws a bare
`StateError`.

## Consequences
Don't file the `StateError` as drift, and don't reject or adopt ownerless entries.
