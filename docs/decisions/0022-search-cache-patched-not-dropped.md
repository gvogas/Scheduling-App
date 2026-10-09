# 0022. Write paths patch the search caches instead of dropping them

**Date:** 2026-09-01 (`_patchWindow` replaced `_invalidateSearchCache`; `SearchResultCache` shared), 2026-09-28 (`patchAll` on cached answers) · **Rules file:** `.claude/rules/search.md`

## Context
`FirebaseAppointmentsRepository` keeps the History scan window — the full paged terminal-status archive,
capped at 5000 — and an LRU of recent `searchHistory` answers on the long-lived singleton.
`_invalidateSearchCache()` THREW THE WINDOW AWAY, and nine write paths called it: an admin who searched
History, opened a result and marked it complete re-paged the entire archive behind the sheet — thousands
of billed reads and four sequential round trips for a one-field write, growing with the archive.
`_patchWindow` merges the changed docs by id instead, as `firebase_clients_repository`'s own
`_patchWindow` already did. On 2026-09-28 it also began patching the cached answers through
`SearchResultCache.patchAll`, firing the new `onRecordWrite` as well as `onLocalWrite`.

The two repositories carried byte-identical `_isFresh`/`_cacheSearch` pairs over identical dials
(50 entries, 2 min), and neither copy had a test for expiry or eviction; both now use
`SearchResultCache<T>` (`core/data/search_result_cache.dart`).

## Decision
Every write path calls `_patchWindow(...)` or, for a write that changes no searched field,
`_notifyLocalWrite()`. `firebase_appointments_repository_invalidation_test.dart` reads the source back so
a write path that calls neither is a test failure.

Cached `searchHistory` answers get the same drop/merge rules as the scan window: an answer is DROPPED
when a listed doc's searchable fields (`clientName`/`clientPhone`/`employeeNames`) change or a doc it
lacks may now belong in it, and nothing is ever INSERTED, since only the query can decide membership.
The crew-notes (`fieldNotes`) write passes `isRecordWrite: false`: it must still patch the cached docs
but changes nothing Job history lists, so it fires `onLocalWrite` without `onRecordWrite`.

`SearchResultCache` reads refresh recency without extending the original TTL; `patchAll` keeps recency
and TTL too but bumps the generation like `clear()`. Searches share pending requests through
`getOrLoad`, and the generation stops a read started before a local write or sign-out from restoring
invalidated results; both scan windows apply the same check and share their pending reads, history
keyed by employee/admin scope.

## Consequences
A write path calling neither serves stale results, including a just-deleted appointment that opens a
detail view for a doc that no longer exists. Don't restore a drop-the-window invalidation. Invalidation
policy stays per-repo — they legitimately differ on the `_localWrites` poke.

**Amended 2026-10-09:** `updateFieldNotes` and the `isRecordWrite` flag are deleted (ADR-0186); every `_patchWindow` call now fires both events.
