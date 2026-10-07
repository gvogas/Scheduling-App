# 0019. Entity search moved server-side onto a client-written token index

**Date:** 2026-09-04 (callables and index), 2026-09-05 (ordering and fold fixes recorded) · **Rules file:** `.claude/rules/search.md`

## Context
Client search, appointment history search and the booking conflict check used capped client-side scan
windows, which went silently incomplete as the business grew. The clients window is `orderBy('name')`,
so at its cap it was the alphabetically FIRST N clients, and everything past that point vanished from
search, the type-filter chips and the Archived chip at once, with no error anywhere. The old rule said to
keep matching in Dart and never "fix" it into a server query; it was written when there was no index to
query, and this decision replaced it.

The callables `searchClients` / `searchHistory` / `findAppointmentConflicts` (`functions/indexed_search.js`)
query token arrays the CLIENT writes: `clients.searchTokens` and `appointments.historySearchScopes`, both
built by `searchIndexTokens` and capped at 240 by `firestore.rules`. A doc written before 2026-09-04 carried
neither until `functions/scripts/backfill-search-tokens.js` ran against it, which made that backfill a
release prerequisite, not a follow-up (it ran LIVE 2026-09-11; see the `docs/DEPLOYMENT.md` log).

Three bugs shaped the tokenizer:
- Appending phones after texts made appointment search-by-phone index nothing at all: the per-scope
  budget is ~10 tokens and a two-word client name fills it. The runs are interleaved now.
- Clamping the per-scope budget to `kSearchTokenQueryLimit` (10, the number a QUERY may send) instead of
  the field cap ÷ scope count starved everything after the client's first name.
- A JS side using NFD folded strictly more than the Dart table (all of Latin Extended-A), so "Muñoz" was
  storable as `t:mu`/`t:oz` and queryable as `t:munoz` — a client nobody can find. Both sides now carry
  an explicit fold table (`ClientSearchPolicy._foldAccent`), pinned by `test/fixtures/shared/accent_fold.json`.

The read cap (200 read `orderBy('name')`, 25 returned) is a known bound: a phone query tokenizes to every
3-12 digit substring, so `514` matches most of the roster. The client-side path it replaced had
`relevanceScore`; the server does not.

## Decision
Search runs through the callables over the token index. The index is hand-mirrored
(`searchIndexTokens` ↔ `functions/search_tokens.js`) with shared worked examples in
`test/fixtures/shared/search_tokens.json`; a token hit is re-verified by `recordMatchesQuery`. Server
write paths maintain the index too (`wave/customers_import.js`, `buildAppointmentPatch`).

## Consequences
A divergence between the two tokenizers, a missing backfill, or a server write that skips the tokens is
a search that silently returns nothing. Don't remove the cap warn, and don't raise the cap without a real
relevance order.
