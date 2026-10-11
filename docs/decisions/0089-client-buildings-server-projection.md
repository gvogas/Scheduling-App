# 0089. Client buildings: a server-owned projection with the city in the key

**Date:** 2026-08-28 (derived, never stored), 2026-09-04 (addresses into the filter sheet; row pill removed), 2026-09-07 (no shared-address count), 2026-09-11 (type badge back), 2026-09-23 (server-owned) · **Rules file:** `.claude/rules/clients.md`

## Context
Deriving the catalog in the app was a 5000-doc roster scan on the first filter open. Without the city, a
Laval client showed under a Montréal address with nothing explaining why. Without `AddressParser.streetOnly`,
legacy docs whose `address` still carries the locality split from normalized ones — on the buildings with the
most history. `ClientAddressFilterMenu` was replaced by a sheet section on 2026-09-04. The per-row Building
pill went 2026-09-04, then the detail count, `clientBuildingCountsProvider` and `clients_sharedAddressCount`
on 2026-09-07: the count answered a question nobody asked on a one-client screen. The type badge came back on
2026-09-11 (reversing that half of 2026-09-07) because the old row was a flat `ListTile` sharing one line, and the row is now a three-line card row with its own
corner for it.

## Decision
`buildingKeyFor` (`clients/domain/policies/client_building.dart`), hand-mirrored by `buildingFor`
(`functions/client_buildings.js`), both suites reading `test/fixtures/client_building_cases.json`.
`syncClientBuilding` keeps `buildingKey`, `clientBuildings/{sha256(key)}` (key/street/city/`clientCount`) and
`clientBuildingMemberships/{clientId}` in one transaction, reconciled from the LIVE doc and stored membership.
Floor of two clients; archived excluded; `noFixedAddress` or a blank address is `null`. `fetchBuildings` reads `clientBuildings` where
`clientCount >= 2`, capped at 5000 with a `CLI-BUILDINGS` warn, busiest first, street as Dart tiebreak.

## Consequences
Reconciling from the event delta double-counts on a retried or reordered event. The catalog is eventually
consistent: an edited address moves groups once the trigger lands.
