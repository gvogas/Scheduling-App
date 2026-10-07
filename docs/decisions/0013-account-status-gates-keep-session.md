# 0013. Invited and reset-required accounts keep the session at sign-in

**Date:** 2026-08-02 (P4c `invited` gate), 2026-09-29 (admin reset, `passwordResetRequired`), 2026-10-07 (`resumeAfterSignUp` note moved from a code comment, audit I5) · **Rules file:** `CLAUDE.md`

## Context
Every signed-in user needs an `active` `users` doc or `SplashScreen` signs out. P4c (2026-08-02) has the
admin create the account up front with a generated starting password and hand it over, so the person's
first sign-in arrives with an `invited` doc. Signing them out there makes setup unreachable: the
credential they just used is the one `AccountSetupScreen` needs. `employee.isInvited` is an EXACT match
checked BEFORE the active gate, so an empty or unknown status still gets the old sign-out; tests pin
both halves. `isDisabled` only matches `'disabled'`, which is why the active gate is
`!employee.isActive`.

`SignInController.resumeAfterSignUp` restates the active gate even though it runs right after
activation: a stale read (offline persistence, or the permission-denied retry served from cache) would
otherwise walk a still-`invited` person into the hub, where every rule denies them and nothing routes
them back to setup.

The admin reset of an ACTIVE account (2026-09-29) sets a server-owned `passwordResetRequired: true`
(`resetEmployeePassword` sets it, `completePasswordReset` clears it, both `/users` rules denylists hold
it). Sign-in clears the identity cache there so a cold start cannot fast-path past it.

## Decision
`invited` → `AccountSetupScreen`, session kept, before the active gate; `active` +
`passwordResetRequired` → `ChangePasswordScreen`, session kept, after the invited and active gates. Both
at `splash_controller.dart` and `sign_in_controller.dart`.

## Consequences
Don't drop the restated gate in `resumeAfterSignUp` as redundant, don't widen `isInvited` beyond an
exact match, and don't let a client write `passwordResetRequired`. Detail: `.claude/rules/employees.md`.
