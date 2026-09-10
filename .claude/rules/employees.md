---
paths:
  - "lib/features/employees/**"
  - "lib/features/auth/**"
  - "lib/features/settings/**"
  - "functions/employee_accounts.js"
  - "functions/bridge.js"
  - "test/features/employees/**"
  - "test/features/settings/**"
  - "test/core/security/emergency*"
---

# Employees, accounts and the users doc

Loaded when working on employee records, account provisioning, or
self-service settings. Root context: `../../CLAUDE.md`.

- **Employee accounts: the admin invites, the employee sets up** (P4c,
  2026-08-02 — this REPLACED the one-time signup-code flow entirely). The
  admin's person sheet calls `createEmployeeAccount`, which mints a **Firebase
  Auth account** on a **random per-account starting password** —
  `generateStartingPassword()` in `functions/employee_accounts.js`, drawn once
  per call, handed to both the create and the re-provision path, returned in the
  response and **never persisted anywhere** (2026-08-21; until then it was the
  shared constant `Welcome123!`) — plus a `users` doc that is `invited` but
  **already carries the real `uid`**, and returns the email + password for the
  admin to hand over out-of-band (the `NewAccountDialog` right after creation,
  or the expanded roster row while that echo is still in memory).
  **The doc is always written `role: "employee"`** (2026-08-21): the callable
  hard-codes it in `performCreateAccount` and never reads a role off the
  payload. **`isAdmin` was accepted-and-ignored in the
  `assertPayloadShape` allowlist as `#compat-1.47.0`, and was RETIRED
  2026-08-29** once the fleet reached 1.53 — it is now refused as
  `unexpected-field`. Keep the reasoning, because it is the shape of every
  future carve-out: `assertPayloadShape` throws on the first key it does not
  recognise, and every admin build at or below 1.47.0 sent `isAdmin`
  unconditionally on BOTH create and Reset password, so dropping the key
  early would have failed both actions on every device that had not updated
  (`docs/DEPLOYMENT.md` §4a, the superset contract). The removal was safe
  only because the current client sends no such key AND no older build
  remained. Don't re-add it.
  Promotion is a separate, later edit on `edit_person_sheet.dart` once the
  person has finished setup — you make an admin by creating them normally and
  then flipping that toggle. The employee then
  signs in normally; both gates see `invited` and route to
  `AccountSetupScreen`, where they **choose their own password** and fill in
  name/phone/consent → `completeEmployeeSetup` flips the doc to `active`.
  **ORDER IS THE APP-LAYER GUARANTEE: the password is replaced FIRST,
  client-side, then the account is activated.** The server cannot see a
  password, so "you must replace the starting password" holds because
  `AuthService.completeAccountSetup` calls `User.updatePassword` before the
  callable — swap the two and an interrupted setup leaves an *active* account
  still on the password the admin read out. Pinned by a test (`verifyInOrder`,
  plus the half that matters: a thrown `updatePassword` must `verifyNever` the
  activation).
  **Be precise about how strong this is: it is client-side ordering, NOT a
  server check.** `completeEmployeeSetup` verifies auth + a matching doc +
  `status == 'invited'`; it does not verify that the password
  actually rotated, so anything reaching the callable directly activates an
  un-rotated account. The reauth check above is client-side too — it closes
  the case of an employee retyping their starting password IN THE APP, not
  the case of someone calling the callable directly. `enforceAppCheck: true` is all that stands in the way
  there, and App Check is attestation, not authorization.
  Don't build on the ordering as if the server enforced it.
  **The password itself is validated TRIMMED** — `completeAccountSetup` stores
  `newPassword.trim()`, so checking the raw text let `"Aa1!bcd "` pass the
  8-character rule and set a 7-character password. The strength meter and the
  requirements checklist read the same trimmed value.
  **The "must differ from the starting password" rule STILL EXISTS, but it is
  no longer a string comparison.** It used to reject `kDefaultStartingPassword`
  by name in `account_setup_screen.dart`. That constant went on 2026-08-21 with
  the shared password, and the check was deleted with it on the reasoning that
  "a random password leaves no constant to *accidentally* re-choose". **That
  reasoning covered only the accidental case and left a real hole**, closed the
  same day: the employee is reading the starting password off a message while
  they fill this form, and retyping it is the path of least resistance. Every
  generated password satisfies `AuthValidators.newPassword` BY CONSTRUCTION —
  12 characters with an uppercase, a lowercase and a digit is exactly
  `PasswordRequirement.allMetBy` now that `symbol` is gone — and
  `updatePassword` accepts a no-op, so setup would complete and leave the
  account `active` on a credential the admin still holds, while
  `auth_setUpYourAccountBody` promised them "the temporary one stops working
  once you finish".
  **The replacement is `AuthService._refuseIfStillTheStartingPassword`**, which
  reauthenticates with the typed value BEFORE `updatePassword`: reauth succeeds
  only while that value is still the account's current credential, so success
  means they retyped what they were given →
  `AuthFailureStartingPasswordReused`, surfaced as a FIELD error on the
  password. The client never sees the generated password, so it cannot compare
  strings — it tests instead. Three things about it are load-bearing:
  it lives in the SERVICE, not the screen, because there are two routes into
  setup (`login_screen.dart`, which holds the typed password, and a cold start
  through `SplashScreen`, which does not) and a screen-level check would cover
  only the first; a wrong-password refusal is the PASS case and must accept all
  three codes (`wrong-password`, `invalid-credential`,
  `invalid-login-credentials`) or setup dead-ends; and any OTHER reauth error
  must be rethrown, never treated as "looks different", or a network blip waves
  through the exact case this exists for. It checks the TRIMMED value, since
  that is what gets stored. Don't re-add a name-based comparison (there is no
  constant), and don't reintroduce a shared default.
  (`PasswordRequirement.symbol` went the same day; the policy is 8+ characters
  with an uppercase, a lowercase and a digit.)
  A failure *after* the password change deliberately does **not** revert
  it: the new password is the one the person just chose and typed twice, so
  leaving them `invited` with a working password beats resetting them to the
  starting password (the next sign-in routes back to setup, which never assumes
  the current password is the starting one). Re-running create on a still-`invited`
  person **resets their password** — that IS the "never signed in / lost it"
  path — but it refuses with `email-exists` once someone has set up. **That
  refusal resolves the target by `uid`, not by email, and the password rotation
  happens AFTER the doc-level transaction claims the person as still-`invited`
  (`resetProvisionedPassword`, split out of `provisionAuthAccount` for exactly
  this).** Both halves are load-bearing and both were bugs: `users.email` is
  admin-editable, and the two stores can still disagree on any doc edited
  before `changeEmployeeEmail` existed (nothing back-fills those), so an
  email-only check can clear a doc that is NOT the account Auth hands back —
  which reset a live employee's password and minted a second `users` doc
  carrying their uid, and `syncUsersByUid` then DELETED their `usersByUid`
  bridge, locking them out of everything. The transaction therefore also
  refuses when the uid already belongs to another doc (the rules' `allow create`
  uid denylist restated for the one path that bypasses rules). And resetting
  before the claim meant a setup committing in that window left the person
  active on a password nobody told them had been reverted.
  **Be precise about what the deferral bought: the window is NARROWED, not
  closed.** Firestore serializes the two transactions, but the Auth call sits
  outside both — a `completeEmployeeSetup` that commits between
  `performCreateAccount` committing and `resetProvisionedPassword` returning
  still ends with an `active` employee on the freshly issued starting password
  rather than the one they just chose. That residue is
  milliseconds wide instead of a whole round trip, and it cannot be closed
  from here (Auth is not transactional); don't write it up as fixed.
  `deleteEmployeeAccount` likewise
  only works while `invited` (transactional, so a setup that commits first makes
  the delete refuse); after that the no-delete invariant applies and disable is
  the only removal. Provisioning **rolls back**: if the Firestore write fails
  after the Auth account is created, that Auth account is deleted — but only if
  *we* just minted it — since an Auth account with no `users` doc is a sign-in
  `SplashScreen` can't resolve and no admin surface can see.
  **The security posture is weaker than the codes it replaced, deliberately and
  with the owner's sign-off — and this assessment has been re-priced twice, so
  read the date on it.** While the starting password was the shared constant
  `Welcome123!` it was known to everyone forever, so between creation and first
  sign-in anyone who merely knew an employee's email address could sign in as
  them; what stopped the race winner going further was `completeEmployeeSetup`'s
  `email_verified` guard (added 2026-08-08), which demanded control of the
  MAILBOX and not just knowledge of the address. **The shared constant and that
  guard were removed TOGETHER on 2026-08-21** — the random password is what pays
  for dropping the guard, so never bring back a shared default without
  reinstating a mailbox check, and never cite this note as precedent for
  deleting one elsewhere. The address alone now buys nothing, because the
  password is a real secret.
  **The residual risk is NOT zero and must not be written up as closed: whoever
  holds the address AND the generated password can still activate the account
  before the intended employee does.** What improved is that this is now a
  secret rather than a value printed in the source and rendered on every pending
  roster row — the race itself is still there. Two things bound it. The worst
  case shrank, because a pre-empted account is always a plain `employee` now
  (it could previously be provisioned `isAdmin: true`, and an admin reads the
  whole `/clients` PII collection); and an `invited` user is granted **nothing**
  by `firestore.rules` — no clients, no appointments, no peers — so reaching the
  setup screen is all a race winner holds until the callable lands. The rest is
  operational, not technical, and belongs in the onboarding instructions:
  **create the account at the moment you hand the credentials over, not weeks
  ahead.** Client side there is no mailbox step left to look for —
  `verify_email_panel.dart`, `AuthService.sendVerificationEmail` /
  `refreshEmailVerified` / `isEmailVerified` and `AuthFailureEmailNotVerified`
  were all deleted on 2026-08-21. One deliberate remnant: `_mapSetupError`
  still maps the callable's `email-not-verified` message onto
  `AuthFailureSetupNotAvailableYet`, purely so a ROLLED-BACK backend under a
  shipped build degrades to an `isExpected` failure with a sentence the
  person can act on, rather than `AuthFailureUnknown` and a non-fatal per
  retry. It is named for what it means to the user, not for the retired
  guard, because this build has no verification UI left to satisfy. `create_account_screen.dart`, both `accept_invite_*` screens,
  `CodeEntryBoxes`, `signup_code_dialog`, `InvitePreview` and the
  `revokeInvite`/`previewInvite` callables are all **deleted** — there is
  nothing left to "accept" in THIS build, which is why sign-in's bottom prompt
  went with them. **The backend half is gone too, as of 2026-08-08**: once every
  device was on 1.40+, the whole `#compat-1.37.1` shim was retired —
  `invites.js`, `signup_code_utils.js`, the `createEmployeeInvite`/
  `redeemSignupCode` callables, the `signupCodes` collection's rules block and
  TTL entry, and the two `allow delete` grants. There is no code-based invite
  anywhere in the stack and none should be reintroduced. Design:
  `docs/archive/redesign-subdocs/2026-08-02-p4c-HANDOFF.md`.
- **An employee's email is their SIGN-IN identity, so an edit to it moves BOTH
  stores or neither** (2026-08-04, which re-enabled a field that had been
  read-only since P4c). The joining callable is `changeEmployeeEmail`
  (`functions/employee_accounts.js`), and `FirebaseEmployeesRepository
  .updateEmployee` is its ONLY caller: it reads the stored doc first and, when
  the email actually changed **and** the doc carries a `uid`, runs the callable
  **before** its own Firestore write, which then merely re-states what the
  server committed. The order is the whole fix — a Firestore-only change left
  the person signing in at the old address while every admin surface showed the
  new one, and desynced the two stores `createEmployeeAccount` joins on (see the
  uid-not-email refusal above). Keep the call **inside** `updateEmployee` rather
  than exposing it on `EmployeesRepository`: "an email edit always moves Auth
  too" is then a property of the one save path, not a second method a call site
  can forget to pair with it.
  **Server-side the order is Auth FIRST, Firestore second, with a revert.**
  Auth is the store that owns sign-in and the only one that can genuinely refuse
  a duplicate, so it must never be the one left behind; if the doc write then
  fails, the Auth email is put back and a failed revert `logger.error`s the
  uid + docId (never the addresses — emails are PII). `performChangeEmail`'s
  transaction re-checks BOTH the previous email and the uniqueness the
  pre-flight checked, and raises `email-changed` on a concurrent edit, which the
  client surfaces as the same "try again" its own transaction guard does.
  A doc with **no** `uid` still takes the direct client write — there is no Auth
  account to join, and that is the one path allowed to write `email` alone.
  **The employee is pushed a `kind:"emailChanged"` notice naming the new
  address**, after the commit and best-effort (`notifyEmailChanged`, through the
  shared `sendToEmployee`). It is a courtesy, **not** a guarantee — no live FCM
  token, no notice — so the admin still has to tell them; don't write it up as
  if the person is reliably informed.
- **A displayed starting password is a CREDENTIAL — state-only, never logged,
  never persisted.** It lives in widget/controller state and dies with the
  surface, keyed to the account it belongs to (`_credentialsFor`, so a recycled
  `State` can't show one person's password on another person's row). It is never
  passed to `logger.*` (auth catch sites log through `logger.authFailure`, whose
  breadcrumb carries only the label and `failure.runtimeType`), never
  interpolated into a notice or an error message, and never written to
  SharedPreferences or secure storage. The **"Copy both"** clipboard action on
  the new-account dialog and on the roster row is the ONE sanctioned egress — it
  is the feature. Both go through `copyCredentialsToClipboard`
  (`employees/widgets/fields/credential_line.dart`), which is the single owner
  of that payload format — never re-inline `'$email\n$password'` at a call
  site, or the two surfaces can put different things on the clipboard. The
  `CredentialLine`, `CopyCredentialsButton`, `kMaskedCredential` and
  `credentialPanelDecoration` beside it are shared for the same reason — the
  whole surface, not just the payload. **The "is there a password" fact is
  ONE nullable `String?`, threaded end to end** (2026-08-21): the same value
  picks the clipboard payload, the button's label (Copy both / Copy email)
  and whether the line renders `kMaskedCredential`. It was briefly a
  `hasPassword` bool defaulting to `true` alongside the nullable, which is
  the shape to avoid — the two could disagree, so a button could say "Copy
  both" over an email-only clipboard, and a new surface holding no password
  inherited the wrong label with no compile error. Both params are REQUIRED
  for that reason; don't re-add a default. They were separate copies and had already drifted twice: the two
  confirmed-state icons disagreed, and the dialog tinted its panel
  `surfaceContainerHighest`/`r8` against the roster row's `sheetRow`/`r12`, so
  the same credential pair rendered on two different fills in the two places an
  admin reads it. Add a new credential surface by calling these, never by
  re-deriving the control or the tint.
- **`EmployeeFormActivity` tracks busy state as SETS OF DOC IDS, not booleans**
  (`savingIds`, `deletingAccountIds`). The notifier is app-wide but its surfaces
  are not: the roster can show several expanded `PendingInviteTile`s at once,
  each with its own Reset and Remove. A single flag made every row claim to be
  busy when any one was, and — worse — made `_save`'s reentrancy guard refuse a
  *different* employee's action, which `EmployeeSaveBusy` then dropped with no
  spinner and no notice. **So `_save` takes a `docId` and guards per key:** the
  same person twice is a double-tap and must be refused; a different person is a
  real action and must proceed. `isSaving` survives as an `isNotEmpty` getter
  for the two person sheets (modal, one at a time). Its sibling
  `isDeletingAccount` has **no** in-app caller — the sheets have no
  delete-account affordance, only `PendingInviteTile` does, and it correctly
  asks the id-keyed form — so it is an aggregate read for tests alone; don't
  wire a surface to it without re-checking that the surface really is modal. A row
  asks `isSavingId(id)`/`isDeletingAccountId(id)` through a Riverpod `select`,
  so it rebuilds only when its OWN state flips. A brand-new person keys on `''`
  — correct, not a gap, since the invite sheet is modal. Never collapse this
  back to booleans, and never "fix" a busy-state bug by adding a flag at a call
  site instead.
- **The deep-link dispatcher is the single `app_links` consumer, and it MUST
  skip any URI carrying the `homeWidget` query param.** `classifyDeepLink`
  (`core/deep_links/deep_link_target.dart`) returns `IgnoredLink` for it, with
  or without a value. That skip is load-bearing, not tidy: once `app_links` is
  listening, BOTH plugins observe the same `openURL`, so without it every
  widget, Live-Activity and Siri tap opens the appointment sheet **twice**. The
  param and the `home_widget` tap channel retire **together, later** (see
  `ios/CLAUDE.md`) — dropping either one alone re-breaks widget taps. On iOS,
  `FlutterDeepLinkingEnabled` stays **false**: that is the correct setting *for*
  `app_links`, since Flutter's own handler would otherwise consume the URL
  first. P4c reduced the dispatcher to the **appointment branch alone**: an old
  `esproschedule://invite?code=…` link now falls through to `IgnoredLink`, which
  is deliberate — those links can still be sitting in someone's messages and
  must not reach a screen that no longer exists. `awaitLoginRoute` and the whole
  invite-branch route race went with it. **`TopRouteObserver` is still
  registered on `MaterialApp.navigatorObservers`, and it now DOES override
  `didRemove` (B4, 2026-08-19) — the guard is `identical` on the `Route`
  object, NEVER the route name.** That distinction is the whole fix:
  `pushNamedAndRemoveUntil` (the account-disabled path) pushes *before* it
  removes, so a name-based guard lets a removed older route that happens to
  share the just-pushed route's name (two `/login` entries) overwrite the top
  with whatever sat beneath the removed one — the observer then reports a route
  no longer on the stack. The override earns its place because `hub_shell.dart`
  calls `nav.removeRoute(this)` on its `HubTabRedirectRoute` shim *while that
  shim is the top route* (post-frame, after handing off to the live shell);
  without handling that, the observer stays stuck on a route that no longer
  exists. Tracking the `Route` object rather than just its name is what makes
  the identity test possible — `currentRouteName` is derived from it. Pinned by
  `test/core/navigation/top_route_observer_test.dart` ("removing the current
  top route falls back to the route beneath", "removing a lower route does not
  overwrite the current top route", and "pushNamedAndRemoveUntil keeps the
  just-pushed name even when a removed route shares it"). Leave it and this
  note in place.
- **`termsAcceptedAt` / `locationConsentAt` are function-owned `users`
  fields.** They are on the `/users` update **denylist** in `firestore.rules`
  beside `uid` — **three fields**, since P4c deleted `codeExpiresAt` everywhere
  (same posture as `jobCount`/`wave` on clients), so a compromised admin session
  can't forge a consent record; `EmployeeRecord.toMap()` must never emit them, or a future
  whole-record `set()` becomes an opaque `permission-denied`. **`toMap()` omits
  `uid` and `status` for the same reason** — `uid` is on that denylist and
  `status` belongs to deactivate/reactivate; the repository's field-scoped
  allowlist in `updateEmployee` is the real write path, and `toMap()` exists
  only to round-trip the editable fields. **`email` is omitted too** (2026-08-15)
  for a sharper reason: it is a SIGN-IN identity and moves through
  `changeEmployeeEmail`, which owns Auth and Firestore together, or not at all
  — a whole-record write carrying it would rewrite the doc while Auth kept the
  old address, and it is the very key `updateEmployee`'s uniqueness query reads.
  It was emitted un-normalized, which was latent only because nothing in
  production calls `toMap()`. **The denylist is on `allow create`
  as well as `allow update`**: without it the same admin session that cannot
  edit `uid` could simply create a doc carrying a forged one, and a second doc
  claiming an existing employee's uid repoints the `usersByUid` bridge every
  rules gate resolves through.
  `completeEmployeeSetup` writes the consent stamps **only when the payload
  flags are actually `true`** — stamping unconditionally would mint a
  legally-flavoured consent record for someone who never saw the checkbox.
- **The consent sentence LINKS to the terms, and the link is what makes the
  stamp mean anything** (2026-08-05, restored 2026-08-08 after a revert dropped
  it). Ticking the box stamps `termsAcceptedAt`, so the person must be able to
  read what they are accepting; the setup screen used to demand acceptance of
  terms that were published nowhere and tappable nowhere. `_ConsentRow`
  (`account_setup_screen.dart`) builds the sentence by locating
  `auth_termsOfServiceLink` **verbatim inside**
  `auth_termsAndLocationConsent` and turning that run into the link, so the two
  keys must stay consistent **in every locale** — a translation that rewords the
  phrase silently renders a plain sentence with no link (`indexOf < 0` falls
  back to one plain span on purpose: a missing link beats half a sentence or a
  `-1` substring crash). It is a `StatefulWidget` solely to own and dispose the
  `TapGestureRecognizer`; one built in `build` leaks on every rebuild. A tap on
  that run is claimed by the recognizer, so it opens the terms instead of
  toggling the checkbox; the rest of the tile still toggles.
  **The per-locale half is pinned by `test/l10n/new_success_strings_test.dart`**,
  which asserts the substring holds in every `supportedLocales` entry — the
  widget test in `account_setup_screen_test.dart` only ever exercises the
  default locale, so a French re-translation would otherwise drop the link with
  nothing failing.
  **Settings › Legal is the DURABLE route** — setup is shown once, only to a new
  employee, and never again, so `LegalSettingsCard` carries a Terms of Service
  row beside Privacy Policy. Both point at `AppUrls`
  (`privacyPolicy`, `termsOfService`); the sources are
  `docs/legal/privacy-policy.html` / `terms-of-service.html`, published to the
  `es-pro-legal` GitHub Pages repo, where **the privacy policy is the index** —
  which is why the terms page links to it by absolute URL rather than a relative
  `privacy-policy.html` that would 404. Neither page is bundled: if the Pages
  repo drifts from `docs/legal/`, the consent record points at the wrong text.
- **Account re-provisioning REFRESHES the pending doc's editable fields, so
  `createAccount` takes the whole `EmployeeRecord` — never loose scalars.**
  `performCreateAccount`'s existing-doc branch *updates*
  `name`/`firstName`/`lastName`/`phone`/`colorValue`/`jobTitle`/`role` with
  whatever it is handed, so a call site that omits one silently wipes the
  pending person's phone or job title. `EmployeeFormController.createAccount`
  therefore takes a record and destructures it in ONE place (the repository
  method below it is the only place that speaks named strings), and
  `PendingInviteTile` passes `widget.employee` whole — the omission is
  unexpressible rather than merely documented. Don't "flatten" the controller
  signature back to named strings: that shape was a trap that bit the old Show
  code and Resend equally, and a new pending-user field had to be threaded
  through four layers with no compile error if you missed one.
  Unlike the retired code flow, **expanding the row is NOT a re-issue** — it
  makes no server round-trip and rotates nothing. As of 2026-08-21 there is also
  nothing left for it to render: the starting password is random per account and
  deliberately **not persisted** (a live plaintext credential must not sit in
  Firestore, where every admin session, backup and export can read it), so a row
  holding no server echo renders the password masked with a hint that **Reset
  password** issues a new one, and its Copy pill copies the **email alone**.
  Only Reset password re-provisions, and only that rotates what the person was
  given — immediately after a create or a reset the row still holds the echoed
  pair and shows and copies both, which is the moment that actually matters.
- **`watchEmployees()`** now filters `status == 'active'` — it no longer returns invited or
  disabled users. Use `watchAllUsers()` (admin-only) if all statuses are needed.
  All three `users` streams are bounded by the shared `_userStreamLimit`
  (**1000** as of 2026-08-19, raised from 500) and WARN at the cap, so a
  runaway collection can't stream an unbounded snapshot to every client —
  add the bound AND the warn to any new one. **The appointment range streams
  are bounded too** (`_rangeStreamLimit`, **3000**) and WARN when a snapshot
  comes back at the cap — past it the calendar is showing a prefix of the
  range, which the grid dots and agenda would otherwise misreport in silence.
  These ceilings were **removed** by the 2026-08-19 cleanup commits and
  restored the same day at higher numbers: the paging that replaced them fixed
  the silent truncation correctly, but an unbounded live `snapshots()` — held
  open at once by the calendar, the day route, the drawer badge, the roster
  reducer and the dashboard, and re-established per month page — is a
  different risk class from an unbounded one-shot `.get()`, and every warn had
  gone with them. **Bounded-and-loud, never unbounded, and never bounded-and-silent.**
  `watchEmployees` deliberately has **no
  `orderBy`**: an `orderBy('name')` makes Firestore exclude docs
  missing `name`, which would drop an unnamed active employee out of the
  picker (and silently change who can see a visit). `watchAllUsers` no longer
  orders either, for the same reason — all three sort in Dart through
  `_toSortedEmployeeRecords`, which is also where the cap warn lives. That
  asymmetry is also why it isn't derived from `allUsersStreamProvider`. **`employeesStreamProvider`
  is `autoDispose`** (2026-08-08): its consumers are the two transient
  appointment sheets plus the Dashboard, so without it opening the
  add-appointment sheet ONCE pinned a second live `users` listener for the rest
  of the session, alongside the always-on `watchAllUsers()`.
- **`users.name` is composed, never abandoned.** P4 added `firstName`/`lastName`,
  but `watchAllUsers()` orders by `name` and Firestore **excludes docs missing
  the orderBy field**, so a user whose `name` went empty vanishes from the admin
  roster. Every write path builds it through `composeEmployeeName`
  (`employees/domain/policies/employee_name_policy.dart`), which falls back to
  the stored name and then to `'—'` (`kUnnamedEmployee`) — it can never return
  `''`. That fallback is an EM DASH, and the en dash joining an employee's
  working hours is an EN dash; a 2026-08-19 cleanup flattened both to a plain
  hyphen and rewrote the tests to match, so the tests pinned the regression
  rather than catching it. Both are restored and re-pinned — treat a
  mechanical non-ASCII sweep over `lib/` as a change to shipped strings, not
  to comments.
  **Rendering side: read `EmployeeRecord.displayName`**, the getter that
  delegates to `displayEmployeeName` (mirroring `ClientRecord.displayName` →
  `ClientNamePolicy.displayFor`) — the four-argument unpack was spelled at four
  render sites. The free function stays public for the one caller holding a raw
  map rather than a record (`account_status_provider.dart`). The edit sheet
  seeds First from the whole stored `name` when both halves are empty, so a
  legacy single-name doc round-trips unchanged. **`EmployeeFormValidator` takes
  the two halves separately, never the composed name** — `composeEmployeeName`
  falls back and so can never return empty, meaning a composed value cannot
  express "the last name is missing". Its `requireLastName` flag is the one real
  difference between the two person sheets: the invite demands both halves, the
  edit leaves the last name optional so a legacy single-name doc still saves.
- **`jobTitle` is not `role`.** `role` stays the ACCESS flag
  (`admin`/`employee`) and is what `firestore.rules` gates on; `jobTitle`
  (Lead tech · Technician · Apprentice · Dispatcher) is what someone does on
  site and gates nothing. `JobTitleChips` therefore has no side effect on the
  ACCESS toggle — conflating them would make picking "Dispatcher" silently
  grant or revoke admin.
  **One title DOES gate something, and only this: `JobTitle.isAssignable`
  (2026-08-24) is false for `dispatcher`**, who schedules the work rather than
  going out on it. `EmployeeRecord.isAssignable` forwards it and
  `assignableEmployeesProvider` (`employees_providers.dart`) applies it to a
  set — the assignee pickers and the dashboard's per-person job numbers read
  THAT provider, never the raw `employeesStreamProvider`, or a dispatcher sits
  at a permanent zero on the workload list AND adds their `maxJobsPerDay` to
  every daily-capacity bar. It is deliberately DERIVED rather than filtered
  inside `employeesStreamProvider` or the repository: `_resolveActiveEmployees`
  (`event_details_controller.dart`) reads `watchEmployees()` straight for the
  retain check, so a dispatcher already stored on a job must still read as
  ACTIVE there or removing them is undone on every save. Still not an access
  flag — a dispatcher's own visibility is unchanged, and the edit picker still
  offers one already on a job (see `offerableAssignees`, root `CLAUDE.md`).
  **The exclusion is ABSOLUTE — there is no personal-block or day-off
  carve-out** (owner call, 2026-08-24, asked and answered when a review raised
  it). A dispatcher is not offered on a personal block either, so a day off
  cannot be booked FOR one; the exclusion is about the person, not about the
  kind of entry. Consequence to keep in mind rather than "fix": assignees are
  required on every appointment and an employee sees only appointments whose
  `employeeIds` contain them, so a dispatcher has nothing on their own
  calendar. That is the accepted shape.
- **`workingDays` is Sunday-indexed** (`[0]` = Sunday), matching
  `weekStartForLocale` and `weekdayLabelsForLocale`, which both read intl's
  Sunday-indexed `NARROWWEEKDAYS`. Storing Monday-first would put a `% 7`
  conversion at every read and write, and one missed conversion shifts a whole
  roster by a day. **That conversion therefore has ONE owner,
  `sundayIndexOf(day)` in `calendar/domain/month_grid.dart`** — it was private
  there and had grown three more hand-spellings (the dashboard's capacity
  reducer, `availabilityConflictPolicy`, the daily-load chart's bar labels),
  each with its own restatement of the "DateTime.sunday is 7" comment. Never
  write `day.weekday % 7` at a call site. Display order comes from
  `orderedWorkingDays`, whose cells carry their own `storedIndex` — a widget
  must write back through that, never through the visual position.
  `formatWorkingDays` (the detail page's DAYS row) takes its `labels`
  **Sunday-indexed and unrotated** (`weekdayAbbreviationsForLocale`), because it
  indexes them by `storedIndex`; passing a display-ordered list silently
  mislabels every day. **Naming a SET of stored day numbers as prose is
  `joinWeekdayNames(context, days)`** (beside `formatWorkingDays`), which
  resolves the labels itself precisely so that unrotated rule can't be got wrong
  at a call site — the dashboard's Attention list and My details both report
  availability conflicts and each carried an identical private copy.
  **The daily-cap picker is shared too: `showMaxJobsPicker` + `kMaxJobsOptions`
  + `maxJobsLabel`**, same file. The admin Team sheet and My details offer the
  same `maxJobsPerDay` field, and a hand-mirrored option list plus `noCap` label
  rule is exactly the drift the `AvailabilityPanel` extraction had just ended
  one row over. This bullet claimed all three were extracted together while
  only the option list actually was; `maxJobsLabel` was added 2026-08-15 to make
  it true, and the ternary it replaced had been re-spelled at three sites.
  **The read-only detail view deliberately renders NO row for an uncapped
  person** rather than "No cap" — a read-only body omits empty sections instead
  of showing a placeholder — so it does not call the helper.
- **A user-doc rules cap must not be tighter than the widest value a shipped
  write path can produce.** `createEmployeeAccount` accepts `phone` up to 40
  chars while `TextLimits.phone` is 24, so `isValidUserData` caps phone at
  **40** — a tighter cap would make every server-created doc with a longer phone
  permanently un-updatable, including by `deactivateEmployee`. Rules caps mirror
  the *server* limit; the client caps with `TextLimits`. **Retiring a callable
  does NOT license tightening a cap it set**: the docs it created outlive it, so
  the 40 survives `createEmployeeInvite` (deleted 2026-08-08) on the strength of
  the rows still in the collection. Same reasoning for the
  P4b `emergencyPhone`: rules cap **40**, client caps `TextLimits.phone`.
  **The converse also holds: a client cap must not be LOOSER than the callable's,
  or the field silently accepts a value the callable rejects as
  `invalid-argument`** — which reaches the user as an unexplained "Something went
  wrong" they cannot fix by editing. That is why the `users` name halves use
  `TextLimits.employeeNameHalf` (**100**), matching `createEmployeeAccount` and
  `completeEmployeeSetup` exactly, rather than the 200-char `TextLimits.firstName`
  used for clients. `name` is the JOIN of those halves, so it legitimately
  reaches 201 — its server and rules caps are **250**, sized to the composed
  value and never to a half. Same reason for **`TextLimits.authEmail` (254)**:
  an employee's email is a sign-in identity and passes through
  `createEmployeeAccount`/`changeEmployeeEmail`, which both
  `requireString(..., 254)`, so the two employee sheets bind to it rather than
  to the 320-char `TextLimits.email` the client records use.
  **`test/core/validators/text_limits_test.dart` now reads `firestore.rules`
  (and `employee_accounts.js`) back and fails the build if a client cap ever
  exceeds its rules or callable cap.** Dart, CEL and JS cannot share a constant,
  so that test is the only mechanism turning this rule into something enforced
  rather than merely written down — four appointment pairs are currently
  EXACTLY equal, so a one-character bump on either side breaks every long save
  with an opaque `permission-denied`.
  **It reads `functions/wave/mappers.js` back too, for `IMPORT_FIELD_CAPS`** —
  a THIRD hand-mirror of `isValidClientData`, and the one where the failure is
  quietest. The Wave import writes with the Admin SDK, which BYPASSES the
  rules, so a cap above the rules cap does not fail the import: it writes a
  client doc the APP can never update again, every later save landing as
  `permission-denied` on a field nobody typed. Add a new capped import field to
  that map and the test picks it up automatically.
- **Phone numbers are stored FORMATTED, not as raw digits** (owner call,
  2026-08-02). `PhoneInputFormatter` (`core/validators/phone_format.dart`) masks
  every phone field as it is typed, so `phone`, `emergencyPhone` and each
  contact phone persist as `(514) 555-1234`. Two deliberate pass-throughs, both
  load-bearing: anything containing `+` is returned untouched (an international
  number has no fixed 10-digit shape, and bracketing its first three digits as
  an area code would be wrong), and digits past the tenth are appended verbatim
  rather than truncated, so an extension survives. Consequences to keep in
  sync — **`launchPhoneCall` strips back to digits** (keeping a leading `+`)
  before building the `tel:` URI, because `Uri` percent-encodes the brackets and
  space into a path some dialers reject; and `ClientSearchPolicy.digitsOnly`
  already normalized on both sides, so phone search is unaffected.
  **Legacy and Wave-imported docs were NOT formatted**, which stayed invisible
  until a person's `name` became their phone number verbatim and Wave's
  customer list started mixing "(514) 234-0818" with "4506220931".
  `functions/scripts/backfill-client-phone-formatting.js` is the cleanup
  (idempotent, `--dry-run`). It formats **only** a NANP number — ten digits
  with no `+`, or eleven beginning with 1, whose leading digit is the `+1`
  country code and is dropped. Deliberately narrower than `formatPhoneNumber`,
  whose progressive mask renders the eleven-digit form as "(151) 455-5123 4"
  (reading the country code as the area code) and would rewrite a half-entered
  number into a shape claiming to be complete. The `+` bar on the ten-digit
  branch is load-bearing: "+49 30 123456" is also ten digits.
  **`TextLimits.phone` is 24, and it must stay above the widest string
  `formatPhoneNumber` can emit** — `LabeledTextField` appends the
  `LengthLimitingTextInputFormatter` **after** `PhoneInputFormatter`, so the
  mask runs first and the cap truncates its output. At the old 15 the two
  pass-throughs above were unreachable: a NANP number typed with its leading 1
  formats to 16 chars, so the 11th digit could never be entered, and every
  further keystroke re-truncated to the same 15 with no error shown. Never size
  this cap to the 14-char happy path.
- **The emergency contact lives in `users/{docId}/private/emergency`, NOT on the
  users doc, and it is the one piece of person data gated to the admin AND the
  person themselves** (owner call, 2026-08-02). Firestore rules are
  document-level — there is no way to hide a field from someone allowed to read
  the document — and `/users` read clause 2 deliberately lets every active
  employee read every active peer (the crew pickers, names and colours need it).
  On the parent doc this pair therefore shipped a **third party's** name and
  phone to every employee's device; that person is not an app user and never
  consented. A subcollection is the only place rules can express the grant:
  `allow read, write: if isAdmin() || (isActiveUser() && myDocId() == userId)`.
  **Never move these back onto the users doc, and never widen a `/users` read
  clause to reach them.** Consequences to keep in sync:
  `EmployeeRecord` does **not** carry them (`EmergencyContact` does, read via
  `emergencyContactProvider`); `isAvailabilityOnlyChange()` no longer lists
  them, because P5's self-service clause governs the users doc and these are
  not on it; and a read
  failure on this path means "not entitled", so a surface must render it as
  *not shown*, never as *none on file*.
  **The rules now make a value on the parent doc unreachable, with NO migration
  (owner call 2026-08-04: nobody had entered one, so there was no data to move,
  and the feature is treated as clean-slate).** `allow create` bans both keys
  outright; `allow update` routes them through **`emergencyFieldNotSet(f)`**,
  which permits a write that leaves the field ABSENT and refuses one that
  leaves a value. That asymmetry is the whole design and must not be
  "simplified" into a plain denylist entry beside `uid`: the denylist form
  rejects any write that touches the key at all, which would reject the
  `FieldValue.delete()` scrub `updateEmployee` still sends on every save AND
  leave any doc that somehow carried the pair permanently un-updatable —
  including by `deactivateEmployee`, since a partial update presents every
  untouched field in `request.resource.data`. As written, an untouched legacy
  value simply passes through (so the doc stays updatable) and the client scrub
  heals it on the next save. The length caps in `isValidUserData` stay for that
  pass-through case — they are not dead. `functions/scripts/backfill-emergency.js`
  is **deleted**; it has nothing to do. Pinned by
  `test/core/security/emergency_contact_rules_test.dart`, which reads
  `firestore.rules` back (rules can't be unit-tested without the emulator).
- **`MyDetailsScreen` (Settings › My details) is the ONLY surface where a person
  edits their own record** — the employee detail and edit sheets are admin-only.
  It exists to exercise the two grants a person holds over their own data, and
  is scoped to **exactly** those: the `private/emergency` subcollection (admin
  OR owner) and P5's self-service clause. Everything else about a person is
  admin-owned, so a general profile editor here would fail with
  `permission-denied`. (It was emergency-contact-only until P5, 2026-08-10.)
  **It carries TWO save behaviours on purpose** (owner call, 2026-08-10), and
  they must not be unified in either direction. The **identity** fields (phone,
  emergency contact, emergency phone) sit behind a Save/Discard bar that appears
  only once the form is dirty — they are free-text, a half-typed phone number
  auto-committing is a bad write with no undo, and dirtiness is recomputed
  against the stored values rather than latched, so typing a change and typing
  it back reads as pristine again. **Availability** (days, hours, on-call)
  applies immediately, optimistically, rolling back and surfacing a notice on
  failure — a switch that needs confirming reads as broken. **The consequence to
  keep: an availability write must send the STORED phone, never the identity
  controller's text**, or toggling a day silently commits the half-typed number
  the bar exists to prevent. Pinned by a test.
  The admin-only SCHEDULING section is `maxJobsPerDay` and nothing else, written
  through the ordinary admin `updateEmployee` path because that field is not on
  the self allowlist — and it is **hidden** for a technician rather than
  disabled, since there is no path there that could ever succeed. Role, job
  title and crew colour deliberately stay on the Team sheet: an admin editing
  their own role from a self-service screen is a privilege-escalation shape with
  no product reason to exist.
- **The emergency pair is its own section, not a tail on availability.** Both
  the edit sheet (`MonoSectionLabel` `employees_sectionEmergency`) and the
  read-only detail view (its own `KeyValuePanel`, rendered only when non-empty)
  group them apart from hours and access — who to call when something goes
  wrong on site is a different question from when someone works.
- **An employee is never deleted — disable is the only removal** (owner decision
  2026-08-02, which withdrew a shipped delete). Deleting the `users` doc
  orphaned every past appointment's `employeeIds` link: the visit keeps the
  denormalized `employeeNames` and loses the crew colour and the person.
  `syncUsersByUid` already does strictly more on disable — it disables the Auth
  account, calls `revokeRefreshTokens`, and purges `presence/location`,
  `fcmTokens`, every `liveActivityTokens` row and the `liveActivityCards`
  marker. `allow delete` is withdrawn from `/users`; the Admin SDK bypasses
  rules, so console cleanup is unaffected.
- **Revoking a PERMISSION deletes nothing server-side, and the published privacy
  policy now says so** (2026-08-08 audit). `presence/location` is deleted only by
  `PresenceSyncController.unregister()` and `fcmTokens` only by
  `unregisterCurrentDevice()`, and both are reached from exactly three places:
  sign-out, self-service account deletion, and the server-side disable/delete
  bridge (`functions/bridge.js`). Losing the OS permission mid-stream only runs
  `_stop()`, which cancels the subscription and timers — no network call. That
  matters because **the stored fix keeps rendering on the admin live map**:
  `LiveMapAggregator.join` filters on missing/inactive user, never on freshness,
  and `staff_marker_icon.dart` has no staleness branch, so a months-old pin is
  visually identical to a live one (only the roster row and info card show the
  age). The policy used to promise deletion on revocation and promise the pin
  disappeared; owner call was to correct the TEXT rather than the code, so
  `docs/legal/privacy-policy.html` §6 and §8 now describe this behaviour
  exactly. **The two must stay in step**: if you ever wire permission-revocation
  into a delete, or add a freshness filter to the map, update those two sections
  in the same change — and republish (see below), or the site keeps describing
  the old behaviour.
- **`docs/legal/*.html` are SOURCES, not the published pages.** The live site is
  the separate `gvogas/es-pro-legal` GitHub Pages repo, where
  `privacy-policy.html` is published as **`index.html`** (which is why the other
  pages link to the privacy policy by absolute root URL — a relative
  `privacy-policy.html` 404s). The four files must stay **byte-identical** across
  the two repos; a 2026-08-08 audit found the support page still describing the
  signup-code flow deleted in P4c, months after the app stopped having it.
  Editing `docs/legal/` alone changes nothing a user can read.
- **A disabled or invited employee's colour is TAKEN.** `usedColors` reads
  `allUsersStreamProvider`, never `employeesStreamProvider` — the latter filters
  to `status == 'active'`, so a disabled employee's colour was offered again and
  two people ended up the same hue, which is what the appointment bar and the
  calendar dots key on.
- **`allow update` on `/users` has TWO branches as of P5 (2026-08-10), and the
  brackets around them are load-bearing.** It reads
  `(isAdmin() || (isSelf() && isAvailabilityOnlyChange())) && <denylist> &&
  emailMovesThroughAuth() && <emergency guards> && isValidUserData(...)`.
  **`emailMovesThroughAuth()` is part of that conjunction and this quote
  dropped it until 2026-09-05** — a reader reconstructing the rule from the
  doc loses the guard that forces every email change through
  `changeEmployeeEmail`, so the Firestore row and the Auth account can diverge. Without the outer parentheses the
  denylist and the validator bind to the self branch alone and an admin write
  skips both. `isSelf()` gates on `isActiveUser()` as well as
  `resource.data.uid == request.auth.uid`: a **disabled** account keeps its Auth
  credential until `syncUsersByUid` revokes it, and an **invited** one is
  mid-setup with `completeEmployeeSetup` owning its doc — neither may self-edit,
  and both must fall through to the admin branch.
  **`isAvailabilityOnlyChange()` uses `hasOnly`, so it is a whitelist of the
  ENTIRE diff, not a per-key permit**: one unnamed key rejects the whole write,
  which reaches the user as an opaque `permission-denied` on an ordinary save.
  `kSelfServiceUserFields`
  (`employees/domain/policies/self_service_fields.dart`) is its hand-mirror, and
  `test/features/employees/domain/self_service_fields_test.dart` reads the rules
  back and fails the build if the two drift — Dart and CEL cannot share a
  constant, so that test is the only thing enforcing it. Add a key to the RULES
  first, then to the Dart set; the reverse order ships a silent
  `permission-denied`. `travelAlertsEnabled` and `locationSharingEnabled` are on the list
  deliberately — a per-person notification or privacy preference is exactly the
  category it exists for, and the second one is the ONLY thing that stops the
  phone uploading a position, so an admin-only field would make consent
  something the person cannot withdraw. Note the two default OPPOSITE ways:
  absent `travelAlertsEnabled` reads as ON, absent `locationSharingEnabled` as
  OFF. Both are also on `isAvailabilityOnlyChange`'s `hasOnly` set, so the
  Settings toggle and the availability form can each write theirs alone.
  **`email` must never join it** — it is a sign-in
  identity, and Auth and Firestore move together through `changeEmployeeEmail`
  or not at all. Neither may `maxJobsPerDay`, `role`, `jobTitle`, `colorValue`
  or `status`: those stay admin-only on both branches.
  The client write path is `EmployeesRepository.updateSelfDetails`, deliberately
  **separate** from `updateEmployee` rather than a flag on it — that method's
  patch carries `role`, `email` and the emergency `FieldValue.delete()` scrub,
  every one of which the `hasOnly` would reject. It is a plain `update()`, not a
  transaction (one person, one device, no concurrent writer, and see the
  no-client-transactions rule). **Because the patch names every allowlisted key,
  each caller must pass through the values it isn't changing** — My details
  carries the stored `travelAlertsEnabled`, Settings carries the stored
  availability, and both carry the STORED phone rather than in-progress text.
  A guessed default there silently flips somebody's setting.
- **An employee's own sign-in email moves through `changeEmployeeEmail`'s SELF
  branch** (P5, 2026-08-10) — never a users-doc write, which is why `email` is
  off the self allowlist. `resolveEmailChangeCaller`
  (`functions/employee_accounts.js`, pure and jest-tested) is the one gate:
  an **active admin** may move any doc, an **active employee** may move their
  OWN, and nothing else gets through — disabled, invited, unknown role, missing
  bridge doc, or an employee naming somebody else's docId. Widening the callable
  past admins must never widen WHICH doc a caller can reach; that function
  exists to make the mistake hard to write. Guard order is auth → payload →
  identity → rate limit → work, and the per-caller budget stays: this rewrites a
  sign-in identity.
  **`isSelf` reports whether the caller IS the target, independent of role**,
  because it routes the notification: an admin edit tells the EMPLOYEE
  (`notifyEmailChanged`), a self edit tells the ACTIVE ADMINS
  (`notifyAdminsOfSelfEmailChange` → the shared `sendToActiveAdmins`, which P6's
  time-off requests will reuse — build new fan-outs on it rather than inlining
  the query). An admin editing their own row is a *self* change and must not be
  pushed a notice about what they just did. **The admin notice carries the NAME,
  never the address**: it lands on every admin's Lock Screen and an email is PII.
  Client side, `SelfEmailService` re-authenticates BEFORE calling — an
  unattended unlocked phone changing the sign-in address is the account-takeover
  primitive — and the sheet demands the address **twice**, because the Admin SDK
  sets it with no proof of control and a typo locks the person out until an
  admin undoes it. That ordering is pinned by
  `test/features/settings/services/self_email_service_test.dart` (`verifyInOrder`
  plus the half that matters: a thrown re-auth must `verifyNever` the callable),
  the same way `completeAccountSetup`'s password-then-activate order is.
  **The server restates it for a NON-ADMIN caller**: `assertFreshReauth`
  (`functions/security.js`, shared with `deleteAccount`) rejects a caller whose
  `auth_time` is over 5 minutes old, so a direct call cannot skip the client's
  ordering. **That gate keys on the caller's ROLE (`isAdmin`), never on
  `isSelf`** — the two are deliberately separate fields on
  `resolveEmailChangeCaller`'s result, because an admin editing their OWN
  roster row IS `isSelf` and yet arrives through `updateEmployee`, which has no
  re-auth step to satisfy. Keyed on `isSelf`, that save was rejected outright —
  and since `_changeAuthEmail` runs BEFORE the Firestore write, the whole edit
  (name, phone, colour, availability with it) died as an opaque `stale-auth`
  five minutes after sign-in. `isSelf` routes the NOTIFICATION and nothing
  else; don't collapse them. The durable budget is **5/hour per caller uid on
  BOTH branches**
  (down from the 20 it shared with account creation) — the freshness gate is
  what differs, not the budget: this rewrites a sign-in identity, so a
  compromised session of either role must not be able to walk the roster.
  **The ADMIN branch is deliberately NOT gated on freshness** — it is
  reached from `updateEmployee`, which has no re-auth step to satisfy, so the
  check would reject every admin email edit made minutes after sign-in. That
  residue is real and stated: an unattended *admin* session can still rewrite a
  colleague's address, bounded by `assertAdmin` and the budget. Closing it needs
  a re-auth prompt on the admin save path first. Firebase's `verifyBeforeUpdateEmail` is not the answer: it
  flips Auth OUTSIDE the callable and leaves `users.email` stale with no trigger
  to reconcile it — the exact desync the callable exists to end.
- **`travelAlertsEnabled` defaults to ON, and absent MUST read as ON.**
  `wantsTravelAlerts` (`functions/travel_utils.js`) and
  `EmployeeRecord.fromMap`'s `!= false` are the two halves; every users doc
  written before the field existed has no value, so an `undefined`-is-off
  reading would silence departure alerts fleet-wide — and the symptom is a push
  that never arrives, which nobody reports. Only an explicit `false` opts out.
  **It gates the ESCALATION to `leaveNow` only**: an opted-out assignee still
  gets the fixed 30-minute `reminder`, the same degradation a missing origin or
  a Routes failure already takes.
  **The flag must be read BEFORE the Routes call, not beside the `kind`
  choice** — `resolveReminderForAssignee` skips the whole
  `decideOrigin`/`computeTravelSeconds` block when it is off, so `travelSeconds`
  stays null and `computeLeadMinutes(null)` yields the fixed 30. Read only at
  `kind`, the escalation was suppressed but the LEAD TIME was still
  travel-derived, so an opted-out tech got the generic "Upcoming job" push up to
  `MAX_LEAD_MINUTES` (90) early on a long drive — and the business still paid
  Google Routes for an estimate that changed nothing. Pinned by
  `travel_utils.test.js` ("an opted-out assignee"), which asserts the sweep
  never calls `fetchImpl`. The toggle is in Settings › NOTIFICATIONS (a
  SERVER flag, unlike the device-local Live Activity switch beside it — the
  sweep picks the push kind, so a local preference could never reach it), and
  the row is hidden until the person's own record loads rather than rendered
  against a guessed default. `EmployeeRecord.toMap()` deliberately does NOT emit
  it: an admin save must leave it exactly as it was.

- **The team roster's "jobs today" count is ONE listener, not one per row.**
  `employeeJobsTodayProvider` reduces a single `appointmentsInRangeProvider` over
  today's range into a `Map<String,int>`; every row reads the map. The range
  comes from `todayRangeProvider`, which watches `currentDayProvider` — never
  `DateTime.now()`, or the counts stick on yesterday in an app left open across
  midnight. Cancelled visits don't count. **The employee detail's TODAY panel
  filters that SAME stream** (`employeeTodayJobsProvider`) rather than opening a
  per-employee query — the Team tab already holds the day range open, so a
  detail costs no extra read and the panel can't disagree with the count on the
  row that opened it.
