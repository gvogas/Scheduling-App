# 0078. The emergency contact lives in a private subcollection

**Date:** 2026-08-02 (owner call), 2026-08-04 (no migration) · **Rules file:** `.claude/rules/employees.md`

## Context
Firestore rules are document-level, and `/users` read clause 2 deliberately lets every active employee read every
active peer (crew pickers, names and colours need it). On the parent doc the emergency pair therefore shipped a third
party's name and phone — a non-user who never consented — to every employee's device. Owner call 2026-08-04: nobody
had entered one, so there was no data to move and the feature was treated as clean-slate;
`functions/scripts/backfill-emergency.js` was deleted. A plain denylist entry beside `uid` would reject any write
touching the key, including the `FieldValue.delete()` scrub `updateEmployee` sends on every save, and leave any doc
carrying the pair un-updatable even by `deactivateEmployee` (a partial update presents every untouched field in
`request.resource.data`). The edit sheet's fields once started blank and a save merged two empty strings over a
stored contact; a stale cache-first emission could be saved back as a lost update.

## Decision
`users/{docId}/private/emergency` with `allow read, write: if isAdmin() || (isActiveUser() && myDocId() ==
userId)`. `allow create` bans both keys on the parent; `allow update` routes them through `emergencyFieldNotSet(f)`,
which refuses a write that leaves a value and admits absence, so an untouched legacy value passes through and the
client scrub heals it on the next save; `isValidUserData`'s caps stay for that pass-through. `isAvailabilityOnlyChange()`
no longer lists the pair, since P5's self clause governs only the users doc. `EditPersonSheet`'s three flags make the
async seed safe. `emergency_contact_rules_test.dart` reads `firestore.rules` back (rules can't be unit-tested without
the emulator).

## Consequences
Who to call when something goes wrong on site is a different question from when someone works, so the pair renders
as its own section. A read failure means "not entitled".
