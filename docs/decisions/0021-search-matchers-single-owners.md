# 0021. One owner per search matcher and per field list

**Date:** 2026-08-22 (`firestoreStringList`), 2026-09-01 (`historyEntryOf`/`historyEntryMatches`), 2026-09-05 (`rawTexts`/`rawPhones`, own vs contact phones) · **Rules file:** `.claude/rules/search.md`

## Context
- `ClientSearchPolicy.rawTexts` / `rawPhones` replaced two hand-written copies of the same ten raw-map
  fields — one read by `rawMatches`, one by the `searchTokens` builder in `firebase_clients_repository`.
  What is INDEXED and what MATCHES cannot be allowed to drift.
- A client's own numbers and its contacts' were spelled at each call site and drifted immediately:
  `scoreRecord` passed the contacts in BOTH lists (so a contact's number could score exact, and every
  contact was compared twice at the weakest tier) while the repository's local-fallback matcher kept them
  out of the own list — two answers to one question. `ownPhoneDigits`/`contactPhoneDigits` and the raw
  twins now own the split, and `rawPhones` is just their concatenation, already reduced to digits
  (`searchIndexTokens` runs `digitsOnly` itself, so handing it digits changes no token).
- The appointment side's two layers (`matchHistoryDocs` and `appointment_history_view.dart`'s loaded-page
  filter) used separate matchers, so a field added to one changed results visibly when the debounce
  settled, with nothing logged. The repository's fallback also briefly carried a third hand-written
  matcher that read `title`, which neither twin does.
- The history filter reads `employeeNames` from the raw map before there is a record; a private list
  parser that accepted less than the record's would silently stop finding a crew member, with nothing
  logged. Hence `firestoreStringList` (`core/utils/firestore_parsing.dart`).

## Decision
Client matching routes through `index()` + `entryMatches()` and `rawMatches()`; appointment matching
through `historyEntryOf` + `historyEntryMatches`; raw list fields through `firestoreStringList`.
`index()` keeps its own `ClientRecord`-shaped copy on purpose. `matchesClient` stays a convenience
wrapper with no production caller, since `index` is hoisted to run once per data change while
`matchesClient` rebuilds the projection per candidate per keystroke.

## Consequences
Don't add a third matcher or spell a field list at a call site. Further ranking rules live in
`.claude/rules/clients.md`.
