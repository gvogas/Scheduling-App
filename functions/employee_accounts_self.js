const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getMessaging} = require("firebase-admin/messaging");
const {withAccountOperation} = require("./account_operation");
const {
  assertPayloadShape,
  requireString,
  requireDocId,
  optionalString,
  assertActiveCall,
  enforceDurableRateLimit,
  assertFreshReauth,
  REAUTH_MAX_AGE_SECONDS,
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

// Setup runs once per person; a handful of retries covers a fumbled password.
const SETUP_RATE_MAX = 5;
const SETUP_RATE_WINDOW_MS = 15 * 60 * 1000;

// changeEmployeeEmail rewrites a SIGN-IN IDENTITY, which is the
// account-takeover primitive an unattended unlocked phone offers — so it is
// budgeted far tighter than account creation, and it demands a fresh re-auth
// the same way deleteAccount does.
const EMAIL_CHANGE_RATE_MAX = 5;
const EMAIL_CHANGE_RATE_WINDOW_MS = 60 * 60 * 1000;

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
        req.auth, "changeEmployeeEmail", REAUTH_MAX_AGE_SECONDS);
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

/**
 * Mirrors the app's PasswordRequirement, Unicode letters included.
 * @param {string} password The trimmed candidate.
 * @return {boolean} True for 8+ chars with an upper, a lower and a digit.
 */
function isStrongPassword(password) {
  return password.length >= 8 && /\p{Lu}/u.test(password) &&
    /\p{Ll}/u.test(password) && /[0-9]/.test(password);
}

// Admin-SDK codes for a password Auth refuses; neither is an HttpsError.
const REFUSED_PASSWORD_CODES = new Set([
  "auth/password-does-not-meet-requirements",
  "auth/invalid-password",
]);

/**
 * Sets a caller-chosen password, surfacing an Auth policy refusal as weak.
 * @param {!Object} auth Admin Auth instance.
 * @param {string} uid the caller's Auth uid.
 * @param {string} password the validated new password.
 * @return {!Promise<void>}
 */
async function setSetupPassword(auth, uid, password) {
  try {
    await auth.updateUser(uid, {password});
  } catch (e) {
    if (e && REFUSED_PASSWORD_CODES.has(e.code)) {
      throw new HttpsError("invalid-argument", "invalid-newPassword");
    }
    throw e;
  }
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
  const newPassword = requireString(req.data, "newPassword", 128);
  if (!isStrongPassword(newPassword)) {
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
    await setSetupPassword(getAuth(), uid, newPassword);
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
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(found.docs[0].ref);
      const live = (snap.exists && snap.data()) || {};
      if (live.status !== "active" || live.uid !== uid) {
        throw new HttpsError("failed-precondition", "not-required");
      }
      tx.update(snap.ref, {
        passwordResetRequired: false,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  });
  return {ok: true};
});

module.exports = {
  completeEmployeeSetup,
  changeEmployeeEmail,
  completePasswordReset,
  // Exported for unit tests of the transactional flows and the pure patch.
  performChangeEmail,
  resolveEmailChangeCaller,
  notifyEmailChanged,
  buildActivationPatch,
  isStrongPassword,
};
