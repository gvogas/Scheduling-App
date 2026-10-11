# 0148. Wave refusals a retry cannot fix: stale links, enum values, inline strings

**Date:** 2026-08-04 (inline strings), 2026-08-15 (stale link, enums) · **Rules file:** `.claude/rules/wave.md`

## Context
Found in prod 2026-08-15: a `waveCustomerId` for a customer Wave no longer had (a missing `customerPatch` target) arrived as
`WaveApiError('graphql')` or a `NOT_FOUND` inputError, and dead-lettered. The bad id is STORED on the doc, so
every push and "Retry failed" re-sent it; two clients sat at "2 clients failed to sync" with no way to clear it.
`writeSyncSuccess` set `waveCustomerId` only on an unlinked doc, so a healed link would never have persisted.
`provinceCode`/`countryCode` are GraphQL enums: an unknown value is not an `inputErrors` entry for one field; it fails
coercion of the whole `$input` as a top-level, non-retryable error. The old shape test `/^[A-Z]{2}$/` let a province typed in the country box ("ON",
"QC") ship as a country, and an unconditional `CA-` prefix sent a New York client as `CA-NY`. `sanitizeError`
flattens every failure to `WaveApiError(graphql)`, leaving the reason recorded nowhere. On 2026-08-04 the live
API refused inline `String` arguments (`GRAPHQL_VALIDATION_FAILED`).

## Decision
Route both stale-link shapes into the create path with the identity search forced on; `replacesLink` lets
`writeSyncSuccess` overwrite only the same stale id. Test enum values by membership and omit unknowns; resolve
country before province. Log `describeWaveError` as `errorDetail`. Pass strings as variables.

## Consequences
A text match on Wave's message could rewrite a client's Wave identity on a false positive. Any new enum field
needs the same membership test. `describeWaveError` must never take the quoted value (customer data).
