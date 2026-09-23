const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getMessaging} = require("firebase-admin/messaging");
const crypto = require("node:crypto");
const {withAccountOperation} = require("./account_operation");
const {
  assertPayloadShape,
  requireString,
  requireDocId,
  optionalString,
  assertAdminCall,
  enforceDurableRateLimit,
  assertFreshReauth,
  APP_CHECK,
} = require("./security");
// index.js already loads notifications.js in every container, so this costs no
// extra cold start.
const {
  sendToEmployee,
  sendToActiveAdmins,
  TIMED_RECIPIENT_ROLES,
} = require("./notification_utils");
const {
  buildEmailChangedMessage,
  buildSelfEmailChangedMessage,
} = require("./notification_messages");

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

// Setup runs once per person; a handful of retries covers a fumbled password.
const SETUP_RATE_MAX = 5;
const SETUP_RATE_WINDOW_MS = 15 * 60 * 1000;

// changeEmployeeEmail rewrites a SIGN-IN IDENTITY, which is the
// account-takeover primitive an unattended unlocked phone offers — so it is
// budgeted far tighter than account creation, and it demands a fresh re-auth
// the same way deleteAccount does.
const EMAIL_CHANGE_RATE_MAX = 5;
const EMAIL_CHANGE_RATE_WINDOW_MS = 60 * 60 * 1000;
const EMAIL_CHANGE_REAUTH_MAX_AGE_SECONDS = 5 * 60;

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
  await auth.updateUser(uid, {password, displayName});
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
 * Transactional core of changeEmployeeEmail, extracted for unit testing.
 * @param {!Object} db Firestore instance.
 * @param {string} docId users-doc id.
 * @param {string} email the new, lowercased email.
 * @param {string} previousEmail what the doc held when we read it.
 * @param {{serverTimestamp: !Function}} opts Timestamp factory (injectable).
 * @return {!Promise<{ok: boolean}>}
 */
async function performChangeEmail(db, docId, email, previousEmail, opts) {
  const {serverTimestamp} = opts;
  return db.runTransaction(async (tx) => {
    const ref = db.collection("users").doc(docId);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "account-not-found");
    }
    if ((snap.data().email || "") !== previousEmail) {
      throw new HttpsError("aborted", "email-changed");
    }
    const dup = await tx.get(
        db.collection("users").where("email", "==", email).limit(2),
    );
    if (dup.docs.some((d) => d.id !== docId)) {
      throw new HttpsError("already-exists", "email-exists");
    }
    tx.update(ref, {email, updatedAt: serverTimestamp()});
    return {ok: true};
  });
}

/**
 * Decides whether this caller may move [docId]'s email, and how.
 * @param {?Object} bridge The caller's `usersByUid/{uid}` data, or null.
 * @param {string} docId The users-doc id being changed.
 * @return {!Promise<{isSelf: boolean, isAdmin: boolean, callerDocId: string}>}
 */
async function resolveEmailChangeCaller(bridge, docId) {
  const data = bridge || null;
  if (!data || data.status !== "active") {
    throw new HttpsError("permission-denied", "not-admin");
  }
  const callerDocId = data.docId || "";
  // An empty callerDocId must never match an empty target.
  const isSelf = callerDocId !== "" && callerDocId === docId;
  if (data.role === "admin") return {isSelf, isAdmin: true, callerDocId};
  if (data.role === "employee" && isSelf) {
    return {isSelf: true, isAdmin: false, callerDocId};
  }
  throw new HttpsError("permission-denied", "not-admin");
}

/**
 * Moves an employee's sign-in email in Firebase Auth AND on their users doc.
 */
const changeEmployeeEmail = onCall(APP_CHECK, async (req) => {
  if (!req.auth || !req.auth.uid) {
    throw new HttpsError("unauthenticated", "auth-required");
  }
  const db = getFirestore();
  assertPayloadShape(req.data, new Set(["docId", "email"]));
  const docId = requireDocId(req.data, "docId");
  const email = requireString(req.data, "email", 254).toLowerCase();
  // Guard order: auth → payload → IDENTITY → re-auth freshness → rate limit →
  // work.
  const bridgeSnap = await db.collection("usersByUid").doc(req.auth.uid).get();
  const {isSelf, isAdmin, callerDocId} = await resolveEmailChangeCaller(
      bridgeSnap.exists ? bridgeSnap.data() : null, docId);
  // A valid ID token alone must not be enough for an EMPLOYEE to move their own
  // sign-in address: SelfEmailService re-authenticates first, but that is a
  // client-side ordering, and anything reaching this callable directly bypasses
  // it.
  if (!isAdmin) {
    assertFreshReauth(
        req.auth, "changeEmployeeEmail", EMAIL_CHANGE_REAUTH_MAX_AGE_SECONDS);
  }
  // Same per-caller budget either way: this rewrites a sign-in identity, so a
  // compromised session must not be able to walk the roster.
  await enforceDurableRateLimit(
      "changeEmployeeEmail", req.auth.uid, EMAIL_CHANGE_RATE_MAX,
      EMAIL_CHANGE_RATE_WINDOW_MS);

  const auth = getAuth();

  const snap = await db.collection("users").doc(docId).get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "account-not-found");
  }
  const previousEmail = snap.data().email || "";
  const uid = snap.data().uid || "";
  if (!uid) {
    throw new HttpsError("failed-precondition", "account-has-no-auth");
  }
  if (email === previousEmail) return {ok: true};

  // Cheap pre-flight so the common conflict costs no Auth write plus rollback.
  const claimed = await db.collection("users")
      .where("email", "==", email).limit(2).get();
  if (claimed.docs.some((d) => d.id !== docId)) {
    throw new HttpsError("already-exists", "email-exists");
  }

  // Auth FIRST, Firestore second, deliberately.
  // NOTE: nothing in this codebase READS that flag any more — the
  // `completeEmployeeSetup` guard that did was removed 2026-08-21.
  try {
    await auth.updateUser(uid, {email, emailVerified: false});
  } catch (e) {
    if (e && e.code === "auth/email-already-exists") {
      throw new HttpsError("already-exists", "email-exists");
    }
    if (e && e.code === "auth/user-not-found") {
      throw new HttpsError("not-found", "account-not-found");
    }
    throw e;
  }

  try {
    await performChangeEmail(db, docId, email, previousEmail, {
      serverTimestamp: () => FieldValue.serverTimestamp(),
    });
  } catch (e) {
    // Put Auth back where the doc still says it is.
    await auth.updateUser(uid, {email: previousEmail}).catch((revertError) => {
      logger.error(
          "changeEmployeeEmail: auth/users email desync; fix it by hand",
          {uid, docId, err: String(revertError)},
      );
    });
    throw e;
  }

  // Who needs telling depends on who did it.
  const deps = {db, messaging: getMessaging(), logger};
  if (isSelf) {
    await notifyAdminsOfSelfEmailChange(deps, callerDocId, docId);
  } else {
    await notifyEmailChanged(deps, docId, email);
  }
  return {ok: true};
});

/**
 * Tells the employee their sign-in address moved.
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {string} docId users doc id of the employee.
 * @param {string} email The new sign-in email.
 * @return {!Promise<void>}
 */
async function notifyEmailChanged(deps, docId, email) {
  try {
    await sendToEmployee(
        deps,
        docId,
        {kind: "emailChanged"},
        (locale) => buildEmailChangedMessage(email, locale),
        TIMED_RECIPIENT_ROLES,
    );
  } catch (e) {
    // Never the address itself — emails are PII and this is a log line.
    logger.warn("changeEmployeeEmail: notify failed", {docId, err: String(e)});
  }
}

/**
 * Tells the active admins that someone changed their OWN sign-in address.
 * @param {!Object} deps `{db, messaging, logger}`.
 * @param {string} callerDocId The person who made the change (excluded).
 * @param {string} docId users doc id whose email moved.
 * @return {!Promise<void>}
 */
async function notifyAdminsOfSelfEmailChange(deps, callerDocId, docId) {
  try {
    const snap = await deps.db.collection("users").doc(docId).get();
    const name = (snap.exists && (snap.data() || {}).name) || "";
    await sendToActiveAdmins(
        deps,
        {kind: "selfEmailChanged", docId},
        (locale) => buildSelfEmailChangedMessage(name, locale),
        {excludeDocId: callerDocId},
    );
  } catch (e) {
    // Never the address itself — emails are PII and this is a log line.
    logger.warn("changeEmployeeEmail: admin notify failed",
        {docId, err: String(e)});
  }
}

/**
 * Builds the activation patch completeEmployeeSetup applies to the invited
 * users doc.
 * @param {{firstName: string, lastName: string, phone: string,
 * termsAccepted: boolean, locationConsent: boolean}} fields The submitted
 * setup profile (already trimmed and length-checked).
 * @param {{userData: !Object, serverTimestamp: !Function}} opts The stored doc
 * data plus the timestamp factory (injectable for tests).
 * @return {!Object} the patch for tx.update.
 */
function buildActivationPatch(fields, opts) {
  const {firstName, lastName, phone, termsAccepted, locationConsent} = fields;
  const {userData, serverTimestamp} = opts;
  const patch = {status: "active", updatedAt: serverTimestamp()};
  if (firstName) patch.firstName = firstName;
  if (lastName) patch.lastName = lastName;
  if (phone) patch.phone = phone;
  const composed = [
    firstName || userData.firstName || "",
    lastName || userData.lastName || "",
  ].filter(Boolean).join(" ");
  if (composed) patch.name = composed;
  // Stamped only when the flags are actually true: a consent record for someone
  // who never saw the checkbox would be a false one.
  if (termsAccepted) patch.termsAcceptedAt = serverTimestamp();
  if (locationConsent) patch.locationConsentAt = serverTimestamp();
  return patch;
}

const completeEmployeeSetup = onCall(APP_CHECK, async (req) => {
  if (!req.auth || !req.auth.uid) {
    throw new HttpsError("unauthenticated", "auth-required");
  }
  // No mailbox check: the starting password is random per account and handed
  // over out-of-band, so signing in is itself the proof this guard provided
  // when every account was minted on a shared constant.
  assertPayloadShape(req.data, new Set([
    "firstName", "lastName", "phone", "termsAccepted", "locationConsent",
    "newPassword",
  ]));
  const hasPassword = req.data?.newPassword !== undefined;
  const newPassword = hasPassword ?
    requireString(req.data, "newPassword", 128) : "";
  if (hasPassword && (newPassword.length < 8 || !/[A-Z]/.test(newPassword) ||
      !/[a-z]/.test(newPassword) || !/[0-9]/.test(newPassword))) {
    throw new HttpsError("invalid-argument", "invalid-newPassword");
  }
  const firstName = optionalString(req.data, "firstName", 100);
  const lastName = optionalString(req.data, "lastName", 100);
  // 40 mirrors createEmployeeAccount's server cap (the client caps at
  // TextLimits.phone via PhoneInputFormatter).
  const phone = optionalString(req.data, "phone", 40);
  // `?.`, like every sibling read here: assertPayloadShape ACCEPTS a null or
  // undefined payload, so a bare call reached these two and threw a TypeError —
  // an opaque `internal` where the shaped `invalid-argument` belongs.
  const termsAccepted = req.data?.termsAccepted === true;
  const locationConsent = req.data?.locationConsent === true;
  await enforceDurableRateLimit(
      "completeEmployeeSetup", req.auth.uid, SETUP_RATE_MAX,
      SETUP_RATE_WINDOW_MS);

  const db = getFirestore();
  const uid = req.auth.uid;
  const outcome = await withAccountOperation(db, uid, "setup", async () => {
    const current = await db.collection("users")
        .where("uid", "==", uid).limit(2).get();
    if (current.empty) return {ok: false, reason: "no-account"};
    if (current.docs.length !== 1 ||
        current.docs[0].data().status !== "invited") {
      return {ok: false, reason: "not-pending"};
    }
    // Never log or persist this payload. Auth is the only password store.
    if (hasPassword) await getAuth().updateUser(uid, {password: newPassword});
    return db.runTransaction(async (tx) => {
      const found = await tx.get(
          db.collection("users").where("uid", "==", uid).limit(1),
      );
      if (found.empty) return {ok: false, reason: "no-account"};
      const doc = found.docs[0];
      const userData = doc.data();
      // Idempotent-ish by refusal: an already-active account must not have its
      // consent stamps rewritten by a replayed call.
      if (userData.status !== "invited") {
        return {ok: false, reason: "not-pending"};
      }
      if (!hasPassword && userData.setupRequiresPassword === true) {
        throw new HttpsError("failed-precondition", "setup-upgrade-required");
      }
      const patch = buildActivationPatch(
          {firstName, lastName, phone, termsAccepted, locationConsent},
          {userData, serverTimestamp: () => FieldValue.serverTimestamp()},
      );
      tx.update(doc.ref, patch);
      return {ok: true};
    });
  });

  if (!outcome.ok) {
    if (outcome.reason === "not-pending") {
      throw new HttpsError("failed-precondition", "setup-not-pending");
    }
    throw new HttpsError("not-found", "account-not-found");
  }
  // No profile echoed back: the client discards it and re-resolves the account
  // through findUserByUid to route, so building one here served nothing.
  return {ok: true};
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

module.exports = {
  generateStartingPassword,
  createEmployeeAccount,
  completeEmployeeSetup,
  deleteEmployeeAccount,
  changeEmployeeEmail,
  // Exported for unit tests of the transactional flows and the pure patch.
  provisionAuthAccount,
  resetProvisionedPassword,
  performCreateAccount,
  performDeleteAccount,
  performChangeEmail,
  resolveEmailChangeCaller,
  notifyEmailChanged,
  buildActivationPatch,
};
