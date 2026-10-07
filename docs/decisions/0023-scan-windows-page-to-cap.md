# 0023. Scan windows page to a cap and warn; `pageToCap` owns the loop

**Date:** 2026-08-19 (paging added; caps and warns restored the same day; `pageToCap` extracted), 2026-09-23 (list filters moved to server paging) · **Rules file:** `.claude/rules/search.md`

## Context
The 2026-08-19 cleanup commits added paging to the scan windows and, in the same change, deleted every
ceiling and every warn; both were restored the same day at 5000. Paging is what stops a window
truncating at one page; the cap is what stops it walking the whole collection — the two are not
alternatives. It matters most on clients: that window is `orderBy('name')`, so at the cap it is the
alphabetically FIRST N clients and everything past it is invisible to the fallback search with no
error. (The list FILTERS stopped reading that window on 2026-09-23; they page server-side, see
`.claude/rules/clients.md`.)

The four call sites each had a hand-written loop — four chances to omit the cap or the warn — so the
loop moved into `pageToCap` (`core/data/paged_scan.dart`). `fetchClientHistory` used its `limit` (50) as
both page size and display bound against a 1000 cap, so one client-detail open cost up to 20 sequential
round trips; it pages at 500 like the other two windows.

A deliberate window (the newest N, e.g. `clientBookingHistoryProvider`) reaches its bound as the normal
case — for the booking form, on exactly the repeat clients it is for — so warning there filed a
Crashlytics non-fatal per form open and buried the real one.

## Decision
Windows page through `pageToCap` to an explicit cap and warn at it; a deliberate window breadcrumbs
instead. The caller supplies its own cap, page size and warn text, each naming a different user-visible
consequence.

## Consequences
Never add a bounded read without the warn, never an unbounded `while (true)` loop, and never a page size
equal to the cap (a wasted second round trip).
