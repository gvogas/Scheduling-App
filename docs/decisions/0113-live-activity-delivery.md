# 0113. Live Activities: direct APNs, best-effort, server-owned lifecycle

**Date:** 2026-07-19 (built), 2026-07-20 (deployed, card start verified on device), 2026-07-21 (terminal end) · **Rules file:** `.claude/rules/notifications.md`

## Context
FCM cannot send Live Activity pushes (they need `apns-push-type: liveactivity` on topic
`net.vogas.scheduling.push-type.liveactivity`), so `apns_client.js` is the one direct APNs HTTP/2 client
(ES256 provider JWT re-minted at 50 min; secrets `APNS_AUTH_KEY`/`APNS_KEY_ID`/`APNS_TEAM_ID`). A
`flutter run` build ships `aps-environment: development`, so its push-to-start token is a SANDBOX token the
production host rejects with `BadDeviceToken`. A push-started activity's id is minted by ActivityKit and
its attributes can't be read back, so the device cannot stamp `appointmentId` on its token row. The
first terminal end (`endCardOnCompletion`) handled only done and rode the notification diff, which on
2026-07-21 was gated by `notPast` (suppressing events once a job had STARTED, exactly when a live card
exists), so a deleted or cancelled started job's card stayed on the Lock Screen. The diff's gate is now
`hasWorkLeft`, which is true for a started job but false after the scheduled end, while the card is still
counting up the overrun, so riding the diff would still miss that window. Dynamic Island is unverified (the test
device, a base iPhone 14, has none).

## Decision
`sendLiveActivityPush` tries production, then sandbox only on `BadDeviceToken` (a delivered production
push is never re-sent). Every path is additive: no token, no secrets, iOS < 17.2, Live Activities off, or
any APNs failure degrades to the unchanged `leaveNow` push. The start hangs off `deliverRecipientOnce`'s
return value (`kind === 'leaveNow' && delivered > 0`, single-day jobs only), inheriting its exactly-once
claim. `liveActivityCards/{employeeDocId}` (Admin-SDK-only) owns the card-to-job association. The
travel-to-on-site flip is clock-derived on both sides; no `markInProgress` write exists. `runOnSiteFlipPass`
runs on every sweep (a started job is no longer a candidate), and for a deleted/terminal job calls
`endLiveActivity`, then `clearCardMarker` (the end returns before clearing when no token rows remain).
The client never ends a card off its own status write: `endAllActivities()` is device-wide, so completing
job B would kill job A's card.
`endCardOnTerminal` ends the card on done, cancelled, deleted and unassigned, unconditional on start time.
The ActivityAttributes type is exactly `LiveActivitiesAppAttributes` (renamed from `JobActivityAttributes`)
in the widget struct, `ActivityConfiguration(for:)` and `ATTRIBUTES_TYPE`; its Swift file is in the
ScheduleWidget target only, because the `live_activities` plugin (linked into Runner) drives
`pushToStartTokenUpdates` against its own copy of the type. The `WidgetBundle` `@main` hosts
`JobLiveActivity`; the app floor is iOS 18.0 (the Directions button's `OpenURLIntent`), while every Live
Activity path stays `@available(iOS 17.2, *)`.

## Consequences
Removing the sandbox fallback breaks every dev-signed build. Resolving a card by employee alone lets a
cancel on next week's job kill today's card. A client end off its own status write is wrong:
`endAllActivities()` is device-wide. Renaming the attributes type fails every push silently. Mac runbook:
`ios/ScheduleWidget/LIVE_ACTIVITY_README.md`.
