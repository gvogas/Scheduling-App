# Admin Password Reset Implementation Plan

**Status: EXECUTED 2026-09-29** (verified 2026-10-01) — built, backend deployed at `306ed848` + `cc38be5d`, app half unshipped in 1.63.0+93. The "Deviations from the spec" section records where the real code forced a different shape; the unticked boxes below are unknown, not outstanding.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin reset the password of an ACTIVE employee: the server issues a temporary password, signs the person out everywhere and sets a server-owned `passwordResetRequired` flag; on next sign-in both gates route the person to a short Change password screen, which clears the flag through a server callable and walks them into the app.

**Architecture:** Two new callables in `functions/employee_accounts.js` — admin `resetEmployeePassword` (`assertAdminCall`, flag first, then Auth password, then `revokeRefreshTokens`, all under `withAccountOperation`) and self-service `completePasswordReset` (`assertActiveCall`, the SAME extracted `isStrongPassword` check as setup, Auth first, then flag clear). `firestore.rules` puts the flag in both `/users` denylists so only the Admin SDK can move it. In the app, `EmployeeRecord.passwordResetRequired` drives a new branch in `splash_controller.dart` and `sign_in_controller.dart` (after the unchanged `invited` branch), a new `ChangePasswordScreen` route, and a Reset password button in the edit-person sheet's account footer, backed by a new `EmployeeFormController.resetPassword` that returns a sealed outcome.

**Tech Stack:** Flutter (Dart ^3.10.7, Riverpod 3 manual providers, freezed, mocktail, gen_l10n), Firebase Cloud Functions v2 (Node 24, firebase-admin 14, jest 29, eslint google), Firestore rules (checked by the emulator safety runner).

Spec: `docs/plans/2026-09-28-admin-password-reset.md` (approved 2026-09-28).

**Working-tree warning.** `dev` carries many uncommitted audit changes, several in files this plan edits (`functions/employee_accounts.js`, `functions/__tests__/employee_accounts_callables.test.js`, `lib/features/auth/screens/account_setup_screen.dart`, …). Every anchor below was read from that working tree. Edit in place; never `git checkout`/`restore` a file to "clean" it, and never commit — the owner ships through `/ship`.

**Rules this plan leans on** (cite them when a reviewer asks why):
- `.claude/rules/code-quality.md` — comments ONE line max; `functions/` needs a JSDoc block with `@param` per parameter and `@return` on every function declaration.
- `.claude/rules/security.md` — guard order auth → admin → payload → rate limit → work; validate before consuming a slot; admin callables open with `assertAdminCall`, self-service ones with `assertActiveCall`; callable suites stub the COMPOSER; fail closed; never log a password; credential fields set `kCredentialImePersonalizedLearning` (already inside `AuthPasswordField`).
- `.claude/rules/error-handling.md` — resolve the logger before the first await; `mounted` after every await; typed failures; `logger.authFailure` at auth catch sites; notice intro keys; the tag registry.
- Root `CLAUDE.md` — reentrancy flag set synchronously before the first await; offline guard via `guardedOffline`; loose callable cast `(res.data as Map?)?.cast<String, dynamic>()`; routes through `AppRoutes.onGenerateRoute`; ARB keys in both files with `@key` metadata in EN.
- `.claude/rules/testing.md` — `ThemeNotifier` + localizations in every widget harness; 260 px × 2.0 text scale overflow check; `tester.takeException()` is null.

---

## File structure

**Created**

| File | Responsibility |
|---|---|
| `lib/features/auth/screens/change_password_screen.dart` | Forced Change password screen: two `AuthPasswordField`s, live `PasswordRequirementsChecklist`, confirm-match check, banner, Sign out, routes in via `resumeAfterSignUp`. |
| `test/features/auth/screens/change_password_screen_test.dart` | Success, validation, server failure, already-cleared, offline, double-tap, sign-out, caps/IME and 260 px × 2.0 cases. |
| `test/routes/change_password_route_test.dart` | `AppRoutes.changePassword` builds `ChangePasswordScreen` with no arguments. |

**Modified — server**

| File | Change |
|---|---|
| `functions/employee_accounts.js` | Extract `isStrongPassword`; add `markPasswordResetRequired`, `resetEmployeePassword`, `completePasswordReset`; import `assertActiveCall` and `shortHash`; export the three new names. |
| `functions/index.js` | Wire the two callables (30 → 32 exports). |
| `functions/__tests__/employee_accounts.test.js` | `isStrongPassword` unit tests. |
| `functions/__tests__/employee_accounts_callables.test.js` | Stub the `assertActiveCall` composer, add `revokeRefreshTokens` to the Auth double, two new `describe` blocks. |
| `functions/__tests__/index_exports.test.js` | Pin the two new export names. |
| `firestore.rules` | `passwordResetRequired` in the `/users` create AND update denylists. |
| `functions/__tests__/emulator/safety_checks.js` | Rules denylist assertions + an end-to-end reset/complete run against the emulators. |
| `functions/__tests__/emulator/README.md` | One sentence naming the new check. |

**Modified — app**

| File | Change |
|---|---|
| `lib/features/employees/domain/models/employee_record.dart` (+ regenerated `employee_record.freezed.dart`) | `passwordResetRequired` field, parsed `== true`, never emitted by `toMap`. |
| `test/features/employees/employee_record_test.dart` | Parse/emit tests. |
| `lib/features/employees/domain/employees_repository.dart` | `resetEmployeePassword(docId)` and `completePasswordReset(newPassword)`. |
| `lib/features/employees/data/firebase_employees_repository.dart` | Callable implementations. |
| `test/features/employees/data/firebase_employees_repository_test.dart` | Payload + credentials tests. |
| `lib/features/auth/services/auth_service.dart` | `completePasswordReset`; `_renewSessionAfterSetup` → `_renewSession(label:)`; `not-required` mapping. |
| `test/features/auth/services/auth_service_test.dart` | Service tests. |
| `lib/features/auth/application/sign_in_controller.dart` | `SignInNeedsPasswordChange`; flagged branch clears the identity cache; `resumeAfterSignUp` refuses a still-flagged doc. |
| `test/features/auth/application/sign_in_controller_test.dart` | Gate tests. |
| `lib/features/splash/application/splash_controller.dart` | `SplashGoToChangePassword` and its branch. |
| `test/features/splash/splash_controller_disabled_test.dart` | Gate tests. |
| `lib/features/splash/screens/splash_screen.dart` | Navigate on the new destination. |
| `lib/features/auth/screens/login_screen.dart` | Navigate on the new outcome. |
| `test/features/auth/screens/login_screen_test.dart` | Route-name aware harness + flagged sign-in test. |
| `lib/features/auth/screens/account_setup_screen.dart` | Exhaustive-switch arm for the new outcome. |
| `lib/routes/app_routes.dart` | `changePassword` constant and case. |
| `lib/features/employees/application/employee_form_controller.dart` | `PasswordResetOutcome` family, `isResettingPassword`, `resetPassword(docId)`. |
| `test/features/employees/application/employee_form_controller_test.dart` | Controller tests. |
| `lib/features/employees/widgets/dialogs/new_account_dialog.dart` | Optional `title`. |
| `lib/features/employees/widgets/sheets/edit_person_sheet.dart` | Reset password button in the account footer + confirm/notice flow. |
| `test/features/employees/widgets/sheets/edit_person_sheet_test.dart` | `authUidProvider`/notice overrides + reset tests. |
| `test/features/employees/employees_scale_sweep_test.dart` | `authUidProvider` override (the sheet now watches it). |
| `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb` | Six new keys (EN with `@` metadata). |

**Modified — docs:** `CLAUDE.md`, `.claude/rules/employees.md`, `.claude/rules/error-handling.md`, `functions/CLAUDE.md`, `docs/CLOUD_FUNCTIONS.md`, `.claude/skills/deploy/SKILL.md`, `docs/plans/README.md`, `docs/plans/2026-09-28-admin-password-reset.md`.

---

## Task 1: Extract the shared password-strength check (server)

**Files:**
- Modify: `functions/employee_accounts.js` (the strength check inside `completeEmployeeSetup`, ~:561-565; `module.exports`)
- Test: `functions/__tests__/employee_accounts.test.js`

- [ ] **Step 1: Write the failing test.** In `functions/__tests__/employee_accounts.test.js`, add `isStrongPassword,` to the destructured `require("../employee_accounts")` list (after `generateStartingPassword,`), then append this block directly after the closing `});` of `describe("generateStartingPassword", …)`:

```js
describe("isStrongPassword", () => {
  test.each([
    ["Chosen1pass", true],
    ["Éric2024", true],
    ["Short1a", false],
    ["alllower1x", false],
    ["ALLUPPER1X", false],
    ["NoDigitsHere", false],
  ])("%s -> %s", (password, expected) => {
    expect(isStrongPassword(password)).toBe(expected);
  });

  test("every generated starting password passes it", () => {
    for (let i = 0; i < 200; i++) {
      expect(isStrongPassword(generateStartingPassword())).toBe(true);
    }
  });
});
```

- [ ] **Step 2: Run it and watch it fail.**

Run: `cd functions && npx jest __tests__/employee_accounts.test.js -t isStrongPassword`
Expected: FAIL — `TypeError: isStrongPassword is not a function`.

- [ ] **Step 3: Implement.** In `functions/employee_accounts.js`, insert immediately ABOVE `// Admin-SDK codes for a password Auth refuses; neither is an HttpsError.`:

```js
/**
 * Mirrors the app's PasswordRequirement, Unicode letters included.
 * @param {string} password The trimmed candidate.
 * @return {boolean} True for 8+ chars with an upper, a lower and a digit.
 */
function isStrongPassword(password) {
  return password.length >= 8 && /\p{Lu}/u.test(password) &&
    /\p{Ll}/u.test(password) && /[0-9]/.test(password);
}

```

Then in `completeEmployeeSetup` replace:

```js
  // Mirrors the app's PasswordRequirement, Unicode letters included.
  if (hasPassword && (newPassword.length < 8 || !/\p{Lu}/u.test(newPassword) ||
      !/\p{Ll}/u.test(newPassword) || !/[0-9]/.test(newPassword))) {
    throw new HttpsError("invalid-argument", "invalid-newPassword");
  }
```

with:

```js
  if (hasPassword && !isStrongPassword(newPassword)) {
    throw new HttpsError("invalid-argument", "invalid-newPassword");
  }
```

And in `module.exports`, add `isStrongPassword,` on the line after `buildActivationPatch,`.

- [ ] **Step 4: Run it and watch it pass.**

Run: `cd functions && npx jest __tests__/employee_accounts.test.js -t isStrongPassword`
Expected: PASS (7 tests).

- [ ] **Step 5: Verify setup still refuses weak passwords the same way.**

Run: `cd functions && npx jest __tests__/employee_accounts.test.js __tests__/employee_accounts_callables.test.js && npm run lint`
Expected: all suites PASS; eslint prints nothing.

---

## Task 2: `resetEmployeePassword` admin callable

**Files:**
- Modify: `functions/employee_accounts.js`
- Test: `functions/__tests__/employee_accounts_callables.test.js`

- [ ] **Step 1: Teach the test doubles the two new seams.** In `functions/__tests__/employee_accounts_callables.test.js`:

(a) In the `jest.mock("../security", …)` factory, directly after the `mock.assertAdminCall = jest.fn(…);` statement and before `return mock;`, add the self-service composer stub (security.md: a callable suite stubs the COMPOSER):

```js
  mock.assertActiveCall = jest.fn(async (req, allowedKeys) => {
    const {HttpsError} = require("firebase-functions/v2/https");
    if (!req.auth || !req.auth.uid) {
      throw new HttpsError("unauthenticated", "auth-required");
    }
    actual.assertPayloadShape(req.data, allowedKeys);
    const {getFirestore} = require("firebase-admin/firestore");
    const snap = await getFirestore()
        .collection("usersByUid").doc(req.auth.uid).get();
    const data = snap.exists ? snap.data() : null;
    if (!data || data.status !== "active") {
      throw new HttpsError("permission-denied", "inactive-user");
    }
    return {...data, uid: req.auth.uid};
  });
```

(b) In `makeAuth`, add after the `deleteUser` entry:

```js
    revokeRefreshTokens: jest.fn(async () => {
      trace.push("auth.revokeRefreshTokens");
      if (opts.revokeError) throw opts.revokeError;
    }),
```

(c) Extend the `require("../employee_accounts")` destructure to:

```js
const {
  createEmployeeAccount,
  completeEmployeeSetup,
  changeEmployeeEmail,
  deleteEmployeeAccount,
  resetEmployeePassword,
  completePasswordReset,
} = require("../employee_accounts");
```

- [ ] **Step 2: Write the failing tests.** Append at the end of the file:

```js
describe("resetEmployeePassword", () => {
  const EMP = "emp-doc";
  const staff = () => ({
    [EMP]: {status: "active", uid: "emp-uid", email: "ada@example.com"},
    "admin-doc": {status: "active", uid: "admin-uid", role: "admin"},
  });
  const run = (data) => resetEmployeePassword.run({data, auth: ADMIN});

  beforeEach(() => {
    security.assertAdmin.mockResolvedValue(undefined);
    security.enforceDurableRateLimit.mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    });
  });

  test("opens with the admin composer on a docId-only payload", async () => {
    getFirestore.mockReturnValue(makeDb(staff(), []));
    getAuth.mockReturnValue(makeAuth([]));

    await run({docId: EMP});

    expect(security.assertAdminCall).toHaveBeenCalledWith(
        expect.objectContaining({auth: ADMIN}), new Set(["docId"]));
    expect(security.assertAdmin).toHaveBeenCalledWith(ADMIN.uid);
  });

  // Mutation check for the gate: delete the assertAdminCall line and this fails.
  test("a non-admin resets nothing and burns no rate-limit slot", async () => {
    const trace = [];
    const docs = staff();
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(makeAuth(trace));
    security.assertAdmin.mockRejectedValueOnce(new Error("admin-required"));

    await expect(run({docId: EMP})).rejects.toThrow(/admin-required/);

    expect(trace).toEqual([]);
    expect(docs[EMP].passwordResetRequired).toBeUndefined();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test.each([
    [{docId: EMP, evil: 1}, /unexpected-field/],
    [{docId: "users/x"}, /invalid-docId/],
    [{}, /invalid-docId/],
  ])("rejects %j before consuming a rate-limit slot", async (data, error) => {
    getFirestore.mockReturnValue(makeDb(staff(), []));
    getAuth.mockReturnValue(makeAuth([]));

    await expect(run(data)).rejects.toThrow(error);

    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("spends the per-admin create/delete budget", async () => {
    getFirestore.mockReturnValue(makeDb(staff(), []));
    getAuth.mockReturnValue(makeAuth([]));

    await run({docId: EMP});

    expect(security.enforceDurableRateLimit).toHaveBeenCalledWith(
        "resetEmployeePassword", "admin-uid", 20, 60 * 60 * 1000);
  });

  test("refuses the caller's own account", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb(staff(), trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await expect(run({docId: "admin-doc"})).rejects.toMatchObject({
      code: "failed-precondition", message: "self-reset",
    });
    expect(trace).toEqual([]);
  });

  test.each([
    ["an invited", {status: "invited", uid: "x-uid"}],
    ["a disabled", {status: "disabled", uid: "x-uid"}],
    ["a uid-less", {status: "active"}],
  ])("refuses %s account as not-active", async (_label, doc) => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb({"x-doc": doc}, trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await expect(run({docId: "x-doc"})).rejects.toMatchObject({
      code: "failed-precondition", message: "not-active",
    });
    expect(trace).toEqual([]);
  });

  test("refuses a missing doc as not-active", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb(staff(), trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await expect(run({docId: "gone-doc"})).rejects.toMatchObject({
      code: "failed-precondition", message: "not-active",
    });
    expect(trace).toEqual([]);
  });

  test("flags the doc BEFORE the password, then revokes sessions", async () => {
    const trace = [];
    const docs = staff();
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(auth);

    await run({docId: EMP});

    expect(trace).toEqual([
      "db.update", "db.commit", "auth.updateUser", "auth.revokeRefreshTokens",
    ]);
    expect(docs[EMP]).toMatchObject({
      status: "active", passwordResetRequired: true, updatedAt: "TS",
    });
    expect(auth.revokeRefreshTokens).toHaveBeenCalledWith("emp-uid");
  });

  test("returns the stored email and the password Auth was given", async () => {
    const auth = makeAuth([]);
    getFirestore.mockReturnValue(makeDb(staff(), []));
    getAuth.mockReturnValue(auth);

    const out = await run({docId: EMP});

    expect(out).toEqual({
      email: "ada@example.com",
      password: expect.stringMatching(/^[A-Za-z0-9!@$?*]{12}$/),
    });
    expect(auth.updateUser).toHaveBeenCalledWith(
        "emp-uid", {password: out.password});
  });

  test("never logs the password or the raw uid", async () => {
    getFirestore.mockReturnValue(makeDb(staff(), []));
    getAuth.mockReturnValue(makeAuth([]));

    const out = await run({docId: EMP});

    const logged = JSON.stringify([
      logger.info.mock.calls, logger.warn.mock.calls,
      logger.error.mock.calls, logger.debug.mock.calls,
    ]);
    expect(logged).not.toContain(out.password);
    expect(logged).not.toContain("emp-uid");
  });

  test("a failed password write keeps the flag and frees the lock", async () => {
    const docs = staff();
    const auth = makeAuth([], {updateUserError: Error("auth down")});
    getFirestore.mockReturnValue(makeDb(docs, []));
    getAuth.mockReturnValue(auth);

    await expect(run({docId: EMP})).rejects.toThrow("auth down");
    expect(docs[EMP].passwordResetRequired).toBe(true);
    expect(auth.revokeRefreshTokens).not.toHaveBeenCalled();

    auth.updateUser.mockResolvedValue({});
    await expect(run({docId: EMP}))
        .resolves.toMatchObject({email: "ada@example.com"});
  });

  test("a deactivate that commits first wins", async () => {
    const trace = [];
    const docs = staff();
    const db = makeDb(docs, trace);
    const collection = db.collection;
    db.collection = (name) => {
      const col = collection(name);
      if (name !== "users") return col;
      return {...col, doc: (id) => ({
        ...col.doc(id),
        get: async () => {
          const before = {...docs[id]};
          docs[id] = {...docs[id], status: "disabled"};
          return {id, exists: true, data: () => before, ref: {id}};
        },
      })};
    };
    getFirestore.mockReturnValue(db);
    getAuth.mockReturnValue(makeAuth(trace));

    await expect(run({docId: EMP})).rejects.toMatchObject({
      code: "failed-precondition", message: "not-active",
    });
    expect(trace).toEqual([]);
    expect(docs[EMP].passwordResetRequired).toBeUndefined();
  });

  test("refuses while another credential operation holds the lock", async () => {
    const db = makeDb(staff(), []);
    const auth = makeAuth([]);
    await db.collection("accountOperations").doc("emp-uid").create({});
    getFirestore.mockReturnValue(db);
    getAuth.mockReturnValue(auth);

    await expect(run({docId: EMP}))
        .rejects.toThrow("account-operation-in-progress");
    expect(auth.updateUser).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run and watch them fail.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js -t resetEmployeePassword`
Expected: FAIL — every test with `TypeError: Cannot read properties of undefined (reading 'run')`.

- [ ] **Step 4: Implement.** In `functions/employee_accounts.js`:

(a) Replace the security import with:

```js
const {
  assertPayloadShape,
  requireString,
  requireDocId,
  optionalString,
  assertAdminCall,
  assertActiveCall,
  enforceDurableRateLimit,
  assertFreshReauth,
  shortHash,
  APP_CHECK,
} = require("./security");
```

(b) Insert immediately ABOVE `module.exports = {`:

```js
/**
 * Flags an active account for a forced password change, re-checked in a tx.
 * @param {!Object} db Firestore instance.
 * @param {string} docId users-doc id.
 * @param {string} uid the Auth uid the doc must still carry.
 * @return {!Promise<void>}
 */
async function markPasswordResetRequired(db, docId, uid) {
  await db.runTransaction(async (tx) => {
    const ref = db.collection("users").doc(docId);
    const snap = await tx.get(ref);
    const data = (snap.exists && snap.data()) || {};
    if (data.status !== "active" || data.uid !== uid) {
      throw new HttpsError("failed-precondition", "not-active");
    }
    tx.update(ref, {
      passwordResetRequired: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

const resetEmployeePassword = onCall(APP_CHECK, async (req) => {
  const callerUid = await assertAdminCall(req, new Set(["docId"]));
  const docId = requireDocId(req.data, "docId");
  await enforceDurableRateLimit(
      "resetEmployeePassword", callerUid, CREATE_RATE_MAX,
      CREATE_RATE_WINDOW_MS);

  const db = getFirestore();
  const snap = await db.collection("users").doc(docId).get();
  const data = (snap.exists && snap.data()) || {};
  const uid = typeof data.uid === "string" ? data.uid : "";
  if (uid !== "" && uid === callerUid) {
    throw new HttpsError("failed-precondition", "self-reset");
  }
  if (uid === "" || data.status !== "active") {
    throw new HttpsError("failed-precondition", "not-active");
  }

  const auth = getAuth();
  const password = generateStartingPassword();
  // Flag first: a failed Auth write then only forces an unneeded change.
  await withAccountOperation(db, uid, "password-reset", async () => {
    await markPasswordResetRequired(db, docId, uid);
    await auth.updateUser(uid, {password});
    await auth.revokeRefreshTokens(uid);
  });
  logger.info("resetEmployeePassword: password reset",
      {uidHash: shortHash(uid)});
  return {email: data.email || "", password};
});

```

(c) In `module.exports`, add `resetEmployeePassword,` after `changeEmployeeEmail,`.

- [ ] **Step 5: Run and watch them pass.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js -t resetEmployeePassword`
Expected: PASS (17 tests).

- [ ] **Step 6: Mutation-check the admin gate** (spec: "proved by deleting it"). Temporarily delete the line `const callerUid = await assertAdminCall(req, new Set(["docId"]));` and change the limiter's `callerUid` to `req.auth.uid`, run the same command, confirm `a non-admin resets nothing and burns no rate-limit slot` FAILS, then restore both lines exactly.

- [ ] **Step 7: Verify.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js && npm run lint`
Expected: whole suite PASS; eslint silent.

---

## Task 3: `completePasswordReset` self-service callable

**Files:**
- Modify: `functions/employee_accounts.js`
- Test: `functions/__tests__/employee_accounts_callables.test.js`

- [ ] **Step 1: Write the failing tests.** Append at the end of `functions/__tests__/employee_accounts_callables.test.js`:

```js
describe("completePasswordReset", () => {
  const BRIDGE = {
    "emp-uid": {role: "employee", status: "active", docId: "emp-doc"},
  };
  const flagged = () => ({
    "emp-doc": {status: "active", uid: "emp-uid", passwordResetRequired: true},
  });
  const CHOSEN = "Chosen1pass";
  const req = (newPassword = CHOSEN) => ({
    data: {newPassword}, auth: {uid: "emp-uid"},
  });

  beforeEach(() => {
    security.enforceDurableRateLimit.mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    });
  });

  test("opens with the active-account composer", async () => {
    getFirestore.mockReturnValue(makeDb(flagged(), [], BRIDGE));

    await completePasswordReset.run(req());

    expect(security.assertActiveCall).toHaveBeenCalledWith(
        expect.objectContaining({auth: {uid: "emp-uid"}}),
        new Set(["newPassword"]));
  });

  test("an inactive caller changes nothing and burns no slot", async () => {
    const docs = flagged();
    getFirestore.mockReturnValue(makeDb(docs, [], {
      "emp-uid": {...BRIDGE["emp-uid"], status: "disabled"},
    }));

    await expect(completePasswordReset.run(req()))
        .rejects.toThrow(/inactive-user/);

    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(getAuth().updateUser).not.toHaveBeenCalled();
    expect(docs["emp-doc"].passwordResetRequired).toBe(true);
  });

  test("sets the password FIRST, then clears the flag", async () => {
    const trace = [];
    const docs = flagged();
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(docs, trace, BRIDGE));
    getAuth.mockReturnValue(auth);

    await expect(completePasswordReset.run(req()))
        .resolves.toEqual({ok: true});

    expect(trace).toEqual(["auth.updateUser", "db.update", "db.commit"]);
    expect(auth.updateUser).toHaveBeenCalledWith(
        "emp-uid", {password: CHOSEN});
    expect(docs["emp-doc"]).toMatchObject({
      passwordResetRequired: false, updatedAt: "TS", status: "active",
    });
  });

  test("spends the setup budget, keyed on the caller", async () => {
    getFirestore.mockReturnValue(makeDb(flagged(), [], BRIDGE));

    await completePasswordReset.run(req());

    expect(security.enforceDurableRateLimit).toHaveBeenCalledWith(
        "completePasswordReset", "emp-uid", 5, 15 * 60 * 1000);
  });

  test("refuses an account with no reset pending", async () => {
    const docs = flagged();
    delete docs["emp-doc"].passwordResetRequired;
    getFirestore.mockReturnValue(makeDb(docs, [], BRIDGE));

    await expect(completePasswordReset.run(req())).rejects.toMatchObject({
      code: "failed-precondition", message: "not-required",
    });
    expect(getAuth().updateUser).not.toHaveBeenCalled();
  });

  test("a replay after success is not-required", async () => {
    getFirestore.mockReturnValue(makeDb(flagged(), [], BRIDGE));

    await completePasswordReset.run(req());

    await expect(completePasswordReset.run(req())).rejects.toMatchObject({
      code: "failed-precondition", message: "not-required",
    });
  });

  test.each([
    ["too short", "Short1a"],
    ["no uppercase", "alllower1x"],
    ["no lowercase", "ALLUPPER1X"],
    ["no digit", "NoDigitsHere"],
    ["over 128 chars", "Aa1" + "b".repeat(126)],
  ])("refuses a password that is %s before a slot", async (_label, pw) => {
    const docs = flagged();
    getFirestore.mockReturnValue(makeDb(docs, [], BRIDGE));

    await expect(completePasswordReset.run(req(pw))).rejects.toMatchObject({
      code: "invalid-argument", message: "invalid-newPassword",
    });
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(getAuth().updateUser).not.toHaveBeenCalled();
    expect(docs["emp-doc"].passwordResetRequired).toBe(true);
  });

  test.each([
    "auth/password-does-not-meet-requirements",
    "auth/invalid-password",
  ])("an Auth %s refusal reaches the app as a weak password", async (code) => {
    const docs = flagged();
    getFirestore.mockReturnValue(makeDb(docs, [], BRIDGE));
    getAuth.mockReturnValue(makeAuth([], {
      updateUserError: Object.assign(Error("refused"), {code}),
    }));

    await expect(completePasswordReset.run(req())).rejects.toMatchObject({
      code: "invalid-argument", message: "invalid-newPassword",
    });
    expect(docs["emp-doc"].passwordResetRequired).toBe(true);
  });

  test("a failed password write keeps the flag and frees the lock", async () => {
    const docs = flagged();
    const auth = makeAuth([], {updateUserError: Error("auth down")});
    getFirestore.mockReturnValue(makeDb(docs, [], BRIDGE));
    getAuth.mockReturnValue(auth);

    await expect(completePasswordReset.run(req())).rejects.toThrow("auth down");
    expect(docs["emp-doc"].passwordResetRequired).toBe(true);

    auth.updateUser.mockResolvedValue({});
    await expect(completePasswordReset.run(req()))
        .resolves.toEqual({ok: true});
    expect(docs["emp-doc"].passwordResetRequired).toBe(false);
  });

  test("refuses while another credential operation holds the lock", async () => {
    const db = makeDb(flagged(), [], BRIDGE);
    await db.collection("accountOperations").doc("emp-uid").create({});
    getFirestore.mockReturnValue(db);

    await expect(completePasswordReset.run(req()))
        .rejects.toThrow("account-operation-in-progress");
    expect(getAuth().updateUser).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run and watch them fail.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js -t completePasswordReset`
Expected: FAIL — `TypeError: Cannot read properties of undefined (reading 'run')`.

- [ ] **Step 3: Implement.** In `functions/employee_accounts.js`, insert immediately ABOVE `module.exports = {` (after `resetEmployeePassword`):

```js
const completePasswordReset = onCall(APP_CHECK, async (req) => {
  const profile = await assertActiveCall(req, new Set(["newPassword"]));
  const newPassword = requireString(req.data, "newPassword", 128);
  if (!isStrongPassword(newPassword)) {
    throw new HttpsError("invalid-argument", "invalid-newPassword");
  }
  await enforceDurableRateLimit(
      "completePasswordReset", profile.uid, SETUP_RATE_MAX,
      SETUP_RATE_WINDOW_MS);

  const db = getFirestore();
  const uid = profile.uid;
  await withAccountOperation(db, uid, "password-reset", async () => {
    const found = await db.collection("users")
        .where("uid", "==", uid).limit(2).get();
    const data = found.docs.length === 1 ? found.docs[0].data() || {} : {};
    if (data.status !== "active" || data.passwordResetRequired !== true) {
      throw new HttpsError("failed-precondition", "not-required");
    }
    // Never log or persist this payload. Auth is the only password store.
    await setSetupPassword(getAuth(), uid, newPassword);
    const ref = found.docs[0].ref;
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      tx.update(ref, {
        passwordResetRequired: false,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  });
  return {ok: true};
});

```

In `module.exports`, add `completePasswordReset,` after `resetEmployeePassword,`.

- [ ] **Step 4: Run and watch them pass.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js -t completePasswordReset`
Expected: PASS (15 tests).

- [ ] **Step 5: Verify.**

Run: `cd functions && npx jest __tests__/employee_accounts_callables.test.js __tests__/employee_accounts.test.js && npm run lint`
Expected: PASS; eslint silent (every new `function` declaration carries JSDoc; the two `onCall` arrows need none, matching `deleteEmployeeAccount`).

---

## Task 4: Wire the exports (30 → 32)

**Files:**
- Modify: `functions/index.js`
- Test: `functions/__tests__/index_exports.test.js`

- [ ] **Step 1: Write the failing test.** In `EXPECTED_EXPORTS`, insert `"completePasswordReset",` directly after `"completeEmployeeSetup",`, and `"resetEmployeePassword",` directly after `"recountClientJobs",` (the array must stay sorted).

- [ ] **Step 2: Run it and watch it fail.**

Run: `cd functions && npx jest __tests__/index_exports.test.js`
Expected: FAIL — `expect(received).toEqual(expected)` with the diff showing `completePasswordReset` and `resetEmployeePassword` missing from received.

- [ ] **Step 3: Implement.** In `functions/index.js`, after `exports.changeEmployeeEmail = employeeAccounts.changeEmployeeEmail;` add:

```js
exports.resetEmployeePassword = employeeAccounts.resetEmployeePassword;
exports.completePasswordReset = employeeAccounts.completePasswordReset;
```

- [ ] **Step 4: Run it and watch it pass.**

Run: `cd functions && npx jest __tests__/index_exports.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: Verify.**

Run: `cd functions && npx jest && npm run lint`
Expected: every suite PASS, coverage thresholds met; eslint silent.

---

## Task 5: Rules — only the Admin SDK may move the flag

**Files:**
- Modify: `firestore.rules` (`/users` `allow create` ~:137, `allow update` ~:241)
- Test: `functions/__tests__/emulator/safety_checks.js`, `functions/__tests__/emulator/README.md`

There is no jest or Dart rules harness in this repo: `firestore.rules` is exercised only by the emulator runner (`functions/__tests__/emulator/`, excluded from jest, run by CI on pushes to `dev`). The existing `setupRequiresPassword` 403 check there is the pattern.

- [ ] **Step 1: Write the failing check.** In `functions/__tests__/emulator/safety_checks.js`, replace:

```js
const {createEmployeeAccount, completeEmployeeSetup} =
  require("../../employee_accounts");
```

with:

```js
const {
  createEmployeeAccount,
  completeEmployeeSetup,
  resetEmployeePassword,
  completePasswordReset,
} = require("../../employee_accounts");
```

Then insert directly AFTER the line `console.log("Account setup: contention and chosen credential checked.");`:

```js
    const signInStatus = async (password) => {
      const response = await fetch(`${auth}/identitytoolkit.googleapis.com/` +
        "v1/accounts:signInWithPassword?key=demo-key", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({email, password}),
      });
      await response.arrayBuffer();
      return response.status;
    };
    const flagMask = "?updateMask.fieldPaths=passwordResetRequired";
    assert.equal(await write(`users/${person.id}`, {
      passwordResetRequired: {booleanValue: true},
    }, flagMask), 403);
    assert.equal(await write(`users/${prefix}-flagged`, {
      name: {stringValue: "Flagged"},
      passwordResetRequired: {booleanValue: true},
    }), 403);
    assert.equal(await write(`users/${prefix}-plain`, {
      name: {stringValue: "Plain"},
    }), 200);
    const reset = await resetEmployeePassword.run({
      auth: {uid: admin.uid}, data: {docId: person.id},
    });
    assert.equal((await person.ref.get()).data().passwordResetRequired, true);
    assert.equal(await write(`users/${person.id}`, {
      passwordResetRequired: {booleanValue: false},
    }, flagMask), 403);
    assert.equal(await signInStatus(reset.password), 200);
    await db.collection("usersByUid").doc(uid).set(
        {docId: person.id, role: "employee", status: "active"}, {merge: true});
    const changed = "ChangedPassword123!";
    await completePasswordReset.run({
      auth: {uid}, data: {newPassword: changed},
    });
    assert.equal((await person.ref.get()).data().passwordResetRequired, false);
    assert.equal(await signInStatus(changed), 200);
    assert.equal(await signInStatus(reset.password), 400);
    console.log("Password reset: denylist, flag and credential checked.");
```

(The bridge row is seeded by hand because this runner starts no functions emulator, so `syncUsersByUid` never writes it; `assertActiveCall` reads it.)

- [ ] **Step 2: Run it and watch it fail.** From the repository root (needs the Firebase CLI and Java 21):

Run: `firebase emulators:exec --project demo-scheduling-review --only "auth,firestore,storage" "node functions/__tests__/emulator/storage_rules.smoke.js"`
Expected: FAIL — `AssertionError [ERR_ASSERTION]: Expected values to be strictly equal: 200 !== 403` on the first `passwordResetRequired` write (the rules allow an admin to set it today).

If Java 21 / the CLI is not installed on this machine, say so in the task report and rely on CI (it runs this runner on pushes to `dev`); do not skip Step 3.

- [ ] **Step 3: Implement.** In `firestore.rules`, in `match /users/{userId}`, replace the create denylist:

```
      allow create: if isAdmin()
            && !request.resource.data.keys()
                 .hasAny(['uid', 'termsAcceptedAt', 'locationConsentAt',
                          'emergencyContact', 'emergencyPhone'])
```

with:

```
      allow create: if isAdmin()
            && !request.resource.data.keys()
                 .hasAny(['uid', 'termsAcceptedAt', 'locationConsentAt',
                          'emergencyContact', 'emergencyPhone',
                          'passwordResetRequired'])
```

and the update denylist:

```
                 .hasAny(['uid', 'termsAcceptedAt', 'locationConsentAt',
                          'setupRequiresPassword'])
```

with:

```
                 .hasAny(['uid', 'termsAcceptedAt', 'locationConsentAt',
                          'setupRequiresPassword', 'passwordResetRequired'])
```

In `functions/__tests__/emulator/README.md`, append to the last paragraph (after "…delete and dry-run).") the sentence: `It also checks that no client can set or clear passwordResetRequired, and runs an admin password reset followed by the employee's forced change against the Auth emulator.`

- [ ] **Step 4: Run it and watch it pass.**

Run: `firebase emulators:exec --project demo-scheduling-review --only "auth,firestore,storage" "node functions/__tests__/emulator/storage_rules.smoke.js"`
Expected: exit 0, the output includes `Password reset: denylist, flag and credential checked.`

- [ ] **Step 5: Verify.**

Run: `cd functions && npm run lint`
Expected: eslint silent (the runner is linted even though jest ignores it).

---

## Task 6: `EmployeeRecord.passwordResetRequired`

**Files:**
- Modify: `lib/features/employees/domain/models/employee_record.dart` (+ regenerated `employee_record.freezed.dart`)
- Test: `test/features/employees/employee_record_test.dart`

- [ ] **Step 1: Write the failing test.** Append inside `main()` of `test/features/employees/employee_record_test.dart`, after the `monthEndReviewPush` test:

```dart
  group('passwordResetRequired', () {
    test('an absent flag reads as not required', () {
      expect(
        EmployeeRecord.fromMap('e1', const {}).passwordResetRequired,
        isFalse,
      );
    });

    test('only an explicit true requires a change', () {
      expect(
        EmployeeRecord.fromMap('e1', const {
          'passwordResetRequired': true,
        }).passwordResetRequired,
        isTrue,
      );
      expect(
        EmployeeRecord.fromMap('e1', const {
          'passwordResetRequired': 'true',
        }).passwordResetRequired,
        isFalse,
      );
    });

    test('toMap never emits it — only the Admin SDK may write it', () {
      const record = EmployeeRecord(id: 'e1', passwordResetRequired: true);

      expect(record.toMap().containsKey('passwordResetRequired'), isFalse);
    });
  });
```

- [ ] **Step 2: Run it and watch it fail.**

Run: `flutter test --no-pub test/features/employees/employee_record_test.dart`
Expected: FAIL at compile — `No named parameter with the name 'passwordResetRequired'` / `The getter 'passwordResetRequired' isn't defined`.

- [ ] **Step 3: Implement.** In `employee_record.dart`, add after `@Default(false) bool monthEndReviewPush,`:

```dart
    // Server-owned: set by resetEmployeePassword, cleared by completePasswordReset.
    @Default(false) bool passwordResetRequired,
```

In `fromMap`, add after `monthEndReviewPush: data['monthEndReviewPush'] == true,`:

```dart
      passwordResetRequired: data['passwordResetRequired'] == true,
```

Do NOT touch `toMap()` (the rules deny the field on every client write; `updateEmployee` builds its own allowlist, which also must not gain it).

- [ ] **Step 4: Regenerate freezed and guard against the known deletion bug.**

Run: `dart run build_runner build --delete-conflicting-outputs`
Then: `git status --short | grep 'D .*\.freezed\.dart'`
Expected: `employee_record.freezed.dart` shows as modified and NO line is printed by the grep. If any `D …freezed.dart` appears, restore each one ONLY if its source is unchanged: `git diff --quiet HEAD -- <source>.dart && git restore --source=HEAD --worktree <file>.freezed.dart` (memory note: build_runner has deleted unrelated tracked freezed files in this repo).

- [ ] **Step 5: Run it and watch it pass.**

Run: `flutter test --no-pub test/features/employees/employee_record_test.dart`
Expected: PASS.

- [ ] **Step 6: Verify.**

Run: `flutter analyze --no-pub`
Expected: `No issues found!`

---

## Task 7: Repository methods for both callables

**Files:**
- Modify: `lib/features/employees/domain/employees_repository.dart`, `lib/features/employees/data/firebase_employees_repository.dart`
- Test: `test/features/employees/data/firebase_employees_repository_test.dart`

- [ ] **Step 1: Write the failing tests.** In `firebase_employees_repository_test.dart`, add directly after the closing `});` of `group('deleteEmployeeAccount', …)`:

```dart
  group('resetEmployeePassword', () {
    test('sends the doc id and returns the issued credentials', () async {
      final callable = stubCallable(
        'resetEmployeePassword',
        data: {'email': 'a@b.test', 'password': 'Tmp2pass!wd9'},
      );

      final credentials = await repo().resetEmployeePassword('doc-1');

      expect(capturedPayload(callable), {'docId': 'doc-1'});
      expect(credentials.email, 'a@b.test');
      expect(credentials.password, 'Tmp2pass!wd9');
    });

    test('rejects a half-blank credential payload', () async {
      stubCallable(
        'resetEmployeePassword',
        data: {'email': 'a@b.test', 'password': ''},
      );

      await expectLater(
        repo().resetEmployeePassword('doc-1'),
        throwsA(isA<EmployeesFailureUnknown>()),
      );
    });
  });

  group('completePasswordReset', () {
    test('sends the new password and nothing else', () async {
      final callable = stubCallable(
        'completePasswordReset',
        data: {'ok': true},
      );

      await repo().completePasswordReset('Chosen1pass');

      expect(capturedPayload(callable), {'newPassword': 'Chosen1pass'});
    });
  });
```

- [ ] **Step 2: Run and watch them fail.**

Run: `flutter test --no-pub test/features/employees/data/firebase_employees_repository_test.dart`
Expected: FAIL at compile — `The method 'resetEmployeePassword' isn't defined for the type 'FirebaseEmployeesRepository'`.

- [ ] **Step 3: Implement the interface.** In `employees_repository.dart`, add after `Future<void> deleteEmployeeAccount(String docId);`:

```dart

  /// Issues a new temporary password for an ACTIVE account and flags it for a forced change.
  Future<NewAccountCredentials> resetEmployeePassword(String docId);

  /// Replaces the signed-in user's temporary password and clears the reset flag.
  Future<void> completePasswordReset(String newPassword);
```

- [ ] **Step 4: Implement the Firebase repository.** In `firebase_employees_repository.dart`, add after the `deleteEmployeeAccount` override:

```dart
  @override
  Future<NewAccountCredentials> resetEmployeePassword(String docId) async {
    final res = await _functions
        .httpsCallable(
          'resetEmployeePassword',
          options: HttpsCallableOptions(timeout: _callableTimeout),
        )
        .call<dynamic>({'docId': docId});
    final data = (res.data as Map?)?.cast<String, dynamic>();
    if (data == null) throw const EmployeesFailureUnknown();
    final credentials = NewAccountCredentials.fromMap(data);
    if (!credentials.isComplete) throw const EmployeesFailureUnknown();
    return credentials;
  }

  @override
  Future<void> completePasswordReset(String newPassword) async {
    await _functions
        .httpsCallable(
          'completePasswordReset',
          options: HttpsCallableOptions(timeout: _callableTimeout),
        )
        .call<dynamic>({'newPassword': newPassword});
  }
```

- [ ] **Step 5: Run and watch them pass.**

Run: `flutter test --no-pub test/features/employees/data/firebase_employees_repository_test.dart`
Expected: PASS.

- [ ] **Step 6: Verify.** Every `_Mock… extends Mock implements EmployeesRepository` in `test/` is a mocktail mock, so the two new abstract members need no stubs there.

Run: `flutter analyze --no-pub`
Expected: `No issues found!`

---

## Task 8: `AuthService.completePasswordReset`

**Files:**
- Modify: `lib/features/auth/services/auth_service.dart`
- Test: `test/features/auth/services/auth_service_test.dart`

- [ ] **Step 1: Write the failing tests.** Append inside `main()` of `auth_service_test.dart`, after the last `group`:

```dart
  group('completePasswordReset', () {
    setUp(() {
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenAnswer((_) async => _FakeUserCredential());
    });

    test('sends the trimmed password, then renews the session with it', () async {
      when(() => employees.completePasswordReset(any())).thenAnswer((_) async {});

      await service.completePasswordReset('  N3wPassw0rd  ');

      verify(() => employees.completePasswordReset('N3wPassw0rd')).called(1);
      final captured = verify(
        () => user.reauthenticateWithCredential(captureAny()),
      ).captured.single;
      expect((captured as EmailAuthCredential).password, 'N3wPassw0rd');
    });

    test('a failed session renewal still completes', () async {
      when(() => employees.completePasswordReset(any())).thenAnswer((_) async {});
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenThrow(FirebaseAuthException(code: 'network-request-failed'));

      await expectLater(
        service.completePasswordReset('N3wPassw0rd'),
        completes,
      );
    });

    test('refuses with no signed-in user and calls nothing', () async {
      when(() => auth.currentUser).thenReturn(null);

      await expectLater(
        service.completePasswordReset('N3wPassw0rd'),
        throwsA(isA<AuthFailureSessionExpired>()),
      );
      verifyNever(() => employees.completePasswordReset(any()));
    });

    for (final (message, matcher) in <(String, Matcher)>[
      ('invalid-newPassword', isA<AuthFailureWeakPassword>()),
      ('not-required', isA<AuthFailureSetupAlreadyComplete>()),
      ('account-operation-in-progress', isA<AuthFailureTooManyRequests>()),
    ]) {
      test('maps the server refusal $message to a typed failure', () async {
        when(() => employees.completePasswordReset(any())).thenThrow(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: message,
          ),
        );

        await expectLater(
          service.completePasswordReset('N3wPassw0rd'),
          throwsA(matcher),
        );
      });
    }
  });
```

- [ ] **Step 2: Run and watch them fail.**

Run: `flutter test --no-pub test/features/auth/services/auth_service_test.dart`
Expected: FAIL at compile — `The method 'completePasswordReset' isn't defined for the type 'AuthService'`.

- [ ] **Step 3: Implement.** In `auth_service.dart`:

(a) Add after `completeAccountSetup` (before the renewal helper):

```dart
  /// Replaces an admin-issued temporary password on an active account.
  Future<void> completePasswordReset(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthFailureSessionExpired();
    final password = newPassword.trim();
    try {
      await _employees.completePasswordReset(password);
    } catch (e) {
      // Logged once, by the screen, through logger.authFailure.
      throw _mapSetupError(e);
    }
    await _renewSession(
      user,
      password,
      label: 'AUTH-CHANGEPW completePasswordReset: session renewal failed',
    );
  }
```

(b) Rename the renewal helper and give it the label (two callers now, and each literal label keeps its tag greppable). Replace the whole method:

```dart
  /// Admin SDK password changes revoke refresh tokens, so re-sign-in here.
  /// Setup already committed: a failure only costs a later sign-in.
  Future<void> _renewSessionAfterSetup(User user, String password) async {
    final email = user.email;
    if (email == null || email.isEmpty) return;
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
    } catch (e, st) {
      _logger.warn(
        'AUTH-SETUP completeAccountSetup: session renewal failed',
        e,
        st,
      );
    }
  }
```

with:

```dart
  /// Admin SDK password changes revoke refresh tokens; best-effort re-sign-in.
  Future<void> _renewSession(
    User user,
    String password, {
    required String label,
  }) async {
    final email = user.email;
    if (email == null || email.isEmpty) return;
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
    } catch (e, st) {
      _logger.warn(label, e, st);
    }
  }
```

and in `completeAccountSetup` replace `await _renewSessionAfterSetup(user, newPassword.trim());` with:

```dart
    await _renewSession(
      user,
      newPassword.trim(),
      label: 'AUTH-SETUP completeAccountSetup: session renewal failed',
    );
```

(c) In `_setupFailuresByMessage`, add after `'setup-not-pending': AuthFailureSetupAlreadyComplete(),`:

```dart
    'not-required': AuthFailureSetupAlreadyComplete(),
```

- [ ] **Step 4: Run and watch them pass.**

Run: `flutter test --no-pub test/features/auth/services/auth_service_test.dart`
Expected: PASS (existing setup cases included — the renewal rename is behaviour-neutral).

- [ ] **Step 5: Verify.**

Run: `flutter analyze --no-pub`
Expected: `No issues found!`

---

## Task 9: Gates — sign-in and splash route a reset account to Change password

**Files:**
- Modify: `lib/features/auth/application/sign_in_controller.dart`, `lib/features/splash/application/splash_controller.dart`, `lib/features/splash/screens/splash_screen.dart`, `lib/features/auth/screens/login_screen.dart`, `lib/features/auth/screens/account_setup_screen.dart`, `lib/routes/app_routes.dart` (constant only; the `case` lands in Task 10)
- Test: `test/features/auth/application/sign_in_controller_test.dart`, `test/features/splash/splash_controller_disabled_test.dart`, `test/features/auth/screens/login_screen_test.dart`

- [ ] **Step 1: Write the failing sign-in tests.** In `sign_in_controller_test.dart`, add after `_unknownStatusDoc`:

```dart
const _flaggedDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Reset User',
    'email': 'user@test.com',
    'status': 'active',
    'role': 'employee',
    'uid': 'u1',
    'passwordResetRequired': true,
  },
);
```

In `setUp`, add `when(() => cache.clear()).thenAnswer((_) async {});` after the `cache.save` stub. Inside `group('signIn', …)`, add:

```dart
    test('routes a reset account to Change password and KEEPS the session', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _flaggedDoc);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'Tmp2pass!wd9',
      );

      expect(outcome, isA<SignInNeedsPasswordChange>());
      verifyNever(() => auth.signOut());
      expect(state().inProgress, isFalse);
    });

    test('clears the identity cache so a cold start cannot skip the change', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _flaggedDoc);

      await notifier().signIn(email: 'user@test.com', password: 'Tmp2pass!wd9');

      verify(() => cache.clear()).called(1);
      verifyNever(() => cache.save(any()));
    });

    test('a failing cache clear still routes to Change password', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _flaggedDoc);
      when(() => cache.clear()).thenAnswer((_) async => throw Exception('keystore'));

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'Tmp2pass!wd9',
      );

      expect(outcome, isA<SignInNeedsPasswordChange>());
    });

    test('an invited doc carrying the flag still goes to setup', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer(
        (_) async => UserUidMatch(
          id: 'doc1',
          data: {..._invitedDoc.data, 'passwordResetRequired': true},
        ),
      );

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInNeedsAccountSetup>());
    });
```

Inside `group('resumeAfterSignUp', …)`, add:

```dart
    test('a still-flagged doc reports a pending profile, never success', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('u1');
      when(() => auth.currentUser).thenReturn(user);
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _flaggedDoc);

      expect(await notifier().resumeAfterSignUp(), isA<SignInProfilePending>());
      verifyNever(() => cache.save(any()));
    });
```

- [ ] **Step 2: Write the failing splash tests.** In `splash_controller_disabled_test.dart`, add inside `group('splashDestinationProvider — disabled account', …)`:

```dart
    ProviderContainer containerFor(Map<String, dynamic> data) {
      when(
        () => mockRepo.findUserByUid('uid1'),
      ).thenAnswer((_) async => UserUidMatch(id: 'doc1', data: data));
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('routes a reset account to Change password and KEEPS the session', () async {
      final container = containerFor({
        'uid': 'uid1',
        'role': 'employee',
        'status': 'active',
        'name': 'Jane',
        'passwordResetRequired': true,
      });

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToChangePassword>());
      verifyNever(() => mockAuth.signOut());
    });

    test('an invited doc carrying the flag still goes to setup', () async {
      final container = containerFor({
        'uid': 'uid1',
        'role': 'employee',
        'status': 'invited',
        'firstName': 'Jane',
        'passwordResetRequired': true,
      });

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToAccountSetup>());
    });

    test('a disabled doc carrying the flag is still signed out', () async {
      final container = containerFor({
        'uid': 'uid1',
        'role': 'employee',
        'status': 'disabled',
        'passwordResetRequired': true,
      });

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToLogin>());
      verify(() => mockAuth.signOut()).called(1);
    });
```

- [ ] **Step 3: Write the failing login-screen test.** In `login_screen_test.dart`, make the harness route-name aware — replace:

```dart
          builder: (_) => Scaffold(
            body: Text(
              settings.name == AppRoutes.mainCalendar
                  ? 'CALENDAR_REACHED'
                  : 'OTHER_ROUTE',
            ),
          ),
```

with:

```dart
          builder: (_) => Scaffold(
            body: Text(switch (settings.name) {
              AppRoutes.mainCalendar => 'CALENDAR_REACHED',
              AppRoutes.changePassword => 'CHANGE_PASSWORD_REACHED',
              _ => 'OTHER_ROUTE',
            }),
          ),
```

and add inside `main()`:

```dart
  testWidgets('routes a reset account to Change password, not the calendar', (
    tester,
  ) async {
    final credential = _MockUserCredential();
    final user = _MockUser();
    when(() => user.uid).thenReturn('u1');
    when(() => credential.user).thenReturn(user);
    when(
      () => auth.signIn(
        email: any(named: 'email'),
        password: any(named: 'password'),
      ),
    ).thenAnswer((_) async => credential);
    when(() => repo.findUserByUid('u1')).thenAnswer(
      (_) async => const UserUidMatch(
        id: 'doc1',
        data: <String, dynamic>{
          'name': 'Reset User',
          'email': 'user@test.com',
          'status': 'active',
          'role': 'employee',
          'uid': 'u1',
          'passwordResetRequired': true,
        },
      ),
    );

    await tester.pumpWidget(_wrap(auth, repo));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'user@test.com');
    await tester.enterText(find.byType(TextField).at(1), 'Tmp2pass!wd9');
    await tester.tap(find.byType(FilledButton).first);
    await tester.pumpAndSettle();

    expect(find.text('CHANGE_PASSWORD_REACHED'), findsOneWidget);
    verifyNever(() => auth.signOut());
    expect(tester.takeException(), isNull);
  });
```

- [ ] **Step 4: Run and watch them fail.**

Run: `flutter test --no-pub test/features/auth/application/sign_in_controller_test.dart test/features/splash/splash_controller_disabled_test.dart test/features/auth/screens/login_screen_test.dart`
Expected: FAIL at compile — `Undefined name 'SignInNeedsPasswordChange'`, `'SplashGoToChangePassword'`, `Member not found: 'changePassword'`.

- [ ] **Step 5: Implement the route constant.** In `lib/routes/app_routes.dart`, add after `static const String accountSetup = '/account-setup';`:

```dart
  static const String changePassword = '/change-password';
```

- [ ] **Step 6: Implement the sign-in gate.** In `sign_in_controller.dart`, add after the `SignInNeedsAccountSetup` class:

```dart
/// Signed in against an active account an admin has reset; the session is KEPT for Change password.
class SignInNeedsPasswordChange extends SignInOutcome {
  const SignInNeedsPasswordChange();
}
```

In `signIn`, insert between the closing `}` of the `if (!employee.isActive) { … }` block and the `// The identity cache and remembered email are best-effort` comment:

```dart
      if (employee.passwordResetRequired) {
        // A stale identity cache would let a cold start fast-path past the change.
        await authCache.clear().catchError((Object e, StackTrace st) {
          logger.warn('AUTH-SIGNIN identity cache clear failed', e, st);
        });
        _settle();
        return const SignInNeedsPasswordChange();
      }

```

In `resumeAfterSignUp`, replace `if (!employee.isActive) return const SignInProfilePending();` with:

```dart
      if (!employee.isActive || employee.passwordResetRequired) {
        return const SignInProfilePending();
      }
```

- [ ] **Step 7: Implement the splash gate.** In `splash_controller.dart`, add after the `SplashGoToAccountSetup` class:

```dart
/// An active account an admin has reset: keep the session and force a new password.
class SplashGoToChangePassword extends SplashDestination {
  const SplashGoToChangePassword();
}
```

In `splashDestinationProvider`, insert between the closing `}` of `if (!employee.isActive) { … }` and `unawaited(`:

```dart
  if (employee.passwordResetRequired) return const SplashGoToChangePassword();
```

- [ ] **Step 8: Complete the three exhaustive switches.**

`splash_screen.dart` `_go`, add after the `SplashGoToAccountSetup` arm:

```dart
        case SplashGoToChangePassword():
          nav.pushReplacementNamed(AppRoutes.changePassword);
```

`login_screen.dart` `_signIn` switch, add after the `SignInNeedsAccountSetup` arm:

```dart
      // A reset account; the session is kept for the Change password screen.
      case SignInNeedsPasswordChange():
        await Navigator.pushReplacementNamed(context, AppRoutes.changePassword);
```

`account_setup_screen.dart` `_routeIntoApp`, extend the "Only signIn() yields these" arm to:

```dart
      case SignInInvalidCredentials() ||
          SignInNoProfile() ||
          SignInAccountDisabled() ||
          SignInNeedsAccountSetup() ||
          SignInNeedsPasswordChange() ||
          SignInError():
```

- [ ] **Step 9: Run and watch them pass.**

Run: `flutter test --no-pub test/features/auth/application/sign_in_controller_test.dart test/features/splash/splash_controller_disabled_test.dart test/features/auth/screens/login_screen_test.dart`
Expected: PASS. (Until Task 10, `AppRoutes.onGenerateRoute` has no `changePassword` case; the login harness uses its own `onGenerateRoute`, so this is fine.)

- [ ] **Step 10: Verify.**

Run: `flutter analyze --no-pub && flutter test --no-pub test/features/auth test/features/splash`
Expected: `No issues found!`; all PASS.

---

## Task 10: `ChangePasswordScreen` + route + auth l10n keys

**Files:**
- Create: `lib/features/auth/screens/change_password_screen.dart`, `test/features/auth/screens/change_password_screen_test.dart`, `test/routes/change_password_route_test.dart`
- Modify: `lib/routes/app_routes.dart`, `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`

- [ ] **Step 1: Add the auth ARB keys.** In `lib/l10n/app_en.arb`, insert after the `"@auth_finishSetup": { … },` block:

```json
  "auth_changePasswordTitle": "Choose a new password",
  "@auth_changePasswordTitle": {
    "description": "Title of the forced Change password screen after an admin reset"
  },
  "auth_changePasswordBody": "Your admin reset your password. Choose a new one to continue.",
  "@auth_changePasswordBody": {
    "description": "Explains why the Change password screen is shown"
  },
  "auth_saveNewPassword": "Save password",
  "@auth_saveNewPassword": {
    "description": "Primary button on the Change password screen"
  },
```

In `lib/l10n/app_fr.arb`, insert after `"auth_finishSetup": "Terminer la configuration",`:

```json
  "auth_changePasswordTitle": "Choisissez un nouveau mot de passe",
  "auth_changePasswordBody": "Votre administrateur a réinitialisé votre mot de passe. Choisissez-en un nouveau pour continuer.",
  "auth_saveNewPassword": "Enregistrer le mot de passe",
```

The ARB-edit hook runs `flutter gen-l10n` automatically. If `context.l10n.auth_changePasswordTitle` is still undefined afterwards, run `flutter gen-l10n` by hand and check `lib/l10n/.gen/untranslated.json` lists none of the three keys.

- [ ] **Step 2: Write the failing screen tests.** Create `test/features/auth/screens/change_password_screen_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/screens/change_password_screen.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

class _MockAuthService extends Mock implements AuthService {}

class _StubSignInController extends SignInController {
  _StubSignInController(this._resumeOutcome);

  final SignInOutcome _resumeOutcome;

  @override
  SignInState build() => const SignInState();

  @override
  Future<SignInOutcome> resumeAfterSignUp() async => _resumeOutcome;
}

const _chosen = 'Chosen1pass';
const _employee = EmployeeRecord(id: 'doc1', status: 'active');

Widget _harness({
  required AuthService auth,
  bool offline = false,
  SignInOutcome resumeOutcome = const SignInSuccess(_employee),
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      isOfflineProvider.overrideWithValue(offline),
      signInControllerProvider.overrideWith(
        () => _StubSignInController(resumeOutcome),
      ),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: textScale,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        ),
        routes: {
          AppRoutes.login: (_) => const Scaffold(body: Text('login screen')),
          AppRoutes.mainCalendar: (_) =>
              const Scaffold(body: Text('main calendar')),
        },
        home: ChangePasswordScreen(authService: auth),
      ),
    ),
  );
}

Future<void> _fill(
  WidgetTester tester, {
  String password = _chosen,
  String? confirm,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), password);
  await tester.enterText(fields.at(1), confirm ?? password);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  final button = find.byType(FilledButton).last;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  late _MockAuthService auth;

  setUp(() {
    auth = _MockAuthService();
    when(() => auth.completePasswordReset(any())).thenAnswer((_) async {});
    when(() => auth.signOut()).thenAnswer((_) async {});
  });

  testWidgets('saves the new password and routes into the app', (tester) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    verify(() => auth.completePasswordReset(_chosen)).called(1);
    expect(find.text('main calendar'), findsOneWidget);
  });

  testWidgets('a mismatched confirmation never calls the server', (tester) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester, confirm: 'Different1x');

    await _submit(tester);

    expect(find.text('Passwords do not match'), findsOneWidget);
    verifyNever(() => auth.completePasswordReset(any()));
  });

  testWidgets('a password failing the checklist never calls the server', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester, password: 'alllower1x');

    await _submit(tester);

    verifyNever(() => auth.completePasswordReset(any()));
  });

  testWidgets('a server refusal shows in the banner and re-enables the form', (
    tester,
  ) async {
    when(
      () => auth.completePasswordReset(any()),
    ).thenThrow(const AuthFailureWeakPassword());
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(tester.widget<AuthBanner>(find.byType(AuthBanner)).message, isNotNull);
    expect(
      tester
          .widget<AnimatedLoadingButton>(find.byType(AnimatedLoadingButton))
          .isLoading,
      isFalse,
    );
    expect(find.text('main calendar'), findsNothing);
  });

  testWidgets('an already-cleared flag walks them into the app', (tester) async {
    when(
      () => auth.completePasswordReset(any()),
    ).thenThrow(const AuthFailureSetupAlreadyComplete());
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    expect(find.text('main calendar'), findsOneWidget);
  });

  testWidgets('a pending profile after the change signs out to login', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(auth: auth, resumeOutcome: const SignInProfilePending()),
    );
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    verify(() => auth.signOut()).called(1);
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('offline fails fast with a banner and no server call', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth, offline: true));
    await tester.pumpAndSettle();
    await _fill(tester);

    await _submit(tester);

    verifyNever(() => auth.completePasswordReset(any()));
    expect(tester.widget<AuthBanner>(find.byType(AuthBanner)).message, isNotNull);
  });

  testWidgets('a double tap submits once', (tester) async {
    final gate = Completer<void>();
    when(
      () => auth.completePasswordReset(any()),
    ).thenAnswer((_) => gate.future);
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    await _fill(tester);
    final button = find.byType(FilledButton).last;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();

    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    verify(() => auth.completePasswordReset(_chosen)).called(1);
  });

  testWidgets('Log out returns to the login screen', (tester) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();
    final logOut = find.text('Log out');
    await tester.ensureVisible(logOut);
    await tester.pumpAndSettle();

    await tester.tap(logOut);
    await tester.pumpAndSettle();

    verify(() => auth.signOut()).called(1);
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('both fields cap at TextLimits.password with IME learning off', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(auth: auth));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<AuthPasswordField>(
      find.byType(AuthPasswordField),
    );
    expect(fields, hasLength(2));
    for (final field in fields) {
      expect(field.maxLength, TextLimits.password);
    }
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(auth: auth, textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
```

Create `test/routes/change_password_route_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/screens/change_password_screen.dart';
import 'package:scheduling/routes/app_routes.dart';

void main() {
  test('the change-password route needs no arguments', () {
    final route = AppRoutes.onGenerateRoute(
      const RouteSettings(name: AppRoutes.changePassword),
    );

    expect(route, isA<MaterialPageRoute<dynamic>>());
    final page = (route! as MaterialPageRoute<dynamic>).builder(_FakeContext());
    expect(page, isA<ChangePasswordScreen>());
  });
}

class _FakeContext extends Fake implements BuildContext {}
```

- [ ] **Step 3: Run and watch them fail.**

Run: `flutter test --no-pub test/features/auth/screens/change_password_screen_test.dart test/routes/change_password_route_test.dart`
Expected: FAIL at compile — `Error when reading 'lib/features/auth/screens/change_password_screen.dart': The system cannot find the file specified`.

- [ ] **Step 4: Implement the screen.** Create `lib/features/auth/screens/change_password_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/auth/widgets/auth_scaffold.dart';
import 'package:scheduling/features/auth/widgets/password_requirements_checklist.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Forced password change for an active account an admin has reset.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({this.authService, super.key});

  final AuthService? authService;

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  late final AuthService _authService =
      widget.authService ?? ref.read(authServiceProvider);

  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final FocusNode _confirmFocus = FocusNode();

  bool _isObscured = true;
  bool _isConfirmObscured = true;
  bool _isLoading = false;
  bool _isSigningOut = false;
  bool _submitted = false;

  String? _passwordError;
  String? _confirmError;
  String? _bannerError;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool get _isBusy => _isLoading || _isSigningOut;

  bool _validate() {
    final l10n = context.l10n;
    final password = _passwordController.text.trim();
    final passwordErr = AuthValidators.newPassword(context, password);
    final confirm = _confirmController.text.trim();
    final confirmErr = confirm.isEmpty
        ? l10n.validation_pleaseConfirmYourPassword
        : confirm != password
        ? l10n.validation_passwordsDoNotMatch
        : null;
    if (passwordErr != _passwordError || confirmErr != _confirmError) {
      setState(() {
        _passwordError = passwordErr;
        _confirmError = confirmErr;
      });
    }
    return passwordErr == null && confirmErr == null;
  }

  void _onFieldChanged() {
    if (_submitted) _validate();
    if (_bannerError != null) setState(() => _bannerError = null);
  }

  Future<void> _submit() async {
    if (_isBusy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitted = true;
      _bannerError = null;
    });
    if (!_validate()) return;
    if (ref.read(isOfflineProvider)) {
      setState(() {
        _bannerError = const AuthFailureNetwork().toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
      return;
    }

    final logger = ref.read(loggerProvider);
    setState(() => _isLoading = true);
    try {
      await _authService.completePasswordReset(_passwordController.text);
      TextInput.finishAutofillContext();
      if (!mounted) return;
      await _routeIntoApp();
    } catch (error, stackTrace) {
      final failure = AuthErrorMapper.map(error);
      logger.authFailure(
        'AUTH-CHANGEPW completePasswordReset failed',
        failure,
        error,
        stackTrace,
      );
      if (!mounted) return;
      // The flag is already clear server-side, so there is nothing left to do here.
      if (failure is AuthFailureSetupAlreadyComplete) {
        await _routeIntoApp();
        return;
      }
      setState(() {
        _isLoading = false;
        _bannerError = failure.toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
    }
  }

  Future<void> _routeIntoApp() async {
    final outcome = await ref
        .read(signInControllerProvider.notifier)
        .resumeAfterSignUp();
    if (!mounted) return;
    switch (outcome) {
      case SignInSuccess(:final employee):
        await Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.mainCalendar,
          (_) => false,
          arguments: MainCalendarArgs(
            isAdmin: employee.isAdmin,
            employeeId: employee.id,
          ),
        );
      case SignInNoSession() || SignInProfilePending():
        await _signOutToLogin();
      case SignInInvalidCredentials() ||
          SignInNoProfile() ||
          SignInAccountDisabled() ||
          SignInNeedsAccountSetup() ||
          SignInNeedsPasswordChange() ||
          SignInError():
        setState(() {
          _isLoading = false;
          _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
        });
    }
  }

  Future<void> _signOut() async {
    if (_isBusy) return;
    setState(() {
      _isSigningOut = true;
      _bannerError = null;
    });
    await _signOutToLogin();
  }

  Future<void> _signOutToLogin() async {
    final logger = ref.read(loggerProvider);
    try {
      await _authService.signOut();
      if (!mounted) return;
      await Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    } catch (error, stackTrace) {
      logger.warn('AUTH-CHANGEPW signOut failed', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _isSigningOut = false;
        _isLoading = false;
        _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AuthScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.auth_changePasswordTitle,
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: AppSpacing.sp8),
          Text(l10n.auth_changePasswordBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.sp24),
          ..._passwordFields(l10n),
          AuthBanner(message: _bannerError),
          const SizedBox(height: AppSpacing.sp24),
          AnimatedLoadingButton(
            label: l10n.auth_saveNewPassword,
            isLoading: _isBusy,
            onPressed: _submit,
          ),
          const SizedBox(height: AppSpacing.sp8),
          Center(
            child: TextButton(
              onPressed: _isBusy ? null : _signOut,
              child: Text(l10n.settings_logOut),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _passwordFields(AppLocalizations l10n) => [
    AuthPasswordField(
      label: l10n.auth_newPassword,
      showLabel: true,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.newPassword],
      maxLength: TextLimits.password,
      controller: _passwordController,
      enabled: !_isBusy,
      errorText: _passwordError,
      isObscured: _isObscured,
      onSubmitted: _confirmFocus.requestFocus,
      onChanged: _onFieldChanged,
      onToggleObscured: () => setState(() => _isObscured = !_isObscured),
    ),
    ValueListenableBuilder<TextEditingValue>(
      valueListenable: _passwordController,
      builder: (context, value, _) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sp8),
        child: PasswordRequirementsChecklist(password: value.text.trim()),
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    AuthPasswordField(
      label: l10n.auth_confirmPassword,
      showLabel: true,
      prefixIcon: Icons.lock_reset_outlined,
      autofillHints: const [AutofillHints.newPassword],
      maxLength: TextLimits.password,
      controller: _confirmController,
      focusNode: _confirmFocus,
      enabled: !_isBusy,
      errorText: _confirmError,
      isObscured: _isConfirmObscured,
      onSubmitted: _submit,
      onChanged: _onFieldChanged,
      onToggleObscured: () =>
          setState(() => _isConfirmObscured = !_isConfirmObscured),
    ),
  ];
}
```

Notes that the reviewer will ask about: `_isLoading` is set synchronously before the first await (reentrancy rule); the logger is hoisted before the await; `ref.read(signInControllerProvider.notifier)` runs only after a `mounted` check (the autoDispose notifier must not be read early, or it can be disposed by the time the callable returns); `AuthPasswordField` already sets `enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning`.

- [ ] **Step 5: Add the route case.** In `lib/routes/app_routes.dart`, import `package:scheduling/features/auth/screens/change_password_screen.dart` (keep the imports sorted) and add after the `accountSetup` case:

```dart
      case changePassword:
        return AppPageRoute(
          settings: settings,
          builder: (_) => const ChangePasswordScreen(),
        );
```

- [ ] **Step 6: Run and watch them pass.**

Run: `flutter test --no-pub test/features/auth/screens/change_password_screen_test.dart test/routes/change_password_route_test.dart`
Expected: PASS (12 tests).

- [ ] **Step 7: Verify.**

Run: `flutter analyze --no-pub && flutter test --no-pub test/features/auth test/routes`
Expected: `No issues found!`; all PASS.

---

## Task 11: `EmployeeFormController.resetPassword`

**Files:**
- Modify: `lib/features/employees/application/employee_form_controller.dart`
- Test: `test/features/employees/application/employee_form_controller_test.dart`

- [ ] **Step 1: Write the failing tests.** Append inside `main()` of `employee_form_controller_test.dart`:

```dart
  group('resetPassword', () {
    const issued = NewAccountCredentials(
      email: 'alex@test.com',
      password: 'Tmp2pass!wd9',
    );

    test('returns the issued credentials and clears the busy flag', () async {
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) async => issued);

      final outcome = await notifier().resetPassword('e1');

      expect(
        outcome,
        isA<PasswordResetIssued>().having(
          (o) => o.credentials,
          'credentials',
          issued,
        ),
      );
      expect(activity().isResettingPassword, isFalse);
    });

    test('a server failure is a Failed outcome carrying the error', () async {
      final error = Exception('boom');
      when(() => repo.resetEmployeePassword('e1')).thenThrow(error);

      final outcome = await notifier().resetPassword('e1');

      expect(
        outcome,
        isA<PasswordResetFailed>().having((o) => o.error, 'error', error),
      );
    });

    test('a second tap while one is in flight is Busy', () async {
      final gate = Completer<NewAccountCredentials>();
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) => gate.future);

      final first = notifier().resetPassword('e1');
      expect(activity().isResettingPassword, isTrue);
      expect(await notifier().resetPassword('e1'), isA<PasswordResetBusy>());

      gate.complete(issued);
      expect(await first, isA<PasswordResetIssued>());
      verify(() => repo.resetEmployeePassword('e1')).called(1);
    });
  });
```

- [ ] **Step 2: Run and watch them fail.**

Run: `flutter test --no-pub test/features/employees/application/employee_form_controller_test.dart`
Expected: FAIL at compile — `The method 'resetPassword' isn't defined for the type 'EmployeeFormController'`.

- [ ] **Step 3: Implement.** In `employee_form_controller.dart`:

(a) Add after the `AccountDeleteBusy` class:

```dart
/// Outcome of an admin resetting an active person's password.
sealed class PasswordResetOutcome {
  const PasswordResetOutcome();
}

/// The server issued a temporary password; [credentials] are what the admin reads out.
class PasswordResetIssued extends PasswordResetOutcome {
  const PasswordResetIssued(this.credentials);
  final NewAccountCredentials credentials;
}

class PasswordResetFailed extends PasswordResetOutcome {
  const PasswordResetFailed(this.error);
  final Object error;
}

/// A duplicate tap while a reset is in flight; surfaces nothing.
class PasswordResetBusy extends PasswordResetOutcome {
  const PasswordResetBusy();
}
```

(b) In `EmployeeFormActivity`: add `this.isResettingPassword = false,` to the constructor after `this.isTogglingStatus = false,`; add the field `final bool isResettingPassword;` after `final bool isTogglingStatus;`; add `bool? isResettingPassword,` to `copyWith`'s parameters and `isResettingPassword: isResettingPassword ?? this.isResettingPassword,` to its body; add `&& other.isResettingPassword == isResettingPassword` to `operator ==` (after the `isTogglingStatus` comparison); and add `isResettingPassword,` as the last argument of `Object.hash` in `hashCode`.

(c) Add to `EmployeeFormController`, after `deleteAccount`:

```dart
  /// Issues a temporary password for an active person and forces a change at next sign-in.
  Future<PasswordResetOutcome> resetPassword(String docId) async {
    if (state.isResettingPassword) return const PasswordResetBusy();
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(isResettingPassword: true);
    try {
      return PasswordResetIssued(await repo.resetEmployeePassword(docId));
    } catch (e, st) {
      logger.warn('EMP-RESETPW resetEmployeePassword failed', e, st);
      return PasswordResetFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isResettingPassword: false);
    }
  }
```

- [ ] **Step 4: Run and watch them pass.**

Run: `flutter test --no-pub test/features/employees/application/employee_form_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Verify.**

Run: `flutter analyze --no-pub`
Expected: `No issues found!`

---

## Task 12: Reset password in the edit-person sheet + employee l10n keys

**Files:**
- Modify: `lib/features/employees/widgets/sheets/edit_person_sheet.dart`, `lib/features/employees/widgets/dialogs/new_account_dialog.dart`, `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Test: `test/features/employees/widgets/sheets/edit_person_sheet_test.dart`, `test/features/employees/employees_scale_sweep_test.dart`

- [ ] **Step 1: Add the ARB keys.** In `lib/l10n/app_en.arb`, insert after the `"@employees_newPasswordIssued": { … },` block:

```json
  "employees_resetPasswordConfirmTitle": "Reset {name}'s password?",
  "@employees_resetPasswordConfirmTitle": {
    "description": "Confirm-dialog title before an admin resets an active person's password",
    "placeholders": {
      "name": {
        "type": "String"
      }
    }
  },
  "employees_resetPasswordConfirmBody": "They'll be signed out on every device and must choose a new password at next sign-in.",
  "@employees_resetPasswordConfirmBody": {
    "description": "Confirm-dialog body explaining what an admin password reset does"
  },
```

and after the `"@error_introChangeEmployeeStatus": { … },` block:

```json
  "error_introResetPassword": "Couldn't reset the password",
  "@error_introResetPassword": {
    "description": "Error intro for EMP-RESETPW"
  },
```

In `lib/l10n/app_fr.arb`, insert after `"employees_newPasswordIssued": "Nouveau mot de passe temporaire — le précédent ne fonctionne plus",`:

```json
  "employees_resetPasswordConfirmTitle": "Réinitialiser le mot de passe de {name} ?",
  "employees_resetPasswordConfirmBody": "Cette personne sera déconnectée sur tous ses appareils et devra choisir un nouveau mot de passe à sa prochaine connexion.",
  "error_introResetPassword": "Impossible de réinitialiser le mot de passe",
```

The existing keys `employees_resetPassword` ("Reset password", the button and confirm label) and `employees_passwordReset` ("Password reset", the credentials-dialog title) are reused. If the hook did not regenerate, run `flutter gen-l10n`.

- [ ] **Step 2: Update the two harnesses** (the sheet now watches `authUidProvider`, which reaches `FirebaseAuth.instance` without an override). In `edit_person_sheet_test.dart`, add imports:

```dart
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
```

Extend `wrap`'s parameter list with `String? signedInUid = 'admin-uid',` and `NoticeService? notices,`, and its `overrides` with:

```dart
      authUidProvider.overrideWith((ref) => Stream<String?>.value(signedInUid)),
      if (notices != null) noticeServiceProvider.overrideWithValue(notices),
```

In `employees_scale_sweep_test.dart`, add `import 'package:scheduling/core/providers/firebase_providers.dart';` and, in `_wrap`'s overrides, `authUidProvider.overrideWith((ref) => Stream<String?>.value('admin-uid')),`.

- [ ] **Step 3: Write the failing tests.** Append inside `main()` of `edit_person_sheet_test.dart`:

```dart
  group('Reset password', () {
    const teammate = EmployeeRecord(
      id: 'e1',
      name: 'Theo',
      email: 'theo@x.com',
      status: 'active',
      uid: 'emp-uid',
    );
    const issued = NewAccountCredentials(
      email: 'theo@x.com',
      password: 'Tmp2pass!wd9',
    );
    final resetButton = find.byKey(const Key('resetPassword'));
    Finder confirmButton() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Reset password'),
    );

    testWidgets('an active teammate offers Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      expect(resetButton, findsOneWidget);
    });

    testWidgets('the signed-in admin gets no Reset on their own sheet', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, signedInUid: 'emp-uid'));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('a disabled person has no Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(status: 'disabled')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('an invited person has no Reset password here', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(status: 'invited')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('confirming issues and shows the temporary password', (
      tester,
    ) async {
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) async => issued);
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      expect(find.text("Reset Theo's password?"), findsOneWidget);
      await tester.tap(confirmButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(() => repo.resetEmployeePassword('e1')).called(1);
      expect(find.text('Password reset'), findsOneWidget);
      expect(find.text('Tmp2pass!wd9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling the confirmation resets nothing', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      // The sheet header carries its own Cancel, so scope to the dialog.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      verifyNever(() => repo.resetEmployeePassword(any()));
    });

    testWidgets('a failed reset composes the reset-password notice', (
      tester,
    ) async {
      final notices = NoticeService();
      final seen = <AppNotice>[];
      notices.stream.listen(seen.add);
      when(() => repo.resetEmployeePassword('e1')).thenThrow(Exception('boom'));
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, notices: notices));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await tester.tap(confirmButton());
      await tester.pumpAndSettle();

      expect(seen.single, isA<NoticeError>());
      expect(seen.single.message, startsWith("Couldn't reset the password"));
    });

    testWidgets('offline, the reset fails fast without the server', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, offline: true));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await tester.tap(confirmButton());
      await tester.pumpAndSettle();

      verifyNever(() => repo.resetEmployeePassword(any()));
    });

    testWidgets('the footer survives 260 px at 2.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(260, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(teammate, textScale: 2));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
```

- [ ] **Step 4: Run and watch them fail.**

Run: `flutter test --no-pub test/features/employees/widgets/sheets/edit_person_sheet_test.dart`
Expected: FAIL — `an active teammate offers Reset password` with `Expected: exactly one matching candidate / Actual: _KeyWidgetFinder:<Found 0 widgets with key [<'resetPassword'>]>` (and the dialog/notice tests likewise); the pre-existing tests keep passing.

- [ ] **Step 5: Give `showNewAccountDialog` an optional title.** In `new_account_dialog.dart`, replace the function and the widget's constructor/fields:

```dart
Future<void> showNewAccountDialog(
  BuildContext context, {
  required String name,
  required NewAccountCredentials credentials,
  String? title,
}) {
  final heading = title ?? context.l10n.employees_accountCreatedTitle;
  if (context.isCupertino) {
    // showCupertinoDialog is non-dismissible by default, which matches what
    // we do in the Material branch.
    return showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => _NewAccountDialog(
        name: name,
        credentials: credentials,
        title: heading,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _NewAccountDialog(
      name: name,
      credentials: credentials,
      title: heading,
    ),
  );
}

class _NewAccountDialog extends StatefulWidget {
  const _NewAccountDialog({
    required this.name,
    required this.credentials,
    required this.title,
  });

  final String name;
  final NewAccountCredentials credentials;
  final String title;
```

and in `build`, replace both `title: Text(l10n.employees_accountCreatedTitle),` with `title: Text(widget.title),`.

- [ ] **Step 6: Implement the sheet.** In `edit_person_sheet.dart`:

(a) Add imports (keep them sorted): `package:scheduling/core/providers/firebase_providers.dart` and `package:scheduling/features/employees/widgets/dialogs/new_account_dialog.dart`.

(b) Add after `_confirmToggleStatus`:

```dart
  Future<void> _confirmResetPassword() async {
    final l10n = context.l10n;
    final name = widget.employee.displayName;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.employees_resetPasswordConfirmTitle(name),
      message: l10n.employees_resetPasswordConfirmBody,
      confirmLabel: l10n.employees_resetPassword,
    );
    if (!mounted || !confirmed) return;
    if (guardedOffline(context, ref, intro: l10n.error_introResetPassword)) {
      return;
    }

    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .resetPassword(widget.employee.id);
    if (!mounted) return;

    switch (outcome) {
      case PasswordResetBusy():
        break;
      case PasswordResetIssued(:final credentials):
        await showNewAccountDialog(
          context,
          name: name,
          credentials: credentials,
          title: l10n.employees_passwordReset,
        );
      case PasswordResetFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: l10n.error_introResetPassword,
                error: error,
              ),
            );
    }
  }
```

(c) In `build`, replace:

```dart
    final sheetBusy = activity.isSaving || activity.isTogglingStatus;
```

with:

```dart
    final sheetBusy =
        activity.isSaving ||
        activity.isTogglingStatus ||
        activity.isResettingPassword;
    final signedInUid = ref.watch(authUidProvider).value;
    // Fail closed: hidden until the signed-in uid is known and is not this person.
    final canResetPassword =
        widget.employee.isActive &&
        !_isDisabled &&
        widget.employee.uid.isNotEmpty &&
        signedInUid != null &&
        signedInUid != widget.employee.uid;
```

and `..._accessSection(theme, l10n, sheetBusy),` with `..._accessSection(theme, l10n, sheetBusy, canResetPassword),`.

(d) Change `_accessSection`'s signature to add `bool canResetPassword,` after `bool sheetBusy,`, and pass it to the footer:

```dart
    _StatusFooter(
      employeeId: widget.employee.id,
      isDisabled: _isDisabled,
      isBusy: sheetBusy,
      onToggle: _confirmToggleStatus,
      onResetPassword: canResetPassword ? _confirmResetPassword : null,
    ),
```

(e) In `_StatusFooter`: add `this.onResetPassword,` to the constructor after `required this.onToggle,`, the field `final VoidCallback? onResetPassword;`, and make the first children of the `Column` in `build`:

```dart
        if (onResetPassword case final onReset?) ...[
          OutlinedButton.icon(
            key: const Key('resetPassword'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            onPressed: isBusy ? null : onReset,
            icon: const Icon(Icons.lock_reset_outlined, size: 18),
            label: Text(l10n.employees_resetPassword),
          ),
          const SizedBox(height: AppSpacing.sp8),
        ],
```

(before the existing destructive `OutlinedButton.icon`). Replace the `_StatusFooter` doc line `/// Disable / re-enable, with the count of jobs a human still has to move.` with `/// Reset password, disable / re-enable, and the count of jobs a human still has to move.`

- [ ] **Step 7: Run and watch them pass.**

Run: `flutter test --no-pub test/features/employees/widgets/sheets/edit_person_sheet_test.dart test/features/employees/employees_scale_sweep_test.dart`
Expected: PASS (the pre-existing sheet tests use `uid: ''` or no status, so their footers are unchanged).

- [ ] **Step 8: Verify.**

Run: `flutter analyze --no-pub && flutter test --no-pub test/features/employees`
Expected: `No issues found!`; all PASS. Also confirm `lib/l10n/.gen/untranslated.json` names none of the six new keys.

---

## Task 13: Docs, rules registry and the deploy count

**Files:** `.claude/rules/employees.md`, `.claude/rules/error-handling.md`, `CLAUDE.md`, `functions/CLAUDE.md`, `docs/CLOUD_FUNCTIONS.md`, `.claude/skills/deploy/SKILL.md`, `docs/plans/README.md`, `docs/plans/2026-09-28-admin-password-reset.md`

Replace every `DATE` below with the output of `date +%F` on the day this task runs.

- [ ] **Step 1: `.claude/rules/employees.md`.** Insert a new bullet directly BEFORE the line `- **Employee accounts: the admin invites, the employee sets up** (P4c,`:

```markdown
- **Admin password reset for an ACTIVE account** (DATE). Employee emails are not
  real inboxes, so Forgot password can never reach anyone. Reset password on
  `edit_person_sheet.dart` (shown only for an `active` doc with a `uid` that is
  NOT the signed-in admin; hidden while that uid is unknown) calls
  `resetEmployeePassword`, which re-checks `active` + the same `uid` in a
  transaction and writes the server-owned **`passwordResetRequired: true`**
  FIRST, then sets a `generateStartingPassword()` value, then
  `revokeRefreshTokens` — all under `accountOperations/{uid}` (`password-reset`).
  The order is fail-safe: an Auth failure leaves the flag set, so the worst case
  is being asked to change a password that did not change. The admin reads the
  result off `NewAccountDialog` (titled `employees_passwordReset`). Both gates
  route `active && passwordResetRequired` to `ChangePasswordScreen` AFTER the
  unchanged `invited` branch and KEEP the session; sign-in also **clears the
  identity cache** on that branch, because a stale `AuthCache` hit lets a cold
  start fast-path past the screen. The screen calls `completePasswordReset`
  (`assertActiveCall`; the SAME `isStrongPassword` as setup; the
  `setSetupPassword` policy-code mapping; Auth first, then the flag clear),
  reauthenticates best-effort and routes in through `resumeAfterSignUp`, which
  now also refuses a still-flagged doc. The flag is in BOTH `/users` rules
  denylists and neither `EmployeeRecord.toMap()` nor `updateEmployee` emits it —
  never add it to a client write path. Status never moves, so `syncUsersByUid`
  has nothing to reconcile. Builds ≤ 1.62.x ignore the flag and simply keep the
  temporary password. Tags: `EMP-RESETPW` (notice), `AUTH-CHANGEPW` (log-only).
```

- [ ] **Step 2: `.claude/rules/error-handling.md`.** (a) In the notice table, add after the `| \`EMP-DELETE\` | \`error_introRemoveAccount\` |` row:

```markdown
  | `EMP-RESETPW` | `error_introResetPassword` |
```

(b) Replace the line `  - Auth / account: \`AUTH-SETUP\`, \`AUTH-SIGNIN\`, \`AUTH-PREFILL\`, \`AUTH-RESET\`` with `  - Auth / account: \`AUTH-SETUP\`, \`AUTH-SIGNIN\`, \`AUTH-PREFILL\`, \`AUTH-RESET\`, \`AUTH-CHANGEPW\``. Then replace the two lines that close that bullet:

```markdown
    the breadcrumb for `AuthFailureStartingPasswordReused`, the load-bearing
    guard.)
```

with:

```markdown
    the breadcrumb for `AuthFailureStartingPasswordReused`, the load-bearing
    guard. `AUTH-CHANGEPW` (DATE) is `ChangePasswordScreen`'s submit and
    sign-out plus `AuthService.completePasswordReset`'s session renewal; the
    route-in after a change logs under `AUTH-SETUP` through the shared
    `resumeAfterSignUp`.)
```

(c) In the `logger.authFailure` bullet, replace `sites (\`sign_in_controller\`, \`account_setup_screen\`, \`forgot_password_screen\`,` with `sites (\`sign_in_controller\`, \`account_setup_screen\`, \`change_password_screen\`, \`forgot_password_screen\`,`.

- [ ] **Step 3: Root `CLAUDE.md`.** (a) In the **Auth** invariant, after `gets the old sign-out. Tests pin both halves.` append:

```markdown
  **An `active` doc with `passwordResetRequired: true` (admin reset, DATE)
  routes to `ChangePasswordScreen` and KEEPS the session** at both gates,
  checked AFTER the invited and active gates; sign-in clears the identity cache
  there so a cold start cannot fast-path past it. The flag is server-owned
  (`resetEmployeePassword` sets it, `completePasswordReset` clears it) and sits
  in both `/users` rules denylists. See `.claude/rules/employees.md`.
```

(b) Directly BEFORE the paragraph that starts `**\`syncClientBuilding\` was ADDED 2026-09-23`, insert:

```markdown
**Two callables were ADDED DATE (30 → 32)** — `resetEmployeePassword` (admin,
`assertAdminCall`) and `completePasswordReset` (self-service, `assertActiveCall`)
in `employee_accounts.js`, with `passwordResetRequired` added to the `/users`
create and update denylists. Deploy `functions,firestore:rules` BEFORE the app
build that calls them; they are new callables, so there is no payload-superset
concern, and no backfill (an absent flag means "not required").

```

- [ ] **Step 4: `functions/CLAUDE.md`.** (a) Replace

```markdown
`us-central1`). `index.js` is now a thin wiring surface that re-exports 30
functions in source, all deployed (`syncClientBuilding` went live 2026-09-29) under their original names (25 until 2026-09-04, when
```

with

```markdown
`us-central1`). `index.js` is now a thin wiring surface that re-exports 32
functions in source — 30 deployed (`syncClientBuilding` went live 2026-09-29;
`resetEmployeePassword` and `completePasswordReset` were added DATE and deploy
before the app build that calls them) — under their original names (25 until 2026-09-04, when
```

(b) Directly BEFORE the line `Pure helpers \`performCreateAccount\`, \`performDeleteAccount\`,`, insert:

```markdown
**Admin password reset (DATE).** `resetEmployeePassword` opens with
`assertAdminCall(req, {docId})` → `requireDocId` → the 20/hr create/delete
budget, refuses the caller's own doc (`self-reset`) and any doc that is not
`active` with a `uid` (`not-active`), then under `withAccountOperation(uid,
"password-reset")` runs `markPasswordResetRequired` (transactional re-check that
lets a deactivate committing first win) → `auth.updateUser(password)` →
`revokeRefreshTokens`, logging only `shortHash(uid)`. `completePasswordReset`
opens with `assertActiveCall(req, {newPassword})` → `requireString(…, 128)` →
`isStrongPassword` (shared with `completeEmployeeSetup` — never spell the regexes
twice) → the 5/15 min setup budget, then under the same lock requires exactly
one `active` doc with `passwordResetRequired === true` (`not-required`), sets the
password through `setSetupPassword` (policy codes → `invalid-newPassword`) and
clears the flag in a transaction. Both are pinned in
`employee_accounts_callables.test.js`; the emulator runner checks the rules
denylist and a full reset → sign-in → change cycle.

```

- [ ] **Step 5: `docs/CLOUD_FUNCTIONS.md`.** (a) In the Summary table, add directly after the `| \`changeEmployeeEmail\` |` row:

```markdown
| `resetEmployeePassword` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` (edit-person sheet, Reset password on an active person) | — | App Check ✓ · admin · durable 20/hr·uid · `accountOperations` lock (uid) · refuses self and non-active |
| `completePasswordReset` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` → `auth_service.dart` (Change password screen) | — | App Check ✓ · active caller (`assertActiveCall`) · durable 5/15min·uid · `accountOperations` lock · requires `passwordResetRequired` |
```

(b) Insert directly BEFORE the heading `## Maps / Places proxies`:

```markdown
### `resetEmployeePassword` — `employee_accounts.js`
Admin-only. Resets an ACTIVE employee's password (their email is not a real
inbox, so Forgot password cannot help). Guard order auth → `assertAdmin` →
payload (`docId` only, `/` rejected) → durable 20/hr per admin uid → work.
Refuses the caller's own account (`failed-precondition / self-reset`) and a doc
that is missing, has no `uid` or is not `active` (`failed-precondition /
not-active`) — invited accounts keep the pending-row Reset, disabled ones stay
locked out. Under the `accountOperations/{uid}` lock: a transaction re-checks
`active` + the same `uid` and writes `passwordResetRequired: true`; THEN
`auth.updateUser` with a `generateStartingPassword()` value; THEN
`revokeRefreshTokens` (signed out everywhere at the next token refresh). A
failure after the flag leaves it set — the worst case is a forced change of a
password that did not change. Returns `{email, password}` in
`createEmployeeAccount`'s shape; logs only `shortHash(uid)`, never the password.

### `completePasswordReset` — `employee_accounts.js`
Self-service. Opens with `assertActiveCall(req, {newPassword})`, then
`requireString(newPassword, 128)` and the shared `isStrongPassword` (8+, `\p{Lu}`,
`\p{Ll}`, a digit) BEFORE the durable 5/15 min limiter, so a malformed payload
burns no slot. Under the `accountOperations/{uid}` lock it requires exactly one
`active` users doc for the caller with `passwordResetRequired === true`
(`failed-precondition / not-required` otherwise, which the app treats as
"already done"), sets the password via `setSetupPassword` (Auth policy refusals
→ `invalid-argument / invalid-newPassword`), then clears the flag in a
transaction. Auth first, flag second: a flag clear that fails after the password
landed is retried by the person and converges. Returns `{ok: true}`.

```

(c) In "Deployment status", insert a new bullet directly ABOVE the line `- **30 functions defined, 29 DEPLOYED** (2026-09-28, release 1.62.1+92):` (leave that bullet as history):

```markdown
- **32 functions defined, 30 DEPLOYED** (DATE): `resetEmployeePassword` and
  `completePasswordReset` are new in source and ship with a
  `functions,firestore:rules` deploy BEFORE the app build that calls them.
```

- [ ] **Step 6: `.claude/skills/deploy/SKILL.md`.** Replace `list (**30 exports**) is the source of truth` with `list (**32 exports**) is the source of truth`, and `\`functions/index.js\` — all 30 deployed, no orphans.` with `\`functions/index.js\` — all 32 deployed, no orphans.`

- [ ] **Step 7: `docs/plans/README.md`.** Replace the `2026-09-28-admin-password-reset.md` row's State cell with:

```markdown
**BUILT DATE, NOT DEPLOYED.** Admin resets an ACTIVE employee's password (emails aren't real inboxes, so Forgot password can't work): server-owned `passwordResetRequired` flag, temp password, sign-out everywhere, forced Change password screen. Two new callables (30 → 32) + a rules denylist field — deploy `functions,firestore:rules` BEFORE the app build. Plan: `2026-09-28-admin-password-reset-plan.md`. |
```

and add a row directly below it:

```markdown
| `2026-09-28-admin-password-reset-plan.md` | **EXECUTED DATE.** Task-by-task TDD plan for the design above; its "Deviations from the spec" section records where the real code forced a different shape. |
```

- [ ] **Step 8: The design doc's status line.** In `docs/plans/2026-09-28-admin-password-reset.md`, replace `Status: **approved 2026-09-28, not started.** Owner-approved in conversation.` with `Status: **approved 2026-09-28, BUILT DATE, not deployed.** Owner-approved in conversation. Implementation: \`2026-09-28-admin-password-reset-plan.md\`.`

- [ ] **Step 9: Verify.**

Run: `git diff --stat -- CLAUDE.md .claude docs functions/CLAUDE.md` and `grep -rnw "DATE" CLAUDE.md .claude/rules/employees.md .claude/rules/error-handling.md functions/CLAUDE.md docs/CLOUD_FUNCTIONS.md docs/plans/README.md docs/plans/2026-09-28-admin-password-reset.md`
Expected: the eight doc files above appear in the stat (several `.claude/rules` and `docs/` files were already modified before this plan, so the stat is not limited to them); the grep prints nothing (every `DATE` substituted). `.claude/rules/security.md` needs no edit: its App Check module list already names `employee_accounts.js`.

---

## Task 14: Full CI run

- [ ] **Step 1: App analyzer.**

Run: `flutter analyze --no-pub`
Expected: `No issues found!`

- [ ] **Step 2: App tests.**

Run: `flutter test --no-pub`
Expected: `All tests passed!` Record the count in the task report — a recorded count is only a claim until this run backs it.

- [ ] **Step 3: Functions lint and tests.**

Run: `cd functions && npm run lint && npx jest`
Expected: eslint silent; every suite PASS and the coverage thresholds in `functions/jest.config.js` met.

- [ ] **Step 4: BOM and codegen hygiene.**

Run: `git status --short | grep 'D .*\.freezed\.dart'` and, for each new or edited `.dart` file, `head -c 3 <file> | od -An -tx1`
Expected: the grep prints nothing; no file starts with `ef bb bf`.

- [ ] **Step 5: Emulator runner** (skip only if Java 21 / the Firebase CLI is unavailable here, and say so — CI runs it on push).

Run: `firebase emulators:exec --project demo-scheduling-review --only "auth,firestore,storage" "node functions/__tests__/emulator/storage_rules.smoke.js"`
Expected: exit 0, including `Password reset: denylist, flag and credential checked.`

---

## Rollout

1. **Backend first:** `firebase deploy --only functions,firestore:rules` (clear `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` first, never `--force`; see `docs/DEPLOYMENT.md` §5). Both callables are NEW, so there is no `assertPayloadShape` superset concern; the new denylist entry rejects nothing any shipped build writes. Verify by NAME that 32 functions are live.
2. **Then** build and ship the app.
3. **No backfill:** an absent `passwordResetRequired` means "not required".
4. Old builds (≤ 1.62.x) ignore the flag; a person reset while on one keeps the temporary password as their password. Nothing breaks.

---

## Deviations from the spec (forced by the real code)

- **`requireDocId`, not `requireString`, for `docId`.** Same caps plus it rejects `/`, exactly as `deleteEmployeeAccount` does; `.doc()` would otherwise throw an opaque `internal`.
- **`completePasswordReset` runs the strength check BEFORE the rate limiter**, not under the lock as spec step 2 lists it. `.claude/rules/security.md` requires payload validation before a slot is consumed, and `completeEmployeeSetup` already orders it that way.
- **`completePasswordReset` re-reads the doc by `uid` query** (as `completeEmployeeSetup` does) and also requires `status === "active"`, failing closed as `not-required`. The bridge row's `docId` is not used for the write.
- **Sign-in CLEARS the identity cache on the flagged branch** (not in the spec). Without it, a person who signs in with the temporary password on a device that cached their identity earlier and then kills the app is routed by `SplashScreen`'s cache fast path straight to the calendar, skipping the Change password screen.
- **`resumeAfterSignUp` also refuses a still-flagged doc**, and `ChangePasswordScreen` reuses it to route in (so route-in failures log under `AUTH-SETUP`, the tag that already owns that method).
- **No new `AuthFailure` variant.** The server's `not-required` maps to the existing `AuthFailureSetupAlreadyComplete`, which the screen treats as "already done — walk in", and `invalid-newPassword` to the existing `AuthFailureWeakPassword`.
- **The reset lives in `EmployeeFormController.resetPassword`** with a sealed `PasswordResetOutcome` (`Issued`/`Failed`/`Busy`) and an `isResettingPassword` flag, following the controller convention for every other sheet action rather than a bare widget flag. "Not self" is decided from `authUidProvider` and fails closed while that uid is unknown.
- **`NewAccountDialog` gains an optional `title`** so a reset reads "Password reset" (existing key `employees_passwordReset`); the button and confirm label reuse the existing `employees_resetPassword`. New keys: `auth_changePasswordTitle`, `auth_changePasswordBody`, `auth_saveNewPassword`, `employees_resetPasswordConfirmTitle`, `employees_resetPasswordConfirmBody`, `error_introResetPassword`.
- **`AuthService.completePasswordReset` does not log**; the screen logs once through `logger.authFailure`, avoiding the two-layer double filing `.claude/rules/error-handling.md` warns about. `_renewSessionAfterSetup` becomes `_renewSession(label:)` so each caller keeps its own greppable tag.
- **Rules are tested through the emulator runner** (`functions/__tests__/emulator/safety_checks.js`), the only harness in the repo that evaluates `firestore.rules`.
- **No "reused the temporary password" refusal** on Change password (setup has one). The spec does not ask for it, and an admin who knows the temporary password can reset again at will, so it buys nothing here.
- **Extra doc touched:** `.claude/skills/deploy/SKILL.md` states the export count (30) and is used as a deploy check.

---

## Self-review against the spec

| Spec point | Task |
|---|---|
| `resetEmployeePassword`: `assertAdminCall({docId})`, docId validation, 20/hr limiter, App Check | 2 |
| Refuse self (`self-reset`), missing / no-uid / non-active (`not-active`) | 2 |
| Lock; transactional re-check + flag + `updatedAt`; `updateUser`; `revokeRefreshTokens`; fail-safe order | 2 |
| Returns `{email, password}`; logs only `shortHash(uid)`; never the password | 2 |
| `completePasswordReset`: `assertActiveCall({newPassword})`, `requireString(128)`, 5/15 min | 3 |
| `not-required` when no flag; shared strength check; policy-code mapping via the B2 helper; clear flag after password | 1, 3 |
| Idempotent retry after a failed flag clear; lock released on failure | 3 |
| Rules: flag in `/users` create + update denylists; no `syncUsersByUid` change | 5 |
| Exports 30 → 32, `index_exports.test.js` | 4 |
| `EmployeeRecord.passwordResetRequired` (default false) | 6 |
| Repository `resetEmployeePassword` → `NewAccountCredentials`, loose cast | 7 |
| `AuthService.completePasswordReset` + best-effort reauth | 8 |
| Both gates, after `isInvited`, route active + flag to Change password; route added | 9, 10 |
| `ChangePasswordScreen`: two `AuthPasswordField`s, `TextLimits.password`, IME flag, checklist, confirm match, Sign out, banner, `AUTH-CHANGEPW` | 10 |
| Admin button beside Deactivate, active + not self, `showConfirmDialog`, `NewAccountDialog`, `composeErrorNotice` + `error_introResetPassword`, `EMP-RESETPW`, in-flight flag before first await | 11, 12 |
| ARB keys EN + FR with metadata | 10, 12 |
| Jest cases listed in the spec (gate mutation, refusals, ordering, flag survives, revoke, limiter after validation, shape; not-required, weak/too-long, mapping, clear-after-set, lock release) | 2, 3 |
| Dart cases listed in the spec (gate routing both controllers, screen success/failure at 260 px × 2, button visibility + dialog flow, record parse) | 6, 9, 10, 12 |
| Docs, tag registry, counts, README row | 13 |
| Full CI | 14 |
| Rollout: functions + rules before the app build, no backfill | Rollout |

Names used consistently across tasks: `isStrongPassword`, `markPasswordResetRequired`, `resetEmployeePassword`, `completePasswordReset`, `passwordResetRequired`, `SignInNeedsPasswordChange`, `SplashGoToChangePassword`, `AppRoutes.changePassword`, `ChangePasswordScreen`, `PasswordResetOutcome` / `PasswordResetIssued` / `PasswordResetFailed` / `PasswordResetBusy`, `isResettingPassword`, `resetPassword(docId)`, `EMP-RESETPW`, `AUTH-CHANGEPW`, `error_introResetPassword`.
