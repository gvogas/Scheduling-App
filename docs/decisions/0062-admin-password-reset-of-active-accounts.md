# 0062. Admin password reset of an active account

**Date:** 2026-09-29 (built, 1.63.0), 2026-10-07 (S1 admin re-auth) · **Rules file:** `.claude/rules/employees.md`

## Context
Employee emails are not real inboxes, so Forgot password can never reach anyone; an active employee who lost
their password had no way back. The first build rethrew a `revokeRefreshTokens` failure after the password had
already changed, locking the person out behind a password nobody had seen (`updateUser` with a password already
invalidates sessions). An early note said "the admin can just reset again" if the employee re-chose the
temporary password; owner call 2026-09-29 reversed it, since the forced change would otherwise complete on a
password the admin read off the dialog. S1 (owner call 2026-10-07) added the admin's own re-auth. The response
email was described as never the Firestore copy, which can disagree with Auth on older docs (and may be empty);
the code prefers the Auth record and falls back to the doc only when Auth has none.

## Decision
`resetEmployeePassword`: admin re-auth (client: `showPasswordReauthDialog`, a `PasswordReauthDialog` with reset copy, then
`AccountDeletionService.reauthenticateWithPassword`, server `assertFreshReauth`); refuse self, non-active and
admin targets (re-checked in `markPasswordResetRequired`'s transaction, which also re-checks `active` + the same `uid`, so a concurrent promotion or disable can't get the flag stamped); under `accountOperations/{uid}` write the
server-owned `passwordResetRequired: true` first, then the password, then revoke (a revoke failure is logged with
`uidHash` and the credentials are still returned). Both gates (`splash_controller.dart`, `sign_in_controller.dart`) route `active && passwordResetRequired` to
`ChangePasswordScreen` (`AppRoutes.changePassword`) AFTER the unchanged invited and `!isActive` checks (so an inactive flagged account is still
signed out), keeping the session; sign-in clears `AuthCache`. `completePasswordReset` (opened with `assertActiveCall`) sets Auth first, then clears
the flag in a transaction re-checking `active` + `uid`, then reauthenticates best-effort (`_renewSession`). Log out on that screen deregisters the device before
`signOut()` and restores it on failure, the same order as account exit.

## Consequences
Status never moves, so `syncUsersByUid` and the Auth-access reconcile have nothing to do and the
active-to-invited revoke never fires. Builds <= 1.62.x ignore the flag and keep the temporary password. The
splash cached-identity fast path doesn't read the flag: a device that signed in with the temporary password on a
pre-1.63 build keeps its cache and skips Change password until it signs out — accepted, consistent with old
builds. The S4 invited-account re-provision reset is a separate path this flow does not touch.

## Functions side
`resetEmployeePassword`: `assertAdminCall(req, {docId})` → `requireDocId` → `assertFreshReauth` (5 min) → the
20/hr create/delete budget; refusals are `self-reset`, `not-active` (not `active` or no `uid`) and
`target-is-admin`; the work runs under `withAccountOperation(uid, "password-reset")` as `markPasswordResetRequired`
→ `auth.updateUser(password)` → `revokeRefreshTokens`. Only `shortHash(uid)` is ever logged. `completePasswordReset`:
`assertActiveCall(req, {newPassword})` → `requireString(…, 128)` → `isStrongPassword` (shared with
`completeEmployeeSetup`; never spell the regexes twice) → 5/15 min, then exactly one `active` doc with
`passwordResetRequired === true` or `not-required`. Pinned in `employee_accounts_callables.test.js`; the emulator
runner `safety_checks.js` checks the rules denylist and a reset → sign-in step.
