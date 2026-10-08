# 0095. Saves compose through `composeSave`; a number in the name field is lifted into phone

**Date:** 2026-08-15 (`composeSave`), 2026-08-14 (name-field lift) · **Rules file:** `.claude/rules/clients.md`

## Context
For a person `composeStored` REPLACES the typed name with the phone number; with empty `firstName`/`lastName`
that name was the only copy and the save destroyed it, with no Firestore history. The Name field is `required`
while both halves are `optional`, so ordinary add-a-client reproduced it, and re-typing in the edit sheet did
it again (`baseNameFor` returns `''`, so the field opens blank). The seeded name in `AddClientSheet` is a
programmatic `controller.text =` write that fires no `onChanged`; while its lift call was missing, the most
common add flow (inline add seeded from a phone search) stored a bare-number `name` with an EMPTY `phone`.
The candidate run starts and ends on a digit, so "Marc Tremblay (514) 555-1234" left "Marc Tremblay (", which
`composeSave` split into a lastName of "(". `restore-client-name-halves.js` imported `splitName` until it was
deleted 2026-09-28. The `name` rules cap was sized to the old "<typed name> <phone>" shape.

## Decision
`ClientNamePolicy.composeSave` returns the stored name and both halves, passing through only when the name came
back unchanged, a half is already populated, or there is no base name. `splitPersonName` is mirrored once in
JS, as `splitName` in `backfill-client-name-with-phone.js`. `liftPhoneFromNameField` runs on both sheets'
`onChanged` and on the seeded name in `AddClientSheet.initState`; it trims brackets at the seam via
`_openSeam`/`_closeSeam` (`OPEN_SEAM`/`CLOSE_SEAM` in JS). The `name` cap stays 225
(`TextLimits.personName` 200 + 1 + `TextLimits.phone` 24), pinned by `text_limits_test.dart`.

## Consequences
Widening `_edgeSeparators` instead strips a name's own bracket ("Depanneur (Nord)"). Lowering the cap under a
stored value makes that doc permanently un-updatable with an opaque `permission-denied`.
