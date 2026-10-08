# 0064. A random starting password, the retired mailbox guard, and employee-only creation

**Date:** 2026-08-08 (`email_verified` guard added), 2026-08-21 (random password, guard removed, role hard-coded), 2026-08-29 (`#compat-1.47.0` retired) · **Rules file:** `.claude/rules/employees.md`

## Context
The posture is weaker than the codes P4c replaced, deliberately and with the owner's sign-off, and it has been
re-priced twice. While the starting password was the shared constant `Welcome123!`, anyone who knew an
employee's address could sign in as them between creation and first sign-in; what stopped the race winner was
`completeEmployeeSetup`'s `email_verified` guard (2026-08-08), which demanded control of the MAILBOX. On
2026-08-21 the shared constant and that guard were removed TOGETHER, replaced by `generateStartingPassword()`
(random per account, drawn once per call and shared by create and re-provision, returned in the response, never persisted). `verify_email_panel.dart`, `AuthService.sendVerificationEmail` /
`refreshEmailVerified` / `isEmailVerified` and `AuthFailureEmailNotVerified` were deleted. The same day the doc
became always `role: "employee"` (a race winner could previously get `isAdmin: true`, and an admin reads all
`/clients` PII); promotion became a later toggle. `isAdmin` stayed accepted-and-ignored as `#compat-1.47.0`
because every admin build <= 1.47.0 sent it on both create and Reset password, and `assertPayloadShape` throws on
the first unknown key; it was retired 2026-08-29 once the fleet reached 1.53 and the current client sent no such
key (`docs/DEPLOYMENT.md` §4a, the superset contract) — the shape of every future carve-out.

## Decision
Never bring back a shared default without a mailbox check, and never cite this as precedent for deleting one
elsewhere. Write the doc `role: "employee"` always. `_mapSetupError` keeps mapping the retired
`email-not-verified` message to `AuthFailureSetupNotAvailableYet` — named for what it means to the user, since
this build has no verification UI — so a rolled-back backend under a shipped build degrades to an `isExpected`
failure rather than `AuthFailureUnknown` and a non-fatal per retry.

## Consequences
The residual risk is NOT zero: whoever holds the address AND the generated password can still activate first.
It is bounded because a pre-empted account is a plain `employee` and an `invited` user is granted nothing by
`firestore.rules` (no clients, appointments or peers); the rest is operational — create the account when you hand
the credentials over, not weeks ahead.

## Functions side
`generateStartingPassword` draws 12 unambiguous characters with `crypto.randomInt`. `provisionAuthAccount` only resolves the uid of an
existing account; the rotation is deferred (ADR-0066). `completeEmployeeSetup` is
transactional and refuses `setup-not-pending` on a replay. `deleteEmployeeAccount` deletes the doc first and Auth
second, so a partial run converges. Both orphan paths (the create's rollback `deleteUser` failing;
`deleteEmployeeAccount` failing on Auth after the doc) `logger.error` the uid: an Auth account with no `users` doc
permanently bricks that email, because the pre-flight refuses an Auth account no doc claims, and only the Firebase
console can clear it.
