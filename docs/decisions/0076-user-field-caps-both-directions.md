# 0076. User-field caps: rules never tighter than the server, client never looser than the callable

**Date:** 2026-08-01 (P4b `emergencyPhone`), 2026-08-08 (`createEmployeeInvite` deleted) · **Rules file:** `.claude/rules/employees.md`

## Context
`createEmployeeAccount` accepts `phone` up to 40 chars while `TextLimits.phone` is 24; a rules cap below 40 would
make every server-created doc with a longer phone permanently un-updatable, including by `deactivateEmployee`. The
40 outlives `createEmployeeInvite` (deleted 2026-08-08) because the docs it created remain. Conversely, a client cap
looser than the callable's lets a field accept a value the callable rejects as `invalid-argument`, which reaches the
user as an unexplained "Something went wrong" they can't fix by editing. Dart, CEL and JS cannot share a constant;
four appointment pairs are EXACTLY equal, so a one-character bump on either side breaks every long save with an
opaque `permission-denied`. The Wave import's `IMPORT_FIELD_CAPS` is a THIRD hand-mirror of `isValidClientData`, and
the quietest: the Admin SDK bypasses rules, so a cap above the rules cap writes a client doc the app can never
update again.

## Decision
Rules caps mirror the SERVER limit; the client caps with `TextLimits`. Name halves use `TextLimits.employeeNameHalf`
(100, matching `createEmployeeAccount` and `completeEmployeeSetup`) rather than the 200-char `TextLimits.firstName`;
`name` is the join (up to 201) and caps at 250 server and rules; employee email binds to `TextLimits.authEmail` (254,
the callables' `requireString(..., 254)`) rather than the 320-char `TextLimits.email`. `text_limits_test.dart` reads
`firestore.rules`, both `employee_accounts_*.js` and `functions/wave/mappers.js` back and fails the build on drift; a
new capped import field added to `IMPORT_FIELD_CAPS` is picked up automatically.

## Consequences
That test is the only mechanism enforcing these pairs.
