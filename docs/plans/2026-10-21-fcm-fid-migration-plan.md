# FCM token → Firebase Installation ID migration

**Status (2026-10-21): step 1 BUILT, not deployed; steps 2 and 3 not started.** Decision: ADR-0190.

`firebase_messaging` 17 deprecates `getToken`/`onTokenRefresh`/`deleteToken`. Their replacements
(`register()`/`onRegistered`/`unregister()`) yield a Firebase Installation ID (FID), not an FCM token,
so the app and the push sender move together. The deprecated calls still work in 17.0.0; nothing here
is urgent until a FlutterFire release removes them.

## Step 1 — backend (BUILT 2026-10-21, ships with the next `Deploy backend`)

- `functions/notification_policy.js`: `messageTargetFor(docId, data)` returns `{fid}` for a
  `kind: 'fid'` row, `{token}` otherwise; `isStaleTokenError` adds
  `messaging/installation-id-not-registered`.
- `functions/notification_utils.js`: `sendToEmployee` builds each message from `messageTargetFor`.
- `firestore.rules`: `fcmTokens` accepts an optional `kind in ['token', 'fid']`.
- Tests: jest (`notification_utils.test.js`: target picker, mixed token + FID batch, FID pruning) and
  the emulator check (`appointment_edits_checks.js`: `fid`/`token` allowed, unknown kind refused).

Inert on its own: no row carries `kind: 'fid'` until step 2. Safe to deploy at any time.

## Step 2 — app (one build after step 1 is live)

1. `PushNotificationService`: `register()` + `onRegistered` replace `getToken` + `onTokenRefresh`;
   `unregister()` replaces `deleteToken`. Drop the three `// ignore: deprecated_member_use` lines.
2. `PushRegistrationController`: on every `onRegistered`, write `fcmTokens/{fid}` with `kind: 'fid'`
   (same `platform`/`locale`/`uid`/`sessionEpoch` fields). On teardown, `unregister()` and delete the
   FID row, still before `signOut()` (the delete needs the credential).
3. No double pushes: after the FID write succeeds, delete the device's legacy token row. The
   controller already knows that token (it deletes it on teardown); a phone upgrading from 1.66 holds
   one. Delete it only after the FID row lands, so the device is never unreachable.
4. Tests: the FID row carries `kind: 'fid'`; the legacy row goes only after the FID write; teardown
   unregisters and deletes before sign-out; a failed FID write keeps the legacy row.
5. Device check: on iOS, confirm `onRegistered` fires (expected after APNs registration, like
   `getToken` today). Sign in on the new build, see only a `kind: 'fid'` row under the user, and
   receive one job-assignment push exactly once.

## Step 3 — retire the token path (after the whole fleet runs a step-2 build)

Same proof as a `#compat` retirement (`.claude/rules/security.md`): no build that writes tokens may
remain. Then, as its own backend change:

- `messageTargetFor` always returns `{fid}`; drop the two token stale codes.
- `firestore.rules`: require `kind == 'fid'`.
- A one-off `functions/scripts/` script (through `run.js`, dry run first) deletes leftover rows without
  `kind: 'fid'`.
