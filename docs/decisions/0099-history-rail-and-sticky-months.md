# 0099. History: left date rail, sticky month bars in groups, one count

**Date:** 2026-08-11 (P7 Phase D, `docs/archive/2026-08-11-history-restyle.md`), 2026-09-06/07 (admin-only; D3 audit) · **Rules file:** `.claude/rules/clients.md`

## Context
Both rejected layouts restyled the one shared `AppointmentCard`. Repeated pinned headers stack — a year of
history parked twelve bars at the top. A sticky header cannot live in `PagedListView`, so the view re-owns the
prefetch trigger and spinner/retry footer (now the shared `paged_sliver_driver.dart`). Wrapping `AppEmptyState` (its own `SingleChildScrollView`) in a
`RefreshIndicator`'s `CustomScrollView` left two controllerless primary scrollables under
`PrimaryScrollScope`, the Scrollbar crash. A per-month count could only report what had loaded. The memos on
`tallyOf`/`monthSectionsOf` silently re-ran on every rebuild: `PagingState.items` re-flattens per access and
filter passes build new lists, re-running per keystroke and per `employeeColorMapProvider`/`currentDayProvider` emission. History went admin-only 2026-09-06 and the view dropped its scope control.

## Decision
Each month is a `SliverMainAxisGroup` with its pinned bar; `fetchNextPage()` from a builder goes post-frame. A
text search renders flat with month (+ year if not current, from `currentDayProvider`) on the rail. One count,
`18 JOBS · 2 CANCELLED`; status vocabulary via `isCancelledStatusRaw`/`isCompletedStatusRaw`
(`appointment_status_values.dart`), never `== 'cancelled'`; chips bind to `statusLabel`; no bold year separator. `RowCache` (`row_cache.dart`) caches row lists at the source, keyed on a record.
`HistoryPager.fetchPage`'s `employeeId` and `HistorySearchKey.employeeId` stay, mirroring `historyScope`.

## Consequences
A test reads the bars actually painted, since a pushed-out bar stays in the tree. Dropping `employeeId` means
re-adding it in two places, one of them `HistorySearchKey`, a provider family key, when technician History returns.
