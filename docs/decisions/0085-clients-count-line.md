# 0085. The clients count line states only what it can prove

**Date:** 2026-09-28 (`total` under every filter); page size owner call · **Rules file:** `.claude/rules/clients.md`

## Context
The list pages, so `onCountChanged` reports rows LOADED: it read "Showing all 500 clients" when 500 was only
scroll depth, and 50 on arrival. `total` was first passed under `ClientsFilterAll` only, so a filtered slice
showed no "of M". A 250-row first page was tried and rejected the same day.

## Decision
The header takes `total` from `clientsTotalCountProvider` (a family keyed on `ClientsFilter`; a `count()`
via `ClientsRepository.countClients` through the same `_filteredQuery` as the page) under every filter. It
renders `clients_showingSome` / `clients_showingSomeType` / `clients_inThisBuildingSome` until loaded ==
total, then the plain sentence (`clients_showingAll`), ignores `total` while searching, and a null count
renders nothing. The unfiltered count stays watched under every filter. Page size is 50 under every sort.

## Consequences
Counting by scanning the roster costs more than the list. A separate count query can disagree with the page.
The `count()` is equality-only and served by the existing composites — no new index.
