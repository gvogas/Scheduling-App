# 0101. The app never prompts for notification permission on its own

**Date:** 2026-09-04 · **Rules file:** `.claude/rules/notifications.md`

## Context
Push registration ran on every sign-in and every account-doc emission, and it asked for permission. iOS
shows that prompt ONCE, ever, so a background `sync()` could spend it at a moment the user had no idea
what was being asked.

## Decision
`PushRegistrationController` reads `service.authorizationStatus()` and registers only when already
granted. `requestPermission()` has exactly one caller: the Settings Notifications row the user taps.
That row reads `notificationAuthStatusProvider` without prompting; `notDetermined` shows the OS prompt,
any other state opens system Settings (iOS never re-shows the dialog). After the tap, and on lifecycle
`resumed`, it invalidates the status provider and re-runs `PushRegistrationController.sync()`, so a
just-enabled device stores its token.

## Consequences
iOS reports `notDetermined` until something asks, so a fresh install registers no FCM token and receives
NOTHING (assignment, travel reminder, digest, Live Activity) until someone taps that row. Accepted. If the
gap is ever closed, close it with an explicit in-context step the person can read (as the location ask
page does, ADR-0110), never by moving the request back onto `sync()`.
