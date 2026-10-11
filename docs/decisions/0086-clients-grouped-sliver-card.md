# 0086. Client grouping: opt-in, one sliver card, no letter headings

**Date:** 2026-09-11 (opt-in grouping; `RowCache` for the list), 2026-09-23 (letter headings removed) · **Rules file:** `.claude/rules/clients.md`

## Context
Pages are server-ordered on the STORED name, which for a person is their bare phone number, while a letter
heading would read `displayName` — so letters over server pages split into a card per row (M · A · M…).
Re-sorting loaded pages client-side was rejected: rows jump into earlier cards as pages arrive.
`letterGroupsOf`/`clientInitialOf`/`sortClients` were deleted. `DecoratedSliver` paints behind the sliver
without clipping while a row is a square `Material` + `InkWell`, so end rows painted square ink and `secondaryContainer` selection fills over the rounded corner. The grouped
list silently went without `RowCache` until 2026-09-11. History and the list each had their own copy of the
pager driver.

## Decision
`ClientsListView(grouped:)` defaults false; only `clients_screen.dart` passes true. Every list is one card
(`singleGroupOf`, `domain/client_grouping.dart`), headed by `buildingLabel` under a building filter, rendered by `ClientsSliverList`: a
`DecoratedSliver` around a `SliverList`, with `ClientsSliverList._clipEndRows` rounding the end rows per row.
`PagedSliverPrefetch` + `PagedListFooter` (`widgets/lists/paged_sliver_driver.dart`) own the first-page
request, prefetch and spinner/retry tail, shared with `AppointmentHistoryView`.

## Consequences
Restoring letters needs a stored, display-ordered sort key. A `Column` card builds every loaded row on each
rebuild, keystrokes included. `PagingController.refresh()` only resets; without `requestFirstPage` the
skeleton shimmers forever with no request in flight.
