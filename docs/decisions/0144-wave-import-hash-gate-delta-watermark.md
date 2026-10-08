# 0144. Wave import: hash gate, delta query and a watermark that only advances over covered windows

**Date:** 2026-08-04 (delta), 2026-09-13 (cadence deleted; watermark kept) · **Rules file:** `.claude/rules/wave.md`

## Context
Without a hash gate the import rewrote all ~650 clients every run: ~650 writes and ~650 `waveUpsertCustomer`
invocations per press that all concluded "nothing to do", and the app reported "650 clients updated". When `since` is supplied, Wave
filters `modifiedAtAfter` server-side, so a delta returns only changed customers; a single query with a nullable
variable risks a server reading it as `null` and returning an import that imports nothing and reports success.
The watermark sequence was once shared with an unattended daily import, deleted with the cadence (ADR-0147).

## Decision
Skip a linked client whose stored hash equals `mappedFieldsHash(fromWaveCustomer(node))` and that has
`createdAt`. `LIST_CUSTOMERS_SINCE` is its own document. `importWithWatermark` owns read → decide → import →
advance; `resolveImportWindow` / `watermarkPatch` are the pure decisions. The watermark is the run's start minus
`DELTA_OVERLAP_MS`, held on a throw or any non-zero or unknown `skippedPending`; a delta-only failure retries
once as a full import; a failed watermark write is logged; a full pass runs every `FULL_RESYNC_INTERVAL_MS`.
`importedPhone` (2026-08-19) puts Wave's `phone`, else `mobile`, else a number lifted from the customer name, in
the one `phone` field, rendered "(514) 555-1234" when NANP, and always writes `mobile: ''`.

## Consequences
Without the delta→full retry, a bad `modifiedAtAfter` fails every interactive sync until the 7-day resync ages
it out. Dropping `hasCreatedAt` from the gate hides a timestampless client from the list forever.
