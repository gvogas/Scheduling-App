# 0109. Live map: staleness is text, a pin never dims or expires

**Date:** 2026-07-19 (dimming removed), 2026-09-13 (team sheet), 2026-09-14 (age cutoff removed) · **Rules file:** `.claude/rules/notifications.md`

## Context
The marker-dimming path (`staleDocIdsProvider`) was removed 2026-07-19. A 2 h `presenceHiddenAfter`
cutoff added 2026-09-13 was removed 2026-09-14 by owner call; the sharing gate is its backstop (see
`employees.md`). The team sheet (`live_map_team_sheet.dart`, a `DraggableScrollableSheet` resting at
48 %) replaced the roster FAB and floating info card.

## Decision
Admins read all presence through the collection-group rule `match /{path=**}/presence/{presenceId}`
(read if `isAdmin()`; the wildcard reserves the subcollection name `presence`), joined to
`watchAllUsers()`. Staleness shows only in labels (`LiveMapAggregator.isStale`/`freshnessOf`,
`live_map_labels.dart`); `StaffMarkerIconRenderer` has no `stale` param. `liveMapTeamProvider` watches the
30 s tick only so labels age. The sheet groups ON THE MAP / NOT SEEN YET / LOCATION SHARING OFF via the
pure `LiveMapAggregator.groupTeam`, excluding test accounts; `sortedByProximity`/`distanceMeters`/
`cityFromAddress` stay pure so they test without plugins; the self row leads, the rest nearest-first. `presenceStaleAfter` (25 min) mirrors
`PRESENCE_STALE_MINUTES`. `syncUsersByUid` (`functions/bridge.js`) purges presence when a user doc is
deleted or leaves `active`, AFTER the auth-critical bridge write, isolated.

## Consequences
Don't reintroduce pin greying or an age cutoff.
