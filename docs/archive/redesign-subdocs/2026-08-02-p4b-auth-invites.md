# P4b — Auth + invites Implementation Plan

> ## ⚠️ WITHDRAWN — do not execute this plan
>
> The signup-code invite lifecycle below was replaced by P4c on 2026-08-02 and
> its backend was deleted from production on 2026-08-08. Only the restyled
> sign-in and reset-password surfaces survive. See
> `2026-08-02-p4c-HANDOFF.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the redesigned auth surfaces and the full invite lifecycle — a restyled sign-in
with an "Accept your invite" path, the two-state reset-password screen, a code-entry screen of
twelve mono boxes, an acceptance details screen with a locked invite email and consent gating,
a real deep-link delivery layer (`app_links`) with one Dart dispatcher, and the pending-invite
row on Team (Show code · Resend · Revoke) backed by a new `revokeInvite` callable and a
`codeExpiresAt` stamp on the invited users doc.

**Architecture:** No new stored entity — the invite stays the existing invited `users` doc +
`signupCodes/{sha256}` pair, exactly as the program doc decided. Every server change lands in
**Task 1 and only Task 1** (`functions/invites.js`, `signup_code_utils.js`, `index.js`,
`firestore.rules`), and Task 1 **ends with the deploy** — deliberately inverted from P4's
deploy-at-close-out, because every backend change here is backward-compatible with the shipped
client while the new client is NOT compatible with the live backend (see the Deploy note).
Everything after Task 1 is client-only. The acceptance flow stays
`signUpWithCode` → `redeemSignupCode`: activation remains Admin-SDK-only, the orphan rollback,
the email-keyed rate limit and the `code-email-mismatch` distinction all survive unchanged.

**Tech stack:** Flutter 3.10.7 / Dart, Riverpod 3, Firebase (Auth, Firestore, Cloud Functions
v2), `app_links` 7.2.1 (SPM-vetted 2026-07-29), `gen_l10n`, mocktail, jest.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Baseline to hold:** `flutter analyze` → **0 issues**, `flutter test` → **1340 passing**,
  `cd functions && npm run lint` clean (80-char limit), `npm test` → **687 passing**. Every
  task ends green on all of these; tasks that touch `functions/` or `firestore.rules` say so
  explicitly (only Task 1 does).
- **A signup code shown in the UI is a credential.** It is never passed to `logger.*`, never
  interpolated into a notice or an error message, never written to SharedPreferences or secure
  storage, and held only in widget/controller state that dies with the surface. The clipboard
  copy is the one sanctioned egress (it is the feature). The server stores sha256 only — no
  plan step may persist plaintext anywhere.
- **`SplashScreen` signs out any signed-in user without an `active` users doc.** The invite
  flow never fights this: the acceptance user is signed OUT until `signUpWithCode` runs, and
  activation is atomic server-side. The bootstrap window in `isAccountDeletionSignal`
  (first-seen empty doc = invited account mid-activation, NOT a deletion) is load-bearing —
  nothing in this plan may "simplify" it.
- **Every auth catch site logs via `logger.authFailure(label, failure, error, st)`** — never a
  hand-rolled `isExpected` branch. Any new `AuthFailure` variant forces an `isExpected` bucket
  at compile time; this plan adds none (every new failure maps onto existing variants or the
  employees family).
- **`TextInput.finishAutofillContext()` commits on success only**, never on a failed attempt.
  Both existing halves (sign-in success, acceptance success) are kept; the new details screen
  inherits the same rule.
- **Offline fail-fast on every new write surface:** check `ref.read(isOfflineProvider)` and
  surface the offline notice BEFORE setting the in-flight flag — acceptance submit, Show code,
  Resend, Revoke. A spinner that hangs until reconnect is the failure mode being prevented.
- **Submit reentrancy:** in-flight flag set synchronously before the first `await`, reset on
  every early return and `catch`.
- **A raw `Stream.listen()` must pass `onError`** — the `app_links` stream included, or an
  error escapes to the zone handler as a fatal.
- **Localisation:** every new string is a paired EN + FR key with an `@key` block in EN
  (`required-resource-attributes: true` fails the build on a bare key). Prefixes: `auth_`,
  `employees_`, `error_`. A hook regenerates `gen_l10n` on Edit/Write; script-edited ARBs need
  a manual `flutter gen-l10n`.
- **Design tokens only.** The hero gradient is `theme.palette.heroGradient` (already on
  `AppPalette`, both themes); the locked email field reads `palette.lockedPanel` /
  `lockedPanelBorder`; dashed-avatar initials read `palette.textMuted` (Ink 25); mono text
  reads `theme.monoType.*`. Never branch on brightness.
- **Touch targets ≥ 48×48** regardless of design's visual sizes; nothing fixed-height holds
  scaled text; every new animation collapses under `MediaQuery.disableAnimationsOf`.
- **Test harness:** autoDispose providers need `container.listen(...)` in `setUp`; screens
  touching secure storage (the login screen's remembered-email prefill) need
  `FlutterSecureStorage.setMockInitialValues({})`; widget tests that build lazily-scrolled
  sheets size the viewport rather than `scrollUntilVisible` (P4 §8d).
- **Files are UTF-8 without a BOM.**

---

## Owner decisions needed before the gated tasks

**ALL FOUR ANSWERED 2026-08-02 — each resolved as recommended. See the "Approved design"
section for the answers and their effect on the tasks.** The reasoning is kept below so nobody
re-litigates it.

| # | Question | Blocks | Recommendation and trade-off |
| --- | --- | --- | --- |
| 1 | **How does the client learn the invite email for the locked "From invite" field?** Storage is sha256-only and `firestore.rules` denies all client access to `signupCodes`, and the invited users doc is unreadable to its own not-yet-verified user (see the read-clause analysis in Task 1) — so a code alone cannot resolve an email client-side. Options: **(a)** a new `previewInvite` callable — App-Check-enforced, **unauthenticated** (the user has no account yet), durable-rate-limited per code hash — that returns `{email, firstName, lastName, role, expiresAtMs}` for a valid code; **(b)** keep email a typed field, locked only when a future deep link supplies it, with a mismatch surfacing as the existing `code-email-mismatch` failure at submit. | Task 1 (the callable) and Task 5 (the screen) | **(a).** A valid code is already the bearer credential for exactly this account — the redeem flow hands the whole account to whoever holds code + matching email, so disclosing the email to a code holder adds nothing an attacker didn't have. It is also the only way the code screen can honestly say *expired* vs *invalid* before the user invents a password. The cost is this repo's first unauthenticated callable — mitigated by App Check enforcement, `assertPayloadShape`, a per-code-hash durable rate limit, and ~60 bits of code entropy making online guessing useless. Option (b) keeps the surface smaller but ships a details screen that contradicts the approved design on day one (no email exists yet to send links, so the field would *always* be editable), and it revives the `invalid-code`-actually-means-email-mismatch confusion the distinct failure was built to kill. The plan below is written against (a); if the owner picks (b), drop the callable from Task 1, make email an `AuthEmailField` on the details screen, and the code screen loses its server-truth error state (format check only). |
| 2 | **"Show code" re-issues via `createEmployeeInvite`, so every tap burns one of the admin's 20/hour invite rate-limit slots. Acceptable?** | Task 8 (and Task 1 if a separate limiter is wanted) | **Yes — share the one budget, and don't add a second limiter.** For a crew this size, 20/hour covers any real mix of inviting and code-showing; a separate `reissueInvite` route would double the effective code-minting budget a compromised admin session gets (the exact thing the cap exists for). Mitigation instead of budget: the pending row caches the fetched code in widget state for the row's lifetime, so collapsing and re-expanding the row does NOT re-mint — only an explicit Show code (first open) or Resend burns a slot. If the owner wants isolation anyway, add `enforceDurableRateLimit("reissueInvite", uid, 20, HOUR)` keyed off the re-issue branch inside `performCreateInvite`'s caller — but then lower both caps so the sum stays ~20. |
| 3 | **A signed-in user taps an invite deep link — what happens?** Redemption requires the NEW account's auth session, so the flow cannot run over an existing session. | Task 7 | **Surface an info notice ("Sign out before accepting an invite") and do nothing else.** Auto-signing the current user out on an inbound URL is a remote-triggered sign-out — a URL any web page can launch must never tear down a session. The notice costs one ARB pair. |
| 4 | **Tapping an invited person's roster row: expand in place (replacing the detail sheet it opens today), and a revoked invite simply vanishes from the roster?** | Task 0 / Task 8 | **Yes to both.** The design says the row expands in place, and an invited person has no detail page worth opening (no jobs, no availability that matters yet — re-issue refreshes their fields anyway). Revoke deletes the `users` doc, so the live stream drops the row on its own; a "Revoked" tombstone state would require a new stored entity, which the program doc explicitly rejected. Confirm at the mockup gate. |

---

## Decisions taken in this plan (not owner-blocking — recorded so nobody re-litigates)

| # | Decision | Why |
| --- | --- | --- |
| 1 | **Consent timestamps are stamped conditionally**: `redeemSignupCode` writes `termsAcceptedAt` / `locationConsentAt` only when the payload carries `termsAccepted: true` / `locationConsent: true`. | The currently-shipped build's acceptance screen has no consent checkbox and sends only `code`. Stamping unconditionally would mint a legally-flavored consent record for a user who never saw the checkbox — a false record. The new details screen gates its CTA on the checkbox and always sends both flags true, so on the new client the stamp always lands. |
| 2 | **`redeemSignupCode` deletes `codeExpiresAt` at activation** (`FieldValue.delete()` in the same transactional update). | The field describes a pending code; leaving it on an active doc is junk that a future reader will misinterpret. One line, same transaction. |
| 3 | **The deep-link dispatcher ignores any URI carrying the `homeWidget` query param.** | The three iOS URL producers (widget, Live Activity, Siri) append `&homeWidget` so the `home_widget` channel claims their taps. Once `app_links` is listening, BOTH plugins observe the same `openURL` — without this skip, every widget tap opens the appointment sheet twice. The param and the channel retire **together, later** (ios/CLAUDE.md); P4b must not touch either. |
| 4 | **The dispatcher waits for the login route via a `TopRouteObserver`, not a delay.** | `SplashScreen` routes with `pushReplacementNamed`, which replaces the **topmost** route — if the dispatcher pushed the code screen while splash was still deciding, splash's post-frame navigation would replace the invite screen itself. Observing the navigator's top route name and pushing only once `/login` is current closes the race deterministically; `_awaitLiveHub`'s 200 ms poll is the same idea for the signed-in branch. |
| 5 | **The invite banner drops "who invited you".** | `createEmployeeInvite` stamps no inviter identity, and adding an `invitedByName` field is scope the program doc didn't ask for. The banner renders role + the locked email + expiry ("You're invited to join as Technician"), which is everything `previewInvite` can truthfully say. Record in the close-out as a deviation. |
| 6 | **No Crockford aliasing (I→1, O→0) in the code entry.** | The generator never emits I/L/O/U, so a typed `I` is a misread `1` — aliasing would actually rescue it, but it is a silent input mutation the server does not mirror (`hashSignupCode` only uppercases and strips dashes), and a half-shared convention is worse than none. The boxes accept A–Z 0–9, uppercase as typed; validity is judged at Continue. Revisit only if support traffic shows misreads. |
| 7 | **`performCreateInvite`'s re-issue branch keeps refreshing the invited doc's editable fields — so every re-issue caller must pass the record's CURRENT values.** | The existing transaction updates `name/firstName/lastName/phone/colorValue/jobTitle/role` on re-issue. Show code / Resend calling it with blanks would silently wipe the invited person's phone and title. Task 8 threads the stored record through; this is a trap, not a redesign. |
| 8 | **No new `PrimaryScrollScope`s.** | Each auth screen sits alone on its own route with exactly one scrollable (`AuthScaffold`'s `SingleChildScrollView`), so the app-wide scrollbar sees one primary position per route — the hazard only exists for simultaneously-mounted scrollables (hub tabs, split panes). The pending-invite row lives inside the employees tab's existing scoped `ListView`. Consciously rejected, not overlooked. |

---

## Deliberate deviations from the handoff / program spec

Record these in the close-out; do not "fix" them back.

| Spec / handoff says | We ship | Why |
| --- | --- | --- |
| Invite **email** (template, deep-link button, store fallback page) | Nothing — codes stay shared out-of-band | Deferred to its own project (owner decision 2026-07-29); no email infrastructure exists, provider choice is shared with the parked client-reminders work. |
| 6-character code, six boxes | **12 chars kept**, three groups of four boxes | Existing codes are Crockford base32 `XXXX-XXXX-XXXX` (~60 bits); 6 chars is 30 bits. Not worth weakening for aesthetics. Hash normalization already strips dashes/case. |
| "Two tries left before the account locks for 15 minutes" | No tries counter | Firebase Auth throttles opaquely and exposes no remaining-tries signal — a client counter would lie. |
| "Keep me signed in" checkbox | Not shipped | Mobile Firebase sessions persist by default; it's a web pattern. |
| "Use Face ID" sign-in button | Not shipped | Re-auth-via-biometric is deferred platform wiring; distinct from the biometric app-lock, which stays. |
| Locked-out state, first-run auth tour, owner/company sign-up | Not shipped | Explicitly out per the program doc ("Not designed / explicitly out"). |
| Invite banner names the inviting admin | Role + locked email + expiry only | No `invitedBy` field exists and stamping one is new scope (decision 5 above). |
| `homeWidget` param / `home_widget` tap channel retired now that a dispatcher exists | **Both kept** | They retire together in a later pass — dropping the param while the channel is still a consumer re-breaks widget taps (ios/CLAUDE.md), and dropping the channel is Mac-verification work P4b doesn't carry. The dispatcher skips `homeWidget` URLs instead (decision 3 above). |
| Tapping an invited row opens the detail sheet (current behaviour) | Expands in place | The pending row IS the invited person's surface; see owner decision 4. |

---

## Approved design — (visuals filled in by Task 0)

**Mockup:** _(URL — pending Task 0)_

### Owner decisions 1–4 — ANSWERED 2026-08-02

All four resolved as recommended. These are authoritative and override any task step that
contradicts them.

| # | Answer | Effect on the tasks |
| --- | --- | --- |
| 1 | **`previewInvite` ships** — a new App-Check-enforced, **unauthenticated**, per-code-hash rate-limited callable returning `{email, firstName, lastName, role, expiresAtMs}`. | Task 1d is IN. Task 5's email field is the locked "From invite" panel, never an editable `AuthEmailField`. Task 6's code screen gets its server-truth expired-vs-invalid error state. This is the repo's first unauthenticated callable — App Check, `assertPayloadShape` and the per-hash limiter are what stand in for the auth guard, and the security rule's guard order applies unchanged below the (absent) identity check. |
| 2 | **Show code shares the one 20/hour `createEmployeeInvite` budget.** No second limiter. | Task 1 adds no `reissueInvite` route. Task 8's tile MUST cache the fetched code in widget state for the row's lifetime, so collapse/re-expand does not re-mint — only first Show code and Resend burn a slot. Pin that with a tile test asserting exactly one repository call across an expand → collapse → expand cycle. |
| 3 | **A signed-in user tapping an invite link gets an info notice only** — never an auto-sign-out. | Task 7's dispatcher, on the `invite` host with a live session, calls `noticeServiceProvider.info(...)` and returns. One new EN/FR ARB pair. No confirm dialog, no session teardown reachable from an inbound URL. |
| 4 | **The invited roster row expands in place; a revoked invite simply vanishes.** | Task 8 replaces the invited row's `showEmployeeDetails` tap with `PendingInviteTile`'s in-place expansion. No tombstone state, no new stored entity — revoke deletes the doc and the live stream drops the row. |

### Visual design — CHOSEN 2026-08-02: **Option A on all five surfaces**

**Mockup:** https://claude.ai/code/artifact/f3f4343c-8c1c-4d1d-b25f-6743b86004ea

No grafts. Option A everywhere, which is the handoff-faithful direction. What that pins,
surface by surface — **this section overrides any task step below that contradicts it**:

| Surface | Option A means | Effect on the tasks |
| --- | --- | --- |
| 1 · Sign in | Hero-gradient block, card lifted **over** it (negative top margin), bordered labelled fields, Show/Hide as a **mono uppercase text link** inside the field, error = red border + red-dot row beneath. The invite route is the **plain text prompt** "Invited by your employer? / **Accept your invite**" under the card — not B's tappable panel. | Task 3. No `invite-panel` widget; the prompt is a `Wrap` of text + link, same shape as today's `_CreateAccountPrompt`, which it replaces. |
| 2 · Reset password | Thin hero on the idle state; the sent state is a **flat bordered card with no hero**, a success badge, facts as a **divided `fact-list`**, and the resend row inside a bordered **`SENT` panel** that relabels and greys once used. | Task 4. The two states keep today's `AuthFormSwitcher`. The `SENT` panel is new; the fact list replaces the single green note. |
| 3 · Code entry | **Bordered** boxes on a flat card (not B's filled boxes, not B's hero). The expiry explanation is a **red-dot error row centred under the box row**, not an amber note. No-code help is a **bordered panel** with a mono `DON'T HAVE A CODE?` label. | Task 6. `CodeEntryBoxes` renders bordered boxes with an `active` ring on the focused index. |
| 4 · Acceptance details | Tinted invite banner (role + locked email + amber expiry pill), first/last **stacked**, phone, **locked** email panel with the "From invite" chip, password + 4-segment meter, **and the existing `PasswordRequirementsChecklist` beneath the meter**, then the consent checkbox on its own tinted surface. No hero, no mono section labels. | Task 5. **`PasswordRequirementsChecklist` SURVIVES** — this settles the open question in the File-structure note. The meter is additive, not a replacement. No `MonoSectionLabel` on this screen. |
| 5 · Pending-invite row | Card rows. Expanding the invited row reveals the `INVITE CODE` block directly — there is **no separate "Show code" button**; the expansion *is* the reveal. Code block on the sheet tone, Copy pill relabelling "Copied", amber caption, then **Resend and Revoke as two equal-width bordered actions** (Revoke in the danger colour). | Task 8. See the constraint immediately below — it is not optional. |

#### Surface 5 carries one mandatory constraint, because A reveals on expand

Expanding the row calls `createEmployeeInvite`, which **re-issues** — the previous code stops
working the moment the row opens. Option B gated that behind a labelled button; A does not, so
the honesty has to move into the copy and the caching instead:

1. **The caption under the code must state the code is new**, unconditionally, in both
   languages — "New code · expires in 14 days", never "Invited 2 days ago". An admin who
   expands a row to peek has already invalidated the code they shared yesterday, and the screen
   is the only place that can tell them.
2. **The fetched code is cached in the tile's state, keyed by the invite doc id, for the
   lifetime of the roster list** — collapse and re-expand must NOT re-mint. Without this, idly
   opening and closing a row burns the admin's 20/hour budget and silently rotates the code
   every time. Pin it with a tile test asserting exactly one repository call across an
   expand → collapse → expand cycle (owner decision 2 already requires this test; A makes it
   load-bearing rather than merely tidy).
3. **Revoke keeps a `showConfirmDialog`** (`destructive: true`). A is the densest layout of the
   three and puts Revoke one tap from a row the admin opened only to read.

_Recorded 2026-08-02. Tasks 3–8 are unblocked._

---

## File structure

**Created**

| Path | Responsibility |
| --- | --- |
| `lib/features/auth/domain/signup_code_policy.dart` | `normalizeSignupCode`, `isCompleteSignupCode`, `kSignupCodeLength` — the one client mirror of the server's hash normalization |
| `lib/features/auth/domain/models/invite_preview.dart` | `InvitePreview` value class (email, firstName, lastName, role, expiresAt) |
| `lib/core/validators/password_strength.dart` | `passwordStrengthScore` (0–4), beside `password_requirements.dart` |
| `lib/features/auth/screens/accept_invite_code_screen.dart` | Code entry — twelve mono boxes, Continue, DON'T HAVE A CODE panel |
| `lib/features/auth/screens/accept_invite_details_screen.dart` | Acceptance details — banner, names, phone, password + meter, consent, submit |
| `lib/features/auth/widgets/code_entry_boxes.dart` | `CodeEntryBoxes` — one hidden `TextField` painting 12 boxes |
| `lib/features/auth/widgets/password_strength_meter.dart` | `PasswordStrengthMeter` — 4 segments driven by `passwordStrengthScore` |
| `lib/core/deep_links/deep_link_target.dart` | `classifyDeepLink(Uri)` → sealed `DeepLinkTarget` (pure, unit-tested) |
| `lib/core/deep_links/deep_link_dispatcher.dart` | The one `app_links` consumer; routes by target |
| `lib/core/navigation/top_route_observer.dart` | `TopRouteObserver` — records the navigator's current top route name |
| `lib/features/employees/widgets/cards/pending_invite_tile.dart` | `PendingInviteTile` — expandable invited row, dashed avatar, code block, actions |

**Modified**

| Path | Change |
| --- | --- |
| `functions/invites.js` | `codeExpiresAt` stamp + re-issue refresh, widened `redeemSignupCode`, `revokeInvite`, `previewInvite` (decision-1-gated), `performRevokeInvite` export |
| `functions/signup_code_utils.js` | `validateInvitePending` extracted from `validateRedemption` |
| `functions/index.js` | export `revokeInvite`, `previewInvite` |
| `firestore.rules` | `/users` update denylist widened; three timestamp caps in `isValidUserData` |
| `lib/features/employees/domain/employees_repository.dart` + `data/firebase_employees_repository.dart` | `revokeInvite`, `previewInvite`, widened `redeemSignupCode` |
| `lib/features/employees/domain/models/employee_record.dart` | `createdAt`, `codeExpiresAt` (read-only, never in `toMap`) |
| `lib/features/employees/application/employee_form_controller.dart` | `revokeInvite` outcome family, `isRevoking` flag |
| `lib/features/auth/services/auth_service.dart` | `signUpWithCode` carries the acceptance profile + consent flags |
| `lib/features/auth/widgets/auth_form_widgets.dart` | Restyled field chrome, Show/Hide as a text link, hero/card scaffolding |
| `lib/features/auth/screens/login_screen.dart` | Restyle + "Accept your invite" path (Task 6 swaps the wiring) |
| `lib/features/auth/screens/forgot_password_screen.dart` | Two-state restyle |
| `lib/routes/app_routes.dart` | `acceptInviteCode` / `acceptInviteDetails` routes + typed args |
| `lib/main.dart` | Dispatcher wiring, `TopRouteObserver` on `MaterialApp.navigatorObservers` |
| `lib/features/employees/screens/employees_screen.dart` | Invited rows render `PendingInviteTile` |
| `android/app/src/main/AndroidManifest.xml` | `esproschedule` intent-filter |
| `pubspec.yaml` | `app_links: ^7.2.1` |
| `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb` | New keys per task |

**Deleted:** `lib/features/auth/screens/create_account_screen.dart` (Task 6 — the acceptance
details screen supersedes it; its tests are retargeted, not dropped).
`password_requirements_checklist.dart` **stays** — the details screen reuses it under the
meter unless the mockup gate says otherwise.

---

## Task 0: Mockup gate — three options, owner picks

**Files:** none in `lib/`. Output is the "Approved design" section of this document.

**Tasks 1–2 do not touch UI and may proceed in parallel with this gate. Tasks 3–8 may not
start until the section is written and committed.** (Owner decision 1 gates part of Task 1 —
ask it alongside the mockup review so Task 1 isn't blocked on the visuals.)

- [ ] **Step 1: Render the mockups**

Invoke the `/mockup` skill with this brief:

> Three labelled options (A / B / C) for the P4b auth + invites surfaces, styled with this
> app's design tokens, one page per surface:
> 1. **Sign in** — hero-gradient top block (`palette.heroGradient`) + floating white card;
>    labelled bordered fields; Show/Hide password as a mono text link; error state with red
>    border + dot; below the card "Invited by your employer? **Accept your invite**". Show
>    both the clean and the error state.
> 2. **Reset password** — idle state (email field, Send reset link, the amber "no email on
>    your account? ask your admin" note) and sent state (expiry + signs-out-everywhere facts,
>    a `SENT` panel whose **Send it again** row relabels and greys once used).
> 3. **Accept your invite — code entry** — twelve mono boxes in three groups of four; CTA
>    relabelling "Enter the code" → "Continue" when full; the all-boxes-red bad-code state
>    with the expiry explanation; the `DON'T HAVE A CODE?` panel (copy: the admin reads it
>    off the Team page — no email exists).
> 4. **Accept your invite — details** — invite banner (role + invited email + expiry, no
>    inviter name), first/last stacked (P4 §8c convention), phone, password with a 4-segment
>    strength meter (+ the existing requirements checklist beneath — the gate decides if it
>    stays), email rendered LOCKED on `palette.lockedPanel` with a "From invite" chip, then
>    the combined terms + location-consent checkbox gating **Create account**.
> 5. **Pending-invite row (Team)** — the invited roster row collapsed and expanded: dashed
>    avatar with Ink-25 initials, `INVITE CODE` block behind **Show code** (19px mono, Copy
>    pill relabelling "Copied"), amber sent/expiry caption, **Resend** ("New code ready"
>    relabel), **Revoke** as the destructive action.
>
> Option A: faithful to handoff doc 11. Option B: richer (P3/P4's chosen direction).
> Option C: leaner chrome.

- [ ] **Step 2: Get the owner's pick and any changes**

Ask explicitly for (a) the option, (b) per-surface changes, (c) answers to owner decisions 1–4
in the table above, and (d) whether the requirements checklist survives under the strength
meter.

- [ ] **Step 3: Write the "Approved design" section** — mockup URL, chosen option, numbered
owner-changes table with an "Effect on the tasks" column, and a line stating the section
overrides conflicting task steps. Amend the affected tasks before starting them.

- [ ] **Step 4: Commit**

```bash
git add docs/plans/redesign-subdocs/2026-08-02-p4b-auth-invites.md
git commit -m "docs(p4b): record the approved auth and invites design"
```

---

## Task 1: Backend — invite lifecycle callables, rules, and the deploy

**Files:**
- Modify: `functions/invites.js`, `functions/signup_code_utils.js`, `functions/index.js`
- Modify: `firestore.rules`
- Test: `functions/__tests__/invites.test.js` (extend),
  `functions/__tests__/signup_code_utils.test.js` (extend),
  `functions/__tests__/invite_lifecycle.test.js` (new — revoke + preview cores)

**Changes `functions/` and `firestore.rules`. Ends with the deploy** (see the step and the
Deploy note for why it runs here and not at close-out). No Dart is touched; `flutter test`
stays at 1340.

### 1a. `codeExpiresAt` on the invited users doc

Clients can never read `signupCodes`, so the Team row's expiry caption needs the expiry
mirrored somewhere an admin CAN read. `performCreateInvite` stamps `codeExpiresAt: expiresAt`
on **both** branches — the `tx.update` of the re-issue path (so Show code / Resend refresh the
caption) and the `tx.set` of the fresh-invite path. `redeemSignupCode` deletes it at
activation (decision 2). `revokeInvite` deletes the whole doc, so no clearing there.

**Which read clause serves it, and what leaks:** the `/users` read rule has four clauses.
Admins read invited docs via clause 1 (`isAdmin()`) — that is the Team row's path. Clause 2
(`isActiveUser() && resource.data.status == 'active'`) excludes invited docs entirely, so
ordinary employees never see a pending invite or its expiry. Clause 3
(`resource.data.uid == request.auth.uid`) can't match — an invited doc has `uid: ""`. Clause 4
requires `email_verified == true`, which a password signup never has (CLAUDE.md documents that
this clause never actually rescues the invited user). Net: `codeExpiresAt` is readable by
admins only, and it is only an instant — never the code. **No read-rule change is needed or
wanted.**

### 1b. `redeemSignupCode` widens — THE ordering hazard of this project

The callable's `assertPayloadShape` allowlist is currently `new Set(["code"])` and
**rejects unexpected keys**. It becomes:

```js
assertPayloadShape(req.data, new Set([
  "code", "firstName", "lastName", "phone",
  "termsAccepted", "locationConsent",
]));
const code = requireString(req.data, "code", 32);
const firstName = optionalString(req.data, "firstName", 100);
const lastName = optionalString(req.data, "lastName", 100);
const phone = optionalString(req.data, "phone", 40);
const termsAccepted = req.data.termsAccepted === true;
const locationConsent = req.data.locationConsent === true;
```

(`optionalString` already exists in `invites.js` — same caps `createEmployeeInvite` uses;
phone's server cap is 40 by the P4 rule that server caps mirror the widest write path, while
the client caps at `TextLimits.phone` = 15 via `PhoneInputFormatter`.)

Inside the transaction, after `validateRedemption` passes, the activation update becomes:

```js
const patch = {
  uid: req.auth.uid, status: "active",
  codeExpiresAt: FieldValue.delete(),
  updatedAt: FieldValue.serverTimestamp(),
};
if (firstName) patch.firstName = firstName;
if (lastName) patch.lastName = lastName;
if (phone) patch.phone = phone;
const composed = [
  firstName || inviteData.firstName || "",
  lastName || inviteData.lastName || "",
].filter(Boolean).join(" ");
if (composed) patch.name = composed;
if (termsAccepted) patch.termsAcceptedAt = FieldValue.serverTimestamp();
if (locationConsent) patch.locationConsentAt = FieldValue.serverTimestamp();
tx.update(inviteRef, patch);
```

Two traps encoded there:

- **`name` may never be emptied** — `watchAllUsers` orders by `name` and Firestore excludes
  docs missing the orderBy field, so a blank `name` vanishes the person from the roster. The
  compose falls back per-half to the invite's stored halves and skips the write entirely when
  both are blank (the invite's composed `name` then survives untouched). This is the JS mirror
  of `composeEmployeeName`'s never-empty contract; a jest case pins it.
- **Consent stamps are conditional** (decision 1): the shipped build sends only `code`, and a
  consent record for a user who never saw the checkbox would be false.

> **DEPLOY ORDERING RULE (bold, same class as P4 §7): the live `redeemSignupCode` rejects any
> payload key beyond `code` — so from the moment a build containing Task 2's widened client
> ships, EVERY invite acceptance fails with `invalid-argument` against the un-deployed
> function. Deploy `functions` (this task's final step) BEFORE any build containing Task 2
> ships, or ship both together. The reverse direction is safe: the widened callable accepts
> the old `{code}` payload unchanged, which is exactly why this plan deploys at Task 1 instead
> of at close-out.**

### 1c. `revokeInvite` — new admin callable

Guard order exactly per the security rule: **auth → `assertAdmin` → `assertPayloadShape` /
`requireString` → `enforceDurableRateLimit` → work** (payload validated before the limiter so
malformed bursts can't exhaust a legitimate admin; identity guards above the limiter so
non-admins can't burn slots). Rate limit: `enforceDurableRateLimit("revokeInvite",
req.auth.uid, 20, 60 * 60 * 1000)` — its own route key, same shape as invites.

The transactional core is extracted as `performRevokeInvite(db, inviteDocId)` (exported for
jest, mirroring `performCreateInvite`):

```js
async function performRevokeInvite(db, inviteDocId) {
  return db.runTransaction(async (tx) => {
    const ref = db.collection("users").doc(inviteDocId);
    const snap = await tx.get(ref);
    if (!snap.exists) return {ok: false, reason: "not-found"};
    const data = snap.data();
    if (data.status !== "invited" || (data.uid || "") !== "") {
      return {ok: false, reason: "not-pending"};
    }
    const codes = await tx.get(
        db.collection("signupCodes").where("inviteDocId", "==", inviteDocId));
    codes.forEach((d) => tx.delete(d.ref));
    tx.delete(ref);
    return {ok: true};
  });
}
```

The wrapper maps `not-pending` → `HttpsError("failed-precondition", "invite-not-pending")`
and `not-found` → `("not-found", "invite-not-found")`. **The transaction is what closes the
revoke-vs-redeem race**: both flows transact over the same two docs, so a redeem that commits
first flips `status` to `active` and the revoke refuses with `invite-not-pending` instead of
deleting a just-activated account — the refusal is the spec'd behaviour ("refuses if the
account is no longer `invited`"), not an error path bolted on. No rules change: the deletes
are Admin SDK. `allow delete` on `/users` stays withdrawn.

### 1d. `previewInvite` — gated on owner decision 1

Unauthenticated (no `req.auth` check — the caller has no account yet), `enforceAppCheck: true`
like every callable, shape-then-limit:

```js
const previewInvite = onCall(APP_CHECK, async (req) => {
  assertPayloadShape(req.data, new Set(["code"]));
  const code = requireString(req.data, "code", 32);
  // Keyed by the code hash: caps hammering of one code at 10/15min. A caller
  // varying codes gets a fresh key each time — that is fine, because at ~60
  // bits of entropy online enumeration is not a real attack, and App Check
  // gates the endpoint to genuine app builds. Never log the code or its hash
  // beyond what the limiter already hashes for its own logs.
  await enforceDurableRateLimit(
      "previewInvite", hashSignupCode(code), 10, 15 * 60 * 1000, "code");
  const db = getFirestore();
  const codeSnap = await db.collection("signupCodes")
      .doc(hashSignupCode(code)).get();
  const codeData = codeSnap.exists ? codeSnap.data() : null;
  let inviteData = null;
  if (codeData) {
    const inviteSnap = await db.collection("users")
        .doc(codeData.inviteDocId).get();
    inviteData = inviteSnap.exists ? inviteSnap.data() : null;
  }
  const v = validateInvitePending({codeData, inviteData, nowMs: Date.now()});
  if (!v.ok) {
    if (v.reason === "expired") {
      throw new HttpsError("failed-precondition", "code-expired");
    }
    throw new HttpsError("invalid-argument", "invalid-code");
  }
  return {
    email: inviteData.email || "",
    firstName: inviteData.firstName || "",
    lastName: inviteData.lastName || "",
    role: inviteData.role || "employee",
    expiresAtMs: codeData.expiresAt.toMillis(),
  };
});
```

`validateInvitePending({codeData, inviteData, nowMs})` is factored out of
`validateRedemption` in `signup_code_utils.js` (the status/uid/expiry checks without the email
comparison); `validateRedemption` becomes `validateInvitePending(...)` + the email-mismatch
check, so the two can never drift. Pure, jest-tested. The response returns only fields the
details screen renders — never the doc id, never phone, never colour.

### 1e. Rules — the three server-owned fields

`isValidUserData` validates the **whole post-write doc** (`request.resource.data`) but has no
`hasOnly` — an unknown field passes. Verified against the live rules file: nothing in
`isValidUserData` mentions `createdAt`/`updatedAt` today and admin updates work, so the three
new server-stamped fields (`codeExpiresAt`, `termsAcceptedAt`, `locationConsentAt`) sitting on
a doc can NOT brick a later admin edit. No cap is *required* — but two changes are still made:

1. **The update denylist grows** — these are function-owned fields, same posture as `jobCount`
   / `wave` on clients (a compromised admin session must not be able to forge a consent
   record or a fake expiry):

   ```
   allow update: if isAdmin()
         && !request.resource.data.diff(resource.data)
              .affectedKeys()
              .hasAny(['uid', 'codeExpiresAt', 'termsAcceptedAt',
                       'locationConsentAt'])
         && isValidUserData(request.resource.data);
   ```

   Safe against every shipped write path: `updateEmployee` writes a field-scoped map that
   never touches them (diff-based `hasAny` only fires when a write *changes* them), and
   deactivate/reactivate write `status`+`updatedAt` only.

2. **Three opt-in type caps** land in `isValidUserData` anyway:

   ```
     && (!('codeExpiresAt' in d.keys()) || d.codeExpiresAt is timestamp)
     && (!('termsAcceptedAt' in d.keys()) || d.termsAcceptedAt is timestamp)
     && (!('locationConsentAt' in d.keys()) || d.locationConsentAt is timestamp)
   ```

   Dead-ish under the denylist today, but `allow create` currently has **zero** field
   validation (the P5 spec's noted loophole) — when P5 wires `isValidUserData` into create,
   these caps are already correct instead of being a fourth forgotten field family. The
   caps-mirror-the-server rule is satisfied trivially: the only writers are the callables, and
   `is timestamp` is exactly what they write.

The redeem update writes `codeExpiresAt: FieldValue.delete()` and the consent stamps via the
**Admin SDK**, which bypasses rules entirely — the denylist constrains clients only.

- [ ] **Step 1:** Extract `validateInvitePending` in `signup_code_utils.js`; rewire
  `validateRedemption` through it. Extend `signup_code_utils.test.js`: pending-valid,
  no-code, claimed (uid set / status active), expired — and assert `validateRedemption` still
  returns `email-mismatch` distinctly.
- [ ] **Step 2:** `performCreateInvite` stamps `codeExpiresAt` on both branches. Extend
  `invites.test.js`: assert the field on the fresh-invite `set` and the re-issue `update`.
- [ ] **Step 3:** Widen `redeemSignupCode` per 1b. New jest cases (fake-db pattern from
  `invites.test.js`): old `{code}` payload still activates (back-compat), names/phone land,
  composed `name` never written empty, consent stamps only when flags true,
  `codeExpiresAt` deleted.
- [ ] **Step 4:** Add `performRevokeInvite` + the `revokeInvite` wrapper per 1c; jest the core
  (happy path deletes code docs then the user doc; `not-pending` on an active doc; `not-found`).
- [ ] **Step 5:** Add `previewInvite` per 1d (skip if owner decision 1 = (b)); jest
  `validateInvitePending` paths via the pure helper (the onCall wrapper's guards follow the
  places pattern and aren't re-tested).
- [ ] **Step 6:** Export both from `index.js`.
- [ ] **Step 7:** Rules per 1e; `firebase deploy --only firestore:rules --dry-run` compiles.
  The three pre-existing `isAvailabilityOnlyChange` warnings still print — they are expected
  until P5 (P4 handoff §3.5), not a regression.
- [ ] **Step 8:** `cd functions && npm run lint && npm test` — lint clean, 687 + new passing.
- [ ] **Step 9: Deploy.**

```bash
firebase deploy --only functions,firestore:rules,storage
```

**Never pass `--force`** (it deletes prod TTL policies missing from `firestore.indexes.json`
— that removed all five live policies once, 2026-07-21). Omit `firestore:indexes` — the file
is unchanged; no new query here needs an index (`signupCodes.where("inviteDocId", ...)` is a
single-field auto-index, already used by the re-issue sweep). `storage` is the target, not
`storage:rules`. **This deploy also flushes P4's still-pending §7/§8e deploy** (widened
`createEmployeeInvite`, `emergencyPhone` rules cap, withdrawn `/users` delete) — run it now
and the standing P4 hazard closes with it. Verify: diff the deployed function list against
`index.js` exports (two new), re-fetch live rules, check for ERROR-severity logs.

- [ ] **Step 10:** Commit.

```bash
git add functions firestore.rules
git commit -m "feat(p4b): invite lifecycle backend - codeExpiresAt, widened redeem, revoke, preview"
```

---

## Task 2: Dart data layer — repository, record, auth service

**Files:**
- Modify: `lib/features/employees/domain/employees_repository.dart`,
  `lib/features/employees/data/firebase_employees_repository.dart`
- Modify: `lib/features/employees/domain/models/employee_record.dart`
- Modify: `lib/features/employees/application/employee_form_controller.dart`
- Modify: `lib/features/auth/services/auth_service.dart`
- Create: `lib/features/auth/domain/models/invite_preview.dart`,
  `lib/features/auth/domain/signup_code_policy.dart`
- Test: `test/features/employees/employee_record_test.dart` (extend),
  `test/features/auth/services/auth_service_test.dart` (extend),
  `test/features/auth/domain/signup_code_policy_test.dart` (new),
  `test/features/employees/application/employee_form_controller_test.dart` (extend if present,
  else the controller paths ride the widget tests in Task 8)

No `functions/`/rules changes. May run in parallel with Task 0. **From this task's commit
onward, a shipped build requires Task 1's deploy** (which Step 9 above already ran — the rule
survives in the Deploy note regardless).

### The pieces

**`signup_code_policy.dart`** — the client mirror of `hashSignupCode`'s normalization, pure:

```dart
const int kSignupCodeLength = 12;

/// Uppercases and strips separators — the exact normalization the server
/// applies before hashing (functions/signup_code_utils.js hashSignupCode).
/// No Crockford aliasing (I→1 etc.): the server does none, and a half-shared
/// convention is worse than none.
String normalizeSignupCode(String raw) =>
    raw.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');

bool isCompleteSignupCode(String raw) =>
    normalizeSignupCode(raw).length == kSignupCodeLength;
```

**`InvitePreview`** — plain value class `{email, firstName, lastName, role, expiresAt}`,
decoded with the loose-cast rule (`(res.data as Map?)?.cast<String, dynamic>()` — a direct
generic cast throws on Android).

**Repository** — three additions on the interface + Firebase impl:

- `Future<InvitePreview> previewInvite(String code)` — maps
  `FirebaseFunctionsException` messages `invalid-code` → `AuthFailureInvalidSignupCode`,
  `code-expired` → `AuthFailureSignupCodeExpired`; `resource-exhausted` →
  `AuthFailureTooManyRequests`; `unavailable`/`deadline-exceeded` → `AuthFailureNetwork` —
  the exact table `_mapRedemptionError` in `auth_service.dart` uses. **All four are already
  `isExpected: true`, so no `AuthFailure` variant is added and no bucket decision arises.**
  Catch sites log via `logger.authFailure` per the error-handling rule.
- `Future<void> revokeInvite(String inviteDocId)` — maps `invite-not-pending` /
  `invite-not-found` to a thrown `EmployeesFailureUnknown`-family typed failure or lets the
  controller's sealed outcome carry the raw error; the UI composes via `composeErrorNotice`
  with a new tag **`EMP-REVOKE`** (+ `error_introRevokeInvite` in both ARBs — intros are
  lowercase mid-sentence fragments).
- `redeemSignupCode` widens:

  ```dart
  Future<void> redeemSignupCode(
    String code, {
    String firstName = '',
    String lastName = '',
    String phone = '',
    bool termsAccepted = false,
    bool locationConsent = false,
  });
  ```

  The impl sends only non-default keys? **No — send all six keys always.** The server treats
  empty strings as absent (`optionalString`) and `=== true` for the flags; a conditional
  payload shape is a second thing to test for zero benefit. (The allowlist already contains
  all six after Task 1.)

**`AuthService.signUpWithCode`** gains the same optional named params and threads them into
`_employees.redeemSignupCode`. **Nothing else in it changes** — the register-or-adopt
branch, `_mapRedemptionError`, the rollback (`_rollbackOrFailLoud` → re-auth → delete →
`AuthFailureAccountCreationIncomplete` on rollback failure) and `_signOutQuietly` are the
hard-won parts and are not touched. Extend `auth_service_test.dart`: the profile params reach
the repository call; a redeem failure still rolls back exactly as before.

**`EmployeeRecord`** gains `DateTime? createdAt` and `DateTime? codeExpiresAt`. Parse them the
way `ClientRecord.fromMap` parses `createdAt` (tolerant of the Firestore `Timestamp` type —
mirror that file's existing pattern rather than inventing a new one). **`toMap` must NOT emit
either** — they are server-owned and `codeExpiresAt`+friends are now on the rules denylist;
a round-trip `toMap` that included them would make any future whole-record `set()` call site a
`permission-denied` grenade. Extend `employee_record_test.dart`: fromMap reads both, absent →
null, `toMap()` contains neither key.

**`EmployeeFormController`** gains a revoke path beside the status one:

```dart
sealed class InviteRevokeOutcome {}
class InviteRevoked extends InviteRevokeOutcome {}
class InviteRevokeFailed extends InviteRevokeOutcome { final Object error; }
```

plus `isRevoking` on `EmployeeFormActivity`. Same shape as `setEmployeeStatus`: deps resolved
before the first await, flag set synchronously, reset in `finally` under `ref.mounted`,
`logger.warn('EMP-REVOKE revokeInvite failed', e, st)` in the catch. A refusal
(`invite-not-pending` — someone redeemed while the admin stared at the row) is a *failed*
outcome whose notice says the invite was already used; the live stream will have flipped the
row to Active by then anyway.

- [ ] **Step 1:** `signup_code_policy.dart` + tests (normalize strips dashes/spaces/case,
  rejects 11 and 13 chars, `isCompleteSignupCode` happy path).
- [ ] **Step 2:** `InvitePreview` + repository methods + widened `redeemSignupCode`
  (interface, impl, loose casts).
- [ ] **Step 3:** `AuthService.signUpWithCode` widening + tests.
- [ ] **Step 4:** `EmployeeRecord` fields + tests.
- [ ] **Step 5:** Controller outcome family + `isRevoking`.
- [ ] **Step 6:** ARB keys for this task: `error_introRevokeInvite`
  (EN "couldn't revoke the invite" / FR "impossible de révoquer l'invitation") — with `@key`
  block; `flutter gen-l10n`.
- [ ] **Step 7:** `flutter analyze` (0), `flutter test` (green). Commit:
  `feat(p4b): invite lifecycle data layer`.

---

## Task 3: Sign-in restyle

**Files:**
- Modify: `lib/features/auth/widgets/auth_form_widgets.dart`,
  `lib/features/auth/screens/login_screen.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Test: `test/features/auth/screens/login_screen_test.dart` (extend/retarget),
  `test/features/auth/screens/auth_screens_scale_sweep_test.dart` (holds)

Gated on Task 0. No functions/rules changes.

The restyle lands in the **shared** widgets so all four auth screens pick it up at once:

- `AuthScaffold` grows the hero-gradient top block + floating-card composition
  (`palette.heroGradient`; card on `scheme.surface` with `cardStyle` decoration). The
  **`AutofillGroup` stays inside it** — restyling must not move the fields out of the group or
  OS password managers stop offering to save. Keep the `ConstrainedBox(maxWidth: 440)` tablet
  cap and the reduce-motion-gated entrance.
- Field chrome: labelled bordered fields per the approved mockup; the error state (red border
  + dot) rides the existing `errorText` path — **the shake and fade-slide stay inside
  `AnimatedFormFieldWrapper` / `formInputDecoration`**, never re-wrapped at call sites.
- `AuthPasswordField`'s suffix becomes the Show/Hide **text link** (mono, tracking shift per
  the design) instead of the eye icon. Keep a `Semantics`/tooltip label
  (`auth_showPassword`/`auth_hidePassword` already exist) and the ≥48px tap target — the
  visible link is smaller than the hit area, per the mobile-use rule.
- Below the card: `_AcceptInvitePrompt` — "Invited by your employer? **Accept your invite**".
  **In this task it is added but wired to the OLD create-account push** (the code screen
  doesn't exist yet); Task 6 swaps the target. Alternative considered and rejected: landing
  the link dead/disabled — a visible dead control in a shipped commit violates the
  every-commit-shippable rule harder than a temporarily-old target does.

Sign-in **logic is untouched**: `signInControllerProvider`, the outcome switch,
`finishAutofillContext()` on `SignInSuccess` only (both call sites — `_signIn` and
`_routeAfterSignUp`), the remembered-email prefill, `_retryOnAuthPropagation` underneath.

New ARB pairs (EN / FR, each with an `@key` block):

| Key | EN | FR |
| --- | --- | --- |
| `auth_invitedByYourEmployer` | Invited by your employer? | Invité par votre employeur ? |
| `auth_acceptYourInvite` | Accept your invite | Accepter votre invitation |

- [ ] **Step 1:** Restyle the shared widgets per the approved mockup (hero, card, fields,
  Show/Hide link).
- [ ] **Step 2:** Login screen layout + `_AcceptInvitePrompt` (old wiring).
- [ ] **Step 3:** ARB keys + `flutter gen-l10n`.
- [ ] **Step 4:** Retarget `login_screen_test.dart` where it found the eye icon by tooltip —
  the tooltip strings survive, so prefer keeping those finders. Add: the accept-invite prompt
  renders; error state shows on a failed attempt.
- [ ] **Step 5:** Run the auth scale sweep — the restyle must hold 0.8–2.0 at 375×667 with no
  exceptions. Fix overflows here, not in Task 9.
- [ ] **Step 6:** `flutter analyze`, `flutter test`, commit
  `feat(p4b): restyle sign-in with the hero card`.

---

## Task 4: Reset password — two states

**Files:**
- Modify: `lib/features/auth/screens/forgot_password_screen.dart`
- Modify: ARBs
- Test: `test/features/auth/screens/forgot_password_screen_test.dart` (extend)

Gated on Task 0. No functions/rules changes.

The screen already has the two-state skeleton (`_emailSent` + `AuthFormSwitcher` +
`_restartTick`) — this is a restyle, not a rebuild:

- **Idle:** restyled field + primary button, plus the amber note ("No email on your account?
  Ask your admin…") on `statusColors.warningContainer` — amber is attention, not success;
  never `tertiary`-as-success.
- **Sent:** `riseIn` entrance (collapsing to instant under `disableAnimationsOf`), the expiry
  + signs-out-everywhere fact lines, and a `SENT` panel whose **Send it again** row calls the
  existing `_sendResetEmail` once more and then relabels + greys for the rest of the session
  (a local `_resentOnce` flag — Firebase throttles the rest; no client counter, per the
  deviations table). The current "resend" behaviour (flip back to the form) is replaced by
  in-place resend per the design.
- Failure handling unchanged: `AuthErrorMapper.map` → `logger.authFailure` →
  `toForgotPasswordMessage`. Note the success copy stays non-committal ("If an account
  exists…") — don't "improve" it into an account-existence oracle.

New ARB pairs: `auth_noEmailOnAccountNote`, `auth_resetSentPanelTitle` ("SENT"),
`auth_resetExpiryFact`, `auth_resetSignsOutFact`, `auth_sendItAgain`, `auth_sentAgainJustNow`
— EN + FR, `@key` blocks; exact copy from the approved mockup.

- [ ] **Step 1:** Restyle both states; add the resend row + `_resentOnce`.
- [ ] **Step 2:** ARBs + gen-l10n.
- [ ] **Step 3:** Tests: sent state renders the panel; Send it again fires exactly one more
  service call then disables; failure still banners.
- [ ] **Step 4:** Scale sweep holds; analyze/test green; commit
  `feat(p4b): two-state reset password`.

---

## Task 5: Accept your invite — details screen

**Files:**
- Create: `lib/features/auth/screens/accept_invite_details_screen.dart`,
  `lib/features/auth/widgets/password_strength_meter.dart`,
  `lib/core/validators/password_strength.dart`
- Modify: `lib/routes/app_routes.dart` (route + `AcceptInviteDetailsArgs`)
- Modify: ARBs
- Test: `test/features/auth/screens/accept_invite_details_screen_test.dart` (new),
  `test/core/validators/password_strength_test.dart` (new)

Gated on Task 0 + owner decision 1. No functions/rules changes. Built **before** the code
screen so Task 6 can wire the whole chain in one commit; until Task 6, this route is
registered but nothing navigates to it — behaviourally a no-op, analyzer-clean because the
route table references it.

### Route and args

```dart
static const String acceptInviteDetails = '/accept-invite/details';

class AcceptInviteDetailsArgs {
  const AcceptInviteDetailsArgs({required this.code, required this.preview});
  final String code;          // normalized; the screen never re-asks
  final InvitePreview preview;
}
```

The code rides the args, never a global. It is a credential: the args object lives only on the
navigator stack and dies with the route.

### The screen

`AuthScaffold` chrome (hero + card from Task 3). Top to bottom:

1. **Invite banner** — "You're invited to join as {role}" + the expiry line from
   `preview.expiresAt` (localized date). Role label via a small switch on
   `admin`/`employee` → existing-style ARB pair. No inviter name (decision 5).
2. **Email, locked** — rendered on `palette.lockedPanel` with `lockedPanelBorder` and a
   "From invite" chip. It is a **read-only presentation, not a disabled `TextField`** — there
   is nothing to focus, autofill must not target it, and a disabled field at 2.0 scale
   truncates worse than a wrapping `Text`. The value is `preview.email`; it is what
   `signUpWithCode` registers with, and the server re-checks it against the invite at redeem
   (`code-email-mismatch` remains the backstop — client lock is UX, not the control).
3. **First / Last** — stacked (P4 §8c), seeded from `preview.firstName/lastName`,
   `TextLimits.firstName/lastName`, `TextCapitalization.words`.
4. **Phone** — optional, `keyboardType: phone`, `inputFormatters: [PhoneInputFormatter()]`,
   `maxLength: TextLimits.phone` (15 — fits the formatted `(514) 555-1234`; the server cap is
   40 and stays 40). Stored formatted, per the phone invariant; `launchPhoneCall` already
   strips for dialing.
5. **Password + confirm** — `AuthPasswordField`s with `AutofillHints.newPassword`, the
   4-segment `PasswordStrengthMeter`, and (per the gate) the existing
   `PasswordRequirementsChecklist`. The **gate on submit stays
   `AuthValidators.newPassword`** (i.e. `PasswordRequirement.allMetBy`) — the meter is
   display-only and must never become a second validator that can disagree with the checklist.
6. **Consent checkbox** — ONE combined terms + location row (`CheckboxListTile.adaptive`,
   `activeColor: scheme.primary`, ≥48px). Unchecked ⇒ the primary button is disabled (null
   `onPressed`), which is the gating; no error text needed.
7. **Create account** — `AnimatedLoadingButton`.

`password_strength.dart`:

```dart
/// 0–4 for the meter's segments. Display-only — the submit gate is
/// PasswordRequirement.allMetBy, and this must never drift into a validator.
/// Four bands, not five: case is one bar (mixed case), matching the design's
/// 4-segment meter.
int passwordStrengthScore(String password) {
  var score = 0;
  if (PasswordRequirement.minLength.isMetBy(password)) score++;
  if (PasswordRequirement.uppercase.isMetBy(password) &&
      PasswordRequirement.lowercase.isMetBy(password)) score++;
  if (PasswordRequirement.number.isMetBy(password)) score++;
  if (PasswordRequirement.symbol.isMetBy(password)) score++;
  return score;
}
```

The meter's segment colours run `statusColors` (error → warning → success); colour is never
the sole indicator — a semantic label speaks "Password strength: N of 4".

### Submit

```
offline check (isOfflineProvider → offline notice, BEFORE the flag)
  → validate (names required? mirror the invite sheet: first required, last required;
     password rules; confirm match; consent already gated the button)
  → _isLoading = true (synchronously)
  → authService.signUpWithCode(
      email: preview.email, password, code: args.code,
      firstName, lastName, phone,
      termsAccepted: true, locationConsent: true)
  → TextInput.finishAutofillContext()          // success only — never in catch
  → resumeAfterSignUp() via signInControllerProvider:
      SignInSuccess  → pushNamedAndRemoveUntil(mainCalendar, (_) => false,
                        arguments: MainCalendarArgs(...))
      SignInProfilePending → pop to login + success banner request
        (popUntil((r) => r.settings.name == AppRoutes.login) — login is always
         beneath this flow, both entry paths)
  → catch: AuthErrorMapper.map → logger.authFailure → banner; _isLoading reset.
```

Failure branching worth spelling out: `AuthFailureInvalidSignupCode` /
`AuthFailureSignupCodeExpired` here means the code died between preview and submit (expired in
the window, or revoked, or redeemed elsewhere) — the screen banners it and offers "Re-enter
code" (pop back to the code screen). `AuthFailureSignupEmailMismatch` should be near-impossible
now (the email came from the invite itself) — if it fires, something re-issued the invite for a
different email mid-flow; banner it verbatim. The rollback path
(`AuthFailureAccountCreationIncomplete`) surfaces its existing message.

**The kick-out guard does not fire during acceptance** — worth restating because it looks
scary: between `register()` and `redeemSignupCode` committing, the signed-in user has no
readable users doc, which is exactly the bootstrap window `isAccountDeletionSignal` was built
to ignore (first-seen empty doc ≠ deletion). Don't add any "wait for doc" logic here; the
controller flow already handles it.

New ARB pairs (EN/FR + `@key`): `auth_acceptInviteTitle`, `auth_invitedToJoinAs` (placeholder
`role`), `auth_inviteExpiresOn` (placeholder `date`), `auth_fromInvite`,
`auth_termsAndLocationConsent` (the combined checkbox copy — final wording from the mockup),
`auth_reEnterCode`, `auth_roleAdmin`, `auth_roleEmployee` (reuse existing role labels if
present in the `employees_` bucket rather than minting duplicates — check first).

- [ ] **Step 1:** `password_strength.dart` + test (0 for empty, 4 for `Aa1!aaaa`, case counts
  as one band).
- [ ] **Step 2:** `PasswordStrengthMeter` (segments animate under `AppDuration`, instant under
  `disableAnimationsOf`; semantic label).
- [ ] **Step 3:** Screen + route + args per above.
- [ ] **Step 4:** ARBs + gen-l10n.
- [ ] **Step 5:** Widget tests: consent unchecked ⇒ button disabled; locked email is not a
  text field (no `TextField` for it in the tree); submit passes profile + consent flags to a
  mocked `AuthService`; a redeem failure banners and re-enables; success calls
  `finishAutofillContext` path (assert navigation intent via mocked controller outcome).
  Screen tests need the l10n delegates + `ThemeNotifier` harness;
  `FlutterSecureStorage.setMockInitialValues({})` is NOT needed here (no storage read) —
  don't cargo-cult it in.
- [ ] **Step 6:** Analyze/test green; commit `feat(p4b): invite acceptance details screen`.

---

## Task 6: Accept your invite — code entry, and the flow goes live

**Files:**
- Create: `lib/features/auth/screens/accept_invite_code_screen.dart`,
  `lib/features/auth/widgets/code_entry_boxes.dart`
- Modify: `lib/routes/app_routes.dart` (route + `AcceptInviteCodeArgs{initialCode}`)
- Modify: `lib/features/auth/screens/login_screen.dart` (the prompt now pushes the code
  screen; the create-account plumbing retires)
- Delete: `lib/features/auth/screens/create_account_screen.dart`
- Modify: ARBs
- Test: `test/features/auth/screens/accept_invite_code_screen_test.dart` (new);
  `test/features/auth/screens/create_account_screen_test.dart` → retargeted onto the two new
  screens (delete only what Task 5's tests already re-cover);
  `auth_screens_scale_sweep_test.dart` swaps `CreateAccountScreen` for the two new screens

Gated on Tasks 0, 5. No functions/rules changes.

### `CodeEntryBoxes` — one field, twelve boxes

One **hidden `TextField`** owns focus, the keyboard, and paste; the twelve boxes are painted
from its value. Twelve separate fields would mean eleven focus hand-offs, broken paste, and a
backspace nightmare — the single-field pattern is standard and testable. Specifics:

- `autocorrect: false`, `enableSuggestions: false`, `textCapitalization:
  TextCapitalization.characters`, `keyboardType: TextInputType.visiblePassword` (kills the
  predictive bar over the boxes — the mobile-use requirement names exactly this),
  `inputFormatters`: uppercase + strip non-`[0-9A-Z]` + `LengthLimitingTextInputFormatter(12)`
  (the strip means a pasted `XXXX-XXXX-XXXX` lands as 12 clean chars).
- Boxes render `theme.monoType.data`; groups of four separated by wider gaps; the active box
  carries the focus ring; `hasError` turns every box's border `scheme.error` (the input-error
  red is the *foreground* slot — correct here).
- Tapping anywhere in the row focuses the hidden field. The row's `Semantics` speaks
  "Signup code, N of 12 characters entered" — twelve decorative boxes are one logical field.
- The whole widget is theme-token-only and holds scaled text: box height derives from the
  text style's line height, not a constant.

### The screen

`AuthScaffold`. Title + subtitle, the boxes, the CTA (relabels
`auth_enterTheCode` → `common_continue` when `isCompleteSignupCode` is true; disabled until
full), the error state, and the `DON'T HAVE A CODE?` panel (`MonoSectionLabel` +
body copy: the admin can read the code off the Team page — no email exists to resend).

**Continue** (owner decision 1 = (a)):

```
offline check → _isLoading (sync) →
repo.previewInvite(normalizeSignupCode(text))
  ok → pushNamed(acceptInviteDetails, AcceptInviteDetailsArgs(code, preview))
       — push, don't pushReplacement: back from details must return HERE with
       the code intact, per "the code screen must pass the code forward so
       acceptance never re-asks".
  AuthFailureInvalidSignupCode  → boxes red + auth_codeInvalidExplanation
  AuthFailureSignupCodeExpired  → boxes red + auth_codeExpiredExplanation
  AuthFailureTooManyRequests / Network → banner (existing messages)
catch-all: AuthErrorMapper.map → logger.authFailure → banner.
```

The preview call is what lets the boxes distinguish *expired* from *invalid* before the user
invents a password — the server truth the design's red-boxes state needs. Under decision 1 =
(b), Continue validates format only and pushes; delete the preview branch and the details
screen gains an email field (amend Task 5 first).

`initialCode` (from the deep link) prefills the boxes and — when complete — leaves the CTA
armed but does NOT auto-submit: a link may carry a stale code, and auto-firing a rate-limited
call on open burns preview slots for nothing the user asked.

### Login rewiring and the retirement

- `_AcceptInvitePrompt` now pushes `AppRoutes.acceptInviteCode`.
- `_openCreateAccount`, `_routeAfterSignUp`, and the `CreateAccountResult` plumbing leave
  `login_screen.dart` — the details screen owns post-signup routing (Task 5). The
  `SignInOutcome` switch keeps its `SignInNoSession`/`SignInProfilePending` arms (sealed —
  the compiler requires them; they're now produced only for the details screen's caller).
  `resumeAfterSignUp` itself is untouched.
- Delete `create_account_screen.dart`. Sweep its imports (`login_screen.dart` only) and
  retarget its tests: the rollback/redemption coverage lives in `auth_service_test` (kept),
  the form-validation coverage moves to the two new screens' tests, the scale sweep swaps
  screens.

New ARB pairs: `auth_enterTheCode`, `auth_codeInvalidExplanation`,
`auth_codeExpiredExplanation` (mentions the admin can issue a fresh one),
`auth_dontHaveACode` ("DON'T HAVE A CODE?"), `auth_dontHaveACodeBody`,
`auth_signupCodeSemantics` (placeholder `count`). Reuse `common_continue` if it exists —
check before minting.

- [ ] **Step 1:** `CodeEntryBoxes` + widget test (typing fills boxes; paste of
  `ABCD-EFGH-JKMN` yields 12; error paints all borders; semantics label).
- [ ] **Step 2:** Screen + route; Continue flow per above.
- [ ] **Step 3:** Login rewiring; delete the old screen; retarget tests.
- [ ] **Step 4:** ARBs + gen-l10n.
- [ ] **Step 5:** Scale-sweep both new screens (add to the auth sweep file — the harness and
  viewport are already there).
- [ ] **Step 6:** Analyze/test green; commit
  `feat(p4b): code entry screen and the acceptance flow goes live`.

---

## Task 7: Deep-link delivery layer

**Files:**
- Modify: `pubspec.yaml` (`app_links: ^7.2.1`)
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `lib/core/deep_links/deep_link_target.dart`,
  `lib/core/deep_links/deep_link_dispatcher.dart`,
  `lib/core/navigation/top_route_observer.dart`
- Modify: `lib/main.dart`
- Test: `test/core/deep_links/deep_link_target_test.dart` (new),
  `test/core/deep_links/deep_link_dispatcher_test.dart` (new — pure routing decisions;
  the plugin stream is device-only)

Gated on Task 6 (the invite target route must exist). No functions/rules changes.
`flutter pub get` after the dependency change **needs the sandbox disabled** (known
plugin-symlink failure on this box).

### Delivery mechanics

- **iOS:** the `esproschedule` scheme is already in `CFBundleURLTypes`, and
  **`FlutterDeepLinkingEnabled` stays `false` — that is the correct setting FOR `app_links`**
  (Flutter's own deep-link handler would consume the URL first). `AppDelegate` gets no
  `open url` override; the plugin handles it. No Info.plist change at all.
- **Android:** add to `MainActivity` (already `launchMode="singleTop"`, which is what
  app_links wants):

  ```xml
  <intent-filter>
      <action android:name="android.intent.action.VIEW"/>
      <category android:name="android.intent.category.DEFAULT"/>
      <category android:name="android.intent.category.BROWSABLE"/>
      <data android:scheme="esproschedule"/>
  </intent-filter>
  ```

  Custom scheme ⇒ no `autoVerify`, no assetlinks. Android is the dev harness; this is also
  how the flow gets exercised without a Mac (`adb shell am start -a android.intent.action.VIEW
  -d "esproschedule://invite?code=..."`).

### `classifyDeepLink` — pure and pinned by tests

```dart
sealed class DeepLinkTarget {}
class AppointmentLink extends DeepLinkTarget { final String id; }
class InviteLink extends DeepLinkTarget { final String code; }
class IgnoredLink extends DeepLinkTarget { const IgnoredLink(); }

DeepLinkTarget classifyDeepLink(Uri uri) {
  if (uri.scheme != 'esproschedule') return const IgnoredLink();
  // The home_widget channel owns widget/Live-Activity/Siri taps until the two
  // retire together (ios/CLAUDE.md). Handling them here too would open the
  // appointment sheet twice per tap — both plugins observe the same openURL.
  if (uri.queryParameters.containsKey('homeWidget')) return const IgnoredLink();
  return switch (uri.host) {
    'appointment' => AppointmentLink(uri.queryParameters['id']?.trim() ?? ''),
    'invite' => InviteLink(uri.queryParameters['code']?.trim() ?? ''),
    _ => const IgnoredLink(),
  };
}
```

Tests: each host, the `homeWidget` skip (with and without a value — `?homeWidget` and
`&homeWidget=x` both skip), foreign scheme, missing params.

### The dispatcher

One class, constructed in `_PaulAppState.initState` beside `_setupWidgetTapHandling`, given
callbacks rather than reaching into the state:

- Listens `AppLinks().uriLinkStream` — **with `onError`**
  (`(Object e, StackTrace st) => logger.warn('DEEP-LINK stream error', e, st)`), the raw-listen
  rule — and awaits `AppLinks().getInitialLink()` for cold start, both funneled through one
  `_handle(Uri)` inside a try/catch that warns with tag `DEEP-LINK` (mirrors
  `_handleWidgetTap`'s swallow-don't-crash posture).
- `AppointmentLink` → the existing `_openAppointmentDeepLink(id)` **unchanged** — it keeps its
  `currentUser == null` early return and `_awaitLiveHub` wait; those guards are correct for a
  signed-in-only surface.
- `InviteLink` → the **signed-out path**, which explicitly bypasses both guards:

  ```
  if (FirebaseAuth.instance.currentUser != null):
      await _awaitLiveHub(); notice(auth_signOutToAcceptInvite)   // decision 3
  else:
      await _awaitLoginRoute();          // TopRouteObserver poll, ~10s cap
      navigatorKey.currentState?.pushNamed(
          AppRoutes.acceptInviteCode,
          arguments: AcceptInviteCodeArgs(initialCode: code));
  ```

  **Why the wait is load-bearing:** on a cold start the stack is
  `OnboardingGate → SplashScreen`, and splash routes with `pushReplacementNamed`, which
  replaces the **topmost** route — push the code screen too early and splash's post-frame
  navigation replaces the invite screen itself. `SplashScreen` also signs out nobody here (the
  user IS signed out; splash's active-doc kick-out concerns signed-in sessions), so the only
  hazard is the navigation race, and waiting for `/login` to be the observed top route closes
  it. First-launch onboarding: the gate shows onboarding INSIDE the home widget (no route
  change), so `/login` never becomes current until the user finishes — the 10s cap expiring
  silently is acceptable (the user still holds the code and can tap "Accept your invite"
  manually; log a breadcrumb, not an error).

`TopRouteObserver` is a ~20-line `NavigatorObserver` recording the current top
`RouteSettings.name` on push/pop/replace, registered via `MaterialApp.navigatorObservers`
(none exist today). Its `currentRouteName` is what `_awaitLoginRoute` polls (200 ms, 50
iterations — the `_awaitLiveHub` pattern).

### What is deliberately NOT done

- The `homeWidget` param and the `home_widget` tap channel are untouched (deviation table).
  The dispatcher's skip rule is the whole interaction between the two systems.
- No https/universal links — the store-fallback page ships with the deferred email project.

New ARB pair: `auth_signOutToAcceptInvite` (EN "Sign out first to accept an invite." /
FR "Déconnectez-vous d'abord pour accepter une invitation.").

- [ ] **Step 1:** pubspec + pub get (sandbox off); Android manifest.
- [ ] **Step 2:** `classifyDeepLink` + tests.
- [ ] **Step 3:** `TopRouteObserver` + registration + test (push/replace/pop sequence yields
  the right names).
- [ ] **Step 4:** Dispatcher + `main.dart` wiring (stream `onError`, initial link, the two
  branches). Dispatcher tests drive `_handle` with fake callbacks — no plugin.
- [ ] **Step 5:** ARB + gen-l10n; analyze/test green.
- [ ] **Step 6:** Android device smoke test via `adb am start` (cold start + warm, signed-out
  + signed-in). iOS end-to-end is Mac-gated — record it in the handoff's still-open list.
- [ ] **Step 7:** Commit `feat(p4b): app_links delivery layer with one dispatcher`.

---

## Task 8: Pending-invite row on Team

**Files:**
- Create: `lib/features/employees/widgets/cards/pending_invite_tile.dart`
- Modify: `lib/features/employees/screens/employees_screen.dart`
- Modify: ARBs
- Test: `test/features/employees/widgets/pending_invite_tile_test.dart` (new),
  `test/features/employees/employees_screen_test.dart` (extend if present)

Gated on Task 0 (+ owner decisions 2 and 4 confirmed). No functions/rules changes.

### Where it hooks in

The admin roster already renders invited people: `filteredEmployeesProvider` indexes
`allUsersStreamProvider` (= `watchAllUsers()` for admins, which has no status filter), so an
invited row is present today as a plain `EmployeeCard` with the Invited chip. The list's
`itemBuilder` branches: `UserStatus.fromRaw(employee.status) == UserStatus.invited` →
`PendingInviteTile`, else `EmployeeCard` unchanged. Tap on an invited row **toggles expansion
in place** and no longer opens the detail sheet (owner decision 4) — `_onEmployeeTap` gets the
same branch. `EmployeeCard` itself is not touched.

### The tile

Collapsed: dashed avatar (a private `_DashedCirclePainter` — `Paint..style = stroke` dashed
arc in `#C0CAD8`-equivalent token `palette.decorFaint`, initials in `palette.textMuted`; no
crew colour rendered, though the invite HAS reserved one in `usedColors` — the dashing is
visual-only, don't "fix" `_usedColorsFor`), name, Invited chip (existing `UserStatusChip`),
chevron. Expansion animates with `AnimatedSize`/`AnimatedCrossFade`, instant under
`disableAnimationsOf`.

Expanded body:

1. **`INVITE CODE` block** (`MonoSectionLabel`). Initially a **Show code** button. Tapping it
   runs the re-issue (below) and swaps in the code — 19px `monoType.data`, `SelectableText`,
   with a **Copy** pill that relabels **Copied** (the `signup_code_dialog` pattern:
   `Clipboard.setData`, `_copied` flag, button disables). The fetched code lives in the tile's
   `State` only — it survives collapse/re-expand of the SAME tile instance (so re-opening the
   row does not burn a rate-limit slot, owner decision 2) and dies with the list item. It is
   never logged, never put in a provider, never persisted.
2. **Amber caption** on `statusColors.warningContainer`: "Code expires {date}" from
   `employee.codeExpiresAt` (omitted when null — a pre-P4b invite has no stamp until its next
   re-issue; empty-omitted rule). After a re-issue the live stream refreshes the record and
   the caption updates itself — don't hand-patch it.
3. **Resend** — same re-issue call; on success the code block updates and the button relabels
   **New code ready** (no email exists; the admin still shares it out-of-band).
4. **Revoke** — `destructiveOutlinedButtonStyle`, `showConfirmDialog(destructive: true)` with
   body copy stating the code stops working and the person disappears from the roster, then
   `employeeFormControllerProvider.notifier.revokeInvite(employee.id)`. Success needs **no
   notice and no local state change** — the stream drops the row (that IS the confirmation);
   a `invite-not-pending` refusal notices "already used" and the stream shows the row Active.

### The re-issue call — the field-wipe trap

Show code / Resend call the existing
`employeeFormControllerProvider.notifier.inviteEmployee(...)` (idempotent re-issue path).
**Every argument comes from the stored record**, because `performCreateInvite`'s re-issue
branch *updates* `name/firstName/lastName/phone/colorValue/jobTitle/role` with whatever it is
given (decision 7) — passing blanks silently wipes the invited person's phone and title:

```dart
inviteEmployee(
  name: employee.name, firstName: employee.firstName,
  lastName: employee.lastName, email: employee.email,
  phone: employee.phone, colorValue: employee.color.toARGB32().toString(),
  jobTitle: employee.jobTitle.raw, isAdmin: employee.isAdmin,
)
```

A tile test pins this: the mocked controller captures the args and they equal the record's
values. Reentrancy: the tile disables Show code/Resend on `activity.isSaving` and Revoke on
`activity.isRevoking` (both flags already set-before-first-await in the controller); offline
check before each action per the global rule. Each action's failure composes via
`composeErrorNotice` — re-issue reuses `error_introSaveEmployee`/`EMP-CREATE`, revoke uses
`error_introRevokeInvite`/`EMP-REVOKE` — and **the notice never contains the code**.

New ARB pairs (EN/FR + `@key`): `employees_inviteCodeKey` ("INVITE CODE"),
`employees_showCode`, `employees_resendCode`, `employees_newCodeReady`,
`employees_codeExpiresOn` (placeholder `date`), `employees_revokeInvite`,
`employees_revokeInviteConfirmBody`, `employees_inviteAlreadyUsed`. Reuse `common_copied`,
`employees_copyCode`.

- [ ] **Step 1:** Tile widget (collapsed/expanded, dashed avatar painter, code block, copy
  pill, caption, actions). ≥48px targets throughout; the whole tile holds 2.0 scale.
- [ ] **Step 2:** Screen branch (invited → tile; tap toggles expansion; detail-sheet path
  skipped for invited).
- [ ] **Step 3:** ARBs + gen-l10n.
- [ ] **Step 4:** Tests: invited row renders the tile; expand shows Show code; Show code
  passes the record's stored fields (the wipe trap); code renders + Copy relabels; collapse →
  re-expand does NOT re-call the controller; Revoke confirm → controller called; refusal
  notices. Viewport sized tall enough for the expanded body (P4 §8d — the sheet-style inner
  scroll doesn't drag in tests).
- [ ] **Step 5:** Analyze/test green; commit `feat(p4b): pending-invite row on team`.

---

## Task 9: Sweep, document, close out

**Files:**
- Modify: `test/features/auth/screens/auth_screens_scale_sweep_test.dart` (confirm the two new
  screens are in — Tasks 5/6 added them; this step verifies the matrix), new
  `test/features/employees/pending_invite_scale_sweep_test.dart` case if the P4 sweep file
  doesn't cover the expanded tile
- Modify: `CLAUDE.md`, `.claude/rules/error-handling.md`, `docs/ARCHITECTURE.md`
- Create: `docs/plans/redesign-subdocs/2026-08-02-p4b-HANDOFF.md`

No functions/rules changes (the deploy already ran in Task 1 — this task only re-verifies it).

- [ ] **Step 1:** Full matrix: `flutter analyze` (0), `flutter test` (green),
  `cd functions && npm run lint && npm test` (green).
- [ ] **Step 2:** Scale sweeps — the two acceptance screens and the expanded pending row at
  375×667 × {0.8, 1.0, 1.4, 2.0}, `takeException()` null.
- [ ] **Step 3:** `CLAUDE.md` additions (Critical invariants):
  - The deep-link dispatcher is the single `app_links` consumer; it MUST skip URIs carrying
    `homeWidget` (double-open), and the param/channel retire together, later.
  - `codeExpiresAt` / `termsAcceptedAt` / `locationConsentAt` are function-owned user-doc
    fields — on the update denylist; `redeemSignupCode` clears `codeExpiresAt`; consent stamps
    are conditional on the payload flags.
  - Invite re-issue refreshes the invited doc's editable fields — every re-issue call site
    passes the stored record's current values or it wipes them.
  - The invited-users read matrix: expiry is admin-only by construction (clauses 2–4 can't
    reach an invited doc for a non-admin).
  - A displayed signup code is a credential: state-only, never logged, never persisted.
  Update the invited-signup bullet (acceptance screens replaced `CreateAccountScreen`; profile
  + consent ride redeem) and the iOS notes' pointer that the dispatcher now exists but the
  `homeWidget` channel is still live.
- [ ] **Step 4:** `.claude/rules/error-handling.md`: add `EMP-REVOKE` to the tag list and
  `DEEP-LINK` to the log-only tags.
- [ ] **Step 5:** `docs/ARCHITECTURE.md`: auth feature (two new screens, deleted
  create-account), `core/deep_links/`, the pending-invite row, the two new callables.
- [ ] **Step 6:** Write `2026-08-02-p4b-HANDOFF.md` in P3/P4's shape: what shipped (task →
  commit table), deviations, bugs/traps found while building, invariants established, what
  P4b hands P5 (nothing structural expected — note `isAvailabilityOnlyChange` is still
  waiting), still open (**the Mac-side iOS deep-link end-to-end check**, the on-device pass,
  and — if the owner chose decision 1(b) — the parked `previewInvite`).
- [ ] **Step 7:** Re-verify the Task 1 deploy is live (function list includes `revokeInvite`
  (+ `previewInvite`), rules fetch shows the denylist) — if any Task-1 step was skipped or the
  deploy failed silently, THIS is the last gate before ship.
- [ ] **Step 8:** Commit `docs(p4b): close out auth and invites`.

---

## Deploy note (do not skip)

Everything server-side lands and **deploys in Task 1** — inverted from P4's close-out deploy,
on purpose:

| Direction | Compatible? | Why |
| --- | --- | --- |
| **New backend + old (shipped) client** | **Yes** | The widened `redeemSignupCode` allowlist is a superset (`{code}` still valid); `codeExpiresAt` is additive; `revokeInvite`/`previewInvite` are simply uncalled; the rules denylist blocks fields no shipped client writes. |
| **New client + old (live) backend** | **NO** | The live `redeemSignupCode`'s `assertPayloadShape` is `new Set(["code"])` and **rejects unexpected keys** — a build containing Task 2 makes *every invite acceptance fail* `invalid-argument`. Same class of hazard P4 §7 documented for `createEmployeeInvite`, now on the redeem side. |

> **Therefore: Task 1's deploy runs before any later task's build can ship. If for any reason
> the deploy is deferred, the P4 rule applies verbatim — deploy `functions` before shipping a
> build containing Task 2, or ship both together.**

```bash
cd functions && npm run lint && npm test && cd ..
firebase deploy --only functions,firestore:rules,storage
```

- **Never pass `--force`** — it deletes any prod Firestore TTL policy missing from
  `firestore.indexes.json` (this removed all five live policies once, 2026-07-21).
- Omit `firestore:indexes` — the file is unchanged and no new query needs a composite index.
- `storage` is the deploy target, not `storage:rules`.
- This deploy **also carries P4's still-pending changes** (P4 handoff §7 + §8e: the widened
  `createEmployeeInvite`, the `emergencyPhone` rules cap, the withdrawn `/users` delete) —
  running it closes that standing hazard; verify those land too.
- The rules deploy still prints the three `isAvailabilityOnlyChange` warnings (unused
  function + two invalid-variable-name). Expected until P5 wires it; not a regression.
