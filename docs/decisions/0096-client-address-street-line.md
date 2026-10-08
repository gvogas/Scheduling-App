# 0096. `clients.address` is the street line; reads and propagation compare the composed address

**Date:** 2026-08-28 · **Rules file:** `.claude/rules/clients.md`

## Context
Storing `city`/`province`/`postalCode`/`country` in `address` as well as their own fields let the copies drift. The
collection holds both shapes forever (Wave import writes a street line, the app wrote the whole picked
string, the console either). The street + apt precedence was a verbatim copy in each sheet. The field drifted
back because `ParsedAddressFields.street` is null on an address with no apt and a `fields.street != null`
guard left the controller holding whatever Places returned. `propagateClientEdits` compared the raw field, so
an apt-bearing client never matched `from` and a city-only edit never propagated; then `composeFullAddress`
spelled the apt `"4-1234 Rue Principale, …"` while the app books `"1234 Rue Principale #4, …"`, and
`buildAppointmentPatch` compares verbatim. Each side's tests asserted its own composer against itself.

## Decision
`AddressParser.canonicalFrom` owns street + apt precedence (explicit apt wins; blank keeps the embedded one).
`AddressParser.streetOnly`/`composeFull` (`ClientRecord.streetLine`/`fullAddress`) own the shape;
`composeFull` reduces through `streetOnly` first; `streetOnly` strips from the tail and never the last segment.
JS twin `functions/client_address_utils.js` (`streetFromAddress`/`composeFullAddress`, apt via
`canonicalToDisplay` = `splitApt` + `formatAptForDisplay`); the app's display spelling is canonical for `appointments.address`. Shared worked
examples; `client_propagation.test.js` pins "normalizing `address` to the street line propagates NOTHING".

## Consequences
If propagation compares the raw field, `backfill-client-address-street.js` becomes destructive. The backfill
is hygiene: it only removes trailing segments matching fields on the doc, skips a doc with no locality
fields, never writes an empty address, and pushes nothing to Wave (`mappedFieldsHash` hashes
`toWaveCustomerInput`'s output, the same `addressLine1` for both shapes, so `shouldEnqueueClientWrite` Rule 1 refuses the write).
