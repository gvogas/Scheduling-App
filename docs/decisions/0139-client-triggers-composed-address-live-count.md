# 0139. Client edits compare the composed address; client delete counts live

**Date:** 2026-08-03 (`deleteClient`), address split (undated) · **Rules file:** `functions/CLAUDE.md`

## Context
`clients/{id}.address` is the STREET LINE and the four locality fields are their own, while an
appointment holds one address string and no locality fields. Fanning a raw street line onto it strips
the city off a live job with nothing left to rebuild from. A matching bug predated the split: the app
books the composed address while the doc stores the canonical `4-1234 …`, so an apt-bearing client
silently never took an address correction at all. `client_address_utils.js` is the JS half of a pair
hand-mirrored as `AddressParser.streetOnly` / `composeFull`.

`deleteClient` is the only client-delete path since `allow delete` on `/clients` was withdrawn. Its
`client-has-history` refusal reads a live `count()` aggregate; the denormalized `jobCount` is lazily
backfilled by `recountClientJobs` and can be stale, missing or wrong after an out-of-band reassignment.

## Decision
`propagateClientEdits` compares `composeFullAddress` on both sides, never the stored field, which also
keeps normalizing the client field a no-op. `deleteClient` refuses on the live count, never `jobCount`;
the pure `performDeleteClient` is exported for jest.

## Consequences
Deleting on a stale zero orphans exactly the visits the gate protects. `client_propagation.js` must not
import from `wave/`.
