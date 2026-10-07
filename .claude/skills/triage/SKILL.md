---
name: triage
description: >-
  Diagnose pasted Flutter/Firebase runtime errors for this app using its
  known error-to-cause map before touching code. Use whenever the user pastes
  an I/flutter log, a [cloud_firestore/...] or [firebase_functions/...]
  error, a Crashlytics fatal, a failed GitHub Actions run, l10n generation
  errors, or says "I get this error when..." — even if they ask for a fix
  rather than a diagnosis. Root-cause first (rules, App Check token, index
  still building, token propagation, an undeployed backend), then fix.
---

# Error Triage Map

Order of operations: (1) match the pasted error against the map below,
(2) gather evidence — Firebase MCP `functions_get_logs` for callable errors,
`firestore.rules` for permission errors, `firestore_list_indexes` for a query
error — (3) state the root cause with that evidence, (4) then fix. If the
evidence contradicts the map, follow the evidence; the map is priors, not
verdicts.

**Ask one question before the map: is the backend actually deployed?** This
repo routinely carries an undeployed `functions/` + `firestore.indexes.json`
across several releases, so "the code is right and it still fails" is most
often a deploy or a prod backfill that has not been run — not a bug. Check
`docs/DEPLOYMENT.md`'s deploy log and `functions_list_functions` before
reading code.

## `[cloud_firestore/permission-denied]`

Check in this order — all of these have caused this exact error here before:

1. **Query-vs-rules mismatch.** List/query rules evaluate against query
   *constraints*, not document data. A query missing a `.where()` that the
   rule requires (e.g. `status == 'active'`, or one of the **three** `users`
   read clauses — admin, `status == 'active'`, own doc) rejects the whole
   query. See `watchEmployees()` for the corrected pattern.
2. **Unregistered App Check debug token.** Writes and uncached reads fail
   while cached reads succeed — which makes it look collection-specific.
   Re-register in Console → App Check → Manage debug tokens.
3. **Right after sign-in:** auth-token propagation race. Retry via
   `retryAsync`/`retryStream` (`lib/core/utils/retry.dart`), whose default
   `retryWhen` is the shared `isAuthPropagationDenied`. Never hand-roll a
   local predicate or an inline catch-then-delay.
4. **During sign-out or account deletion:** expected. Revoking the token
   denies any snapshot stream still attached, and `isFatalUnhandledError`
   already classifies it non-fatal. Not a bug unless it fires outside teardown.
5. **Surfacing as generic "Something went wrong" in an auth flow:**
   `AuthErrorMapper` only maps `FirebaseAuthException`; a Firestore rules
   rejection falls through to `AuthFailureUnknown`. Check `firestore.rules`
   first, not Auth error codes.

## `[cloud_firestore/failed-precondition]` — "query requires an index"

The composite is missing **or still building**. Run `firestore_list_indexes`
on the collection group and read the state: `CREATING` is not `READY`, and the
app fails identically for both. A deploy can add an index but never delete one,
and `--force` is banned here.

## `[firebase_functions/...]`

- **`unexpected-field`** — `assertPayloadShape` rejected a key the deployed
  allowlist does not know. Almost always version skew: a shipped build sends a
  field the backend has not been deployed to accept, or an allowlist entry was
  removed while an old build still sends it. Removing a key is a **breaking**
  change — see the `#compat-<version>` carve-out rule in
  `.claude/rules/security.md` before "fixing" the client.
- **`resource-exhausted` / rate limited** — `enforceDurableRateLimit` counters
  live in `rateLimits/*`. Every limiter is durable now, so the cap is real and
  shared across instances; read the counter doc before assuming a bug.
- **`wave/not-bootstrapped`** — run `waveBootstrap` (admin, Settings).
  **`wave/business-ambiguous`** — the `WAVE_BUSINESS_NAME` secret must
  resolve to exactly one Wave business.
- **A Wave dead-letter that never drains** — its cause is *stored* on the doc
  (a blank composed name, a `waveCustomerId` deleted in Wave). Retrying cannot
  fix stored data: repair the doc, then have the admin press "Retry failed".
  Verify by the **absence** of a dead-letter line after `WAVE-RETRY requeued`.
- **`failed-precondition` / `internal`** — read the function's logs
  (MCP `functions_get_logs`) before guessing; the client-side message is
  usually truncated.

## Account setup / sign-in failures

- **Setup rejects a generated starting password** — check the **Identity
  Platform password policy in the Firebase console FIRST.** It is binding
  config that lives nowhere in the repo, and a console/code mismatch took the
  invite flow down once with no code defect at all.
- **An `invited` employee is signed out instead of reaching setup** — the
  `employee.isInvited` exact-match test must run BEFORE the active gate, at
  both `splash_controller.dart` and `sign_in_controller.dart`.
- **An invited employee is kicked out mid-activation** — the deletion signal
  needs a *populated→empty* transition; someone simplified
  `isAccountDeletionSignal` back to `doc.isEmpty`.

## Crashlytics fatals

- **`StateError` / "used after being disposed" from a timer or callback** — a
  `ref.read` ran after an `await`. Riverpod 3 throws unconditionally on an
  unmounted consumer, so the provider must be resolved BEFORE the first await
  (logger, notice service, repository, `AppLocalizations`). See
  `.claude/rules/error-handling.md`; this shipped as a real fatal.
- **A fatal from a discarded future** — `unawaited(...)`, `Future.microtask`,
  a fire-and-forget `sync()`, or an `async` method wired to a `ValueChanged`.
  Nothing is left to catch it, so an `await` hoisted **above** the `try` goes
  straight to the zone handler. Put every await inside the guard.
- **Keychain `-25308` on cold start** — a pre-first-unlock read. Secure storage
  is `first_unlock_this_device` and `isKeychainLockedError` classifies this as
  log-only; if biometrics silently did not engage, check that both `AppLock`
  lifecycle gates still honour the unresolved tri-state.

## Behaviour that fails silently (no error at all)

- **Search returns nothing for clients or closed jobs that visibly exist** —
  either `functions/scripts/backfill-search-tokens.js` has not been run against
  those docs, or `searchIndexTokens` (Dart) and `functions/search_tokens.js`
  have drifted. Both sides are hand-mirrored; a divergence is silent by design.
- **A just-created or server-edited client cannot be found** — a server write
  path did not maintain `searchTokens` / `historySearchScopes`.
- **A very broad query returns the wrong slice** — the read cap warns at the
  bound. Look for that warn before calling it a matcher bug.
- **Save spins forever** — an awaited Firestore write only resolves on server
  ack, so the offline guard must fail fast BEFORE the in-flight flag is set.
- **A button stays disabled, or a double-tap wrote twice** — the reentrancy
  flag was not reset on an early return, or was set after the first await.
- **A rule that never runs on a seeded field** — anything wired to `onChanged`
  is skipped when the field is populated programmatically.

## Build & tooling failures

- **A GitHub Actions run failed on push** — CI runs `flutter analyze`,
  `dart run tool/test.dart --coverage` (the sharded suite), `npm run lint`,
  `npx jest` and the emulator rules smoke test. A test that fails only in the
  sharded run is leaning on state another file left behind — see "Shard
  isolation" in `.claude/rules/testing.md`. Reproduce with
  those locally before reading the log twice. If they are green locally, the
  difference is the workflow file itself — a bootstrap step referencing a
  deleted file, or a pinned `flutter-version` that differs from the local SDK.
- **`flutter gen-l10n` errors** — a bare key missing its `@key` metadata block
  (`required-resource-attributes: true`), or EN/FR out of lockstep; check
  `lib/l10n/.gen/untranslated.json` for drift.
- **"LayoutBuilder does not support returning intrinsic dimensions"** (or a
  release-mode paint-time null-check on a scroll viewport) — a
  `LayoutBuilder`-based widget (`AutoSizeText`) under
  `IntrinsicHeight`/`IntrinsicWidth`. See the frontend rules.
- **A widget error that never reaches the console** — `FlutterError.onError`
  routes to Crashlytics, not stdout. Temporarily add
  `FlutterError.dumpErrorToConsole(details)` in that handler, or read
  Crashlytics via the MCP tools.
- **An iOS build or CocoaPods question** — there is no Podfile and never will
  be; the project is SPM-only (`ios/CLAUDE.md`). There is no `android/` and no
  Gradle either: an Android-shaped error means a `flutter` command regenerated
  that directory, which is a secret-leak hazard to clean up, not a build to fix.

## Ground rules

State the diagnosis and its evidence before editing anything. Cheap checks
first — deploy state, logs, rules, index state, console config. Most of these
are configuration, deploy or backfill issues where a code "fix" would be wrong.
