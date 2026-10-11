# 0083. Clients are archived, not deleted; delete is a fenced callable for junk only

**Date:** 2026-08-03 (archive), 2026-08-08 (`allow delete` withdrawn), 2026-09-23 (`deletionToken`), 2026-09-28 (token-release catch) · **Rules file:** `.claude/rules/clients.md`

## Context
2026-08-01 said "never removed — no delete, no archive"; the owner reversed it on 2026-08-03, retiring the
`kShowTestingDeleteClient` `#pre-ship` hole (`lib/core/testing_flags.dart` deleted). Deleting a client
orphaned its past visits: they keep the denormalized `clientName` but lose the `clientId` link, so history
silently detached. Firestore excludes docs missing a filtered field, so a doc without `archived` is invisible
in the list yet still found by search; one turned up 2026-09-10 (deploy log). `allow delete` on `/clients`
had survived as a `#compat-1.37.1` shim for that build's ungated Delete button; while it did, an admin on the
old build could orphan a client's history. A job booked between the callable's count and its delete was
orphaned until the 2026-09-23 `deletionToken` fence. Until 2026-09-28 a failed token release could mask the
real refusal. The "never inside `ClientTile`" rule was once justified by the booking picker reusing the tile;
it has not since recents were removed (`ClientPicker` builds `AttachedDropdownRow`s in an `AttachedDropdown`;
`ClientTile`'s one caller is `ClientsListView._slidableTile`, verified 2026-09-11).

## Decision
Archive hides a client from the paged list and type filter and keeps it searchable and bookable. `archived`
is stamped on both create paths (`_normalizedMap` via `ClientRecord.toMap`, Wave `importCustomers`), never
by the Wave update branch; `syncClientBuilding` stamps a boolean on any write lacking one (since 2026-09-23);
`backfill-clients-archived.js` (idempotent, `--dry-run`, `--verbose`) ran before the filtered query deployed.
Delete exists only in the `deleteClient` callable: a live `count()` gate, a `deletionToken` fence
(`canLinkClient` in rules), and a cleanup in its own try/catch that logs and rethrows the original error.
No rules delete grant.

## Consequences
A Dart post-query archive filter truncates the list at the first archived client. Gating delete on
`jobCount` trusts a lazy, possibly stale count. Clearing another attempt's token reopens the race.
Admin-SDK console cleanup is unaffected by rules.
