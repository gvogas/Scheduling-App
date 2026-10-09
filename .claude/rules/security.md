---
alwaysApply: true
---

# Security

## Input and payloads

- Validate all user input at the system boundary; never trust data from the UI directly.
- On every Cloud Function callable, reject a non-object, >4 KB or unexpected-key payload with `assertPayloadShape` and validate string fields with `requireString` (trim, length cap, control-char reject) or `readSessionToken` (length cap, control-char reject, returned untrimmed) before use.
- Treat REMOVING a key from an `assertPayloadShape` allowlist as a BREAKING change, not a tightening — it throws `unexpected-field`, so the allowlist must stay a SUPERSET of the deployed one (`docs/DEPLOYMENT.md` §4a). (ADR-0038)
- Neutralize a field where it is USED instead (stop reading it; hard-code the safe value), leave it ACCEPTED AND IGNORED in the set, and tag the entry `#compat-<version>` so the carve-out is greppable. (ADR-0038)
- Retire a `#compat-<version>` entry only when BOTH hold: the current client sends no such key, AND no build at or below that version remains in the fleet — the second is easy to assume rather than verify, and getting it wrong breaks every stale device on deploy. Retiring is a backend change with its own deploy; it never rides along with the app build that stopped sending the field. (ADR-0038)
- Validate image uploads by magic bytes (JPEG `FF D8 FF`, PNG `89 50 4E 47`, `lib/core/images/image_magic.dart`), never by extension alone; the upload pipeline is in `.claude/rules/images.md`.

## Secrets, auth and client data

- Never read `isAdmin` or a user's role from SharedPreferences — always re-read from Firestore.
- Never cache or store authentication tokens manually; FirebaseAuth manages them.
- Never log secrets, API keys, tokens, passwords or PII.
- Set `enableIMEPersonalizedLearning` to `kCredentialImePersonalizedLearning` (`lib/core/security/credential_input.dart`) explicitly and unconditionally on every `TextField` that receives a credential, beside `obscureText`, never a bare `false` — every password field has a Show/Hide toggle, so `obscureText` (and `keyboardType: visiblePassword`) is no proxy, and a field rendering its characters lets a third-party keyboard retain and cloud-sync them. (ADR-0042)
- Route all Firestore writes through service classes; never call `FirebaseFirestore.instance` from UI.
- Never commit or read `dev/firebase.local.json` or `google-services.json` — they are gitignored for a reason. Build config is `--dart-define-from-file`, so nothing ships as a readable IPA asset. (ADR-0012)

## Callable guards

- Keep the guard ORDER: auth → `assertAdmin` → `assertPayloadShape`/`requireString` → `enforceDurableRateLimit` → work. Validate the payload BEFORE consuming a rate-limit slot, so malformed bursts can't exhaust a legitimate caller's window; keep identity guards above the limiter, so non-privileged callers can't burn slots.
- Open every admin-only callable with `assertAdminCall(req, allowedKeys)` (`functions/security.js`), which fixes the first three steps and returns the uid for the limiter — an un-composed `assertAdmin` gate can be deleted with every test green. (ADR-0040)
- Prove the composer's order against the real `assertAdmin` (`assert_admin.test.js`); in callable suites stub the COMPOSER — stubbing `assertAdmin` alone intercepts nothing (the composer holds a module-internal reference), so every gate assertion passes vacuously. (ADR-0040)
- Open every SELF-SERVICE callable with `assertActiveCall(req, allowedKeys)`: auth → `assertPayloadShape` → the `usersByUid/{uid}` bridge row, refusing anyone not `active`, returning the profile (`role`/`docId`). (ADR-0040)
- `assertActiveCall` proves a live account, NEVER access to a particular document — keep per-doc scoping at the call site: `mayRestore` requires the caller be assigned, `findAppointmentConflicts` refuses a non-admin any `employeeIds` but their own doc id (`scope-denied`).
- Don't reach for `assertAdminCall` on a self-service callable either: `changeEmployeeEmail` resolves its caller through the pure `resolveEmailChangeCaller`, so widening it past admins cannot widen WHICH doc a caller reaches.
- Resolve the AUTHENTICATED identity LAST in a composed guard: `assertActiveCall` returns `{...data, uid: req.auth.uid}` — the other order lets a `uid` on the Firestore-writable `usersByUid` row shadow the Auth-proved one for every `profile.uid` scoping, the rate limiter included. Latent (nothing writes it); the spread ORDER is what makes it unreachable. (ADR-0040)
- Make a guard FAIL CLOSED on missing input: copy `assertFreshReauth` (`functions/security.js`), which reads `auth && auth.token ? auth.token.auth_time : undefined` while `isReauthStale` treats any non-number as stale. Write `if (!req.auth.token || ...)`, never `if (req.auth.token && ...)` — that waves through a caller presenting no token. A test passing `token: {}` won't catch it; omit the key. Unreachable today is not correct. (ADR-0041)

## Rate limits

- Make every rate limit the DURABLE Firestore `enforceDurableRateLimit` (counters in `rateLimits/*`, which clients cannot read or write) — an in-memory bucket is per function INSTANCE, and `maxInstances: 10` gives a caller up to ten times the cap. The billed cost (one read plus one write per address lookup) is accepted; don't add an in-memory limiter to "save" it. (ADR-0039)
- Rate-limit auth-sensitive callables: `deleteAccount`, `completeEmployeeSetup` and `completePasswordReset` at 5 attempts / 15 min; `changeEmployeeEmail` at 5 / hour. Firebase Auth already rate-limits sign-in; don't bypass it.
- Cap admin write-callables too: `createEmployeeAccount`, `deleteEmployeeAccount` and `resetEmployeePassword` at 20 / hour per admin uid, so a compromised admin session can't mass-create or mass-delete real Auth accounts. Cap a new admin write-callable the same way.

## Firestore rules and App Check

- Keep `firestore.rules` restrictive — it is the last line of defense.
- Bound a client-written TTL field in the rules, not just by type — `expiresAt is timestamp` alone lets a client park a row past every server-side reaper. `liveActivityTokens` caps it at `request.time + 31 d`, just above the longest TTL the app writes (`liveActivityPushToStartTtl`, 30 d): raise both together, and never derive the bound from a server-side constant without checking what the client writes.
- Keep App Check (`firebase_app_check`) activated in `main()`.
- Set `enforceAppCheck: true` on every callable — today `places.js`, `account.js`, `clients.js`, `employee_accounts_admin.js`, `employee_accounts_self.js`, `indexed_search.js`, `appointment_actions.js`, `wave/callables.js`. Never default a new one off. It activates on `firebase deploy --only functions`. (ADR-0043)
- Spread the shared `APP_CHECK` (`functions/security.js`) rather than re-declaring `{enforceAppCheck: true}` — except in an options object that also sets a region, a timeout or a secret, which writes `enforceAppCheck: true` inline beside them, because spreading a one-key constant there reads as less explicit on a security-critical line. (ADR-0043)
