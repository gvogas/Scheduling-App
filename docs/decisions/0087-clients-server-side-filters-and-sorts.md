# 0087. Every client list filter is a server `where`; nullable sort fields need a backfill

**Date:** 2026-09-23 (reversed the in-memory filter window) · **Rules file:** `.claude/rules/clients.md`

## Context
The type/building/Archived filters read a bounded in-memory window. A Dart post-query filter shortens a page
the server filled, so `pages.last.length < pageSize` (and `items.last` as cursor, which needs a plain `List` page) ends the list at the first non-matching client.
Firestore `orderBy` drops docs lacking the field, so a client never stamped with `jobCount`, or a
pre-`createdAt` import, vanished from Most jobs / Recently added while showing under Name — the same posture
`searchTokens` took. A boundary cached under `name` would resume a `jobCount` query from a string.

## Decision
`fetchClientsPage(filter:)` builds one query: `archived == (filter is Archived)`, plus `type ==` or
`buildingKey ==`, the sort's `orderBy`, and `__name__`; each filter × sort has its composite
(`(archived, type|buildingKey, <sort field>, __name__)`), and a search within a filter sends the same keys to
`searchClients`. `backfill-client-sort-fields.js` is a release prerequisite and stamps a FIXED pre-app date,
not `serverTimestamp()`. The cursor tuple follows the sort; the boundary cache is keyed `"<sort>:<docId>"`.

## Consequences
"Archived AND commercial" is unexpressible by design. A doc with a non-boolean `archived` or a padded `type`
is invisible until `syncClientBuilding` or `backfill-client-buildings.js` normalizes it. A cache patch
that substitutes `toMap()` instead of merging drops `jobCount`/`createdAt` until the TTL expires.
