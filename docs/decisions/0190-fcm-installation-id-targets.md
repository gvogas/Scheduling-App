# 0190. FCM sends target Firebase Installation IDs, one `fcmTokens` row per device

**Date:** 2026-10-21 · **Rules file:** `.claude/rules/notifications.md`

## Context
`firebase_messaging` 17.0.0 (the FlutterFire 2026-10 major, Firebase Apple SDK 13) deprecates
`getToken`/`onTokenRefresh`/`deleteToken` in favour of `register()`/`onRegistered`/`unregister()`. The
replacements do not hand back an FCM registration token: `onRegistered` emits the device's Firebase
Installation ID (FID), the new direct-send target. The Admin SDK in `functions/` (14.3.0) already
sends to one (`FidMessage {fid}`, `sendEach` accepts both shapes) and marks `TokenMessage` deprecated;
a dead FID fails `messaging/installation-id-not-registered`, not the two token codes.

Every stored target was a token: the app writes `users/{docId}/fcmTokens/{token}` and
`sendToEmployee` built `{token: doc.id}`. Swapping only the client would write FIDs the server sent as
tokens, so every push would fail and prune the row. The old calls still work in 17.0.0, so the client
stays on them (behind `// ignore: deprecated_member_use`) until the server can send to both.

## Decision
Keep one collection. A row may carry `kind`: absent or `'token'` means the doc id is an FCM token,
`'fid'` means it is an installation id. `messageTargetFor(docId, data)` (`notification_policy.js`) is
the one place that picks `{fid}` or `{token}`; `sendToEmployee` spreads it into every message, so the
admin fan-out and every sweep follow. `isStaleTokenError` also prunes on
`messaging/installation-id-not-registered`. `firestore.rules` allows an optional `kind in ['token',
'fid']` on `fcmTokens`. A separate `fcmInstallations` subcollection was rejected: account deletion,
`bridge.js`'s subcollection sweep and the rules would each need a second path.

The migration ships in three steps (`docs/plans/2026-10-21-fcm-fid-migration-plan.md`): this backend
change first (inert, since nothing writes `kind: 'fid'` yet), then an app build that registers by FID
and deletes its own legacy token row after the FID write lands, then a later backend change that retires
the token branch once no build that writes tokens remains in the fleet.

## Consequences
A device that holds both rows during the switch gets every push twice, so the app — which knows its
own legacy token — must delete that row; the server cannot link a token to a FID. Older builds keep
working throughout, because a row without `kind` is still sent as a token. Removing `kind` handling or
the `token` branch is a breaking change and needs the same fleet proof as a `#compat` retirement
(`.claude/rules/security.md`). Live Activities are unaffected: they push through APNs directly.
