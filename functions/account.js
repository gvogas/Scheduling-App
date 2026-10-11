const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getAuth} = require("firebase-admin/auth");
const {getFirestore} = require("firebase-admin/firestore");

const {
  APP_CHECK,
  assertPayloadShape,
  enforceDurableRateLimit,
  assertFreshReauth,
  REAUTH_MAX_AGE_SECONDS,
} = require("./security");
const {runAccountDeletion} = require("./account_policy");

// deleteAccount is capped at AUTH_RATE_MAX attempts per AUTH_RATE_WINDOW_MS,
// enforced in Firestore (not in-memory) so the cap holds across instances
// and cold starts.
const AUTH_RATE_MAX = 5;
const AUTH_RATE_WINDOW_MS = 15 * 60 * 1000;

// ----- deleteAccount callable ------------------------------------------------
//
// Satisfies the in-app deletion requirement from Apple App Store Guideline
// 5.1.1(v) and the Google Play Account Deletion policy. The client
// re-authenticates first, and the server also re-checks auth_time against
// REAUTH_MAX_AGE_SECONDS.
//
// Deletion is intentionally narrow — it only removes the caller's
// `users/{docId}` doc (which cascades to `usersByUid/{uid}` via
// syncUsersByUid) and the Firebase Auth user. Shared business data
// (appointments, clients, images) is left untouched.
const deleteAccount = onCall(
    APP_CHECK,
    async (req) => {
      if (!req.auth || !req.auth.uid) {
        throw new HttpsError("unauthenticated", "auth-required");
      }
      assertPayloadShape(req.data, new Set());
      // Checked before the rate limiter so a stale-auth rejection doesn't
      // burn one of the caller's deletion slots.
      //
      // Through the shared `assertFreshReauth`, not a local copy: this was the
      // helper's whole body hand-inlined — same `isReauthStale` call, same
      // warn fields, same `stale-auth` code — which is the two-owner shape
      // this codebase kills everywhere else (`displayStatusAt`, `_who`,
      // `hasWorkLeft`). The `stale-auth` string in particular is a contract:
      // the Flutter client branches on it.
      assertFreshReauth(req.auth, "deleteAccount", REAUTH_MAX_AGE_SECONDS);
      const limiter = await enforceDurableRateLimit(
          "deleteAccount",
          req.auth.uid,
          AUTH_RATE_MAX,
          AUTH_RATE_WINDOW_MS,
      );
      // The ordering rules live in account_policy.js so they can be tested
      // with injected doubles — this callable owns only the guards above.
      const {deleted} = await runAccountDeletion(
          {
            db: getFirestore(),
            auth: getAuth(),
            logger,
            limiter,
            onAuthFailure: () =>
              new HttpsError("internal", "delete-auth-user-failed"),
          },
          req.auth.uid,
      );
      return {deleted};
    },
);

module.exports = {deleteAccount};
