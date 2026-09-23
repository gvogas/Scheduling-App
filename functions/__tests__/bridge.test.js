jest.mock("firebase-admin/firestore");
jest.mock("firebase-admin/auth");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));

const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {
  syncUsersByUid,
  shouldPurgePresence,
  authAccessChange,
  applyAuthAccess,
} = require("../bridge");

describe("shouldPurgePresence", () => {
  test("purges when the user doc is deleted", () => {
    expect(shouldPurgePresence({status: "active"}, null)).toBe(true);
  });
  test("purges when an active account is disabled", () => {
    expect(shouldPurgePresence(
        {status: "active"}, {status: "disabled"})).toBe(true);
  });
  test("does not purge on an active -> active update", () => {
    expect(shouldPurgePresence(
        {status: "active"}, {status: "active"})).toBe(false);
  });
  test("does not purge on invited -> active activation", () => {
    expect(shouldPurgePresence(
        {status: "invited"}, {status: "active"})).toBe(false);
  });
  test("does not purge on doc creation (no before)", () => {
    expect(shouldPurgePresence(null, {status: "active"})).toBe(false);
  });
});

describe("authAccessChange", () => {
  test("revokes when an active account is disabled", () => {
    expect(authAccessChange({status: "active"}, {status: "disabled"}))
        .toBe("revoke");
  });
  test("revokes when the user doc is deleted", () => {
    expect(authAccessChange({status: "active"}, null)).toBe("revoke");
  });
  test("restores when a disabled account is reactivated", () => {
    expect(authAccessChange({status: "disabled"}, {status: "active"}))
        .toBe("restore");
  });
  test("restores on invited -> active first activation", () => {
    expect(authAccessChange({status: "invited"}, {status: "active"}))
        .toBe("restore");
  });
  test("restores on create of an active account", () => {
    expect(authAccessChange(null, {status: "active"})).toBe("restore");
  });
  test("does nothing on active -> active", () => {
    expect(authAccessChange({status: "active"}, {status: "active"}))
        .toBeNull();
  });
  test("does nothing on disabled -> disabled", () => {
    expect(authAccessChange({status: "disabled"}, {status: "disabled"}))
        .toBeNull();
  });
  test("does nothing on create of an invited account", () => {
    expect(authAccessChange(null, {status: "invited"})).toBeNull();
  });
});

describe("applyAuthAccess", () => {
  const makeAuth = () => ({
    updateUser: jest.fn().mockResolvedValue(undefined),
    revokeRefreshTokens: jest.fn().mockResolvedValue(undefined),
  });

  test("revoke disables the account AND revokes refresh tokens", async () => {
    const auth = makeAuth();
    await applyAuthAccess("uid-1", "revoke", auth);

    expect(auth.updateUser).toHaveBeenCalledWith("uid-1", {disabled: true});
    expect(auth.revokeRefreshTokens).toHaveBeenCalledWith("uid-1");
  });

  test("restore re-enables and does NOT revoke tokens", async () => {
    const auth = makeAuth();
    await applyAuthAccess("uid-1", "restore", auth);

    expect(auth.updateUser).toHaveBeenCalledWith("uid-1", {disabled: false});
    expect(auth.revokeRefreshTokens).not.toHaveBeenCalled();
  });

  test("a missing auth user is swallowed, not retried forever", async () => {
    const auth = makeAuth();
    const err = new Error("no user");
    err.code = "auth/user-not-found";
    auth.updateUser.mockRejectedValue(err);

    await expect(applyAuthAccess("gone", "revoke", auth)).resolves
        .toBeUndefined();
  });

  test("any other auth error propagates so the handler retries", async () => {
    const auth = makeAuth();
    auth.updateUser.mockRejectedValue(new Error("network"));

    await expect(applyAuthAccess("uid-1", "revoke", auth))
        .rejects.toThrow("network");
  });
});

describe("syncUsersByUid bridge/presence isolation", () => {
  const makeSnap = (data) => data === null ?
    {exists: false, data: () => null} :
    {exists: true, data: () => data};

  const makeEvent = (userId, before, after) => {
    currentUser = after;
    if (before?.uid && ["active", "disabled"].includes(before.status)) {
      bridgeRows.set(`usersByUid/${before.uid}`, {
        docId: userId, role: before.role, status: before.status,
      });
    }
    return {
      params: {userId},
      data: {before: makeSnap(before), after: makeSnap(after)},
    };
  };

  let batch;
  let presenceDelete;
  let db;
  let recursiveDeletes;
  let collectionDeletes;
  let auth;
  let currentUser;
  let bridgeRows;

  beforeEach(() => {
    jest.clearAllMocks();
    currentUser = null;
    bridgeRows = new Map();
    batch = {
      get: jest.fn(async (ref) => ref.path.startsWith("users/") ?
        makeSnap(currentUser) : makeSnap(bridgeRows.get(ref.path) || null)),
      delete: jest.fn((ref) => {
        bridgeRows.delete(ref.path);
        collectionDeletes.push(ref.path);
      }),
      set: jest.fn((ref, data) => bridgeRows.set(ref.path, data)),
      commit: jest.fn().mockResolvedValue(undefined),
    };
    presenceDelete = jest.fn().mockRejectedValue(new Error("boom"));
    // recursiveDeletes records the collection paths passed to
    // db.recursiveDelete, and collectionDeletes records the deleted doc-marker
    // paths.
    recursiveDeletes = [];
    collectionDeletes = [];
    db = {
      collection: jest.fn((path) => ({
        path,
        doc: jest.fn((id) => ({
          path: `${path}/${id}`,
          get: async () => makeSnap(bridgeRows.get(`${path}/${id}`) || null),
          delete: jest.fn(() => {
            collectionDeletes.push(`${path}/${id}`);
            return Promise.resolve(undefined);
          }),
        })),
      })),
      recursiveDelete: jest.fn((ref) => {
        recursiveDeletes.push(ref.path);
        return Promise.resolve(undefined);
      }),
      runTransaction: jest.fn(async (fn) => {
        const result = await fn(batch);
        await batch.commit();
        return result;
      }),
      doc: jest.fn((path) => ({
        path,
        get: async () => makeSnap(currentUser),
        delete: presenceDelete,
      })),
    };
    getFirestore.mockReturnValue(db);
    auth = {
      updateUser: jest.fn().mockResolvedValue(undefined),
      revokeRefreshTokens: jest.fn().mockResolvedValue(undefined),
    };
    getAuth.mockReturnValue(auth);
  });

  test("bridge mirror writes even when the presence purge throws, " +
      "then the purge failure is rethrown for retry", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "disabled", role: "employee"};

    await expect(
        syncUsersByUid.run(makeEvent("u_doc", before, after)),
    ).rejects.toThrow("boom");

    // Bridge mirror completed despite the failing purge.
    expect(batch.set).toHaveBeenCalledTimes(1);
    expect(batch.commit).toHaveBeenCalledTimes(1);
    // Purge was attempted against the correct path.
    expect(db.doc).toHaveBeenCalledWith("users/u_doc/presence/location");
    expect(presenceDelete).toHaveBeenCalledTimes(1);
    // And it ran strictly after the bridge write.
    expect(batch.commit.mock.invocationCallOrder[0])
        .toBeLessThan(presenceDelete.mock.invocationCallOrder[0]);
  });

  // The doc-DELETED branch. Fourteen makeEvent(...) calls existed and not one
  // passed `after` as null, so this path never ran — and it is the teardown for
  // `usersByUid`, which is assertAdmin's ONLY data source and the collection
  // every rules role gate resolves through. Break it and a deleted user's
  // bridge row survives carrying `role: "admin", status: "active"`: a live
  // admin credential for an account that no longer exists.
  test("a DELETED user doc removes its bridge row", async () => {
    presenceDelete.mockResolvedValue(undefined);
    const before = {uid: "auth1", status: "active", role: "admin"};

    await syncUsersByUid.run(makeEvent("u_doc", before, null));

    expect(collectionDeletes).toContain("usersByUid/auth1");
    // Terminal cleanup, so nothing is re-created.
    expect(batch.set).not.toHaveBeenCalled();
  });

  test("a deleted doc with no uid deletes no bridge row", async () => {
    // A pre-P4c doc that never got an Auth account has nothing to tear down,
    // and deleting `usersByUid/` (empty id) would be a path error.
    presenceDelete.mockResolvedValue(undefined);
    const before = {uid: "", status: "invited", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, null));

    // Scoped to the bridge: the delivery-state purge legitimately deletes other
    // markers on this same event.
    expect(
        collectionDeletes.filter((p) => p.startsWith("usersByUid/")),
    ).toEqual([]);
    expect(batch.set).not.toHaveBeenCalled();
  });

  test("a deleted user doc also revokes the Auth credential", async () => {
    // authAccessChange already pins "revokes when the user doc is deleted";
    // this is the same rule reached through the real handler, so the two cannot
    // drift.
    presenceDelete.mockResolvedValue(undefined);
    const before = {uid: "auth1", status: "active", role: "admin"};

    await syncUsersByUid.run(makeEvent("u_doc", before, null));

    expect(auth.updateUser).toHaveBeenCalledWith("auth1", {disabled: true});
    expect(auth.revokeRefreshTokens).toHaveBeenCalledWith("auth1");
  });

  test("a successful presence purge resolves", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "disabled", role: "employee"};
    presenceDelete.mockResolvedValue(undefined);

    await expect(
        syncUsersByUid.run(makeEvent("u_doc", before, after)),
    ).resolves.toBeUndefined();

    expect(batch.commit).toHaveBeenCalledTimes(1);
    expect(presenceDelete).toHaveBeenCalledTimes(1);
  });

  test("deactivation also purges push + Live Activity delivery state",
      async () => {
        const before = {uid: "auth1", status: "active", role: "employee"};
        const after = {uid: "auth1", status: "disabled", role: "employee"};
        presenceDelete.mockResolvedValue(undefined);

        await expect(
            syncUsersByUid.run(makeEvent("u_doc", before, after)),
        ).resolves.toBeUndefined();

        // Both token subcollections were recursively deleted — that's what lets
        // us paginate past the 500-write batch cap.
        expect(recursiveDeletes).toEqual([
          "users/u_doc/fcmTokens",
          "users/u_doc/liveActivityTokens",
        ]);
        // And the server-owned card marker was cleared.
        expect(collectionDeletes).toContain("liveActivityCards/u_doc");
      });

  test("deactivation disables the Auth account after the bridge write",
      async () => {
        const before = {uid: "auth1", status: "active", role: "employee"};
        const after = {uid: "auth1", status: "disabled", role: "employee"};
        presenceDelete.mockResolvedValue(undefined);

        await syncUsersByUid.run(makeEvent("u_doc", before, after));

        expect(auth.updateUser)
            .toHaveBeenCalledWith("auth1", {disabled: true});
        expect(auth.revokeRefreshTokens).toHaveBeenCalledWith("auth1");
        // Strictly after the auth-critical bridge mirror.
        expect(batch.commit.mock.invocationCallOrder[0])
            .toBeLessThan(auth.updateUser.mock.invocationCallOrder[0]);
      });

  test("reactivation re-enables the Auth account", async () => {
    const before = {uid: "auth1", status: "disabled", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(auth.updateUser).toHaveBeenCalledWith("auth1", {disabled: false});
    expect(auth.revokeRefreshTokens).not.toHaveBeenCalled();
  });

  test("an active -> active update leaves the Auth account alone", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("a failing bridge write happens before any auth change", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "disabled", role: "employee"};
    presenceDelete.mockRejectedValue(new Error("boom"));

    // The presence purge throws first, so the auth change never runs and the
    // retry re-runs both — neither step may be half-applied silently.
    await expect(
        syncUsersByUid.run(makeEvent("u_doc", before, after)),
    ).rejects.toThrow("boom");
    expect(auth.updateUser).not.toHaveBeenCalled();
  });

  test("no delivery-state purge on an active -> active update", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(recursiveDeletes).toEqual([]);
    expect(collectionDeletes).not.toContain("liveActivityCards/u_doc");
  });

  test("no presence purge on an active -> active update", async () => {
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(db.doc).not.toHaveBeenCalled();
    expect(presenceDelete).not.toHaveBeenCalled();
  });

  test("an edit that touches nothing the bridge mirrors writes nothing",
      async () => {
        // The hot path: My details' availability panel commits per switch with
        // no debounce, so flipping five working days is five invocations of
        // this trigger.
        const before = {
          uid: "auth1", status: "active", role: "employee",
          workingDays: [false, true, true, true, true, true, false],
        };
        const after = {
          uid: "auth1", status: "active", role: "employee",
          workingDays: [true, true, true, true, true, true, false],
        };

        await syncUsersByUid.run(makeEvent("u_doc", before, after));

        expect(batch.set).not.toHaveBeenCalled();
        expect(batch.commit).not.toHaveBeenCalled();
      });

  test("a role change still rewrites the bridge", async () => {
    // Role is exactly what the rules resolve through the bridge, so this one
    // must never be skipped.
    const before = {uid: "auth1", status: "active", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "admin"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(batch.set).toHaveBeenCalledTimes(1);
    expect(batch.set.mock.calls[0][1])
        .toEqual({role: "admin", docId: "u_doc", status: "active"});
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });

  test("a status change still rewrites the bridge", async () => {
    const before = {uid: "auth1", status: "disabled", role: "employee"};
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", before, after));

    expect(batch.set.mock.calls[0][1])
        .toEqual({role: "employee", docId: "u_doc", status: "active"});
  });

  test("a uid rotation still deletes the stale bridge doc and writes the new",
      async () => {
        const before = {uid: "old", status: "active", role: "employee"};
        const after = {uid: "new", status: "active", role: "employee"};

        await syncUsersByUid.run(makeEvent("u_doc", before, after));

        // Both halves land in ONE batch, so a crash between them can't leave
        // two live bridge docs.
        expect(batch.delete).toHaveBeenCalledTimes(1);
        expect(batch.set).toHaveBeenCalledTimes(1);
        expect(batch.commit).toHaveBeenCalledTimes(1);
      });

  test("a doc creation still writes the bridge", async () => {
    // No `before` at all, so the no-op guard must not swallow it.
    const after = {uid: "auth1", status: "active", role: "employee"};

    await syncUsersByUid.run(makeEvent("u_doc", null, after));

    expect(batch.set).toHaveBeenCalledTimes(1);
    expect(batch.commit).toHaveBeenCalledTimes(1);
  });

  test("a delayed activation cannot restore a disabled user's access",
      async () => {
        const active = {uid: "auth1", status: "active", role: "admin"};
        const event = makeEvent("u_doc", null, active);
        currentUser = {...active, status: "disabled"};

        await syncUsersByUid.run(event);

        expect(bridgeRows.get("usersByUid/auth1").status).toBe("disabled");
        expect(auth.updateUser).toHaveBeenLastCalledWith(
            "auth1", {disabled: true});
      });

  test("a delayed activation cannot recreate a deleted user's bridge",
      async () => {
        const disabled = {uid: "auth1", status: "disabled", role: "admin"};
        const event = makeEvent("u_doc", disabled,
            {...disabled, status: "active"});
        currentUser = null;

        await syncUsersByUid.run(event);

        expect(bridgeRows.has("usersByUid/auth1")).toBe(false);
        expect(auth.updateUser).toHaveBeenLastCalledWith(
            "auth1", {disabled: true});
      });

  test("a delayed deactivation preserves reactivated access and tokens",
      async () => {
        const active = {uid: "auth1", status: "active", role: "employee"};
        const event = makeEvent("u_doc", active,
            {...active, status: "disabled"});
        currentUser = active;

        await syncUsersByUid.run(event);

        expect(bridgeRows.get("usersByUid/auth1").status).toBe("active");
        expect(recursiveDeletes).toEqual([]);
        expect(presenceDelete).not.toHaveBeenCalled();
        expect(auth.updateUser).toHaveBeenLastCalledWith(
            "auth1", {disabled: false});
      });

  test("a status change during the Auth write is reconciled again",
      async () => {
        const active = {uid: "auth1", status: "active", role: "employee"};
        const event = makeEvent("u_doc", null, active);
        auth.updateUser.mockImplementationOnce(async () => {
          currentUser = {...active, status: "disabled"};
        });

        await syncUsersByUid.run(event);

        expect(auth.updateUser).toHaveBeenLastCalledWith(
            "auth1", {disabled: true});
      });

  test("an old deletion leaves another profile's bridge and Auth alone",
      async () => {
        presenceDelete.mockResolvedValue(undefined);
        const event = makeEvent("u_doc",
            {uid: "auth1", status: "active", role: "employee"}, null);
        const owner = {docId: "other", status: "active", role: "employee"};
        bridgeRows.set("usersByUid/auth1", owner);

        await syncUsersByUid.run(event);

        expect(bridgeRows.get("usersByUid/auth1")).toEqual(owner);
        expect(auth.updateUser).not.toHaveBeenCalled();
      });

  test("a delayed uid rotation removes every stale bridge it names",
      async () => {
        const active = {uid: "old", status: "active", role: "employee"};
        const event = makeEvent("u_doc", active, {...active, uid: "middle"});
        currentUser = {...active, uid: "new"};
        bridgeRows.set("usersByUid/middle", {
          docId: "u_doc", status: "active", role: "employee",
        });

        await syncUsersByUid.run(event);

        expect([...bridgeRows.keys()]).toEqual(["usersByUid/new"]);
      });

  test("an invalid live role removes its privileged bridge", async () => {
    const before = {uid: "auth1", status: "active", role: "admin"};
    await syncUsersByUid.run(makeEvent("u_doc", before,
        {...before, role: "unknown"}));
    expect(bridgeRows.has("usersByUid/auth1")).toBe(false);
  });

  test("a live uid collision cannot overwrite another profile's bridge",
      async () => {
        const active = {uid: "auth1", status: "active", role: "employee"};
        const event = makeEvent("u_doc", null, active);
        const owner = {docId: "other", status: "active", role: "admin"};
        bridgeRows.set("usersByUid/auth1", owner);
        await expect(syncUsersByUid.run(event))
            .rejects.toThrow("uid belongs to another profile");
        expect(bridgeRows.get("usersByUid/auth1")).toEqual(owner);
        expect(auth.updateUser).not.toHaveBeenCalled();
      });

  test("an unstable Auth profile requests trigger retry after three attempts",
      async () => {
        presenceDelete.mockResolvedValue(undefined);
        const active = {uid: "auth1", status: "active", role: "employee"};
        const event = makeEvent("u_doc", null, active);
        auth.updateUser.mockImplementation(async () => {
          currentUser = {...currentUser,
            status: currentUser.status === "active" ? "disabled" : "active"};
        });
        await expect(syncUsersByUid.run(event))
            .rejects.toThrow("profile changed during Auth reconciliation");
        expect(auth.updateUser).toHaveBeenCalledTimes(3);
      });
});
