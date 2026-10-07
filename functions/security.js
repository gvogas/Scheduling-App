const crypto = require("node:crypto");
const {HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");

const SESSION_TOKEN_MAX_LEN = 64;

// Firestore's own document-id ceiling as the rules state it — hand-mirrored
// from `isValidDocIdField` in firestore.rules.
const DOC_ID_MAX_LEN = 128;

// Hard cap on a callable payload once serialized.
const MAX_PAYLOAD_BYTES = 4 * 1024;

/**
 * Stable, short log token for identifiers that should not be emitted raw.
 * @param {string} value identifier to hash.
 * @return {string}
 */
function shortHash(value) {
  // Coerced, not assumed: every caller here is a LOGGING site, and
  // `createHash().update()` throws on a non-string — a guard whose log line
  // throws turns its intended `permission-denied` into an opaque `internal`.
  return crypto.createHash("sha256").update(String(value == null ? "" : value))
      .digest("hex").slice(0, 12);
}

/**
 * True if the string contains a C0 control character or DEL.
 * @param {string} s value to inspect.
 * @return {boolean}
 */
function hasControlChar(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x20 || c === 0x7F) return true;
  }
  return false;
}

/**
 * Throws HttpsError("invalid-argument") when `data` isn't a plain object, is
 * oversized once serialized, or carries a key outside `allowedKeys` — this is
 * our mass-assignment defence.
 * @param {*} data raw callable request data.
 * @param {!Set<string>} allowedKeys the only keys this endpoint accepts.
 */
function assertPayloadShape(data, allowedKeys) {
  if (data === undefined || data === null) return;
  if (typeof data !== "object" || Array.isArray(data)) {
    throw new HttpsError("invalid-argument", "malformed-payload");
  }
  let serialized;
  try {
    serialized = JSON.stringify(data);
  } catch {
    throw new HttpsError("invalid-argument", "malformed-payload");
  }
  // BYTES, not `.length`: that counts UTF-16 code units, so 4096 emoji or CJK
  // characters serialize to ~12-16 KB and passed a cap whose constant and error
  // code both say bytes.
  if (Buffer.byteLength(serialized, "utf8") > MAX_PAYLOAD_BYTES) {
    throw new HttpsError("invalid-argument", "payload-too-large");
  }
  for (const key of Object.keys(data)) {
    if (!allowedKeys.has(key)) {
      throw new HttpsError("invalid-argument", "unexpected-field");
    }
  }
}

/**
 * Validates and returns a trimmed string field, throwing
 * HttpsError("invalid-argument") when missing, wrong type, out of range, or
 * containing control characters.
 * @param {object} data callable request data.
 * @param {string} key field name.
 * @param {number} maxLen max length (inclusive).
 * @return {string}
 */
function requireString(data, key, maxLen) {
  const value = typeof data?.[key] === "string" ? data[key].trim() : "";
  if (!value || value.length > maxLen || hasControlChar(value)) {
    throw new HttpsError("invalid-argument", `invalid-${key}`);
  }
  return value;
}

/**
 * Validates and returns a Firestore document id: a required string of at most
 * `DOC_ID_MAX_LEN` characters that carries no "/".
 * @param {object} data callable request data.
 * @param {string} key field name.
 * @return {string}
 */
function requireDocId(data, key) {
  const value = requireString(data, key, DOC_ID_MAX_LEN);
  if (value.includes("/")) {
    throw new HttpsError("invalid-argument", `invalid-${key}`);
  }
  return value;
}

/**
 * Same as requireString but allows the field to be absent or empty — the length
 * cap and the control-char reject still apply to whatever is there.
 * @param {object} data callable request data.
 * @param {string} key field name.
 * @param {number} maxLen max length (inclusive).
 * @return {string} the trimmed value, or "" when absent.
 */
function optionalString(data, key, maxLen) {
  const value = typeof data?.[key] === "string" ? data[key].trim() : "";
  if (value.length > maxLen || hasControlChar(value)) {
    throw new HttpsError("invalid-argument", `invalid-${key}`);
  }
  return value;
}

/**
 * Validates and returns a finite number within [min, max], throwing
 * HttpsError("invalid-argument") when missing, non-numeric, non-finite, or out
 * of range.
 * @param {*} value raw payload value.
 * @param {string} name field name, used to build the error code.
 * @param {number} min minimum allowed value (inclusive).
 * @param {number} max maximum allowed value (inclusive).
 * @return {number}
 */
function requireNumberInRange(value, name, min, max) {
  if (typeof value !== "number" || !Number.isFinite(value) ||
      value < min || value > max) {
    throw new HttpsError("invalid-argument", `invalid-${name}`);
  }
  return value;
}

/**
 * Reads an optional sessionToken, returning "" if absent and throwing
 * HttpsError("invalid-argument") if present but malformed.
 * @param {object} data callable request data.
 * @return {string}
 */
function readSessionToken(data) {
  if (data?.sessionToken === undefined || data?.sessionToken === null) {
    return "";
  }
  if (typeof data.sessionToken !== "string" ||
      data.sessionToken.length > SESSION_TOKEN_MAX_LEN ||
      hasControlChar(data.sessionToken)) {
    throw new HttpsError("invalid-argument", "invalid-sessionToken");
  }
  return data.sessionToken;
}

/**
 * A sliding-window rate limit backed by Firestore, so it survives across
 * function instances and cold starts (unlike the in-memory limiter).
 * @param {string} route stable endpoint identifier (part of the doc key).
 * @param {string} key per-caller limiter key — usually the Auth uid, but any
 * stable per-caller identifier a route needs (see `keyKind`).
 * @param {number} max max attempts per window.
 * @param {number} windowMs window length in milliseconds.
 * @param {string} [keyKind] label for `key` ("uid" | "email"), purely for log
 * discrimination; email keys are PII, so only a hash is logged.
 * @return {!Promise<{refund: function(): !Promise<void>}>} A handle whose
 * `refund()` undoes the recorded attempt on a best-effort basis, so a
 * server-side failure (not the caller's fault) doesn't burn one of their
 * limited attempts. Existing callers that ignore the return value are
 * unaffected.
 */
async function enforceDurableRateLimit(route, key, max, windowMs,
    keyKind = "uid") {
  const db = getFirestore();
  const ref = db.collection("rateLimits").doc(`${route}__${key}`);
  const now = Date.now();
  let overLimit = false;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : null;
    const prior = data && Array.isArray(data.attempts) ? data.attempts : [];
    // We track per-attempt timestamps instead of a single windowStart counter —
    // a counter would let a caller burst 2×max across the boundary.
    const recent = prior.filter(
        (t) => typeof t === "number" && now - t < windowMs,
    );
    if (recent.length >= max) {
      // Rejected attempts are not recorded — otherwise a hammering caller would
      // hold the window full forever.
      overLimit = true;
      return;
    }
    recent.push(now);
    tx.set(ref, {
      route,
      attempts: recent,
      // Lets an optional Firestore TTL policy on `expiresAt` reap old rows.
      expiresAt: new Date(now + windowMs),
    });
  });
  if (overLimit) {
    // Never log the raw key — it's PII for the email-keyed route.
    logger.warn("enforceDurableRateLimit: limit exceeded", {
      route,
      keyKind,
      keyHash: shortHash(key),
    });
    throw new HttpsError("resource-exhausted", "too-many-attempts");
  }

  // Best-effort refund of the recorded attempt.
  const refund = async () => {
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const data = snap.exists ? snap.data() : null;
        const prior = data && Array.isArray(data.attempts) ?
          data.attempts : [];
        const idx = prior.indexOf(now);
        if (idx === -1) return;
        const next = prior.slice(0, idx).concat(prior.slice(idx + 1));
        tx.set(ref, {route, attempts: next}, {merge: true});
      });
    } catch (err) {
      logger.warn("enforceDurableRateLimit: refund failed", {
        route,
        err: err.message,
      });
    }
  };
  return {refund};
}

/**
 * The whole opening of an ADMIN-ONLY callable: signed in, actually an admin,
 * and a payload of exactly [allowedKeys].
 * @param {!Object} req The callable request.
 * @param {!Set<string>} allowedKeys The only keys this endpoint accepts.
 * @return {!Promise<string>} The caller's uid, which every site needs next for
 * its rate limiter.
 */
async function assertAdminCall(req, allowedKeys) {
  if (!req.auth || !req.auth.uid) {
    throw new HttpsError("unauthenticated", "auth-required");
  }
  await assertAdmin(req.auth.uid);
  assertPayloadShape(req.data, allowedKeys);
  return req.auth.uid;
}

/**
 * The self-service twin of `assertAdminCall`: auth -> payload shape -> the
 * `usersByUid/{uid}` bridge row, refusing anyone whose account is not active.
 *
 * Composed for the same reason the admin one is — a guard nobody has looked at
 * is the one that silently loses a clause. Returns the caller's profile,
 * because every site needs `role`/`docId` next to scope what it may reach.
 * @param {!Object} req The callable request.
 * @param {!Set<string>} allowedKeys The only keys this endpoint accepts.
 * @return {!Promise<!Object>}
 */
async function assertActiveCall(req, allowedKeys) {
  if (!req.auth || !req.auth.uid) {
    throw new HttpsError("unauthenticated", "auth-required");
  }
  assertPayloadShape(req.data, allowedKeys);
  const snap = await getFirestore()
      .collection("usersByUid").doc(req.auth.uid).get();
  const data = snap.exists ? snap.data() : null;
  if (!data || data.status !== "active") {
    logger.warn("assertActiveCall: caller is not active", {
      uidHash: shortHash(req.auth.uid),
      status: data ? data.status : null,
    });
    throw new HttpsError("permission-denied", "inactive-user");
  }
  return {...data, uid: req.auth.uid};
}

/**
 * Throws HttpsError("permission-denied", "wave/not-admin") unless the
 * `usersByUid/{uid}` bridge (kept in sync by syncUsersByUid) shows an active
 * admin.
 * @param {string} uid Firebase Auth uid of the caller.
 * @return {!Promise<void>}
 */
async function assertAdmin(uid) {
  const db = getFirestore();
  const snap = await db.collection("usersByUid").doc(uid).get();
  const data = snap.exists ? snap.data() : null;
  if (!data || data.role !== "admin" || data.status !== "active") {
    logger.warn("assertAdmin: caller is not an active admin", {
      uidHash: shortHash(uid),
      role: data ? data.role : null,
      status: data ? data.status : null,
    });
    throw new HttpsError("permission-denied", "wave/not-admin");
  }
}

// Re-auth window: deleteAccount, changeEmployeeEmail, resetEmployeePassword.
const REAUTH_MAX_AGE_SECONDS = 5 * 60;

/**
 * True when the caller's re-authentication is missing or too old to permit an
 * irreversible or identity-rewriting action.
 * @param {*} authTime ID-token `auth_time` (epoch seconds) or undefined.
 * @param {number} nowSec Current time in epoch seconds.
 * @param {number} maxAgeSeconds Allowed staleness window in seconds.
 * @return {boolean}
 */
function isReauthStale(authTime, nowSec, maxAgeSeconds) {
  return typeof authTime !== "number" ||
      nowSec - authTime > maxAgeSeconds;
}

/**
 * Rejects a caller whose re-authentication is older than [maxAgeSeconds].
 * @param {!Object} auth The callable's `req.auth`.
 * @param {string} route Callable name, for the log line.
 * @param {number} maxAgeSeconds Allowed staleness window in seconds.
 * @return {void}
 */
function assertFreshReauth(auth, route, maxAgeSeconds) {
  const authTime = auth && auth.token ? auth.token.auth_time : undefined;
  const nowSec = Math.floor(Date.now() / 1000);
  if (isReauthStale(authTime, nowSec, maxAgeSeconds)) {
    logger.warn(`${route}: stale auth_time; reauth required`, {
      uidHash: auth ? shortHash(auth.uid) : null,
      authTime,
      ageSec: typeof authTime === "number" ? nowSec - authTime : null,
    });
    throw new HttpsError("unauthenticated", "stale-auth");
  }
}

// The App Check option block every callable spreads.
const APP_CHECK = {enforceAppCheck: true};

// Keep guards inline per callable — a shared helper here would close over the
// real assertAdmin and break the guard-order mocks in
// __tests__/places_admin_gate.test.js.

module.exports = {
  APP_CHECK,
  shortHash,
  hasControlChar,
  assertPayloadShape,
  requireString,
  requireDocId,
  optionalString,
  requireNumberInRange,
  readSessionToken,
  enforceDurableRateLimit,
  assertAdmin,
  assertAdminCall,
  assertActiveCall,
  REAUTH_MAX_AGE_SECONDS,
  isReauthStale,
  assertFreshReauth,
};
