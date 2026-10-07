# 0039. Every rate limit is the durable Firestore one

**Date:** 2026-09-04 · **Rules file:** `.claude/rules/security.md`

## Context
`placesAutocomplete` was the last in-memory limiter. An in-memory bucket is per function INSTANCE, and
`setGlobalOptions({maxInstances: 10})` meant a caller spread across containers got up to ten times the
documented cap: the limit read as 20/min and was not one. On 2026-09-04 it moved to
`enforceDurableRateLimit` (counters in `rateLimits/*`).

## Decision
Every limiter is `enforceDurableRateLimit`. The cost was taken deliberately: it puts one Firestore
transaction on a per-keystroke-debounce path that was chosen to avoid exactly that, so address typing
went from zero Firestore ops to one read plus one write per lookup.

## Consequences
Don't add an in-memory limiter to "save" that cost; the cap has to be true.
