# Admin password reset for active accounts — design

Status: **approved 2026-09-28, BUILT 2026-09-29, backend DEPLOYED 2026-09-29, app NOT SHIPPED** (verified 2026-10-01). Both callables went live at `306ed848` (30 → 32 exports) and the review fixes to their bodies at `cc38be5d` (`docs/DEPLOYMENT.md` log); the app half rides 1.63.0+93, which has not shipped. Open: S4 in `docs/audits/CODEBASE_AUDIT_2026-09-28.md` (a demoted account's reset leaves it disabled). Owner-approved in conversation. Implementation: `2026-09-28-admin-password-reset-plan.md`.

## Why

Employee emails in this app are not real inboxes, so Firebase's "Forgot
password" email can never reach anyone. Today an admin can reset only an
**invited** account (the pending-invite tile re-provisions it). An **active**
employee who forgets their password has no way back in.

## What

An admin taps **Reset password** on an active employee. The server sets a new
temporary password, signs the person out everywhere and flags the account. The
employee signs in with the temporary password, lands on a **Change password**
screen, picks their own, and continues into the app. The account stays `active`
throughout — name, phone, role and history are untouched.

## Decisions (owner, 2026-09-28)

- A short **Change password** screen, NOT the new-hire setup screen: the account
  never leaves `active`, so the S1 active→invited revoke in
  `bridge_reconcile.js` never fires and nothing about authorization changes.
- **Approach A**: a server-owned flag plus a server-side change callable. Rejected:
  a client-side `updatePassword` then clearing the flag (two non-atomic steps
  and a client-writable flag — the split the setup flow already moved away
  from), and an Auth custom claim (up-to-an-hour token lag, more moving parts).
- The reset **signs the person out on every device**.
- Out of scope (YAGNI): a self-service "change my password" in Settings, and a
  live kick-out at the moment of reset.

## Server

### `resetEmployeePassword` (admin callable, `functions/employee_accounts.js`)

- Opens with `assertAdminCall(req, new Set(["docId"]))`, then
  `requireString(req.data, "docId", …)`, then `enforceDurableRateLimit`
  (20/hour per admin uid, the same budget as create/delete).
  `enforceAppCheck: true`.
- Refuses:
  - the caller's own account (`failed-precondition`, `self-reset`);
  - a doc that is missing, has no `uid`, or is not `active`
    (`failed-precondition`, `not-active`). Invited accounts keep the existing
    pending-tile Reset; disabled accounts stay locked out.
- Under `withAccountOperation(db, uid, "password-reset", …)`:
  1. Transaction: re-read the doc, require it still `active` with the same
     `uid`, then write `passwordResetRequired: true`, `updatedAt`.
  2. `auth.updateUser(uid, {password: generateStartingPassword()})`.
  3. `auth.revokeRefreshTokens(uid)`.
- **Order is fail-safe.** If step 2 or 3 throws, the flag stays set and the
  error propagates: the worst case is a person forced to change a password
  that did not change.
- Returns `{email, password}` in the same shape as `createEmployeeAccount`, so
  the app reuses `NewAccountCredentials` and `NewAccountDialog`.
- Logs nothing identifying beyond `shortHash(uid)`; never the password.

### `completePasswordReset` (self-service callable, same module)

- Opens with `assertActiveCall(req, new Set(["newPassword"]))`, then
  `requireString(req.data, "newPassword", 128)`, then a durable rate limit of
  5 attempts per 15 minutes.
- Under `withAccountOperation(db, uid, "password-reset", …)`:
  1. Re-read the doc; require `passwordResetRequired === true`
     (`failed-precondition`, `not-required`).
  2. Apply the SAME strength check as `completeEmployeeSetup` (8+, `\p{Lu}`,
     `\p{Ll}`, a digit). Extract it into one shared function rather than
     spelling it twice.
  3. `auth.updateUser(uid, {password})`, mapping
     `auth/password-does-not-meet-requirements` / `auth/invalid-password` to
     `invalid-argument` / `invalid-newPassword`. Reuse the B2 helper.
  4. Transaction: clear the flag (`passwordResetRequired: false`, `updatedAt`).
- If the Auth write succeeds but the flag clear fails, the person sees an error
  and retries; the retry sets the password again and clears the flag. That is
  idempotent and safe.

### Rules and triggers

- `firestore.rules`: add `passwordResetRequired` to the `/users` create and
  update denylist, so only the Admin SDK can set or clear it.
- `syncUsersByUid`: no change. The status does not move, so there is no bridge
  or Auth-access reaction.

## App

### Admin: Reset password on `edit_person_sheet.dart`

- Goes in the account footer beside Deactivate/Reactivate. It is shown only
  when the employee is `active` and is not the signed-in admin.
- Confirmation dialog through `showConfirmDialog`: "Reset {name}'s password?
  They'll be signed out on every device and must choose a new password at next
  sign-in."
- New repository method `resetEmployeePassword(docId)` returns
  `NewAccountCredentials`; the response is cast loosely, per the callable
  convention.
- On success it shows the existing `NewAccountDialog` with the email and the
  temporary password.
- On failure it composes a notice through `composeErrorNotice` with a new intro
  key `error_introResetPassword`, logged as `EMP-RESETPW`. The in-flight flag is
  set before the first await, per the reentrancy rule.

### Employee: forced Change password

- `EmployeeRecord.passwordResetRequired` (bool, default false when absent).
- Both gates, `splash_controller.dart` and `sign_in_controller.dart`, add a check
  **after** the unchanged `isInvited` check: `isActive && passwordResetRequired`
  goes to the new `ChangePasswordScreen`. A route is added in
  `AppRoutes.onGenerateRoute`.
- `ChangePasswordScreen` (`lib/features/auth/screens/`):
  - two `AuthPasswordField`s with `maxLength: TextLimits.password` and
    `kCredentialImePersonalizedLearning`;
  - the live `PasswordRequirement` checklist and a confirm-match check;
  - a Sign out link.
- On save, `AuthService.completePasswordReset(newPassword)` calls the callable
  and then reauthenticates with the new password, best-effort, the same way as
  setup's `_renewSession`. It then routes home.
- Errors map through `AuthErrorMapper` to typed `AuthFailure`s and show in the
  screen's banner, logged via `logger.authFailure('AUTH-CHANGEPW …')`.
- New ARB keys (EN + FR) with `@` metadata: the screen title and body, the Reset
  button, the confirmation title and body, and `error_introResetPassword`.

## Edge cases

- **Reset while the person is signed in:** their session ends at the next token
  refresh, within an hour. They sign in with the temporary password and land on
  Change password.
- **Two resets in a row:** the second temporary password wins and the flag stays
  set.
- **Reset racing a deactivate:** the lock plus the in-transaction `active`
  re-check mean disabled wins.
- **Admin resets another admin:** allowed; the role is untouched.
- **Old app builds (≤ 1.62.x)** ignore the flag. A reset person on an old build
  keeps the temporary password as their password. Nothing breaks.

## Testing

- **Jest, `resetEmployeePassword`:**
  - the admin gate, proved by deleting it and watching a test fail;
  - refusals for self, invited, disabled, missing and no-uid docs;
  - the flag is written before `updateUser`, and the flag survives when
    `updateUser` fails;
  - `revokeRefreshTokens` is called;
  - the rate limit is consumed after payload validation;
  - the credentials shape.
- **Jest, `completePasswordReset`:**
  - `not-required` when no flag is set;
  - weak and too-long passwords are refused;
  - policy-code mapping;
  - the flag is cleared only after the password is set;
  - the lock is released on failure.
- **Rules:** a client cannot set or clear `passwordResetRequired`.
- **Dart:**
  - gate routing in both controllers: invited → setup, active + flag → change
    password, active with no flag → home;
  - the `ChangePasswordScreen` success and failure paths, at 260 px with 2×
    text;
  - the admin button's visibility (active, not self) and dialog flow;
  - the `EmployeeRecord` parse.
- The full CI run: `flutter analyze`, `flutter test`, `npm run lint` and
  `npx jest`.

## Rollout

1. Deploy `functions,firestore:rules` (the two new callables and the denylist
   field). This is a new callable, so there is no payload-superset concern.
2. Then build and ship the app.
3. No backfill: an absent flag means "not required".

The export count goes from 30 to 32. Update `index_exports.test.js`,
`docs/CLOUD_FUNCTIONS.md`, and the callable list in `.claude/rules/security.md`
if it enumerates modules. `employee_accounts.js` is already listed there.

## Related

- S4 in `docs/audits/CODEBASE_AUDIT_2026-09-28.md` (`disabled: false` on the
  invited-account re-provision reset) is separate; it was approved and built
  2026-10-07. It is not needed by this design, because active accounts are never
  disabled by it.
