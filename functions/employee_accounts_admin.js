const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const crypto = require("node:crypto");
const {withAccountOperation} = require("./account_operation");
const {
  requireString,
  requireDocId,
  optionalString,
  assertAdminCall,
  enforceDurableRateLimit,
  assertFreshReauth,
  REAUTH_MAX_AGE_SECONDS,
  shortHash,
  APP_CHECK,
} = require("./security");

/** The starting password a new employee account is created with. */
const PASSWORD_UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ";
const PASSWORD_LOWER = "abcdefghijkmnopqrstuvwxyz";
const PASSWORD_DIGITS = "23456789";
// Kept OUT of PASSWORD_ALPHABET on purpose, so a mint carries EXACTLY one
// symbol: the admin dictates this aloud, and one awkward glyph is a bounded ask
// where "somewhere between none and twelve" is not.
const PASSWORD_SYMBOLS = "!@$?*";
const PASSWORD_ALPHABET = PASSWORD_UPPER + PASSWORD_LOWER + PASSWORD_DIGITS;
const PASSWORD_LENGTH = 12;

/**
 * One uniformly-random character of [alphabet].
 * @param {string} alphabet Characters to choose from.
 * @return {string} One character.
 */
function pickChar(alphabet) {
  return alphabet[crypto.randomInt(alphabet.length)];
}

/**
 * Generates a starting password.
 * @return {string} 12 unambiguous characters with at least one uppercase, one
 * lowercase and one digit, and exactly one symbol.
 */
function generateStartingPassword() {
  const chars = [
    pickChar(PASSWORD_UPPER),
    pickChar(PASSWORD_LOWER),
    pickChar(PASSWORD_DIGITS),
    pickChar(PASSWORD_SYMBOLS),
  ];
  while (chars.length < PASSWORD_LENGTH) {
    chars.push(pickChar(PASSWORD_ALPHABET));
  }
  // Fisher-Yates: without it the four guaranteed picks always sit in front,
  // which leaks 4 of the 12 positions' character classes.
  for (let i = chars.length - 1; i > 0; i--) {
    const j = crypto.randomInt(i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join("");
}

// Account creation is bounded per admin uid — defense-in-depth so a compromised
// admin session can't mass-create employees (each one is a real Firebase Auth
// account, not just a Firestore doc).
const CREATE_RATE_MAX = 20;
const CREATE_RATE_WINDOW_MS = 60 * 60 * 1000;

// Mirrors JobTitle.raw (lib/features/employees/domain/models/job_title.dart)
// and the rules' isValidJobTitle allowlist.
const JOB_TITLES = [
  "", "lead_tech", "technician", "apprentice", "dispatcher",
];

/**
 * Creates (or re-provisions) the Firebase Auth account for an employee.
 * @param {!Object} auth Admin Auth instance.
 * @param {string} email lowercased email.
 * @param {string} displayName composed name.
 * @param {string} password the starting password generated for this call.
 * @return {!Promise<{uid: string, reused: boolean}>}
 */
async function provisionAuthAccount(auth, email, displayName, password) {
  try {
    const user = await auth.createUser({
      email, password, displayName, emailVerified: false,
    });
    return {uid: user.uid, reused: false};
  } catch (e) {
    if (e && e.code === "auth/email-already-exists") {
      // Resolve the uid ONLY — the password of an existing account is not
      // touched here.
      const existing = await auth.getUserByEmail(email);
      return {uid: existing.uid, reused: true};
    }
    throw e;
  }
}

/**
 * Rotates a re-provisioned account to a newly generated starting password.
 * @param {!Object} auth Admin Auth instance.
 * @param {string} uid the provisioned Auth uid.
 * @param {string} displayName composed name.
 * @param {string} password the starting password generated for this call.
 * @return {!Promise<void>}
 */
async function resetProvisionedPassword(auth, uid, displayName, password) {
  // A demoted account was disabled by syncUsersByUid; a reset must work.
  await auth.updateUser(uid, {password, displayName, disabled: false});
}

/**
 * Transactional core of createEmployeeAccount, extracted for unit testing.
 * @param {!Object} db Firestore instance.
 * @param {{name: string, firstName: string, lastName: string, email: string,
 * phone: string, colorValue: string, jobTitle: string}}
 * fields Validated fields (email already lowercased).
 * @param {{uid: string, serverTimestamp: !Function}} opts The provisioned Auth
 * uid and a serverTimestamp factory (injectable for tests).
 * @return {!Promise<{ok: boolean, docId: (string|undefined)}>} `ok:false`
 * means the email belongs to an account that has already been set up.
 */
async function performCreateAccount(db, fields, opts) {
  const {
    name, firstName, lastName, email, phone, colorValue, jobTitle,
  } = fields;
  const {uid, serverTimestamp} = opts;
  // Never "admin": a created account can be pre-empted by whoever holds the
  // starting password, so it must never be able to arrive privileged.
  const role = "employee";

  return db.runTransaction(async (tx) => {
    const dup = await tx.get(
        db.collection("users").where("email", "==", email).limit(1),
    );
    const existing = dup.empty ? null : dup.docs[0];
    // A person who has finished setup owns their account now — re-creating them
    // would reset a password they chose.
    if (existing && existing.data().status !== "invited") {
      return {ok: false};
    }

    // The uid must not already belong to somebody else's doc.
    const byUid = await tx.get(
        db.collection("users").where("uid", "==", uid).limit(2),
    );
    const claimedElsewhere = byUid.docs.some(
        (d) => !existing || d.id !== existing.id,
    );
    if (claimedElsewhere) {
      return {ok: false};
    }

    if (existing) {
      // Refresh the editable fields; status and uid are already right.
      tx.update(existing.ref, {
        name, firstName, lastName, phone, colorValue, jobTitle, role, uid,
        // A legacy setup changed its password before calling us. Once an
        // admin resets this invitation, only coordinated setup may activate it.
        setupRequiresPassword: true,
        updatedAt: serverTimestamp(),
      });
      return {ok: true, docId: existing.id};
    }

    const ref = db.collection("users").doc();
    tx.set(ref, {
      name, firstName, lastName, email, phone, colorValue, jobTitle, role,
      // The Auth account exists from this moment, so the doc carries its uid
      // immediately — unlike the retired code flow, where uid stayed "" until
      // redemption.
      status: "invited", uid,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
    return {ok: true, docId: ref.id};
  });
}

const createEmployeeAccount = onCall(APP_CHECK, async (req) => {
  // Validate the payload before consuming a rate-limit slot so malformed
  // submissions can't lock out a legitimate admin for an hour —
  // `assertAdminCall` fixes that order (auth -> admin -> payload) so it cannot
  // be re-decided here.
  await assertAdminCall(req, new Set([
    "name", "firstName", "lastName", "email", "phone", "colorValue",
    "jobTitle",
  ]));
  // 250, not 100: `name` is the JOIN of the two halves, each capped at 100
  // client- and server-side, so the composed value legitimately reaches 201.
  const name = requireString(req.data, "name", 250);
  const firstName = optionalString(req.data, "firstName", 100);
  const lastName = optionalString(req.data, "lastName", 100);
  const email = requireString(req.data, "email", 254).toLowerCase();
  const phone = optionalString(req.data, "phone", 40);
  const colorValue = requireString(req.data, "colorValue", 40);
  const jobTitle = optionalString(req.data, "jobTitle", 40);
  // Mirrors the rules' colorValue guard (firestore.rules isValidUserData) —
  // this Admin SDK write bypasses rules, so it's the one path that could
  // otherwise seed a value they'd reject.
  if (!/^-?[0-9]+$/.test(colorValue)) {
    throw new HttpsError("invalid-argument", "invalid-colorValue");
  }
  // Same reasoning for jobTitle: the allowlist here IS the enforcement.
  if (!JOB_TITLES.includes(jobTitle)) {
    throw new HttpsError("invalid-argument", "invalid-jobTitle");
  }
  await enforceDurableRateLimit(
      "createEmployeeAccount", req.auth.uid, CREATE_RATE_MAX,
      CREATE_RATE_WINDOW_MS);

  const db = getFirestore();
  const auth = getAuth();

  // Lock duplicate creates before minting Auth: a losing request must not
  // roll back an account a different request has already claimed.
  const emailLock = "email_" + crypto.createHash("sha256")
      .update(email).digest("hex");
  return withAccountOperation(db, emailLock, "create", async () => {
    // Refuse before touching Auth when the account has finished setup.
    const existingAuth = await auth.getUserByEmail(email).catch((error) => {
      if (error.code === "auth/user-not-found") return null;
      throw error;
    });
    if (existingAuth) {
      // Whose account IS this? Resolve by uid — that is the join the bridge and
      // every rules gate use.
      const byUid = await db.collection("users")
          .where("uid", "==", existingAuth.uid).limit(1).get();
      if (byUid.empty || byUid.docs[0].data().status !== "invited") {
        throw new HttpsError("already-exists", "email-exists");
      }
    }
    const claimed = await db.collection("users")
        .where("email", "==", email).limit(1).get();
    if (!claimed.empty && claimed.docs[0].data().status !== "invited") {
      throw new HttpsError("already-exists", "email-exists");
    }

    // Resolve the uid without changing an existing password yet.
    const startingPassword = generateStartingPassword();
    const provisioned = existingAuth ?
      {uid: existingAuth.uid, reused: true} :
      await provisionAuthAccount(auth, email, name, startingPassword);

    // Keep refusal and rollback under one owner.
    try {
      await withAccountOperation(db, provisioned.uid, "provision", async () => {
        const outcome = await performCreateAccount(
            db,
            {name, firstName, lastName, email, phone, colorValue, jobTitle},
            {
              uid: provisioned.uid,
              serverTimestamp: () => FieldValue.serverTimestamp(),
            },
        );
        if (!outcome.ok) throw new HttpsError("already-exists", "email-exists");
        // Setup holds this same lock across its password write and activation.
        if (provisioned.reused) {
          await resetProvisionedPassword(
              auth, provisioned.uid, name, startingPassword);
        }
      });
    } catch (e) {
      if (!provisioned.reused) {
        // A failed rollback leaves an Auth account no admin surface can see.
        // Report it so an operator can recover the orphaned account.
        await auth.deleteUser(provisioned.uid).catch((rollbackError) => {
          logger.error(
              "createEmployeeAccount: orphaned auth account; delete it by hand",
              {uid: provisioned.uid, err: String(rollbackError)},
          );
        });
      }
      throw e;
    }
    // The password is returned so the admin surface shows exactly what was set
    // rather than a constant it hopes still matches the server.
    return {email, password: startingPassword};
  });
});

/**
 * Transactional core of deleteEmployeeAccount, extracted for unit testing.
 * @param {!Object} db Firestore instance.
 * @param {string} docId users-doc id.
 * @return {!Promise<{ok: boolean, reason: (string|undefined),
 * uid: (string|undefined)}>}
 */
async function performDeleteAccount(db, docId) {
  return db.runTransaction(async (tx) => {
    const ref = db.collection("users").doc(docId);
    const snap = await tx.get(ref);
    if (!snap.exists) return {ok: false, reason: "not-found"};
    const data = snap.data();
    // Transactional so a setup that commits first flips status and this refuses
    // instead of deleting a just-activated account.
    if (data.status !== "invited") {
      return {ok: false, reason: "not-pending"};
    }
    tx.delete(ref);
    return {ok: true, uid: data.uid || ""};
  });
}

const deleteEmployeeAccount = onCall(APP_CHECK, async (req) => {
  await assertAdminCall(req, new Set(["docId"]));
  const docId = requireDocId(req.data, "docId");
  await enforceDurableRateLimit(
      "deleteEmployeeAccount", req.auth.uid, CREATE_RATE_MAX,
      CREATE_RATE_WINDOW_MS);

  const outcome = await performDeleteAccount(getFirestore(), docId);
  if (!outcome.ok) {
    if (outcome.reason === "not-pending") {
      throw new HttpsError("failed-precondition", "account-not-pending");
    }
    throw new HttpsError("not-found", "account-not-found");
  }
  // Doc first, Auth second: an Auth account with no doc is invisible to every
  // admin surface, while a doc with no Auth account is visible and fixable by
  // re-creating.
  if (outcome.uid) {
    await getAuth().deleteUser(outcome.uid).catch((e) => {
      if (!e || e.code !== "auth/user-not-found") {
        // The doc is already gone, so this leaves an Auth account no admin
        // surface can see and whose email createEmployeeAccount will then
        // refuse.
        logger.error(
            "deleteEmployeeAccount: orphaned auth account; delete it by hand",
            {uid: outcome.uid, err: String(e)},
        );
        throw e;
      }
    });
  }
  return {ok: true};
});

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
    // Re-checked here so a promotion committing first cannot slip through.
    if (data.role === "admin") {
      throw new HttpsError("failed-precondition", "target-is-admin");
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
  assertFreshReauth(
      req.auth, "resetEmployeePassword", REAUTH_MAX_AGE_SECONDS);
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
  if (data.role === "admin") {
    throw new HttpsError("failed-precondition", "target-is-admin");
  }

  const auth = getAuth();
  const password = generateStartingPassword();
  let record;
  // Flag first: a failed Auth write then only forces an unneeded change.
  await withAccountOperation(db, uid, "password-reset", async () => {
    await markPasswordResetRequired(db, docId, uid);
    record = await auth.updateUser(uid, {password});
    // Past this point the password is set, so the admin must still get it.
    await auth.revokeRefreshTokens(uid).catch((e) => {
      logger.error("resetEmployeePassword: password changed, revoke failed",
          {uidHash: shortHash(uid), err: String(e)});
    });
  });
  logger.info("resetEmployeePassword: password reset",
      {uidHash: shortHash(uid)});
  // Auth owns sign-in; the Firestore copy can lag on older docs.
  return {email: (record && record.email) || data.email || "", password};
});

module.exports = {
  generateStartingPassword,
  createEmployeeAccount,
  deleteEmployeeAccount,
  resetEmployeePassword,
  // Exported for unit tests of the transactional flows.
  provisionAuthAccount,
  resetProvisionedPassword,
  performCreateAccount,
  performDeleteAccount,
};
