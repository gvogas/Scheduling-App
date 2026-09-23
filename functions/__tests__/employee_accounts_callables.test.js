"use strict";

/** Ordering tests for the two employee-account callables. */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-admin/auth");
jest.mock("firebase-admin/messaging");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  const mock = {
    ...actual,
    assertAdmin: jest.fn().mockResolvedValue(undefined),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
  // The callables open with `assertAdminCall`, which COMPOSES the auth check,
  // `assertAdmin` and `assertPayloadShape`.
  mock.assertAdminCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new (require("firebase-functions/v2/https").HttpsError)(
          "unauthenticated", "auth-required");
    }
    await mock.assertAdmin(req.auth.uid);
    actual.assertPayloadShape(req.data, allowedKeys);
    return req.auth.uid;
  });
  return mock;
});
jest.mock("../notification_utils", () => ({
  sendToEmployee: jest.fn().mockResolvedValue(0),
  sendToActiveAdmins: jest.fn().mockResolvedValue(undefined),
  TIMED_RECIPIENT_ROLES: ["employee", "admin"],
}));

const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {
  sendToEmployee,
  sendToActiveAdmins,
} = require("../notification_utils");
const security = require("../security");
const {
  createEmployeeAccount,
  completeEmployeeSetup,
  changeEmployeeEmail,
  deleteEmployeeAccount,
} = require("../employee_accounts");

const ADMIN = {uid: "admin-uid"};

const VALID_CREATE = {
  name: "Ada Lovelace",
  firstName: "Ada",
  lastName: "Lovelace",
  email: "Ada@Example.com",
  phone: "(514) 555-1234",
  colorValue: "4280391411",
  jobTitle: "technician",
};

/**
 * Firestore double. `docs` is the users collection keyed by doc id. Records an
 * ordered trace of the operations the callables perform.
 * @param {!Object} docs Map of docId -> doc data (the `users` collection).
 * @param {!Array<string>} trace Shared ordered call log.
 * @param {!Object=} bridge Map of auth uid -> `usersByUid` doc data.
 * @return {!Object}
 */
function makeDb(docs, trace, bridge) {
  const bridgeDocs = bridge || {
    "admin-uid": {role: "admin", status: "active", docId: "admin-doc"},
  };
  const snapOf = (id) => ({
    id,
    exists: Object.prototype.hasOwnProperty.call(docs, id),
    data: () => docs[id],
    ref: {id},
  });
  const queryFor = (field, value) => {
    const matches = Object.keys(docs)
        .filter((id) => (docs[id] || {})[field] === value)
        .map(snapOf);
    return {empty: matches.length === 0, docs: matches};
  };

  const makeQuery = (field, value) => ({
    limit: () => makeQuery(field, value),
    get: async () => queryFor(field, value),
    __field: field,
    __value: value,
  });

  const bridgeSnapOf = (id) => ({
    id,
    exists: Object.prototype.hasOwnProperty.call(bridgeDocs, id),
    data: () => bridgeDocs[id],
    ref: {id},
  });

  const locks = new Set();
  const db = {
    collection: (name) => ({
      where: (field, _op, value) => makeQuery(field, value),
      doc: (id) => ({
        id: id || "generated-doc-id",
        create: async () => {
          if (locks.has(id)) throw Object.assign(Error("busy"), {code: 6});
          locks.add(id);
        },
        delete: async () => {
          locks.delete(id);
        },
        get: async () => (name === "usersByUid" ?
          bridgeSnapOf(id) :
          snapOf(id)),
      }),
    }),
    runTransaction: async (fn) => {
      const tx = {
        get: async (target) => (target && target.__field ?
          queryFor(target.__field, target.__value) :
          snapOf(target.id)),
        update: (ref, patch) => {
          trace.push("db.update");
          docs[ref.id] = {...(docs[ref.id] || {}), ...patch};
        },
        set: (ref, value) => {
          trace.push("db.set");
          docs[ref.id] = value;
        },
        delete: (ref) => {
          trace.push("db.delete");
          delete docs[ref.id];
        },
      };
      const out = await fn(tx);
      trace.push("db.commit");
      return out;
    },
  };
  return db;
}

/**
 * Auth double recording every call into the shared trace.
 * @param {!Array<string>} trace Shared ordered call log.
 * @param {!Object} opts Behaviour overrides.
 * @return {!Object}
 */
function makeAuth(trace, opts = {}) {
  return {
    getUserByEmail: jest.fn(async (email) => {
      trace.push("auth.getUserByEmail");
      if (opts.existingUser) return opts.existingUser;
      const err = new Error("no user");
      err.code = "auth/user-not-found";
      throw err;
    }),
    createUser: jest.fn(async () => {
      trace.push("auth.createUser");
      if (opts.createUserError) throw opts.createUserError;
      return {uid: "new-uid"};
    }),
    updateUser: jest.fn(async () => {
      trace.push("auth.updateUser");
      if (opts.updateUserError) throw opts.updateUserError;
      return {};
    }),
    deleteUser: jest.fn(async () => {
      trace.push("auth.deleteUser");
      if (opts.deleteUserError) throw opts.deleteUserError;
    }),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  FieldValue.serverTimestamp = jest.fn(() => "TS");
  getMessaging.mockReturnValue({});
  getAuth.mockReturnValue(makeAuth([]));
});

describe("createEmployeeAccount ordering", () => {
  test("mints a brand-new account and never resets its password", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb({}, trace));
    getAuth.mockReturnValue(auth);

    const out = await createEmployeeAccount.run({
      data: VALID_CREATE,
      auth: ADMIN,
    });

    expect(out.email).toBe("ada@example.com");
    expect(trace).toEqual([
      "auth.getUserByEmail", // pre-flight: is this email taken?
      "auth.createUser",
      "db.set",
      "db.commit",
    ]);
    // reused === false, so the reset path must not run.
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("rejects isAdmin now that the #compat-1.47.0 carve-out is retired",
      async () => {
        const trace = [];
        const auth = makeAuth(trace);
        const docs = {};
        getFirestore.mockReturnValue(makeDb(docs, trace));
        getAuth.mockReturnValue(auth);

        // Builds at or below 1.47.0 sent `isAdmin` unconditionally, so the
        // allowlist accepted-and-ignored it until the fleet reached 1.53
        // (retired 2026-08-29).
        await expect(createEmployeeAccount.run({
          data: {...VALID_CREATE, isAdmin: true},
          auth: ADMIN,
        })).rejects.toThrow(/unexpected-field/);

        // Refused before any write — no account, no Auth user.
        expect(docs["generated-doc-id"]).toBeUndefined();
        expect(auth.createUser).not.toHaveBeenCalled();
      });

  test("resets a pending account's password only AFTER the doc transaction",
      async () => {
        const trace = [];
        const auth = makeAuth(trace, {existingUser: {uid: "existing-uid"}});
        getFirestore.mockReturnValue(makeDb({
          d1: {
            email: "ada@example.com",
            uid: "existing-uid",
            status: "invited",
          },
        }, trace));
        getAuth.mockReturnValue(auth);

        await createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN});

        // The rotation must come after "db.commit".
        expect(trace.indexOf("auth.updateUser"))
            .toBeGreaterThan(trace.indexOf("db.commit"));
      });

  test("never deletes the Auth account of a REUSED (existing) user",
      async () => {
        const trace = [];
        const auth = makeAuth(trace, {existingUser: {uid: "existing-uid"}});
        // Status is no longer `invited`, so performCreateAccount returns
        // ok:false and the callable throws.
        getFirestore.mockReturnValue(makeDb({
          d1: {
            email: "ada@example.com",
            uid: "existing-uid",
            status: "invited",
          },
          d2: {email: "other@example.com", uid: "existing-uid"},
        }, trace));
        getAuth.mockReturnValue(auth);

        await expect(
            createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN}),
        ).rejects.toThrow(/email-exists/);

        // Rolling back a reused account would delete a real employee's Auth
        // record — the account was theirs before this call started.
        expect(auth.deleteUser).not.toHaveBeenCalled();
      });

  test("rolls back an account it just minted when the doc write fails",
      async () => {
        const trace = [];
        const auth = makeAuth(trace);
        const db = makeDb({}, trace);
        db.runTransaction = async () => {
          throw new Error("firestore unavailable");
        };
        getFirestore.mockReturnValue(db);
        getAuth.mockReturnValue(auth);

        await expect(
            createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN}),
        ).rejects.toThrow(/unavailable/);

        // An Auth account with no users doc is a sign-in SplashScreen cannot
        // resolve and no admin surface can see.
        expect(auth.deleteUser).toHaveBeenCalledWith("new-uid");
      });

  test("a failed rollback is logged loudly with the orphaned uid", async () => {
    const trace = [];
    const auth = makeAuth(trace, {
      deleteUserError: new Error("auth down"),
    });
    const db = makeDb({}, trace);
    db.runTransaction = async () => {
      throw new Error("firestore unavailable");
    };
    getFirestore.mockReturnValue(db);
    getAuth.mockReturnValue(auth);

    await expect(
        createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN}),
    ).rejects.toThrow();

    // Unrecoverable in-app and it bricks that email, so silence is the one
    // unacceptable outcome.
    expect(logger.error).toHaveBeenCalledWith(
        expect.stringContaining("orphaned auth account"),
        expect.objectContaining({uid: "new-uid"}),
    );
  });
});

// The admin gate on this callable was MUTATION-PROVEN open on 2026-09-01:
// deleting `await assertAdmin(req.auth.uid)` left all 1636 tests green.
describe("createEmployeeAccount admin gate", () => {
  beforeEach(() => {
    security.assertAdmin.mockResolvedValue(undefined);
    security.enforceDurableRateLimit.mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    });
  });

  test("refuses a signed-out caller before the gate", async () => {
    await expect(
        createEmployeeAccount.run({data: VALID_CREATE, auth: null}),
    ).rejects.toThrow(/auth-required/);
    expect(security.assertAdmin).not.toHaveBeenCalled();
  });

  test("puts the caller uid through assertAdmin", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb({}, trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN});

    expect(security.assertAdmin).toHaveBeenCalledWith(ADMIN.uid);
  });

  test("a non-admin mints nothing, in Auth or Firestore", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    const docs = {};
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(auth);
    security.assertAdmin.mockRejectedValueOnce(
        new Error("permission-denied: admin-required"),
    );

    await expect(
        createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN}),
    ).rejects.toThrow(/admin-required/);

    expect(auth.createUser).not.toHaveBeenCalled();
    expect(trace).toEqual([]);
    expect(docs).toEqual({});
  });

  test("a non-admin burns NO rate-limit slot", async () => {
    // Guard order: auth -> assertAdmin -> payload -> limiter.
    getFirestore.mockReturnValue(makeDb({}, []));
    getAuth.mockReturnValue(makeAuth([]));
    security.assertAdmin.mockRejectedValueOnce(new Error("admin-required"));

    await expect(
        createEmployeeAccount.run({data: VALID_CREATE, auth: ADMIN}),
    ).rejects.toThrow(/admin-required/);

    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });
});

// The entire callable wrapper was untested — only performDeleteAccount had a
// suite — so its admin gate was mutation-proven deletable too.
describe("deleteEmployeeAccount callable", () => {
  const pendingDocs = () => ({
    "pending-doc": {status: "invited", uid: "pending-uid", email: "a@b.com"},
  });

  beforeEach(() => {
    security.assertAdmin.mockResolvedValue(undefined);
    security.enforceDurableRateLimit.mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    });
  });

  test("refuses a signed-out caller before the gate", async () => {
    await expect(
        deleteEmployeeAccount.run({data: {docId: "pending-doc"}, auth: null}),
    ).rejects.toThrow(/auth-required/);
    expect(security.assertAdmin).not.toHaveBeenCalled();
  });

  test("puts the caller uid through assertAdmin", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb(pendingDocs(), trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await deleteEmployeeAccount.run({
      data: {docId: "pending-doc"},
      auth: ADMIN,
    });

    expect(security.assertAdmin).toHaveBeenCalledWith(ADMIN.uid);
  });

  test("a non-admin deletes nothing, in Firestore or Auth", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    const docs = pendingDocs();
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(auth);
    security.assertAdmin.mockRejectedValueOnce(new Error("admin-required"));

    await expect(
        deleteEmployeeAccount.run({
          data: {docId: "pending-doc"},
          auth: ADMIN,
        }),
    ).rejects.toThrow(/admin-required/);

    expect(docs["pending-doc"]).toBeDefined();
    expect(auth.deleteUser).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("rejects a payload with an unexpected key", async () => {
    getFirestore.mockReturnValue(makeDb(pendingDocs(), []));
    getAuth.mockReturnValue(makeAuth([]));

    await expect(
        deleteEmployeeAccount.run({
          data: {docId: "pending-doc", evil: 1},
          auth: ADMIN,
        }),
    ).rejects.toThrow(/unexpected-field/);
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("deletes the DOC first and the Auth account second", async () => {
    // Ordering is load-bearing: an Auth account with no doc is invisible to
    // every admin surface, while a doc with no Auth account is visible and
    // fixable by re-creating.
    const trace = [];
    const docs = pendingDocs();
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(auth);

    const out = await deleteEmployeeAccount.run({
      data: {docId: "pending-doc"},
      auth: ADMIN,
    });

    expect(out).toEqual({ok: true});
    expect(trace).toEqual(["db.delete", "db.commit", "auth.deleteUser"]);
    expect(docs["pending-doc"]).toBeUndefined();
  });

  test("refuses an account that is no longer pending", async () => {
    const trace = [];
    const docs = {"pending-doc": {status: "active", uid: "pending-uid"}};
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(docs, trace));
    getAuth.mockReturnValue(auth);

    await expect(
        deleteEmployeeAccount.run({
          data: {docId: "pending-doc"},
          auth: ADMIN,
        }),
    ).rejects.toThrow(/account-not-pending/);

    expect(docs["pending-doc"]).toBeDefined();
    expect(auth.deleteUser).not.toHaveBeenCalled();
  });

  test("reports a missing doc as not-found", async () => {
    getFirestore.mockReturnValue(makeDb({}, []));
    getAuth.mockReturnValue(makeAuth([]));

    await expect(
        deleteEmployeeAccount.run({data: {docId: "ghost"}, auth: ADMIN}),
    ).rejects.toThrow(/account-not-found/);
  });

  test("swallows auth/user-not-found so a partial earlier run converges",
      async () => {
        const trace = [];
        const notFound = new Error("gone");
        notFound.code = "auth/user-not-found";
        getFirestore.mockReturnValue(makeDb(pendingDocs(), trace));
        getAuth.mockReturnValue(makeAuth(trace, {deleteUserError: notFound}));

        await expect(
            deleteEmployeeAccount.run({
              data: {docId: "pending-doc"},
              auth: ADMIN,
            }),
        ).resolves.toEqual({ok: true});
        expect(logger.error).not.toHaveBeenCalled();
      });

  test("logs the orphaned uid loudly when the Auth delete really fails",
      async () => {
        // The doc is already gone, so this leaves an Auth account no admin
        // surface can see and whose email createEmployeeAccount will refuse.
        const trace = [];
        getFirestore.mockReturnValue(makeDb(pendingDocs(), trace));
        getAuth.mockReturnValue(
            makeAuth(trace, {deleteUserError: new Error("boom")}),
        );

        await expect(
            deleteEmployeeAccount.run({
              data: {docId: "pending-doc"},
              auth: ADMIN,
            }),
        ).rejects.toThrow(/boom/);

        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining("orphaned auth account"),
            expect.objectContaining({uid: "pending-uid"}),
        );
      });
});

describe("completeEmployeeSetup activation", () => {
  const SETUP = {
    newPassword: "ChosenSecret123!",
    firstName: "Ada",
    lastName: "Lovelace",
    phone: "(514) 555-1234",
    termsAccepted: true,
    locationConsent: true,
  };
  const invitedDocs = () => ({
    d1: {email: "ada@example.com", uid: "emp-uid", status: "invited"},
  });

  test("legacy setup remains compatible before an admin reset", async () => {
    const docs = invitedDocs();
    getFirestore.mockReturnValue(makeDb(docs, []));
    await expect(completeEmployeeSetup.run({
      data: {firstName: "Ada"}, auth: {uid: "emp-uid"},
    })).resolves.toEqual({ok: true});
    expect(getAuth().updateUser).not.toHaveBeenCalled();
  });

  test("legacy setup cannot activate after an admin reset", async () => {
    const docs = invitedDocs();
    docs.d1.setupRequiresPassword = true;
    getFirestore.mockReturnValue(makeDb(docs, []));
    await expect(completeEmployeeSetup.run({
      data: {firstName: "Ada"}, auth: {uid: "emp-uid"},
    })).rejects.toThrow("setup-upgrade-required");
    expect(docs.d1.status).toBe("invited");
    expect(getAuth().updateUser).not.toHaveBeenCalled();
  });

  test("password failure leaves the invitation pending and releases the lock",
      async () => {
        const docs = invitedDocs();
        const db = makeDb(docs, []);
        const auth = makeAuth([], {updateUserError: Error("password failed")});
        getFirestore.mockReturnValue(db);
        getAuth.mockReturnValue(auth);
        const req = {data: SETUP, auth: {uid: "emp-uid"}};
        await expect(completeEmployeeSetup.run(req))
            .rejects.toThrow("password failed");
        expect(docs.d1.status).toBe("invited");
        auth.updateUser.mockResolvedValue({});
        await expect(completeEmployeeSetup.run(req))
            .resolves.toEqual({ok: true});
      });

  test("setup refuses a concurrent provisioning operation", async () => {
    const db = makeDb(invitedDocs(), []);
    await db.collection("accountOperations").doc("emp-uid").create({});
    getFirestore.mockReturnValue(db);
    await expect(completeEmployeeSetup.run({
      data: SETUP, auth: {uid: "emp-uid"},
    }))
        .rejects.toThrow("account-operation-in-progress");
    expect(getAuth().updateUser).not.toHaveBeenCalled();
  });

  test("activates a caller presenting no email claim at all", async () => {
    const trace = [];
    const docs = invitedDocs();
    getFirestore.mockReturnValue(makeDb(docs, trace));

    // The mailbox check went with the shared starting password (2026-08-21):
    // the password is now a random per-account secret, so signing in is itself
    // the proof that guard used to provide.
    const out = await completeEmployeeSetup.run({
      data: SETUP,
      auth: {uid: "emp-uid", token: {}},
    });

    expect(out).toEqual({ok: true});
    expect(docs.d1.status).toBe("active");
  });

  test("refuses an unauthenticated caller before the rate limiter",
      async () => {
        const {enforceDurableRateLimit} = require("../security");
        getFirestore.mockReturnValue(makeDb(invitedDocs(), []));

        await expect(completeEmployeeSetup.run({
          data: SETUP,
          auth: null,
        })).rejects.toThrow(/auth-required/);

        // The guard-order rule outlives the email_verified check that used to
        // demonstrate it: identity is settled before a caller can burn any of
        // the real employee's five attempts.
        expect(enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test("still refuses an account that is no longer invited", async () => {
    const docs = {
      d1: {email: "ada@example.com", uid: "emp-uid", status: "active"},
    };
    getFirestore.mockReturnValue(makeDb(docs, []));

    await expect(completeEmployeeSetup.run({
      data: SETUP,
      auth: {uid: "emp-uid", token: {}},
    })).rejects.toThrow(/setup-not-pending/);
  });
});

describe("changeEmployeeEmail ordering", () => {
  const PAYLOAD = {docId: "d1", email: "New@Example.com"};
  const seedDocs = () => ({
    d1: {email: "old@example.com", uid: "u1", status: "active"},
  });

  test("updates Auth BEFORE Firestore", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace));
    getAuth.mockReturnValue(auth);

    await changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN});

    // Auth owns sign-in and is the only store that can truly refuse a
    // duplicate, so it must never be the one left behind.
    expect(trace.indexOf("auth.updateUser"))
        .toBeLessThan(trace.indexOf("db.update"));
    expect(auth.updateUser).toHaveBeenCalledWith("u1", {
      email: "new@example.com",
      emailVerified: false,
    });
  });

  test("reverts the Auth email when the doc write fails", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    const db = makeDb(seedDocs(), trace);
    const realTx = db.runTransaction;
    let calls = 0;
    db.runTransaction = async (fn) => {
      calls += 1;
      if (calls === 1) throw new Error("firestore unavailable");
      return realTx(fn);
    };
    getFirestore.mockReturnValue(db);
    getAuth.mockReturnValue(auth);

    await expect(
        changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN}),
    ).rejects.toThrow(/unavailable/);

    expect(auth.updateUser).toHaveBeenLastCalledWith("u1", {
      email: "old@example.com",
    });
  });

  test("a failed revert logs uid + docId and never an email address",
      async () => {
        const trace = [];
        const auth = makeAuth(trace);
        // First call (the real change) succeeds, the revert then fails.
        auth.updateUser
            .mockImplementationOnce(async () => {
              trace.push("auth.updateUser");
              return {};
            })
            .mockImplementationOnce(async () => {
              throw new Error("auth down");
            });
        const db = makeDb(seedDocs(), trace);
        db.runTransaction = async () => {
          throw new Error("firestore unavailable");
        };
        getFirestore.mockReturnValue(db);
        getAuth.mockReturnValue(auth);

        await expect(
            changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN}),
        ).rejects.toThrow();

        expect(logger.error).toHaveBeenCalledWith(
            expect.stringContaining("desync"),
            expect.objectContaining({uid: "u1", docId: "d1"}),
        );
        // Emails are PII — the uid pair is what makes it findable instead.
        const [, payload] = logger.error.mock.calls[0];
        expect(JSON.stringify(payload)).not.toContain("@example.com");
      });

  test("refuses a doc with no Auth account rather than writing one store",
      async () => {
        const trace = [];
        const auth = makeAuth(trace);
        getFirestore.mockReturnValue(makeDb({
          d1: {email: "old@example.com", status: "invited"},
        }, trace));
        getAuth.mockReturnValue(auth);

        await expect(
            changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN}),
        ).rejects.toThrow(/account-has-no-auth/);

        expect(auth.updateUser).not.toHaveBeenCalled();
      });
});

describe("changeEmployeeEmail caller branches", () => {
  const PAYLOAD = {docId: "d1", email: "New@Example.com"};
  const seedDocs = () => ({
    d1: {
      email: "old@example.com", uid: "u1", status: "active", name: "Theo Roy",
    },
  });
  // The self branch demands a fresh re-auth, so every self caller carries a
  // current `auth_time` the way a real re-authenticated client does.
  const freshAuthTime = () => Math.floor(Date.now() / 1000);
  const SELF = {uid: "self-uid", token: {auth_time: freshAuthTime()}};
  const selfBridge = {
    "self-uid": {role: "employee", status: "active", docId: "d1"},
  };

  test("an employee may move their OWN email", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, selfBridge));
    getAuth.mockReturnValue(auth);

    await changeEmployeeEmail.run({data: PAYLOAD, auth: SELF});

    expect(auth.updateUser).toHaveBeenCalledWith("u1", {
      email: "new@example.com",
      emailVerified: false,
    });
  });

  test("an employee may NOT move someone else's email", async () => {
    // Widening past admins must not widen WHICH doc a caller can reach.
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, {
      "self-uid": {role: "employee", status: "active", docId: "other"},
    }));
    getAuth.mockReturnValue(auth);

    await expect(
        changeEmployeeEmail.run({data: PAYLOAD, auth: SELF}),
    ).rejects.toThrow(/not-admin/);
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("a disabled employee may not move their own email", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, {
      "self-uid": {role: "employee", status: "disabled", docId: "d1"},
    }));
    getAuth.mockReturnValue(auth);

    await expect(
        changeEmployeeEmail.run({data: PAYLOAD, auth: SELF}),
    ).rejects.toThrow(/not-admin/);
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("a SELF change notifies the admins, not the person", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, selfBridge));
    getAuth.mockReturnValue(makeAuth(trace));

    await changeEmployeeEmail.run({data: PAYLOAD, auth: SELF});

    expect(sendToActiveAdmins).toHaveBeenCalled();
    expect(sendToEmployee).not.toHaveBeenCalled();
  });

  test("an ADMIN change notifies the person, not the admins", async () => {
    const trace = [];
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace));
    getAuth.mockReturnValue(makeAuth(trace));

    await changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN});

    expect(sendToEmployee).toHaveBeenCalled();
    expect(sendToActiveAdmins).not.toHaveBeenCalled();
  });

  test("the admin notice never carries the address", async () => {
    // It lands on every admin's Lock Screen, and an email is PII.
    const trace = [];
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, selfBridge));
    getAuth.mockReturnValue(makeAuth(trace));

    await changeEmployeeEmail.run({data: PAYLOAD, auth: SELF});

    const [, data, buildMsg] = sendToActiveAdmins.mock.calls[0];
    expect(JSON.stringify(data)).not.toContain("@example.com");
    expect(JSON.stringify(buildMsg("en"))).not.toContain("@example.com");
    expect(buildMsg("en").body).toContain("Theo Roy");
  });

  test("a signed-out caller is refused before anything else", async () => {
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace));
    getAuth.mockReturnValue(auth);

    await expect(
        changeEmployeeEmail.run({data: PAYLOAD, auth: null}),
    ).rejects.toThrow(/auth-required/);
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("a SELF change with a stale re-auth is refused", async () => {
    // A still-valid ID token alone must not move a sign-in address — that is
    // the unattended-unlocked-phone primitive SelfEmailService guards against
    // client-side, restated here so a direct call can't skip it.
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, selfBridge));
    getAuth.mockReturnValue(auth);

    await expect(changeEmployeeEmail.run({
      data: PAYLOAD,
      auth: {uid: "self-uid", token: {auth_time: freshAuthTime() - 600}},
    })).rejects.toThrow(/stale-auth/);
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("a SELF change presenting no token at all is refused", async () => {
    // Fails closed: a missing auth_time must not read as "recently
    // re-authenticated".
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace, selfBridge));
    getAuth.mockReturnValue(auth);

    await expect(
        changeEmployeeEmail.run({data: PAYLOAD, auth: {uid: "self-uid"}}),
    ).rejects.toThrow(/stale-auth/);
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("an ADMIN change is NOT gated on re-auth freshness", async () => {
    // Deliberate scope: updateEmployee has no re-auth step to satisfy, so
    // gating it would reject every admin edit made minutes after sign-in.
    const trace = [];
    const auth = makeAuth(trace);
    getFirestore.mockReturnValue(makeDb(seedDocs(), trace));
    getAuth.mockReturnValue(auth);

    await changeEmployeeEmail.run({data: PAYLOAD, auth: ADMIN});

    expect(auth.updateUser).toHaveBeenCalled();
  });
});
