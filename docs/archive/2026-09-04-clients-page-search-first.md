# Clients page — "Search first"

**Date:** 2026-09-04
**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** Design approved,
build authorized by the owner 2026-09-05 and **implemented the same day** —
commits `767ec99e` + `b2adc705`, released in 1.58.0+87. The deploy gate this
banner carried is **CLOSED**: both new `clients` composites reached `READY` and
`backfill-client-sort-fields.js` ran live against prod on 2026-09-06
(720 scanned / 658 patched) — see the three 2026-09-06 rows in the deploy log
in `docs/DEPLOYMENT.md`, which is the only authority on what production runs.
This doc owes nothing further; shipping the app build that carries the UI is
tracked in `docs/plans/README.md`, not here.
**Implementation plan:** `docs/plans/2026-09-04-clients-page-search-first-implementation.md`
— read its three findings (nullable sort fields, the name-bound paging cursor,
and the missing third client type) before starting; each changes what a task
has to do.
**Mockup:** https://claude.ai/code/artifact/baeb4b51-f338-4fc1-840e-4c0fd0ac4724
(five states: at rest, filter sheet, filtered, searching, nothing found)
**Supersedes:** `docs/archive/2026-08-29-clients-address-filter.md` — the address
chip-menu it specifies is deleted by this direction, and the in-panel search
field it deferred is never built.

## Why

Six problems, found by reading the screen against what it now does:

1. **~14× read amplification on tab open.** `ClientsListView.build` watches
   `clientBuildingsProvider` and `clientBuildingKeysProvider` before the filter
   switch, so opening the tab pays the paged `orderBy('name')` scan window
   (`_clientScanLimit`, ~700 clients today) on top of the paginated first 50 —
   purely to know which addresses are shared. Already documented at
   `clients_providers.dart:78`; this is the expensive one.
2. **The filter row scrolls.** Five controls in a 48 px horizontal scroller, so
   at large text scale something is always off-screen on arrival.
3. **The search hint under-sells search.** It reads "name or phone"
   (`clients_searchByNameOrPhone`) while `ClientSearchPolicy.rawTexts` matches
   name, business name, first/last, email, address, city, province, postal
   code, country and contact names — plus phones through `rawPhones`.
4. **Four signals per row.** Archived pill, type chip, Building pill and the
   job count all compete under one name.
5. **Address is a menu wearing a chip.** Same pill as its neighbours, but it
   opens rather than toggles.
6. **No order but alphabetical.** No way to reach the busiest clients or the
   ones added recently.

Options B ("buildings as a view", grouped list on a server-side aggregate) and
C ("flatten in place", segmented control + calmer row, scan untouched) were
drawn and rejected in the same artifact. B is the better end state but needs a
function, a backfill and an index; C is cheap but leaves problem 1 on the table.

## The decision

Delete the chip row. One search field, one Filter button, one sheet.

| Element | Decision |
|---|---|
| Search field | Hint names what it matches: "Name, phone, address, email…". New ARB key both languages; `clients_searchByNameOrPhone` retired |
| Filter button | Pinned FIRST and OUTSIDE the scroller, so it can never scroll off. Carries a dot when a filter is active |
| Active filter | Returns as ONE dismissible chip beside the button, so what is on is visible without reopening the sheet |
| Filter sheet | Two labelled sections — Type (All / Residential / Commercial / Archived) and Shared address — as ONE radio group |
| List header | Count on the left, sort on the right, one line |
| Sort | Name / Most jobs / Recently added |
| Row | Avatar, name, address-or-phone, job count. Archived pill kept; type chip and Building pill removed |
| FAB | Unchanged |

### Answers to the four open questions (owner, 2026-09-04 — "defaults are fine")

1. **Filters stay SINGLE-SELECT.** `ClientsFilter` remains a sealed one-of, so
   picking a type still clears the address and vice versa. This is today's
   behaviour and it is deliberate here: combinable filters would change the
   sealed model, change how the type and address queries compose, and require
   the `firestore.rules` read clauses to admit archived-plus-a-type. The sheet
   therefore renders as one radio group across two labelled sections. **Expect
   this to read as a bug in review** — it is the constraint the chip row hid,
   now visible. If it turns out to be intolerable on device, that is the moment
   to reopen multi-select, not before.
2. **Losing the Building pill is ACCEPTED.** It is the price of fixing problem
   1 — a row cannot show a shared-address count that the scan no longer feeds.
   The count moves to the client detail sheet, where it is a single document
   read. If a shared address ever has to be visible in the LIST again, this
   direction needs option B's server-side aggregate and the scan returns until
   that ships.
3. **Sort ships WITH this change**, not separately.
4. **The sheet shows counts** next to each type and address. They come from the
   same scan the sheet already pays for, so they are free once it is open.

### The read-amplification fix, precisely

`clientBuildingsProvider` / `clientBuildingKeysProvider` stop being watched by
`ClientsListView` and are watched by the filter sheet instead. Tab open then
costs the paginated first page and nothing else. The sheet shows a skeleton in
its "Shared address" section while the scan resolves (state 02 in the mockup) —
the sheet opens immediately rather than waiting.

This does NOT remove the scan; it moves it off the path everyone walks onto one
almost nobody opens. Removing it for real is still the server-maintained
`buildings` aggregate described at `clients_providers.dart:78`, and that stays
unbuilt.

## Not in scope

The `buildings` server aggregate; grouping the list by building; combinable
filters; any change to `searchClients` or the token index; the client detail
sheet beyond receiving the shared-address count.

## Before building

- Confirm "Most jobs" has an index, or add one — sorting by `jobCount` is a new
  query shape.
- `clients_searchByNameOrPhone` is retired, so check for other callers first;
  the booking-flow client picker reuses `ClientsListView`.
- The picker reuse matters throughout: `ClientsListView` is also the
  add-appointment client picker, so the Filter button and sort must be
  suppressible there rather than assumed.
- `tour_clientsFilterDesc` describes the chip row this deletes, and
  `TourStepId.clientsFilter` targets it. Both need rewriting against the new
  control — see `docs/archive/2026-09-04-feature-tour-1-57-update-implementation.md`,
  which is unstarted and touches the same copy.
