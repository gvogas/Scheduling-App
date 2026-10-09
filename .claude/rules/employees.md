---
paths:
  - "lib/features/employees/**"
  - "lib/features/auth/**"
  - "lib/features/settings/**"
  - "functions/employee_accounts_admin.js"
  - "functions/employee_accounts_self.js"
  - "functions/bridge.js"
  - "test/features/employees/**"
  - "test/features/settings/**"
  - "test/core/security/emergency*"
---

# Employees, accounts and the users doc

Loaded when working on employee records, account provisioning, or
self-service settings. Root context: `../../CLAUDE.md`.

## Authorization and removal

- Decide authorization from the LIVE `users` doc, never a trigger snapshot: `bridge_reconcile.js` reads the profile and `usersByUid` rows in a transaction, because events arrive out of order and an old activation must not restore a disabled or deleted account. Keep the bridge-ownership checks when removing stale uids, and re-check the live profile after each Auth write, retrying when it changed. (ADR-0061)
- Keep `reconcileAuthAccess` computing "revoke" for anything not `active` (only a uid or bridge-owner mismatch returns early), so it never re-enables an invited account and an active→invited demotion revokes again; call it only when `authAccessChange(before, after)` is non-null, or a new invite gets disabled. (ADR-0061)
- Keep `resetProvisionedPassword` sending `disabled: false` with the password — a console-demoted account was disabled by that revoke, and a reset that left it disabled handed over a password nobody could use. (ADR-0061)
- Never delete an employee; disable is the only removal — deleting the `users` doc orphans every past appointment's `employeeIds` (the visit keeps `employeeNames` but loses the colour and the person). `syncUsersByUid` on disable disables Auth, calls `revokeRefreshTokens` and purges `presence/location`, `fcmTokens`, every `liveActivityTokens` row and the `liveActivityCards` marker. `/users` grants no `allow delete`; console cleanup uses the Admin SDK. (ADR-0080)

## Invite and setup (P4c)

- Provision only through `createEmployeeAccount` (`functions/employee_accounts_admin.js`): an Auth account on a random `generateStartingPassword()` value, NEVER persisted (Firestore is readable by every admin session, backup and export), plus an `invited` `users` doc already carrying the real `uid`. Never reintroduce a code-based invite anywhere in the stack. (ADR-0063, ADR-0064)
- Never bring back a shared default starting password without reinstating a mailbox check — the random password is what paid for dropping the `email_verified` setup guard. Don't write the residual risk up as closed: whoever holds the address AND the generated password can still activate first, so create the account at the moment you hand the credentials over. (ADR-0064)
- Write the new doc `role: "employee"` always (hard-coded in `performCreateAccount`; never read a role or `isAdmin` off the payload); make an admin by a later toggle on `edit_person_sheet.dart`. (ADR-0064)
- Route `invited` to `AccountSetupScreen` at both gates (root `CLAUDE.md`); the person chooses their own password and fills name/phone/consent, and `completeEmployeeSetup` flips the doc to `active`.
- Hold `accountOperations/{uid}` (`withAccountOperation`) across setup's Auth password write AND activation transaction, and across re-provision's claim AND password reset, keeping it through the Auth call (releasing at the Firestore commit reopens the reset race); duplicate creates take an email-hash lock first. Re-provision resolves its target by `uid`, never email (`users.email` can disagree with Auth), refuses a uid already on another doc, and rotates the password (`resetProvisionedPassword`) only AFTER `performCreateAccount`'s transaction claims the person still `invited`. Re-running create on an `invited` person IS the "lost it" path; once set up it refuses `email-exists`. Locks have no TTL or takeover; recovery: `docs/audits/AUDIT_ROLLOUT_2026-09-23.md`. (ADR-0066)
- Require `newPassword` on `completeEmployeeSetup` (`invalid-newPassword` when missing); never reintroduce a setup that activates without setting the password under the lock. `setupRequiresPassword` is no longer stamped or read, but stays server-owned (below). (ADR-0066, ADR-0185)
- Roll provisioning back — delete the Auth account when the Firestore write fails, only if this call minted it — since an Auth account with no `users` doc is invisible to every admin surface. `deleteEmployeeAccount` works only while `invited`, transactionally, so a setup that commits first makes it refuse. (ADR-0066)
- Never revert a password when activation fails after it changed — the person just chose it, and setup never assumes the current password is the starting one. Renew the session afterwards BEST-EFFORT (`_renewSession(label:)`): the account is already active, and reporting a failed reauth sent a retry to `not-pending`. (ADR-0066)
- Require 8+ characters with an uppercase and a lowercase Unicode letter (`\p{Lu}`/`\p{Ll}`, matching `PasswordRequirement`) and a digit. The Admin SDK bypasses the console password policy, so keep `isStrongPassword` at least as strict as that console config (which lives nowhere in the repo); `setSetupPassword` maps `auth/password-does-not-meet-requirements` / `auth/invalid-password` to `invalid-newPassword` (`AuthFailureWeakPassword`). (ADR-0065)
- Bind `TextLimits.password` (128, the `newPassword` cap of `completeEmployeeSetup`/`completePasswordReset`) only to the new-password fields of `AccountSetupScreen` and `ChangePasswordScreen`; sign-in stays uncapped on purpose (`text_limits_test.dart` pins the ≤).
- Validate the password TRIMMED — `completeAccountSetup` stores `newPassword.trim()`, so a raw check let `"Aa1!bcd "` set 7 characters; the strength meter and checklist read the same trimmed value. (ADR-0065)
- Refuse a retyped starting password with `AuthService._refuseIfStillTheStartingPassword`, which reauthenticates with the trimmed candidate BEFORE the callable; success → `AuthFailureStartingPasswordReused`, a FIELD error. Keep it in the SERVICE (a cold start through `SplashScreen` holds no typed password, unlike `login_screen.dart`); treat `wrong-password` / `invalid-credential` / `invalid-login-credentials` as the PASS case, and rethrow any other error, or a network blip waves the reuse through. (ADR-0065)
- Keep three `AccountSetupScreen` guards that look redundant: consent re-checked inside `_finishSetup` (keyboard submit bypasses the button); `AuthFailureSetupAlreadyComplete` WALKS THEM IN (the password change landed); abandoning setup is a PLAIN `signOut`, not `AccountExitController` — an `invited` account holds no push, presence or Live Activity registration. If any registration ever starts before activation, route through the shared exit path. (ADR-0065)
- Stamp consent only when the payload flags are `true` (`buildActivationPatch`) — an unconditional stamp mints a consent record for someone who never saw the checkbox.

## Admin password reset (active accounts)

- Reset an ACTIVE account's password only by admin action (employee emails are not real inboxes, so Forgot password reaches nobody): Reset password in `edit_person_sheet.dart`'s footer, shown only for an `active`, non-admin doc whose known `uid` is not the signed-in admin → `EmployeeFormController.resetPassword` (sealed `PasswordResetIssued`/`Failed`/`Busy`) → `resetEmployeePassword`. (ADR-0062)
- Make the admin re-enter their OWN password first (`showPasswordReauthDialog`, then `AccountDeletionService.reauthenticateWithPassword` BEFORE the callable); the server restates it with `assertFreshReauth` (`stale-auth` → `EmployeesFailureReauthRequired`). (ADR-0062)
- Keep the server refusing self, non-active and any admin target (`target-is-admin` → `EmployeesFailureTargetIsAdmin`, re-checked in `markPasswordResetRequired`'s transaction, which also re-checks `active` + the same `uid`, so a concurrent promotion or disable can't get the flag stamped), then, under `accountOperations/{uid}` (`password-reset`): `passwordResetRequired: true` FIRST, then the `generateStartingPassword()` password, then `revokeRefreshTokens` — an Auth failure then only forces an unneeded change. A revoke failure logs `logger.error` (`uidHash`) and still RETURNS the credentials, since the password is already set. (ADR-0062)
- Return the email from the Auth record `updateUser` returns, using the Firestore copy only when Auth has none — older docs can disagree with Auth. Show it in `showNewAccountDialog` (`employees_passwordReset` / `employees_newPasswordIssued`) on the ROOT navigator captured before the await — a drag-dismiss pops the sheet (`PopScope` can't veto) and the password must outlive it. (ADR-0062)
- Route `active && passwordResetRequired` per root `CLAUDE.md`; `resumeAfterSignUp` refuses a still-flagged doc, and the splash cached-identity fast path doesn't read the flag (a pre-1.63 temporary-password sign-in skips the screen until sign-out — accepted). (ADR-0062)
- Keep `completePasswordReset` on the same `isStrongPassword` and `setSetupPassword` mapping as setup: Auth first, then clear the flag in a TRANSACTION re-checking `active` + `uid`, so a doc disabled mid-change keeps it; `not-required` reads as already done. `AuthService.completePasswordReset` refuses the temporary password through `_refuseIfStillTheStartingPassword` (a password-field error, never a banner), renews best-effort and routes in via `resumeAfterSignUp`. (ADR-0062)
- Have `ChangePasswordScreen` surface offline through its own banner, log ONCE via `logger.authFailure` (the service doesn't double-file), and on Log out run `deregisterThisDevice` BEFORE `signOut()`, `restoreThisDevice` if sign-out fails — the account is active and holds registrations. (ADR-0062)

## Email is a sign-in identity

- Move an email edit through BOTH stores or neither: `FirebaseEmployeesRepository.updateEmployee` is the ONLY caller of `changeEmployeeEmail` (`functions/employee_accounts_self.js`), calling it (`_changeAuthEmail`) BEFORE its own write when the email changed AND the doc has a `uid`. Keep the call inside `updateEmployee`, not on `EmployeesRepository`, so no call site can forget it. A doc with no `uid` takes the direct client write — the one path that may write `email` alone. (ADR-0067)
- Keep the server order Auth FIRST, then Firestore, reverting Auth if the doc write fails (a failed revert `logger.error`s uid + docId, never addresses); `performChangeEmail`'s transaction re-checks the previous email and uniqueness and raises `email-changed` on a concurrent edit. (ADR-0067)
- Keep `resolveEmailChangeCaller` (pure, jest-tested) the one gate: an active admin may move any doc, an active employee only their OWN, everyone else is refused — widening the callable must never widen WHICH doc a caller reaches. Guard order: auth → payload → identity → freshness → rate limit → work. (ADR-0067)
- Gate freshness (`assertFreshReauth`, 5 minutes, shared with `deleteAccount`) on the caller's ROLE (`isAdmin`), never `isSelf` — an admin editing their own row is `isSelf` yet arrives through `updateEmployee`, which has no re-auth step. The admin branch stays ungated, an accepted residue until the admin save path gets a re-auth prompt. Budget 5/hour per caller uid on BOTH branches. (ADR-0067)
- Route the notification on `isSelf`: an admin edit tells the EMPLOYEE (`notifyEmailChanged`, `kind:"emailChanged"`, via `sendToEmployee`); a self edit tells the active admins (`notifyAdminsOfSelfEmailChange` → `sendToActiveAdmins`, the base for new admin fan-outs) with the NAME, never the address (Lock Screen, PII). Both are best-effort — the admin still has to tell the person. (ADR-0067)
- Re-authenticate in `SelfEmailService` BEFORE calling (`self_email_service_test.dart`: `verifyInOrder`, and `verifyNever` the callable after a failed re-auth), and demand the address twice — the Admin SDK sets it with no proof of control. Never use `verifyBeforeUpdateEmail`: it flips Auth outside the callable and leaves `users.email` stale. (ADR-0067)

## Credentials on screen

- Treat a displayed starting password as a credential: widget/controller state only, keyed to its account (`_credentialsFor`, so a recycled `State` can't show it on another row); never passed to `logger.*`, a notice or an error, never written to SharedPreferences or secure storage. (ADR-0068)
- Copy credentials only through `copyCredentialsToClipboard` (`employees/widgets/fields/credential_line.dart`), the one sanctioned egress and payload owner — never re-inline `'$email\n$password'`. Build every credential surface from `CredentialLine`, `CopyCredentialsButton`, `kMaskedCredential` and `credentialPanelDecoration`, never a re-derived control or tint. (ADR-0068)
- Thread "is there a password" as ONE nullable `String?` (payload, Copy both / Copy email label, `kMaskedCredential`), both params REQUIRED with no default — a parallel `hasPassword` bool let the label disagree with the clipboard. (ADR-0068)
- Pass `createAccount` the whole `EmployeeRecord`, never loose scalars: `performCreateAccount`'s existing-doc branch overwrites `name`/`firstName`/`lastName`/`phone`/`colorValue`/`jobTitle`/`role`, so an omitted one is wiped. `EmployeeFormController.createAccount` destructures it in ONE place (a new server field must be added there by hand — no compile error), and `PendingInviteTile` passes `widget.employee`. (ADR-0068)
- Expanding a pending row is NOT a re-issue (no round-trip, nothing rotates): with no server echo it masks the password with a hint that Reset password issues a new one, and copies the email alone. Only Reset password re-provisions. (ADR-0068)

## Busy state

- Track `EmployeeFormActivity` busy state as SETS OF DOC IDS (`savingIds`, `deletingAccountIds`) and guard `_save` per `docId`: the same person twice is a double-tap to refuse, a different person must proceed (one flag let `EmployeeSaveBusy` silently drop another row's action). Rows read `isSavingId(id)` / `isDeletingAccountId(id)` through a `select`; `isSaving` (`isNotEmpty`) serves the two modal sheets; `isDeletingAccount` is test-only — check a surface is modal before wiring it. A new person keys on `''`. Never collapse to booleans or add a call-site flag. (ADR-0069)
- Run `updateEmployee`'s `emergency` write inside the same `_save` as the users-doc write, so Save keeps one in-flight flag and a failure surfaces once.
- Report a server refusal of `EmployeeFormController.deleteAccount` (setup finished meanwhile) as `AccountDeleteFailed`, never success — the live stream has flipped the row to Active by the time the notice lands.

## Deep links

- Keep `FlutterDeepLinkingEnabled` false (Flutter's handler would consume the URL before `app_links`); an old `invite?code=` link falls to `IgnoredLink` on purpose. The `homeWidget` skip lives in root `CLAUDE.md` and `ios/CLAUDE.md`. (ADR-0063, ADR-0070)

## The `users` doc and its rules

- Keep `uid`, `termsAcceptedAt`, `locationConsentAt`, `setupRequiresPassword` and `passwordResetRequired` function-owned: all five on both `/users` denylists (`allow create` also lists `emergencyContact`/`emergencyPhone`) — a created doc with a forged `uid` repoints the `usersByUid` bridge; `setupRequiresPassword` is retired but persists on old docs, so it stays listed. Neither `EmployeeRecord.toMap()` nor `updateEmployee` emits any of them (never put `passwordResetRequired` on a client write path); `toMap()` also omits `status` (deactivate/reactivate) and `email` (only via `changeEmployeeEmail`); it round-trips editable fields, and `updateEmployee`'s field-scoped patch is the real write path. (ADR-0071, ADR-0185)
- Keep `/users` `allow update` as `(isAdmin() || (isSelf() && isAvailabilityOnlyChange())) && <denylist> && emailMovesThroughAuth() && emergencyFieldNotSet(...) && isValidUserData(...)` — without the outer brackets the guards bind to the self branch and an admin write skips them. `isSelf()` requires `isActiveUser()`, so a disabled (credential not yet revoked) or invited account falls to the admin branch. (ADR-0079)
- Treat `isAvailabilityOnlyChange()`'s `hasOnly` as a whitelist of the ENTIRE diff — one extra key turns a save into `permission-denied`. `kSelfServiceUserFields` (`self_service_fields.dart`) is its hand-mirror, checked by `self_service_fields_test.dart`; add a key to the RULES first, then the Dart set. (ADR-0079)
- Keep `travelAlertsEnabled` and `locationSharingEnabled` self-writable — sharing is the only thing stopping a position upload, so admin-only would make consent unwithdrawable. Never add `email`, `maxJobsPerDay`, `role`, `jobTitle`, `colorValue`, `status`, `isTestAccount` or `monthEndReviewPush` to the self set. (ADR-0079)
- Write self edits only through `EmployeesRepository.updateSelfDetails`, a plain `update()` (no transaction), separate from `updateEmployee`, whose patch carries keys the `hasOnly` rejects. Every caller passes the STORED values it isn't changing (My details the stored `travelAlertsEnabled`, Settings the stored availability, both the stored phone) — a guessed default flips someone's setting. (ADR-0079)
- Keep `monthEndReviewPush` ADMIN-ONLY, on neither self list: written by the admin `updateEmployee` path and `toMap()`, shown on `EditPersonSheet` only for an admin, saved `false` whenever the admin switch is off, absent = OFF. (ADR-0079)
- Keep `isTestAccount` admin-only (an admin tester clearing its own flag is accepted) and filter it in exactly two owners, never a call-site copy: `EmployeeRecord.isAssignable` (`jobTitle.isAssignable && !isTestAccount`) and `LiveMapAggregator` (`join`/`groupTeam`). The roster moves it to a collapsed `TestAccountsSection`, or an admin could never reach the switch. (ADR-0074)
- Never filter a LOOKUP for `isTestAccount` (colour and name maps, own-record reads, `usedColors`, `offerableAssignees`, `neverSetUpAccountsProvider`), or names and colours blank on assigned jobs. (ADR-0074)
- Read `allUsersStreamProvider` in `neverSetUpAccountsProvider` (the active-only stream would leave it empty), oldest first with a null `createdAt` LISTED LAST, never dropped; and in `usedColors`, so a disabled or invited employee's colour stays taken — the bars and dots key on it.
- Size a `/users` rules cap to the widest value a shipped SERVER path writes (the client caps with `TextLimits`): `phone`/`emergencyPhone` 40, since `createEmployeeAccount` accepts 40 — tighter leaves server-created docs un-updatable, even by `deactivateEmployee`. Retiring a callable never licenses tightening its cap; its docs outlive it. (ADR-0076)
- Never make a client cap LOOSER than its callable's, or the callable rejects an unfixable `invalid-argument`: name halves `TextLimits.employeeNameHalf` (100, not the clients' 200), composed `name` capped 250 server and rules (the join reaches 201), email `TextLimits.authEmail` (254, not 320). `text_limits_test.dart` reads `firestore.rules`, both `employee_accounts_*.js` and the Wave import's `IMPORT_FIELD_CAPS` back and fails on drift. (ADR-0076)

## Names, titles, days, phones

- Build `users.name` on every write path through `composeEmployeeName` (`employee_name_policy.dart`), which falls back to the stored name, then `kUnnamedEmployee` (`'—'`, an EM dash) — never `''`. Working hours join with an EN dash; treat a non-ASCII sweep over `lib/` as a change to shipped strings. (ADR-0073)
- Render through `EmployeeRecord.displayName` (→ `displayEmployeeName`, public for `account_status_provider.dart`'s raw map). The edit sheet seeds First from the whole `name` when both halves are empty. `EmployeeFormValidator` takes the halves, never the composed name (which is never empty); `requireLastName` is the invite/edit difference. (ADR-0073)
- Keep `role` the ACCESS flag (`admin`/`employee`, what rules gate on) and `jobTitle` descriptive; `JobTitleChips` never touches the access toggle. Its one gate: `JobTitle.isAssignable` is false for `dispatcher`, with no personal-block or day-off carve-out (a dispatcher's empty calendar is accepted). Pickers and dashboard per-person numbers read `assignableEmployeesProvider`, never raw `employeesStreamProvider`; it is DERIVED, not filtered in the stream, because `_resolveActiveEmployees` must still see a stored dispatcher as active. (ADR-0074)
- Store `workingDays` Sunday-indexed (`[0]` = Sunday, like intl's `NARROWWEEKDAYS`), converting only through `sundayIndexOf` (`calendar/domain/month_grid.dart`) — never `day.weekday % 7` at a call site. Write back through `orderedWorkingDays`' `storedIndex`, never the visual position; give `formatWorkingDays` Sunday-indexed, unrotated labels (`weekdayAbbreviationsForLocale`); name a day set via `joinWeekdayNames` (`work_schedule_pickers.dart`). (ADR-0075)
- Share the daily-cap picker: `showMaxJobsPicker` (`work_schedule_pickers.dart`) with `kMaxJobsOptions` and `maxJobsLabel` (`work_schedule_policy.dart`), on the Team sheet and My details. The read-only detail renders NO row for an uncapped person. (ADR-0075)
- Store phones FORMATTED through `PhoneInputFormatter` (`core/validators/phone_format.dart`), e.g. `(514) 555-1234`, passing anything with `+` untouched and appending digits past the tenth (extensions). `launchPhoneCall` strips to digits (keeping a leading `+`) for `tel:`. Keep `TextLimits.phone` (24) above `formatPhoneNumber`'s widest output — the length formatter runs AFTER the mask, and at 15 an 11-digit NANP number was untypeable. (ADR-0077)
- Keep `functions/scripts/backfill-client-phone-formatting.js` formatting only NANP (ten digits with no `+`, or eleven starting 1, dropping that country code) — narrower than `formatPhoneNumber`, whose progressive mask misreads eleven digits. (ADR-0077)

## Emergency contact

- Store the emergency pair in `users/{docId}/private/emergency` (admin OR the active owner), never on the users doc, and never widen a `/users` read clause to reach it — every active employee reads every active peer doc, and the contact is a non-user who never consented. `EmployeeRecord` doesn't carry it (`EmergencyContact` via `emergencyContactProvider`); a read failure renders "not shown", never "none on file". (ADR-0078)
- Keep `emergencyFieldNotSet(f)` on `allow update` (create bans both keys): it refuses a write that LEAVES a value and admits absence — never "simplify" it to a denylist entry, which rejects `updateEmployee`'s `FieldValue.delete()` scrub and strands any doc carrying the pair. Keep the scrub in `updateEmployee`, not `saveEmergencyContact` (self-service calls that, and its `hasOnly` rejects deletes), and keep `isValidUserData`'s caps for the pass-through. Pinned by `emergency_contact_rules_test.dart`. (ADR-0078)
- Seed `EditPersonSheet`'s pair asynchronously behind three flags: `_emergencyLoaded` (fields `readOnly`, Save sends `emergency: null` until a snapshot lands), `_emergencyDirty` (re-seed from a fresher snapshot until the admin types), `_emergencyFailed` (`employees_emergencyLoadFailed`). Read the initial value with `ref.read` in `initState` — an immediate listener fire lands where `setState` is illegal. (ADR-0078)
- Render the pair as its own section (`MonoSectionLabel` `employees_sectionEmergency` on edit; its own `KeyValuePanel`, only when non-empty, on detail), apart from hours and access.

## My details

- Make `MyDetailsScreen` the ONLY self-edit surface, scoped to exactly the person's two grants (`private/emergency` and the self clause); anything more would be `permission-denied`. (ADR-0079)
- Keep its TWO save behaviours: identity fields (phone, emergency pair) behind a Save/Discard bar shown only while dirty against the stored values; availability (days, hours, on-call) applied immediately and optimistically, rolled back with a notice. An availability write sends the STORED phone, never the controller text. (ADR-0079)
- Show its SCHEDULING section (`maxJobsPerDay` only, via admin `updateEmployee`) to admins and HIDE it for a technician; keep role, job title and colour on the Team sheet — a self-service role edit is a privilege-escalation shape. (ADR-0079)

## Legal text

- Change `docs/legal/privacy-policy.html` §2, §6 and §8 in the same change as any revocation delete, age cutoff or sharing-gate change, and republish. (ADR-0080)
- Treat `docs/legal/*.html` as SOURCES: publish to `gvogas/es-pro-legal` (privacy policy as `index.html`, so links to it are absolute) and keep the four files byte-identical. (ADR-0071)
- Keep the consent sentence a LINK: `ConsentRow` (`auth/widgets/account_setup/consent_row.dart`) finds `auth_termsOfServiceLink` verbatim inside `auth_termsAndLocationConsent` in EVERY locale (`new_success_strings_test.dart`); `indexOf < 0` falls back to plain text on purpose. It is Stateful only to dispose its `TapGestureRecognizer`. `LegalSettingsCard` keeps the durable Terms row beside Privacy (`AppUrls`). (ADR-0071)

## Streams and counts

- Keep `watchEmployees()` active-only with NO `orderBy` (it would exclude docs missing `name`); use `watchAllUsers()` (admin-only) for every status. Cap every `users` stream at `_userStreamLimit` (1000) with the warn in `_toSortedEmployeeRecords` — bounded-and-loud, never unbounded or silent. (ADR-0072)
- Keep `employeesStreamProvider` `autoDispose` and NOT derived from `allUsersStreamProvider` (that one is admin-only and includes invited/disabled) — its consumers are transient sheets and the Dashboard, and without it one sheet pins a second `users` listener for the session. (ADR-0072)
- Count the roster's "jobs today" with ONE listener: `employeeJobsTodayProvider` reduces `appointmentsInRangeProvider` over `todayRangeProvider` (watching `currentDayProvider`, never `DateTime.now()`, or counts stick across midnight) into a map, excluding cancelled; the detail's TODAY panel (`employeeTodayJobsProvider`) filters the SAME stream.
- Treat a null from `EmployeesRepository.cachedUserDocId(uid)` (the doc id `watchUserDoc` last resolved) as "query the slow way", never "no doc".

## Travel alerts

- Read absent `travelAlertsEnabled` as ON (`EmployeeRecord.fromMap`'s `!= false`, `wantsTravelAlerts`); `toMap()` never emits it. Sweep behaviour: `.claude/rules/notifications.md`. (ADR-0081)
