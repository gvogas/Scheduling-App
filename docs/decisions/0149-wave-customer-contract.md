# 0149. The customer contract owns "will Wave accept this client?"

**Date:** 2026-08-30 · **Rules file:** `.claude/rules/wave.md`

## Context
Every rule traces to a dead-letter: a blank `name`, a field past Wave's cap (latent: `firestore.rules` permits
`name` 225 and `address` 533 where Wave caps at 200 and 500, and the push capped nothing, since `capped()` runs
only in `fromWaveCustomer`), an unusable email or phone. The first production run (714 clients, 1 refusal) found
a client storing "a contact's name" in `phone`, which Wave had SYNCED; blocking it would strand a client Wave
accepts, so that rule became `NOT_DIALABLE`/advisory. A `blockingProblems` export existed for a week claiming to
own the blocking test while `buildCustomerPayload` still spelled it inline and no gate called it. The design
proposed making `toWaveCustomerInput` private; ~50 `wave_mappers.test.js` cases drive it with `null`/`undefined`
inputs the contract refuses. Design: `docs/archive/2026-08-30-wave-validated-contract-design.md`.

## Decision
`buildCustomerPayload` returns a payload plus hash or doc-field `problems`, each `blocking` or `advisory`; only
`blocking` decides `ok`. Caps come from `IMPORT_FIELD_CAPS` via `importCap`, which throws at require time.
`wave_contract_is_sole_producer.test.js` pins the boundary (verified against a planted violation).
`IMPORT_FIELD_CAPS` (`mappers.js`) is pinned as TEXT against the rules caps by
`test/core/validators/text_limits_test.dart`; `PAYLOAD_CAPS` adds only the payload path and two deviations
(`provinceCode`/`countryCode` are enums, so no length; `mobile` borrows `phone`'s cap, since the import folds
mobile into `phone` while the push sends both). The phone rule is `NOT_DIALABLE`/advisory, deliberately not
`INVALID_PHONE`; the documented length caps stay (not guesses); demote the unproven email rule if real data
contradicts it.

## Consequences
Lowering the rules caps makes stored docs permanently un-updatable. One severity for both questions fails both
ways: all-blocking strands accepted clients, none-blocking restores the permanent dead-letter. An undefined cap
makes `overLongProblems` report every client `TOO_LONG`, which is blocking, so every client is refused.
