# 0093. `mobile` folds into `phone`, in the app and in the Wave import

**Date:** owner change 5 (edit sheet), 2026-08-19 (`importedPhone`) · **Rules file:** `.claude/rules/clients.md`

## Context
The edit sheet dropped the second phone field. A stored `mobile` would otherwise sit on the doc forever —
invisible, uneditable, still matched by `matchClientDocs` and still in the Wave payload. The app never clears
Wave's copy (`toWaveCustomerInput` omits an empty field rather than blanking it), so the import put the value
back on the next run. This business names a person by their phone number in Wave, so a customer added THERE
arrives called "5145551234" with the phone box empty, and no in-app save repaired it (`composeStored` reads a
name made of digits as a business). `backfill-client-phone-formatting.js` did the formatting once by hand.

## Decision
`EditClientSheet._save` promotes `mobile` into an empty `phone` and clears `mobile` on every save; no
migration — the fleet heals as clients are edited. `importedPhone` (`functions/wave/mappers.js`) resolves ONE
phone — Wave `phone`, else `mobile`, else a number lifted from the name (`liftPhoneFromName`, phone half only)
— writes `mobile: ''`, and renders NANP as "(514) 555-1234" via `formatNanpNumber` (`client_name_utils.js`).

## Consequences
Rewriting `name` locally would push a rename to Wave. The caller hashes the resolved fields into
`wave.lastSyncedHash`, so a reshaped number does not enqueue a push; hashing Wave's raw values instead would
re-enter the whole roster into the outbox on every import.
