# 0187. Technician-scoped History retired

**Date:** 2026-10-09 · **Rules file:** `.claude/rules/appointments.md` · **Amends:** ADR-0060, ADR-0099, ADR-0019

## Context
ADR-0060 kept the repository's `employeeId` scoping, one scan window per scope, the server `historyScope`
guard and the `emp:<id>:` token scopes because shipped builds still called that contract. History has been
admin-only (`AdminOnly` on `/history`) since 2026-09-06, and 1.63.0+93 (`cc38be5d`) calls `searchHistory`
and `fetchPage` with no `employeeId`, so the server already resolved scope `all` for every caller. On
2026-10-09 the owner confirmed every phone runs 1.63.0+93 or newer and that technician History is not
coming back.

## Decision
- App: `fetchHistoryPage`/`searchHistory`, `HistoryPager.fetchPage` and `historySearchProvider` (now keyed by
  the query string; `HistorySearchKey` is gone) take no `employeeId`. One scan window (`_historyWindow`),
  patched by `_patchWindow`; a reassigned terminal job stays in it.
- Server: `searchHistory` opens with `assertAdminCall` (a non-admin gets `permission-denied`) and queries the
  `all:` scope only; `historyScope` and `mayReadHistoryDoc` are deleted. `employeeId` stays in the allowlist,
  accepted and ignored, as `#compat-1.63.0`.
- Index: `appointmentHistoryScopes` (now in `core/search/search_tokens.dart` and `functions/search_tokens.js`,
  pinned by `historyScopes` in `test/fixtures/shared/search_tokens.json`) writes only `all:` tokens, with the
  whole 240-token field cap.

## Consequences
Docs written before this keep their `emp:<id>:` tokens until their next write; nothing queries them.
`functions/scripts/backfill-search-tokens.js` can rewrite them if the owner wants the index tidy (optional).
The `(employeeIds CONTAINS, status ASC, startTime DESC)` composite is now unused; it stays in
`firestore.indexes.json`, since removing it without `--force` changes nothing in prod. Retire the
`#compat-1.63.0` key only under `.claude/rules/security.md`'s two conditions.
