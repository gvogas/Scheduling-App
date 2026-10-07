# 0037. Crashlytics severity is classified in two places

**Date:** by 2026-08-14 (rule first committed) · **Rules file:** `.claude/rules/error-handling.md`

## Context
Filing routine outcomes as error records buries the real ones. The auth catch sites double-filed the
same failure from two layers before `logger.authFailure` (`AuthFailureLogging`) existed. The rule's
site list once said "the four sites" and named `create_account_screen` (deleted by P4c) and
`settings_screen`, where the delete-account branch has never been — it lives in
`settings/widgets/views/delete_account_flow.dart`, and it was the one branch with no log at all.

An unhandled Firestore `permission-denied` was filed as a fatal crash, but it is the signature of auth
teardown racing a live listener: revoking the token (sign-out, account deletion, the since-retired signup-code rollback)
denies any snapshot stream still attached, and the app keeps running.

## Decision
`AuthFailure.isExpected` buckets every variant (a new variant must pick one at compile time) and every
auth catch site logs through `logger.authFailure`. `isFatalUnhandledError`
(`core/logging/unhandled_error_severity.dart`) gates `fatal:` on `PlatformDispatcher.onError` and
`runZonedGuarded`; `FlutterError.onError` stays unconditionally fatal.

## Consequences
The denied stream is still recorded and its owner logs a tagged `warn`, so a genuine rules rejection
surfaces twice. Don't re-decide severity at a call site.
