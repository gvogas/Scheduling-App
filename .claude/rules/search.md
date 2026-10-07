---
paths:
  - "lib/core/search/**"
  - "lib/core/data/**"
  - "lib/core/utils/firestore_parsing.dart"
  - "lib/core/utils/debouncer.dart"
  - "lib/features/clients/application/**"
  - "lib/features/clients/data/**"
  - "lib/features/clients/domain/**"
  - "lib/features/clients/widgets/views/debounced_paged_search.dart"
  - "lib/features/clients/widgets/views/appointment_history_view.dart"
  - "lib/features/clients/widgets/views/clients_list_view.dart"
  - "lib/features/calendar/application/appointment_form_concerns.dart"
  - "lib/features/calendar/utils/client_booking_context_scope.dart"
  - "lib/features/employees/application/employees_providers.dart"
  - "lib/features/calendar/data/**"
  - "lib/features/calendar/domain/policies/**"
  - "lib/features/calendar/domain/appointment_day_slice.dart"
  - "lib/features/calendar/domain/models/appointment_record.dart"
  - "functions/indexed_search.js"
  - "functions/search_tokens.js"
  - "functions/day_slice_utils.js"
  - "functions/client_propagation.js"
  - "functions/appointment_scan.js"
  - "functions/wave/customers_import.js"
  - "functions/scripts/**"
  - "test/core/search/**"
  - "test/core/data/**"
  - "test/core/utils/firestore_parsing_test.dart"
  - "test/features/clients/application/**"
  - "test/features/clients/data/**"
  - "test/features/clients/domain/**"
  - "test/features/clients/client_search_policy_test.dart"
  - "test/features/calendar/domain/policies/**"
  - "test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart"
  - "test/features/calendar/data/firebase_appointments_repository_cap_warning_test.dart"
  - "test/fixtures/shared/search_tokens.json"
  - "test/fixtures/shared/accent_fold.json"
  - "functions/__tests__/search_tokens.test.js"
  - "functions/__tests__/indexed_search*.test.js"
  - "functions/__tests__/client_propagation.test.js"
  - "functions/__tests__/backfill_search_tokens.test.js"
  - "functions/__tests__/appointment_scan.test.js"
  - "functions/__tests__/repair_client_address_mojibake.test.js"
  - "functions/__tests__/scripts_scan.test.js"
---

# Entity search

Loaded when working on search, the token index or the scan windows. Root context: `../../CLAUDE.md`.

## Server-side search and the token index

- Search clients, appointment history and booking conflicts through the callables `searchClients` / `searchHistory` / `findAppointmentConflicts` (`functions/indexed_search.js`), never a capped client-side scan — an `orderBy('name')` window silently drops every client past the first N. (ADR-0019)
- Write the index from the client on every entity write: `clients.searchTokens` and `appointments.historySearchScopes`, both from `searchIndexTokens` (`core/search/search_tokens.dart`), capped at 240 by `firestore.rules`. A doc without tokens is invisible until `functions/scripts/backfill-search-tokens.js` runs, so a backfill gates the build that queries it. (ADR-0019)
- Change `searchIndexTokens` and its hand-mirror `functions/search_tokens.js` in one commit, with new examples in `test/fixtures/shared/search_tokens.json`, never inline — a divergence silently returns nothing.
- Emit each word's WHOLE token before its prefixes (an exact-word query survives truncation) and INTERLEAVE text and phone runs, so a long name never pushes phone tokens past the cap. (ADR-0019)
- Size the per-scope budget as the FIELD cap ÷ scope count (`all:` plus `emp:<id>:` per assignee), never `kSearchTokenQueryLimit` (10, a QUERY limit), which starves everything after the first name. (ADR-0019)
- Treat a token hit as a PREFILTER: both callables re-verify with `recordMatchesQuery` over the stored doc, since a prefix matches more than the query.
- Mirror `normalize` as an explicit fold TABLE on both sides (`ClientSearchPolicy._foldAccent`, `functions/search_tokens.js`), never NFD, which folds more and stores tokens no query can reach. Add a letter to both tables or neither; `test/fixtures/shared/accent_fold.json` pins all 64 Latin-1 entries. (ADR-0019)
- Keep the read cap (200 read `orderBy('name')`, 25 returned) and its warn; never remove the warn, and don't raise the cap without a real relevance order — a phone query matches every 3-12 digit substring, so `514` matches most of the roster. (ADR-0019)
- Maintain the index on every SERVER write path, or an admin can't find a client they can see: `wave/customers_import.js` sets `searchTokens`, and `buildAppointmentPatch` rebuilds `historySearchScopes` whenever it moves `clientName`/`clientPhone`. (ADR-0019)
- Filter `findAppointmentConflicts` through `dailyWindowsOverlap` (`functions/day_slice_utils.js`, mirrored from `appointment_day_slice.dart`) — a DAILY-window overlap, not a raw instant test; unparseable stored times clash unconditionally. Pinned by `functions/__tests__/indexed_search_conflicts.test.js`. (ADR-0020)

## Local fallback matchers

- Keep the local scan windows as the injected-`FirebaseFunctions`-absent fallback (tests only; `firebaseFunctionsProvider` is non-nullable): `_historySearchScanLimit` 5000 / `_clientScanLimit` 5000 via `clientSearchProvider` / `historySearchProvider` (`autoDispose.family` keyed by query); the loaded-page filter fills the gap until the debounced read settles. Don't delete them or add a third matcher.
- Route client matching through `ClientSearchPolicy` `index()` + `entryMatches()` (loaded-page filter) and `rawMatches()` (debounced scan), on `ClientSearchPolicy.normalize` + `digitsOnly`. Keep `matchesClient` with NO production caller — it rebuilds the projection per candidate per keystroke. (ADR-0021)
- Keep `ClientSearchPolicy.rawTexts` / `rawPhones` the ONE raw-map field list, read by `rawMatches` and by the `searchTokens` builder in `firebase_clients_repository`, so indexed and matched never drift; `index()` keeps its own `ClientRecord`-shaped copy on purpose. (ADR-0021)
- Keep own and contact numbers separate (`ownPhoneDigits`/`contactPhoneDigits` and `raw*` twins): only own may score exact or prefix in `relevanceScore`. `rawPhones` is their concatenation, already digits. (ADR-0021)
- Route appointment matching through `historyEntryOf` + `historyEntryMatches` (`calendar/domain/policies/history_search_policy.dart`), shared by `matchHistoryDocs` and `appointment_history_view.dart`'s loaded-page filter — one search at two layers. (ADR-0021)
- Parse raw-map list fields through `firestoreStringList` (`core/utils/firestore_parsing.dart`, beside `firestoreDateTime`/`firestoreInt`), never a private copy that silently stops matching `employeeNames`. (ADR-0021)

## Write-path cache patching

- Call `_patchWindow(...)` or `_notifyLocalWrite()` from every `FirebaseAppointmentsRepository` write path, never drop the 5000-doc window — one that calls neither serves stale results, even a deleted job. `firebase_appointments_repository_invalidation_test.dart` reads the source back. (ADR-0022)
- In `_patchWindow`, REMOVE a doc no longer terminal (`status whereIn terminalStatusQueryValues`) and insert a new one at its `startTime` position (the window is `startTime` DESC; `searchHistory` returns it unsorted).
- Patch cached answers too (`SearchResultCache.patchAll`): drop one when a listed doc's `clientName`/`clientPhone`/`employeeNames` change or a missing doc may belong; never INSERT, since only the query decides membership. Fire `onRecordWrite` and `onLocalWrite`, except `isRecordWrite: false` (the `fieldNotes` write) skips `onRecordWrite` — it must still patch the cached docs but changes nothing Job history lists. (ADR-0022)
- Use `_notifyLocalWrite()` (fires `onLocalWrite` only) just for writes that change no field `matchHistoryDocs` reads — the two photo paths.
- Share one LRU, `SearchResultCache<T>` (`core/data/search_result_cache.dart`, 50 entries, 2 min); invalidation stays per-repo (`_localWrites`). Reads refresh recency, not TTL; `patchAll` keeps both and bumps the generation like `clear()`. Share pending loads via `getOrLoad`; the generation stops a read begun before a write or sign-out restoring stale results — scan windows too, history keyed by scope. (ADR-0022)

## Bounded scans

- Page every scan window to its cap and WARN at it (as `_mapRangeSnapshot` does); never a bounded read without the warn or an unbounded `while (true)` loop — `fetchClientHistory` (`_clientHistoryScanLimit` 1000) and `fetchClientsCreatedSince` included. (ADR-0023)
- Page only through `pageToCap` (`core/data/paged_scan.dart`); the caller supplies cap, page size and warn text.
- Keep page size apart from the display bound and the cap (windows page at 500): `pageToCap` asks for `cap + 1 - fetched`, so a page equal to the cap costs a second trip. For the newest N pass `limit: N + 1, cap: N` (`clientBookingHistoryProvider`). (ADR-0023)
- Breadcrumb, not warn, when a deliberate window hits its cap, or every form open files a non-fatal; `fetchClientHistory` keys this on an explicit `cap`. (ADR-0023)
