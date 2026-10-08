# 0097. Booking client picker: phone slices, local narrowing, and a visible failure

**Date:** 2026-09-05 (shipped in 1.58.0) · **Rules file:** `.claude/rules/clients.md`

## Context
A bare area code matches the roster twice over and costs 200 reads to prove it. A typo lands in the tail, so
`5145628233` against a stored `5145628332` misses on last-7 and last-4 and hits on first-7. Joining `phone`,
`mobile` and contact phones into one `phoneDigits` blob let a query straddle the seam and match a number nobody
has, and made `relevanceScore`'s exact tier unreachable for anyone with two numbers; three sites had the blob
(`ClientSearchPolicy.index`, the repository's relevance call, `recordMatchesQuery` in
`functions/search_tokens.js`). `searchClients` ends `orderBy("name")`, so the closest number on a fallback rung
landed wherever the alphabet put it. "No clients found" on a failed search read as "new customer", creating a
duplicate carrying a number that could never be searched.

## Decision
`PhoneQueryPolicy` drops a leading `1`, holds under 7 digits, and on a miss at 10+ retries the first seven then
the last seven; fallback results are "closest numbers on file". `ClientSearchWindow.canNarrowTo` narrows a
complete answer locally and refuses at `resultDisplayLimit`. `ClientSearchEntry.phoneDigits` is one entry per number, holding own and contact numbers for matching; `scoreRecord` builds its lists from `ownPhoneDigits`/`contactPhoneDigits`, never `entry.phoneDigits` (which let a contact score exact and compared each twice in `contactsDigits` at tier 4), and `matchClientDocs` reads `rawOwnPhoneDigits`/`rawContactPhoneDigits`; `index()` keeps both. The
repository re-ranks with `ClientSearchPolicy.scoreRecord`. `ClientSearchStatus.failed` renders a failure.

## Consequences
The server's 200-doc read cap is still alphabetical and out of scope. Ranking in the controller would split
the callable path from the local fallback.
