/**
 * @fileoverview Tests the orchestration bodies behind the photo
 * subcollection. All of them take an injected `db`, so none needs the emulator.
 *
 * The cascade is the one that matters most: Firestore does not delete a
 * subcollection with its parent, so if `purgeAppointmentImages` regresses,
 * every appointment delete leaves photo documents orphaned under a parent that
 * no longer exists — invisible in the console, unreachable by every query the
 * app makes, and with nothing anywhere reporting it.
 *
 * The debounce is the one most easily broken into a data bug: it must collapse
 * one photo batch into ONE parent write without ever suppressing the offline
 * queue's replay, which is the only self-heal `pictureCount` has.
 *
 * The claim PROTOCOL — staleness takeover, both fail-open branches, the
 * swallowed release failure, the TTL stamp — belongs to `recount_claim.js` and
 * is pinned by `__tests__/recount_claim.test.js`. What is asserted here is
 * only what this adapter decides: the ledger it claims in, the settle window,
 * the `{skipped, count}` shape, and that the aggregate it hands over is
 * `recountPictures`.
 */
const {
  purgeAppointmentImages,
  appointmentImagePrefix,
  recountPictures,
  debouncedRecountPictures,
  IMAGES_SUBCOLLECTION,
  PICTURE_COUNT_WARN_CAP,
  RECOUNT_CLAIM_COLLECTION,
  RECOUNT_SETTLE_MS,
} = require("../appointment_images");

/**
 * Resolves after every pending promise job has drained.
 * @return {!Promise<void>}
 */
function flush() {
  return new Promise((resolve) => setImmediate(resolve));
}

/**
 * Minimal Firestore fake: an in-memory claim ledger plus recorders for the
 * recursiveDelete targets, the parent updates and the ORDER of every
 * operation (the release-before-aggregate rule is an ordering property, so it
 * can only be pinned by observing order).
 * @param {!Object=} config `{count, updateError, deleteError, claimCreateError,
 *   claimDeleteError}`.
 * @return {!Object}
 */
function makeDb(config = {}) {
  const state = {
    count: config.count || 0,
    claims: new Map(),
    recursiveDeletes: [],
    updates: [],
    claimCreates: [],
    claimSets: [],
    claimDeletes: [],
    ops: [],
  };
  const claimDoc = (id) => ({
    create: async (data) => {
      if (config.claimCreateError) throw config.claimCreateError;
      if (state.claims.has(id)) {
        throw Object.assign(new Error("already exists"), {code: 6});
      }
      state.claims.set(id, data);
      state.claimCreates.push({id, data});
      state.ops.push("claim");
    },
    get: async () => {
      const data = state.claims.get(id);
      return {
        exists: data !== undefined,
        get: (field) => (data ? data[field] : undefined),
      };
    },
    set: async (data) => {
      state.claims.set(id, data);
      state.claimSets.push({id, data});
      state.ops.push("takeover");
    },
    delete: async () => {
      if (config.claimDeleteError) throw config.claimDeleteError;
      state.claims.delete(id);
      state.claimDeletes.push(id);
      state.ops.push("release");
    },
  });
  const appointmentDoc = (name, id) => {
    const parentPath = `${name}/${id}`;
    return {
      _path: parentPath,
      get: async () => ({exists: true}),
      update: async (patch) => {
        if (config.updateError) throw config.updateError;
        state.updates.push({path: parentPath, patch});
        state.ops.push("update");
      },
      collection: (sub) => ({
        _path: `${parentPath}/${sub}`,
        count: () => ({
          get: async () => {
            state.ops.push("count");
            return {data: () => ({count: state.count})};
          },
        }),
      }),
    };
  };
  const db = {
    runTransaction: async (body) => {
      const writes = [];
      const result = await body({
        get: (ref) => ref.get(),
        update: (ref, patch) => writes.push({ref, patch}),
      });
      for (const {ref, patch} of writes) await ref.update(patch);
      return result;
    },
    recursiveDelete: async (ref) => {
      if (config.deleteError) throw config.deleteError;
      state.recursiveDeletes.push(ref._path);
    },
    collection(name) {
      if (name === RECOUNT_CLAIM_COLLECTION) return {doc: claimDoc};
      return {doc: (id) => appointmentDoc(name, id)};
    },
  };
  return {db, state};
}

/**
 * A logger that swallows, so a fail-open path doesn't print.
 * @return {!Object}
 */
function quietLogger() {
  return {warn: () => {}, info: () => {}};
}

describe("the subcollection name is a hand-mirror", () => {
  test("matches the Dart repository and firestore.rules", () => {
    // `_imagesSubcollection` in firebase_appointments_repository.dart and the
    // `match /images/{imageId}` block in firestore.rules both spell this. A
    // rename in one place alone points the trigger at a collection nothing
    // writes, and the cascade silently stops cascading.
    expect(IMAGES_SUBCOLLECTION).toBe("images");
  });
});

/**
 * Records the Storage prefixes a purge asked to clear.
 * @param {!Error=} error Thrown by every call when given.
 * @return {{deleteImages: function(string): !Promise<void>,
 *   prefixes: !Array<string>}}
 */
function makeImageDeleter(error) {
  const prefixes = [];
  return {
    prefixes,
    deleteImages: async (appointmentId) => {
      prefixes.push(appointmentId);
      if (error) throw error;
    },
  };
}

describe("appointmentImagePrefix", () => {
  test("ends in a slash", () => {
    // Without it `deleteFiles({prefix})` matches by bare string prefix.
    expect(appointmentImagePrefix("appt1").endsWith("/")).toBe(true);
  });

  test("appointment 12's prefix does NOT match appointment 123's objects",
      () => {
        // The cross-appointment data loss the trailing slash prevents: a
        // dropped slash makes deleting `12` sweep `123`, `120`, `1234`...
        const twelve = appointmentImagePrefix("12");
        const oneTwoThree = appointmentImagePrefix("123");
        expect(oneTwoThree.startsWith(twelve)).toBe(false);
        expect(`${oneTwoThree}a.jpg`.startsWith(twelve)).toBe(false);
      });

  test("matches its own objects", () => {
    const p = appointmentImagePrefix("appt1");
    expect(`${p}photo.jpg`.startsWith(p)).toBe(true);
  });

  test("agrees with the path the client writes", () => {
    // Hand-mirror of image_storage_service.dart:
    //   appointments/$appointmentId/images/$fileName
    expect(appointmentImagePrefix("A9")).toBe("appointments/A9/images/");
  });
});

describe("purgeAppointmentImages", () => {
  test("recursively deletes the images subcollection", async () => {
    const {db, state} = makeDb();
    const {deleteImages} = makeImageDeleter();
    await purgeAppointmentImages("appt1", {db, deleteImages});
    expect(state.recursiveDeletes).toEqual(["appointments/appt1/images"]);
  });

  test("targets the subcollection, never the parent document", async () => {
    // A ref one level too high deletes the appointment's siblings' data or the
    // appointment itself. Worth pinning explicitly — the bug would be silent
    // and catastrophic rather than silent and merely untidy.
    const {db, state} = makeDb();
    const {deleteImages} = makeImageDeleter();
    await purgeAppointmentImages("appt1", {db, deleteImages});
    expect(state.recursiveDeletes[0]).not.toBe("appointments/appt1");
    expect(state.recursiveDeletes[0].endsWith(`/${IMAGES_SUBCOLLECTION}`))
        .toBe(true);
  });

  test("RETHROWS, so the trigger's retry can run", async () => {
    // Deliberately unlike the best-effort cleanup elsewhere in this codebase.
    // A swallowed failure here leaves permanently invisible orphans; letting it
    // throw is what makes `retry: true` mean anything.
    const {db} = makeDb({deleteError: new Error("boom")});
    const {deleteImages} = makeImageDeleter();
    await expect(purgeAppointmentImages("appt1", {db, deleteImages}))
        .rejects.toThrow("boom");
  });

  test("deletes the appointment's Storage bytes too", async () => {
    // The CONTRACT step took the `pictures` array away, and with it the list
    // the client used to enumerate which objects to delete. Nothing else
    // deletes these bytes now: miss this and every appointment delete orphans
    // its photos in Storage, invisibly and forever.
    const {db} = makeDb();
    const {deleteImages, prefixes} = makeImageDeleter();
    await purgeAppointmentImages("appt1", {db, deleteImages});
    expect(prefixes).toEqual(["appt1"]);
  });

  test("clears the bytes BEFORE the documents", async () => {
    // Bytes first, docs second — the same ordering rule `purgeExpiredHistory`
    // follows. The documents are what a human has left to find the objects
    // with; dropping them first and then failing loses the trail.
    const order = [];
    const {db} = makeDb();
    const baseDelete = db.recursiveDelete;
    db.recursiveDelete = async (ref) => {
      order.push("docs");
      return baseDelete(ref);
    };
    await purgeAppointmentImages("appt1", {
      db,
      deleteImages: async () => {
        order.push("bytes");
      },
    });
    expect(order).toEqual(["bytes", "docs"]);
  });

  test("a Storage failure RETHROWS, leaving the documents alone", async () => {
    // Same reasoning as the recursiveDelete rethrow: `retry: true` is the only
    // thing that gets these bytes deleted, and it can only run if this throws.
    const {db, state} = makeDb();
    const {deleteImages} = makeImageDeleter(new Error("storage down"));
    await expect(purgeAppointmentImages("appt1", {db, deleteImages}))
        .rejects.toThrow("storage down");
    expect(state.recursiveDeletes).toEqual([]);
  });
});

describe("recountPictures", () => {
  test("warns once the count passes what the app can read", async () => {
    // The only replacement the `pictures` array's 100-entry rules cap has:
    // photos past the Dart read cap are simply absent from the app, and
    // without this line nothing anywhere says so.
    const warns = [];
    const {db} = makeDb({count: PICTURE_COUNT_WARN_CAP + 1});
    await recountPictures("appt1", {
      db,
      logger: {warn: (msg, ctx) => warns.push({msg, ctx})},
    });
    expect(warns).toHaveLength(1);
    expect(warns[0].ctx).toMatchObject({
      appointmentId: "appt1",
      count: PICTURE_COUNT_WARN_CAP + 1,
    });
  });

  test("stays quiet at the cap", async () => {
    const warns = [];
    const {db} = makeDb({count: PICTURE_COUNT_WARN_CAP});
    await recountPictures("appt1", {db, logger: {warn: () => warns.push(1)}});
    expect(warns).toEqual([]);
  });


  test("writes the count() aggregate absolutely", async () => {
    // Absolute, never an increment: the trigger runs with retry: true, and a
    // retried FieldValue.increment double-counts. Same rule as
    // recountClientJobs.
    const {db, state} = makeDb({count: 3});
    await expect(recountPictures("appt1", {db})).resolves.toBe(3);
    expect(state.updates).toEqual([
      {path: "appointments/appt1", patch: {pictureCount: 3}},
    ]);
  });

  test("writes zero when the last photo is removed", async () => {
    // The card's indicator reads this, so the count has to fall as well as
    // rise — a photo indicator that never clears is the visible bug.
    const {db, state} = makeDb({count: 0});
    await expect(recountPictures("appt1", {db})).resolves.toBe(0);
    expect(state.updates[0].patch).toEqual({pictureCount: 0});
  });

  test("tolerates the parent being already deleted", async () => {
    // The cascade deletes photos when an appointment goes, and each of those
    // deletes fires this trigger. Racing a NOT_FOUND is the normal path, not an
    // error — and `update()` (not set+merge) is what stops it resurrecting the
    // appointment as a count-only stub.
    const notFound = Object.assign(new Error("missing"), {code: 5});
    const {db, state} = makeDb({count: 0, updateError: notFound});
    await expect(recountPictures("appt1", {db})).resolves.toBe(-1);
    expect(state.updates).toEqual([]);
  });

  test("rethrows any other write failure", async () => {
    const denied = Object.assign(new Error("denied"), {code: 7});
    const {db} = makeDb({count: 1, updateError: denied});
    await expect(recountPictures("appt1", {db})).rejects.toThrow("denied");
  });
});

describe("debouncedRecountPictures collapses one batch", () => {
  test("ten image creates in one batch produce exactly ONE parent update",
      async () => {
        // appendAppointmentPictures commits N image docs in one WriteBatch, so
        // N triggers land on the same parent within milliseconds. Each parent
        // write also re-fires notifyAppointmentChanges, so the un-debounced
        // cost of ten photos was 10 recounts + 11 notification invocations for
        // one user action.
        const {db, state} = makeDb({count: 10});
        let openGate = () => {};
        const gate = new Promise((resolve) => {
          openGate = resolve;
        });
        const runs = Array.from({length: 10}, () =>
          debouncedRecountPictures("appt1", {
            db, logger: quietLogger(), sleep: () => gate,
          }));
        // Let every sibling's claim attempt settle before the winner releases,
        // which is what a real batch's simultaneous triggers do.
        await flush();
        openGate();
        const results = await Promise.all(runs);

        expect(state.updates).toEqual([
          {path: "appointments/appt1", patch: {pictureCount: 10}},
        ]);
        expect(state.claimCreates).toHaveLength(1);
        expect(results.filter((r) => r.skipped)).toHaveLength(9);
      });

  test("the one write it makes is the absolute aggregate, not a delta",
      async () => {
        const {db, state} = makeDb({count: 7});
        const result = await debouncedRecountPictures(
            "appt1", {db, logger: quietLogger(), sleep: async () => {}});
        expect(result).toEqual({skipped: false, count: 7});
        expect(state.updates[0].patch).toEqual({pictureCount: 7});
      });

  test("releases the claim BEFORE running the aggregate", async () => {
    // The whole safety argument for the debounce. A suppressed sibling's photo
    // was committed before its trigger fired, and its trigger fired before this
    // release — so an aggregate that runs after the release necessarily sees
    // it. Count first and release after, and a photo written in that gap would
    // be both suppressed and uncounted.
    const {db, state} = makeDb({count: 2});
    await debouncedRecountPictures(
        "appt1", {db, logger: quietLogger(), sleep: async () => {}});
    expect(state.ops).toEqual(["claim", "release", "count", "update"]);
  });

  test("a suppressed sibling writes nothing at all", async () => {
    const {db, state} = makeDb({count: 4});
    const now = new Date(1000000);
    state.claims.set("appt1", {claimedAt: now});
    const result = await debouncedRecountPictures("appt1", {
      db, logger: quietLogger(), now, sleep: async () => {},
    });
    expect(result).toEqual({skipped: true, count: null});
    expect(state.updates).toEqual([]);
    expect(state.ops).toEqual([]);
  });

  test("claims in the appointment ledger, and settles for RECOUNT_SETTLE_MS",
      async () => {
        // The two things this adapter chooses, and both are silent when wrong.
        // A wrong collection name lands on a ledger the rules deny and the TTL
        // policy never sweeps: `claimRecount` then fails open on every call and
        // the debounce simply never engages, with no error and no log.
        const slept = [];
        const {db, state} = makeDb({count: 1});
        await debouncedRecountPictures("appt1", {
          db, logger: quietLogger(), sleep: async (ms) => slept.push(ms),
        });
        expect(RECOUNT_CLAIM_COLLECTION).toBe("appointmentRecountClaims");
        expect(state.claimCreates.map((c) => c.id)).toEqual(["appt1"]);
        expect(slept).toEqual([RECOUNT_SETTLE_MS]);
      });
});

describe("the replay self-heal survives the debounce", () => {
  test("a later independent write still recounts", async () => {
    // The offline queue replays `set(..., {merge: true})` on the DERIVED doc
    // id, and the backfill re-runs — those two are the ONLY self-heal
    // pictureCount has. A debounce whose claim outlived its batch would eat
    // them and leave a wrong count wrong forever.
    const {db, state} = makeDb({count: 2});
    const deps = {db, logger: quietLogger(), sleep: async () => {}};
    await debouncedRecountPictures("appt1", deps);
    state.count = 3; // a replay landing a photo the first pass never saw
    const second = await debouncedRecountPictures("appt1", deps);

    expect(second).toEqual({skipped: false, count: 3});
    expect(state.updates.map((u) => u.patch)).toEqual([
      {pictureCount: 2}, {pictureCount: 3},
    ]);
  });
});

describe("debouncedRecountPictures and a missing parent", () => {
  test("swallows a NOT_FOUND parent rather than throwing", async () => {
    // The cascade has just removed the photos; racing it is the normal path.
    const notFound = Object.assign(new Error("missing"), {code: 5});
    const {db, state} = makeDb({count: 0, updateError: notFound});
    const result = await debouncedRecountPictures(
        "appt1", {db, logger: quietLogger(), sleep: async () => {}});
    expect(result).toEqual({skipped: false, count: -1});
    expect(state.updates).toEqual([]);
  });

  test("still rethrows a real write failure, having released first",
      async () => {
        // Rethrowing is what makes `retry: true` mean anything, and the
        // already-released claim is what lets the retry re-claim instead of
        // suppressing itself.
        const denied = Object.assign(new Error("denied"), {code: 7});
        const {db, state} = makeDb({count: 1, updateError: denied});
        await expect(debouncedRecountPictures(
            "appt1", {db, logger: quietLogger(), sleep: async () => {}}))
            .rejects.toThrow("denied");
        expect(state.claimDeletes).toEqual(["appt1"]);
        expect(state.claims.has("appt1")).toBe(false);
      });
});
