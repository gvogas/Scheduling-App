# Codebase Audit — 2026-09-28

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`firestore.indexes.json`, `test/`). Baseline: `dev` @ `cee76f45`, clean tree.
Emphasis on the code changed since the 2026-09-23 audit (`6b96db46..HEAD`:
`client_buildings.js`, `bridge_reconcile.js`, `employee_accounts.js`,
`account_operation.js`, the server-paged clients list, `SearchResultCache`).

## Summary
- Reviewed by five parallel lenses (security, bugs, dead code/conventions,
  performance, maintainability) plus the static scan. Every finding below was
  re-traced against the source before it was listed.
- Auto-fixed (safe, in the diff): 1 — a stale comment naming the deleted
  `sortClients`.
- Reported for your decision: 17 (⚠️ 0 pre-ship · 🔴 3 security, all low ·
  🟠 4 bugs · 🔵 10 improvements)
- Verification: `flutter analyze --no-pub` → No issues found · touched test
  file `firebase_clients_repository_test.dart` 45/45 · functions lint clean
  (static scan) · `dart fix` nothing to fix.

## Decide first
**Resolved 2026-09-28:** B1 → `count()`; I1b → past jobs only; S1 → fix in the
function; closed-migration scripts → delete. **Still open:** S4.

- **B1** — the filtered Clients header counts loaded rows as if they were the
  total. Fix it with a `count()` aggregate (one read per filter change) or with
  wording that stops claiming a total? `.claude/rules/clients.md` §161 says
  "loaded rows with no 'of M'", so the rule itself needs a word either way.
- **I1b** — the client "Job history" section lists a repeat client's
  FURTHEST-FUTURE occurrences first (`startTime DESC` over all docs). Is future
  work meant to be in a section called history? The cap fix in I1 interacts:
  with a 60-row window a weekly repeat client would show only future jobs.
- **S1** — close it in the function (skip only on `restore`) or in the rules
  (refuse `active → invited`)? The rules route is a stronger guarantee but
  also blocks a console repair path.

Everything that needs a **functions or rules deploy** is marked; none is
auto-implemented by "do all" until you schedule the deploy.

## Auto-applied cleanups (review the diff)
| File:line | Change | Why |
|---|---|---|
| `lib/features/clients/data/firebase_clients_repository.dart:367` | Comment no longer cites `sortClients` | the symbol was deleted in the 09-23 refactor |

Considered and NOT applied: deleting `AppRadius.r24` (zero references) — the
class is documented "a complete rung ladder; don't prune rungs".

## ⚠️ Pre-ship checklist
None. Zero `TODO(pre-ship)` markers in the tree.

## 🔴 Security findings

### S1 — `active → invited` no longer revokes the Auth credential · low · confidence high (path) / low (exploit)
- **Status:** **DONE — needs functions deploy.** `reconcileAuthAccess` drops the `invited` short-circuit; an invited live doc computes `revoke`. (Deviated slightly: a delayed restore that finds the live doc invited now revokes instead of returning — the fail-safe direction.) Follow-on opened as S4.
- **Where:** `functions/bridge_reconcile.js:55-57`, called from
  `functions/bridge.js:120-133`.
- **Risk:** `authAccessChange(active, invited)` returns `"revoke"`, but
  `reconcileAuthAccess` returns early whenever the LIVE doc is `invited`, so
  neither `updateUser({disabled:true})` nor `revokeRefreshTokens` runs. The
  pre-09-23 code revoked unconditionally. The bridge row is removed, so data
  access is denied — but the person keeps a working credential, the app routes
  `invited` to `AccountSetupScreen`, and `completeEmployeeSetup` can re-activate
  a doc without `setupRequiresPassword` (only stamped on re-provision,
  `employee_accounts.js:183`). Reachable only via a console write or modified
  admin client — no app path writes `invited` onto an active doc.
- **Fix:** skip the `invited` short-circuit unless the computed change is
  `restore`, or refuse `status → 'invited'` from a non-invited doc in the rules.
  Add a `bridge.test.js` case for the transition. **Needs deploy.**

### S2 — setup password now bypasses the console password policy · low · medium
- **Status:** **NOT A DEFECT (verified 2026-09-28)** — server and app checks enforce the same rules (8+, `p{Lu}`, `p{Ll}`, digit); the server adds the 128 cap and control-char reject. Console policy recorded as binding config in `.claude/rules/employees.md`.
- **Where:** `functions/employee_accounts.js:567` (validated at `:534-541`).
- **Risk:** the password is set with Admin-SDK `updateUser`, which Identity
  Platform's password policy does not govern. The only gate is the hand-mirrored
  8+/upper/lower/digit check. If the console policy is ever stricter (it has
  diverged once, 2026-08-21), setup silently accepts what the policy forbids.
- **Fix:** record the console policy as binding in `.claude/rules/employees.md`
  and keep the server check at least as strict; no deploy unless tightened.
  See B2 for the inverse failure.

### S3 — unsalted email hash logged on lock-release failure · low · high
- **Status:** **DONE — needs functions deploy.** Logs `keyHash: shortHash(docId)` + `operation`.
- **Where:** `functions/account_operation.js:33` with the `email_<sha256>` key
  from `employee_accounts.js:240-242`.
- **Risk:** a plain SHA-256 of an email is dictionary-reversible and links log
  records. Fires only when the lock `delete()` fails.
- **Fix:** log `shortHash(key)` or a non-identifying label. **Needs deploy**
  (low priority, can ride the next functions deploy).

### S4 — resetting a demoted account's password leaves it disabled · low · high (NEW, from the S1 fix)
- **Status:** **OPEN — needs your decision.**
- **Where:** `functions/employee_accounts.js` `resetProvisionedPassword` (sets only `password`/`displayName`).
- **Risk:** after S1, an account an admin demotes active→invited in the console has its credential disabled; a later Reset password hands over a password for a still-disabled account, so first sign-in fails.
- **Fix:** add `disabled: false` to the reset's `updateUser` (the admin's reset IS the intent to hand over a working credential). Needs deploy.

## 🟠 Bug findings

### B1 — filtered Clients header states a loaded count as the total · medium · 80%
- **Status:** **DONE** (owner chose `count()`). `countClients(filter:)` counts through `_filteredQuery`; header reads "50 of 120 Commercial clients" until everything is loaded. App-only; existing composites serve it.
- **Where:** `lib/features/clients/widgets/sections/clients_list_header.dart:73-81`,
  fed by `clients_screen.dart:199-201`.
- **Problem:** since the 09-23 server paging, type / Archived / building slices
  load 50 at a time, but `clients_showingType(shown, …)` and
  `clients_inThisBuilding(shown)` still read as a total — "50 Commercial
  clients", then 100, then 120 as you scroll. Same bug `clients_showingSome`
  fixed for the unfiltered list.
- **Fix:** see Decide first. Either a filtered `count()` (same `where` as
  `_filteredQuery`, indexes already exist) passed as `total`, or wording that
  doesn't assert a total until the last page is short.

### B2 — a policy rejection in `completeEmployeeSetup` reaches the app as `internal` · low · 85%
- **Status:** **DONE — needs functions deploy.** Both Auth codes rethrow `invalid-argument / invalid-newPassword`.
- **Where:** `functions/employee_accounts.js:568`.
- **Problem:** Admin-SDK `auth/password-does-not-meet-requirements` /
  `auth/invalid-password` are not `HttpsError`s, so the app shows
  `AuthFailureUnknown` behind a green checklist and files a non-fatal per retry.
- **Fix:** catch around `updateUser` and rethrow
  `HttpsError("invalid-argument", "invalid-newPassword")`, which already maps to
  `AuthFailureWeakPassword`. **Needs deploy.**

### B3 — passwords over 128 chars are rejected as "weak" · low · 80%
- **Status:** **DONE (deviated — cap applied to the two setup fields only, not sign-in, so an existing >128 password can still sign in).** `TextLimits.password = 128`, pinned against the server cap by `text_limits_test.dart`.
- **Where:** `functions/employee_accounts.js:535-536` (`requireString(..., 128)`);
  `AuthPasswordField` has no `maxLength`.
- **Problem:** a password-manager passphrase over 128 characters passes every
  client check, then fails as `invalid-newPassword` → "weak password".
- **Fix:** add `TextLimits.password = 128` and bind the field to it (app-only,
  no deploy).

### B4 — `performDeleteClient` cleanup can mask the real error · low · 85%
- **Status:** **DONE — needs functions deploy.** Cleanup has its own try/catch; the original error is rethrown.
- **Where:** `functions/clients.js:64-71`.
- **Problem:** if the token-clearing transaction in the `catch` throws, its
  error replaces `client-has-history`, so the app loses the "archive it instead"
  branch — and the token stays set, so the rules refuse every update to that
  client until a retried delete.
- **Fix:** wrap the cleanup in its own try/catch that `logger.error`s the
  clientId and still rethrows the original. **Needs deploy.**

## 🔵 Areas to improve

### I1 — client "Job history" reads up to 1000 docs to render 50, and re-reads on every write · high · 90%
- **Status:** **DONE (deviated — added an `onRecordWrite` stream rather than filtering `onLocalWrite`).** Window `limit: 61, cap: 60`, keeps 50; I1b resolved: past jobs only (`pastOnly: true`, `startTime < clock()`).
- **Where:** `lib/features/clients/application/appointment_history_providers.dart:81-93`;
  `firebase_appointments_repository.dart:548-583`;
  `client_job_history_section.dart:90,98`.
- **Opportunity:** no `cap` is passed, so `pageToCap` reads to 1000 (two round
  trips past 500) while the section renders `take(50)`. It also
  `invalidateSelf()`s on every `onLocalWrite`, including photo and field-note
  pokes that change nothing it shows. A 300-visit client opened, then 3 jobs
  completed from it ≈ 1,200 reads.
- **Suggested improvement:** `fetchClientHistory(clientId:, limit: 61, cap: 60)`
  (headroom for the Dart-side `dayIndex` filter; explicit cap turns the cap-hit
  into a breadcrumb), and stop invalidating on the `_notifyLocalWrite` pokes.
  Resolve **I1b** (Decide first) in the same change.

### I2 — live-map roster geocodes at ~110 m to show a city name · medium · 85%
- **Status:** **DONE.** Roster rows key at 2 decimals (`kCoarseGeocodePrecision`); `StaffFocusPanel` keeps 3.
- **Where:** `lib/features/maps/application/maps_providers.dart:17-23`;
  `lib/features/presence/widgets/live_map_team_sheet.dart:278-289`.
- **Opportunity:** each ≥250 m presence move lands in a new 3-decimal cell → a
  billed Geocoding call + a rate-limit transaction. Ten driving techs can burn
  the 120/h per-admin cap (`functions/places.js:34-35`) in ~25 min, after which
  roster rows AND `StaffFocusPanel` read "No location" for the rest of the hour.
- **Suggested improvement:** key the roster row on a coarse cell (1–2 decimals);
  keep 3 decimals for the single-person `StaffFocusPanel` address.

### I3 — phone-only client propagation is untested · medium · high
- **Status:** **DONE.**
- **Where:** `functions/client_propagation.js:135`;
  `__tests__/client_propagation.test.js:193` (titled "name **or phone**" but
  passes only `clientName`).
- **Suggested improvement:** add a `{clientPhone}`-only case asserting
  `patch.clientPhone` and a phone token in `historySearchScopes` — the
  documented search-by-phone regression area.

### I4 — `cancelCustomerUpsert` guard is mocked everywhere, tested nowhere · medium · high
- **Status:** **DONE.** Verified by breaking the guard: a test fails.
- **Where:** `functions/wave/enqueue.js:119-131`; mocked in
  `__tests__/wave_triggers.test.js:14`.
- **Suggested improvement:** three cases in `wave_enqueue.test.js`: missing doc
  → false; `inflight` → false and not deleted; `queued` → deleted.

### I5 — an open History search re-runs `searchHistory` on every status write · low · 85%
- **Status:** **DONE (deviated — a cached answer is DROPPED, never inserted into, when a doc it lacks may now belong; only the server query can decide membership).** `SearchResultCache.patchAll`.
- **Where:** `appointment_history_providers.dart:39-54`;
  `firebase_appointments_repository.dart:95-112` (`_patchWindow` clears
  `_searchCache`).
- **Opportunity:** each re-run is up to 200 reads + a rate-limit transaction,
  though the write touched one doc. Admin-only and short-lived, so modest.
- **Suggested improvement:** patch cached callable results by id (drop a doc no
  longer terminal, merge the rest) instead of clearing.

### I6 — the Material app-chooser sheet is hand-written twice beside a helper that has one · low · high
- **Status:** **DONE.** Material fallback loses the drag handle / `sheetStyle` — test-only path on an iOS-only app.
- **Where:** `lib/core/launchers/email_compose_launcher.dart:~50-110`,
  `address_map_launcher.dart:~64-125`, vs `core/adaptive/adaptive_action_sheet.dart:~50`.
- **Suggested improvement:** call `showAdaptiveActionSheet` unconditionally and
  delete both `else` branches (~90 lines). Launcher widget tests default to the
  Material path — update their finders.

### I7 — split the two ~890-line functions modules along the existing `*_policy.js` line · low · high
- **Status:** **DONE.** `travel_policy.js`, `notification_sweeps.js` (lazy re-export to avoid a require cycle); export set unchanged.
- **Where:** `functions/travel_utils.js` (887 — pure decisions `:125-420`, I/O
  sweeps `:420-887`); `functions/notification_utils.js` (891 — delivery core vs
  the three sweeps at `:545`, `:604`, `:682`).
- **Suggested improvement:** `travel_policy.js` and `notification_sweeps.js`.
  Split-on-touch; no behaviour change.

### I8 — `backfill-client-sort-fields.js` has no dry-run test · low · high
- **Status:** **DONE.**
- **Where:** `functions/scripts/backfill-client-sort-fields.js` (0% coverage;
  its policy is covered). A recurring release prerequisite, run live 3×.
- **Suggested improvement:** one "dry run writes nothing" test, matching the
  other backfills.

### I9 — three discarded microtasks touch `ref`/`state` outside their `try` · low · low
- **Status:** **DONE.**
- **Where:** `lib/features/calendar/.../event_details_controller.dart:100-101,122`
  (bodies at `:144`, `:178`, `:200`).
- **Suggested improvement:** `if (!ref.mounted) return;` first line in each, on
  next touch. Theoretical today — the microtask runs before autoDispose teardown.

### I10 — two-button dialog footer copied 3× · low · high
- **Status:** **DONE.** `shared/widgets/dialogs/dialog_action_pair.dart`.
- **Where:** `busy_conflict_dialog.dart:135`, `personal_block_clash_dialog.dart:290`,
  `series_scope_dialog.dart:~95` (`Size(double.infinity, 44)` spelled only there).
- **Suggested improvement:** a small `DialogActionPair` in `shared/widgets/dialogs/`.

## 🟡 Code-quality suggestions (optional)
Status 2026-09-28: retracted packages **DONE** (`cupertino_ui` 1.1.1, `material_ui` 1.5.0); closed-migration scripts **DONE — deleted** (owner call); raw `EdgeInsets` **NOT A DEFECT** — an accepted exemption in `.claude/rules/frontend.md`; test-only symbols, long comments and long `build()`s left for trim/split-on-touch.

- `pubspec.lock` resolves two **retracted** versions: `cupertino_ui 1.1.0`
  (1.1.1 available) and `material_ui 1.3.0` (1.5.0). A `flutter pub upgrade` of
  those two plus analyze/test.
- ~700 multi-line `//` comment blocks remain in `lib/` against the one-line rule
  (worst: `details_edit_body.dart` 21, `clients_list_view.dart` 15,
  `details_view_body.dart` 13, `firebase_employees_repository.dart` 13).
  Manual trim-on-touch, not a sweep.
- ~32 raw `EdgeInsets` numbers, mostly off-grid (13/14/15/18/25) with no
  `AppSpacing` rung — token choice is a judgment call.
- Test-only symbols (dead in production): `searchQueryTokens`
  (`core/search/search_tokens.dart:7`), `monthGridMaxRows`
  (`month_grid.dart:5`), `HubShell.currentTab` (`hub_shell.dart:64`). Keep
  `allTourScopes` (tour storage keys) and `ClientsSort.requiresBackfill`
  (documents the backfill).
- Retirement candidates in `functions/scripts/` whose migrations are closed:
  `count-legacy-image-urls.js`, `clear-appointment-picture-arrays.js`,
  `backfill-appointment-images.js`, the one-time client-name repair scripts.
- 64 of 351 `build()` methods exceed 60 lines; the top six are the ones the
  09-19 audit (I8) chose to leave. New since then, split on touch:
  `dashboard_screen.dart:145` (97), `notifications_settings_card.dart:53` (96),
  `employee_profile_card.dart:29` (96), `additional_contacts_section.dart:52` (96).

## Checked and sound
- `syncClientBuilding`: reconciles from live docs in one transaction, no
  self-write loop, zero reads on irrelevant updates; the `jobCount: 0` stamp
  cannot clobber a concurrent recount. Dart/JS building-key mirror agrees and
  both suites read `test/fixtures/client_building_cases.json`.
- Every clients query shape (page × filter × sort, callable filters) has a
  composite in `firestore.indexes.json`.
- All 16 callables enforce App Check with the composed guards; `clientBuildings`
  admin-read / no write; `clientBuildingMemberships` and `accountOperations`
  default-deny; `buildingKey`/`deletionToken` refused on client writes;
  `storage.rules` create-only for assignees.
- `SearchResultCache` generations and shared pending loads behave as documented.
- No secrets tracked; `npm audit --omit=dev` 0 vulnerabilities.
- l10n: EN/FR 911/911 keys, zero orphans. No BOMs, no `throw Exception(`, only
  the three sanctioned SnackBars, no `ref.read` in a `catch`, every `.listen`
  has `onError`, every log tag is in the registry, nothing undisposed.

## Notes / uncertainties
- `flutter analyze` inside `static_scan.sh` printed no result on this box: `pub
  get` needs symlink support (Windows Developer Mode off). Analyze was re-run
  with `--no-pub` and is clean. The scan's zero-inbound-imports heuristic was
  still running at report time; the dead-code lens's symbol scan covered it.
- Full `flutter test` / `jest` were not re-run — the only change is a comment.
- No iOS build or device pass (Windows workstation).
