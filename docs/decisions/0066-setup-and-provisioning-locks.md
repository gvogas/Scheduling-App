# 0066. Setup and provisioning share a server lock; re-provision resolves by uid

**Date:** 2026-08-02 (uid-not-email refusal), 2026-09-23 (`accountOperations` locks, local audit changes) · **Rules file:** `.claude/rules/employees.md`

## Context
`users.email` is admin-editable and can disagree with Auth on docs edited before `changeEmployeeEmail` existed
(nothing back-fills them). An email-only "still invited?" check cleared a doc that was not the account Auth
handed back: it reset a live employee's password and minted a second `users` doc carrying their uid, and
`syncUsersByUid` then deleted their `usersByUid` bridge, locking them out of everything. Rotating the password
before the transaction claimed the person meant a setup committing in that window left them active on a password
nobody told them had been reverted. A post-transaction reset race remained until 2026-09-23, when setup and
re-provision began sharing `withAccountOperation` locks and re-provision began stamping `setupRequiresPassword`.
Reporting a failed post-setup session renewal as a setup failure sent a retry to `not-pending` on an account
still holding the FIRST password.

## Decision
Re-provision resolves by `uid`, refuses a uid owned by another doc (the rules' `allow create` uid denylist
restated for the one path that bypasses rules), and rotates the password (`resetProvisionedPassword`, split out of `provisionAuthAccount` for this) only after the claim, inside the lock
held through the Auth call. Setup holds the same lock across its password write and activation; duplicate creates
take an email-hash lock before minting Auth. Legacy setup without `newPassword` may activate only unflagged
invitations. Provisioning rolls back an Auth account it minted. A failure after the password changed does not
revert it (leaving them `invited` on a password they chose beats resetting them). Renewal is best-effort.

## Consequences
Auth and Firestore remain separate stores: a partial failure can leave an invited account on the chosen password
(the next sign-in routes back to setup). Locks have no TTL or automatic takeover; recovery is in
`docs/audits/AUDIT_ROLLOUT_2026-09-23.md`. After setup, `deleteEmployeeAccount` refuses and disable is the only
removal.

**Amended 2026-10-09:** legacy setup without `newPassword` is refused and `setupRequiresPassword` is no longer stamped or read (ADR-0185).
