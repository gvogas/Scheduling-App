# 0088. `ClientType.building` replaced `propertyManagement` with no legacy alias

**Date:** 2026-08-28 · **Rules file:** `.claude/rules/clients.md`

## Context
`propertyManagement`/`"property_mgmt"` became `building`/`"building"` in Dart and in `BUSINESS_TYPES`
(`functions/client_name_utils.js`). Prod held zero `property_mgmt` docs when checked 2026-08-28; that count
is the whole justification. `fromRaw` maps an unknown value to `unset`, which also flips
`ClientNamePolicy.isBusiness` to false and exposes the customer to the name-is-the-phone rewrite.

## Decision
No alias. If a `property_mgmt` row turns up, map it forward; never re-add the old value to make a read pass.

## Consequences
The live risk is a fleet one: a build older than 1.53.0 still writes `property_mgmt`, so re-run the count
while such a build may be installed.
