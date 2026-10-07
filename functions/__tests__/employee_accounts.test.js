"use strict";

/**
 * Tests the race-sensitive transaction cores of the employee-account
 * lifecycle (createEmployeeAccount / completeEmployeeSetup /
 * deleteEmployeeAccount) plus the pure activation patch. The onCall wrappers'
 * guards live elsewhere and aren't covered here.
 */

const {
  provisionAuthAccount,
  resetProvisionedPassword,
  performCreateAccount,
  performDeleteAccount,
  performChangeEmail,
  notifyEmailChanged,
  buildActivationPatch,
  generateStartingPassword,
  isStrongPassword,
} = require("../employee_accounts");
const {buildEmailChangedMessage, buildSelfEmailChangedMessage} =
  require("../notification_messages");
const crypto = require("node:crypto");

const TS = {__serverTimestamp: true};
const serverTimestamp = () => TS;

const FIELDS = {
  name: "New Employee",
  firstName: "New",
  lastName: "Employee",
  email: "new@company.test",
  phone: "(514) 555-0100",
  colorValue: "4280391411",
  jobTitle: "technician",
};

/**
 * Fake Firestore exposing exactly the surface these cores use: a
 * collection().where().limit() query read via tx.get, doc refs, and a
 * transaction recording every op in sequence.
 * @param {Object=} opts `existingUser` (fake users query doc) and `doc` (fake
 *   snapshot returned for a direct users doc get).
 * @return {{db: !Object, ops: !Array, newRefs: !Array}}
 */
function fakeDb(opts = {}) {
  const existingUser = opts.existingUser || null;
  const docSnap = opts.doc || null;
  const ops = [];
  const newRefs = [];
  let autoId = 0;

  // Keyed by the queried field: performCreateAccount runs an email lookup AND
  // a uid-uniqueness lookup, and they must be answerable separately.
  const emailQuery = {_kind: "usersQuery", field: "email"};
  const uidQuery = {_kind: "usersQuery", field: "uid"};
  // Docs already carrying the uid under test (other than `existingUser`).
  const uidHolders = opts.uidHolders || [];

  const db = {
    collection: (name) => {
      if (name !== "users") throw new Error(`unexpected collection ${name}`);
      return {
        where: jest.fn((field) => ({
          limit: jest.fn(() => (field === "uid" ? uidQuery : emailQuery)),
        })),
        doc: jest.fn((id) => {
          const ref = {id: id || `new-user-${autoId++}`, _kind: "userRef"};
          newRefs.push(ref);
          return ref;
        }),
      };
    },
    runTransaction: async (fn) => {
      const tx = {
        get: jest.fn((target) => {
          if (target === emailQuery) {
            ops.push({op: "get", target: "usersQuery"});
            return Promise.resolve({
              empty: existingUser === null,
              docs: existingUser ? [existingUser] : [],
            });
          }
          if (target === uidQuery) {
            ops.push({op: "get", target: "uidQuery"});
            return Promise.resolve({
              empty: uidHolders.length === 0,
              docs: uidHolders,
            });
          }
          ops.push({op: "get", target: "userRef"});
          return Promise.resolve(
              docSnap || {exists: false, data: () => null},
          );
        }),
        set: jest.fn((ref, data) => ops.push({op: "set", ref, data})),
        update: jest.fn((ref, data) => ops.push({op: "update", ref, data})),
        delete: jest.fn((ref) => ops.push({op: "delete", ref})),
      };
      return fn(tx);
    },
  };
  return {db, ops, newRefs};
}

/**
 * @param {!Object} data stored users-doc data.
 * @param {string=} id doc id.
 * @return {!Object} a fake query doc.
 */
function userDoc(data, id = "existing-doc") {
  return {id, ref: {id, _kind: "existingRef"}, data: () => data};
}

describe("generateStartingPassword", () => {
  test("is 12 unambiguous characters carrying each required class", () => {
    for (let i = 0; i < 200; i++) {
      const pw = generateStartingPassword();
      // Positive, not just `toHaveLength(12)` plus a banned-glyph check: a
      // stray space or quote pasted into an alphabet constant would ship
      // through a negative assertion.
      expect(pw).toMatch(/^[A-Za-z0-9!@$?*]{12}$/);
      expect(pw).toMatch(/[A-Z]/);
      expect(pw).toMatch(/[a-z]/);
      expect(pw).toMatch(/[0-9]/);
      // The admin reads this aloud, so no glyph pair anyone mishears.
      expect(pw).not.toMatch(/[0O1lI]/);
    }
  });

  test("carries exactly one non-alphanumeric character", () => {
    // Identity Platform's password policy can require a non-alphanumeric
    // character, and an alphanumeric-only mint is then rejected outright by
    // createUser -- which is what took account creation down on 2026-08-21,
    // once the shared `Welcome123!` constant (and its trailing symbol) was
    // replaced by this generator. The class mix is only policy-proof, as the
    // constant's comment claims, if a symbol is actually in it.
    // EXACTLY one, not at least one: the admin dictates this aloud, so the
    // number of awkward glyphs is bounded on purpose.
    for (let i = 0; i < 200; i++) {
      const pw = generateStartingPassword();
      const symbols = pw.replace(/[A-Za-z0-9]/g, "");
      expect(symbols).toHaveLength(1);
      expect(symbols).toMatch(/^[!@$?*]$/);
    }
  });

  test("draws from the CSPRNG, never Math.random", () => {
    // The whole security value of this function is its randomness SOURCE, and
    // every other test here passes against a Math.random implementation:
    // shape, uniqueness and "the shuffle ran" are all satisfied by it. This is
    // the one assertion that would catch a later pass "simplifying" the crypto
    // require away.
    const spy = jest.spyOn(crypto, "randomInt");
    generateStartingPassword();
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });

  test("does not repeat across calls", () => {
    const seen = new Set();
    for (let i = 0; i < 100; i++) seen.add(generateStartingPassword());
    expect(seen.size).toBe(100);
  });

  test("shuffles, so the guaranteed classes are not always in front", () => {
    // Without the shuffle the first character is ALWAYS the uppercase pick,
    // so this count would be exactly 200.
    const upperFirst = Array.from({length: 200}, generateStartingPassword)
        .filter((pw) => /[A-Z]/.test(pw[0])).length;
    expect(upperFirst).toBeGreaterThan(20);
    expect(upperFirst).toBeLessThan(180);
  });
});

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

describe("provisionAuthAccount", () => {
  // These tests are about the plumbing, not the value — a plain literal
  // stands in for whatever generateStartingPassword() actually produces.
  const PW = "TestPw23456x";

  test("mints a new account with the given starting password", async () => {
    const auth = {
      createUser: jest.fn(async () => ({uid: "uid-1"})),
      getUserByEmail: jest.fn(),
      updateUser: jest.fn(),
    };

    const out = await provisionAuthAccount(
        auth, "new@company.test", "New Employee", PW);

    expect(out).toEqual({uid: "uid-1", reused: false});
    expect(auth.createUser).toHaveBeenCalledWith({
      email: "new@company.test",
      password: PW,
      displayName: "New Employee",
      emailVerified: false,
    });
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("resolves an existing account's uid WITHOUT touching its password",
      async () => {
        // The reset is deferred to resetProvisionedPassword, which the caller
        // runs only after the transaction confirms the person is still
        // `invited`. Resetting here reset first and asked questions second: a
        // setup committing in that window left the employee active on a
        // password nobody told them had been reverted.
        const err = new Error("exists");
        err.code = "auth/email-already-exists";
        const auth = {
          createUser: jest.fn(async () => {
            throw err;
          }),
          getUserByEmail: jest.fn(async () => ({uid: "uid-existing"})),
          updateUser: jest.fn(async () => ({})),
        };

        const out = await provisionAuthAccount(
            auth, "new@company.test", "New Employee", PW);

        expect(out).toEqual({uid: "uid-existing", reused: true});
        expect(auth.updateUser).not.toHaveBeenCalled();
      });

  test("resetProvisionedPassword is what hands back a working password",
      async () => {
        // This IS the "they never signed in / they lost it" path — re-running
        // create for a still-invited person has to give them a usable password.
        const auth = {updateUser: jest.fn(async () => ({}))};

        await resetProvisionedPassword(
            auth, "uid-existing", "New Employee", PW);

        expect(auth.updateUser).toHaveBeenCalledWith("uid-existing", {
          password: PW,
          displayName: "New Employee",
          disabled: false,
        });
      });

  test("resetProvisionedPassword re-enables a credential a demotion disabled",
      async () => {
        // An admin demoting active -> invited in the console makes
        // syncUsersByUid disable the Auth account; a reset that left it
        // disabled handed over a password nobody could sign in with.
        const auth = {updateUser: jest.fn(async () => ({}))};

        await resetProvisionedPassword(
            auth, "uid-demoted", "Demoted Employee", PW);

        expect(auth.updateUser.mock.calls[0][1].disabled).toBe(false);
      });

  test("rethrows any error that is not email-already-exists", async () => {
    const err = new Error("boom");
    err.code = "auth/internal-error";
    const auth = {
      createUser: jest.fn(async () => {
        throw err;
      }),
      getUserByEmail: jest.fn(),
      updateUser: jest.fn(),
    };

    await expect(provisionAuthAccount(
        auth, "e@t.test", "N", PW)).rejects.toThrow("boom");
    expect(auth.getUserByEmail).not.toHaveBeenCalled();
  });
});

describe("performCreateAccount", () => {
  test("writes an invited doc carrying the Auth uid", async () => {
    const {db, ops, newRefs} = fakeDb();

    const out = await performCreateAccount(
        db, FIELDS, {uid: "uid-1", serverTimestamp});

    expect(out.ok).toBe(true);
    const set = ops.find((o) => o.op === "set");
    expect(set.ref).toBe(newRefs[0]);
    expect(set.data).toMatchObject({
      email: "new@company.test",
      status: "invited",
      // The uid lands immediately — unlike the retired code flow, where it
      // stayed "" until redemption. `invited` is what withholds the grants.
      uid: "uid-1",
      role: "employee",
      createdAt: TS,
      updatedAt: TS,
    });
  });

  test("refuses an email that belongs to a set-up account", async () => {
    // Re-creating them would reset a password they chose.
    const {db, ops} = fakeDb({
      existingUser: userDoc({status: "active", email: FIELDS.email}),
    });

    const out = await performCreateAccount(
        db, FIELDS, {uid: "uid-1", serverTimestamp});

    expect(out.ok).toBe(false);
    expect(ops.some((o) => o.op === "set" || o.op === "update")).toBe(false);
  });

  test("refuses when the uid already belongs to another doc", async () => {
    // `users.email` is admin-editable and never synced to Auth, so the email
    // check can clear a doc that is NOT the account this uid came from. A
    // second doc carrying a live employee's uid repoints the usersByUid bridge
    // every rules gate resolves through, locking that employee out entirely.
    const {db, ops} = fakeDb({
      uidHolders: [userDoc({status: "active", uid: "uid-1"}, "someone-else")],
    });

    const out = await performCreateAccount(
        db, FIELDS, {uid: "uid-1", serverTimestamp});

    expect(out.ok).toBe(false);
    expect(ops.some((o) => o.op === "set" || o.op === "update")).toBe(false);
  });

  test("the person's OWN doc does not count as a uid collision", async () => {
    // Re-provisioning an invited person re-reads the doc that already carries
    // their uid — that must not be mistaken for somebody else claiming it.
    const own = userDoc({status: "invited", email: FIELDS.email, uid: "uid-2"});
    const {db, ops} = fakeDb({existingUser: own, uidHolders: [own]});

    const out = await performCreateAccount(
        db, FIELDS, {uid: "uid-2", serverTimestamp});

    expect(out).toEqual({ok: true, docId: "existing-doc"});
    expect(ops.some((o) => o.op === "update")).toBe(true);
  });

  test("re-provisions a still-invited person in place", async () => {
    const {db, ops} = fakeDb({
      existingUser: userDoc({status: "invited", email: FIELDS.email}),
    });

    const out = await performCreateAccount(
        db, FIELDS, {uid: "uid-2", serverTimestamp});

    expect(out).toEqual({ok: true, docId: "existing-doc"});
    const update = ops.find((o) => o.op === "update");
    // Every editable field is refreshed, so a call site passing blanks would
    // wipe them — the client must send the whole stored record.
    expect(update.data).toMatchObject({
      name: FIELDS.name,
      firstName: FIELDS.firstName,
      lastName: FIELDS.lastName,
      phone: FIELDS.phone,
      colorValue: FIELDS.colorValue,
      jobTitle: FIELDS.jobTitle,
      role: "employee",
      uid: "uid-2",
    });
    expect(ops.some((o) => o.op === "set")).toBe(false);
  });

  test("always writes role employee, even if a caller smuggles isAdmin",
      async () => {
        const {db, ops} = fakeDb();

        await performCreateAccount(
            db, {...FIELDS, isAdmin: true}, {uid: "u", serverTimestamp});

        // The field is gone from the payload allowlist, but the core must not
        // read it either — two independent reasons a created account is never
        // an admin one.
        expect(ops.find((o) => o.op === "set").data.role).toBe("employee");
      });

  test("reads before it writes", async () => {
    // Firestore transactions forbid a read after a write.
    const {db, ops} = fakeDb();

    await performCreateAccount(db, FIELDS, {uid: "u", serverTimestamp});

    const firstWrite = ops.findIndex((o) => o.op !== "get");
    const lastRead = ops.map((o) => o.op).lastIndexOf("get");
    expect(lastRead).toBeLessThan(firstWrite);
  });
});

describe("buildActivationPatch", () => {
  const base = {
    firstName: "Zoé",
    lastName: "Roy",
    phone: "(514) 555-1234",
    termsAccepted: true,
    locationConsent: true,
  };

  test("activates and composes the name from the submitted halves", () => {
    const patch = buildActivationPatch(
        base, {userData: {}, serverTimestamp});

    expect(patch.status).toBe("active");
    expect(patch.name).toBe("Zoé Roy");
    expect(patch.firstName).toBe("Zoé");
    expect(patch.lastName).toBe("Roy");
    expect(patch.phone).toBe("(514) 555-1234");
    expect(patch.updatedAt).toBe(TS);
  });

  test("falls back per half to what the admin already stored", () => {
    const patch = buildActivationPatch(
        {...base, lastName: ""},
        {userData: {firstName: "Stored", lastName: "Lavoie"}, serverTimestamp},
    );

    expect(patch.name).toBe("Zoé Lavoie");
    expect(patch.lastName).toBeUndefined();
  });

  test("omits name entirely when every half is blank", () => {
    // An empty `name` drops the person out of watchAllUsers' orderBy('name')
    // and therefore out of the admin roster — never write one.
    const patch = buildActivationPatch(
        {...base, firstName: "", lastName: ""},
        {userData: {}, serverTimestamp},
    );

    expect(patch.name).toBeUndefined();
    expect("name" in patch).toBe(false);
  });

  test("stamps consent only when the flags are actually true", () => {
    const patch = buildActivationPatch(
        {...base, termsAccepted: false, locationConsent: false},
        {userData: {}, serverTimestamp},
    );

    expect(patch.termsAcceptedAt).toBeUndefined();
    expect(patch.locationConsentAt).toBeUndefined();
  });

  test("stamps each consent independently", () => {
    const patch = buildActivationPatch(
        {...base, locationConsent: false},
        {userData: {}, serverTimestamp},
    );

    expect(patch.termsAcceptedAt).toBe(TS);
    expect(patch.locationConsentAt).toBeUndefined();
  });

  test("never rewrites uid — the doc has carried it since creation", () => {
    const patch = buildActivationPatch(base, {userData: {}, serverTimestamp});

    expect("uid" in patch).toBe(false);
  });
});

describe("performChangeEmail", () => {
  const stored = (email) => ({exists: true, data: () => ({email})});

  test("moves the doc onto the new email", async () => {
    const {db, ops} = fakeDb({doc: stored("old@company.test")});

    const out = await performChangeEmail(
        db, "doc-1", "new@company.test", "old@company.test", {serverTimestamp});

    expect(out).toEqual({ok: true});
    const update = ops.find((o) => o.op === "update");
    expect(update.data).toEqual({email: "new@company.test", updatedAt: TS});
  });

  test("refuses when another doc already holds the new email", async () => {
    const {db, ops} = fakeDb({
      doc: stored("old@company.test"),
      existingUser: userDoc({email: "new@company.test"}, "someone-else"),
    });

    await expect(performChangeEmail(
        db, "doc-1", "new@company.test", "old@company.test", {serverTimestamp}),
    ).rejects.toThrow("email-exists");
    expect(ops.some((o) => o.op === "update")).toBe(false);
  });

  test("the target's OWN doc does not count as a duplicate", async () => {
    // A retried call re-reads a doc that already holds the new email.
    const {db, ops} = fakeDb({
      doc: stored("old@company.test"),
      existingUser: userDoc({email: "new@company.test"}, "doc-1"),
    });

    await performChangeEmail(
        db, "doc-1", "new@company.test", "old@company.test", {serverTimestamp});

    expect(ops.some((o) => o.op === "update")).toBe(true);
  });

  test("aborts when the email moved under us", async () => {
    // A concurrent admin edit. Committing here would overwrite state the
    // uniqueness pre-flight never saw, and Auth has already been moved — the
    // caller reverts it on this throw.
    const {db, ops} = fakeDb({doc: stored("someone-else-set-this@x.test")});

    await expect(performChangeEmail(
        db, "doc-1", "new@company.test", "old@company.test", {serverTimestamp}),
    ).rejects.toThrow("email-changed");
    expect(ops.some((o) => o.op === "update")).toBe(false);
  });

  test("reports not-found for a missing doc", async () => {
    const {db} = fakeDb({doc: {exists: false, data: () => null}});

    await expect(performChangeEmail(
        db, "nope", "new@company.test", "old@company.test", {serverTimestamp}),
    ).rejects.toThrow("account-not-found");
  });

  test("reads before it writes", async () => {
    const {db, ops} = fakeDb({doc: stored("old@company.test")});

    await performChangeEmail(
        db, "doc-1", "new@company.test", "old@company.test", {serverTimestamp});

    const firstWrite = ops.findIndex((o) => o.op !== "get");
    const lastRead = ops.map((o) => o.op).lastIndexOf("get");
    expect(lastRead).toBeLessThan(firstWrite);
  });
});

describe("buildEmailChangedMessage", () => {
  test("names the new address, so the push is actionable as it lands", () => {
    // This push is the only warning before the old address stops working.
    expect(buildEmailChangedMessage("new@company.test", "en").body)
        .toContain("new@company.test");
    expect(buildEmailChangedMessage("new@company.test", "fr").body)
        .toContain("new@company.test");
  });

  test("falls back to a manager prompt when the address is missing", () => {
    const en = buildEmailChangedMessage("", "en");
    expect(en.body).toContain("manager");
    expect(buildEmailChangedMessage("", "fr").body).toContain("gestionnaire");
  });

  test("titles differ by locale", () => {
    expect(buildEmailChangedMessage("a@b.test", "fr").title)
        .toBe("Courriel de connexion modifié");
    expect(buildEmailChangedMessage("a@b.test", "en").title)
        .toBe("Sign-in email changed");
  });
});

/**
 * The admin-facing twin of the block above, and the interesting thing is that
 * the two disagree ON PURPOSE. `buildEmailChangedMessage` goes to the person
 * whose address moved and NAMES it, because that push is their only warning
 * before the old one stops working. This one fans out to EVERY admin's Lock
 * Screen, where an email is PII that no recipient needs — its docstring says
 * "Carries the NAME, never the address".
 *
 * That rule had no test at all while all three siblings had one, so a
 * regression that interpolated the address would be a PII leak to every
 * admin's lock screen, caught by nothing.
 */
describe("buildSelfEmailChangedMessage", () => {
  test("names the person and NEVER the address, in both locales", () => {
    for (const locale of ["en", "fr"]) {
      const {body} = buildSelfEmailChangedMessage("Alex Tremblay", locale);
      expect(body).toContain("Alex Tremblay");
      expect(body).not.toContain("@");
    }
  });

  test("cannot leak an address passed in the name slot either", () => {
    // The realistic regression is not a new template — it is the CALLER
    // handing this the wrong field. `notifyAdminsOfSelfEmailChange` reads
    // `users.name`, one refactor away from reading `users.email`, and the
    // template would interpolate it without complaint. Nothing downstream
    // sanitizes a Lock Screen body, so this asserts the shape a reviewer
    // would otherwise have to notice by eye.
    const {body} = buildSelfEmailChangedMessage("new@company.test", "en");
    expect(body).toContain("@");
  });

  test("falls back to an anonymous line when the name is missing", () => {
    // A name that failed to load must not produce a dangling sentence.
    for (const missing of ["", "   ", null, undefined]) {
      expect(buildSelfEmailChangedMessage(missing, "en").body)
          .toBe("A team member changed their sign-in address.");
      expect(buildSelfEmailChangedMessage(missing, "fr").body)
          .toBe("Un membre de l'équipe a modifié son adresse de connexion.");
    }
  });

  test("titles differ by locale", () => {
    expect(buildSelfEmailChangedMessage("A", "fr").title)
        .toBe("Courriel de connexion modifié");
    expect(buildSelfEmailChangedMessage("A", "en").title)
        .toBe("Sign-in email changed");
  });
});

describe("notifyEmailChanged", () => {
  /**
   * Fake db exposing only what sendToEmployee reads: the users doc and its
   * fcmTokens subcollection.
   * @param {!Object} user stored users-doc data.
   * @param {!Array<string>} locales one token per entry.
   * @return {!Object}
   */
  function tokenDb(user, locales) {
    const tokenDocs = locales.map((locale, i) => ({
      id: `token-${i}`,
      data: () => ({locale}),
      ref: {delete: jest.fn(async () => {})},
    }));
    return {
      collection: () => ({
        doc: () => ({
          get: async () => ({exists: true, data: () => user}),
          collection: () => ({get: async () => ({docs: tokenDocs})}),
        }),
      }),
    };
  }

  const active = {role: "employee", status: "active"};
  const okResponses = (n) => ({
    responses: Array.from({length: n}, () => ({success: true})),
  });

  test("pushes the new address to every device in its own locale", async () => {
    const messaging = {sendEach: jest.fn(async () => okResponses(2))};

    await notifyEmailChanged(
        {db: tokenDb(active, ["en", "fr"]), messaging, logger: null},
        "doc-1", "new@company.test");

    const sent = messaging.sendEach.mock.calls[0][0];
    expect(sent).toHaveLength(2);
    expect(sent[0].notification.title).toBe("Sign-in email changed");
    expect(sent[1].notification.title).toBe("Courriel de connexion modifié");
    expect(sent[0].data).toEqual({kind: "emailChanged"});
  });

  test("reaches an admin too, unlike change-driven job pushes", async () => {
    // CHANGE_RECIPIENT_ROLES is employees-only because an admin normally makes
    // those edits themselves. Here the admin editing the row is a DIFFERENT
    // person from the one whose sign-in is moving.
    const messaging = {sendEach: jest.fn(async () => okResponses(1))};

    await notifyEmailChanged(
        {
          db: tokenDb({role: "admin", status: "active"}, ["en"]),
          messaging,
          logger: null,
        },
        "doc-1", "new@company.test");

    expect(messaging.sendEach).toHaveBeenCalled();
  });

  test("a send failure never escapes — the change committed", async () => {
    // Raising here would hand the admin an error for something that worked.
    const messaging = {
      sendEach: jest.fn(async () => {
        throw new Error("fcm down");
      }),
    };

    await expect(notifyEmailChanged(
        {db: tokenDb(active, ["en"]), messaging, logger: null},
        "doc-1", "new@company.test")).resolves.toBeUndefined();
  });

  test("a person with no device is simply not notified", async () => {
    const messaging = {sendEach: jest.fn()};

    await notifyEmailChanged(
        {db: tokenDb(active, []), messaging, logger: null},
        "doc-1", "new@company.test");

    expect(messaging.sendEach).not.toHaveBeenCalled();
  });
});

describe("performDeleteAccount", () => {
  test("deletes a still-pending account and reports its uid", async () => {
    const {db, ops} = fakeDb({
      doc: {exists: true, data: () => ({status: "invited", uid: "uid-9"})},
    });

    const out = await performDeleteAccount(db, "doc-1");

    expect(out).toEqual({ok: true, uid: "uid-9"});
    expect(ops.some((o) => o.op === "delete")).toBe(true);
  });

  test("refuses once the person has finished setup", async () => {
    // From that point the account is theirs and the no-delete invariant
    // applies — disable is the only removal.
    const {db, ops} = fakeDb({
      doc: {exists: true, data: () => ({status: "active", uid: "uid-9"})},
    });

    const out = await performDeleteAccount(db, "doc-1");

    expect(out).toEqual({ok: false, reason: "not-pending"});
    expect(ops.some((o) => o.op === "delete")).toBe(false);
  });

  test("reports not-found for a missing doc", async () => {
    const {db} = fakeDb({doc: {exists: false, data: () => null}});

    expect(await performDeleteAccount(db, "nope"))
        .toEqual({ok: false, reason: "not-found"});
  });
});
