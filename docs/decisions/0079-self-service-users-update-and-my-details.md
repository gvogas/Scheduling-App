# 0079. Self-service: the two-branch `/users` update and My details

**Date:** 2026-08-10 (P5), 2026-09-05 (`emailMovesThroughAuth()` restored to this rule's quote), 2026-09-13 (`monthEndReviewPush`) · **Rules file:** `.claude/rules/employees.md`

## Context
P5 gave a person two grants over their own data: `private/emergency` (admin OR owner) and a self clause on
`/users`. `MyDetailsScreen` was emergency-contact-only until P5. This rule's quote of `allow update` dropped
`emailMovesThroughAuth()` until 2026-09-05, so a reader reconstructing the rule lost the guard forcing every email
change through `changeEmployeeEmail`. A disabled account keeps its Auth credential until `syncUsersByUid` revokes it,
and an invited one is mid-setup with `completeEmployeeSetup` owning its doc, so neither may self-edit. My details
uses two save behaviours (owner call 2026-08-10): a half-typed phone auto-committing is a bad write with no undo,
while an availability switch that needs confirming reads as broken. `monthEndReviewPush` decides who receives the
month-end overdue push — an operational setting, so nobody opts themselves in or out; no rules change was needed
because `isValidUserData` is per-key and the admin branch has no key allowlist.

## Decision
`allow update` keeps its outer brackets around the two branches. `isAvailabilityOnlyChange`'s `hasOnly` lists the
whole permitted diff; `kSelfServiceUserFields` mirrors it and `self_service_fields_test.dart` reads the rules back
(Dart and CEL cannot share a constant). Both `travelAlertsEnabled` and `locationSharingEnabled` are on it, so the
Settings toggle and the availability form can each write theirs alone. `updateSelfDetails` is a separate plain
`update()` (one person, one device, and the no-client-transactions rule), naming every allowlisted key, so callers
pass stored values through. `monthEndReviewPush` is written only by the admin `updateEmployee` path and `toMap`. Role, job title and colour stay on the Team sheet.

## Consequences
Adding a key to Dart before the rules ships a silent `permission-denied`. A `maxJobsPerDay` control shown to a
technician could never succeed, so it is hidden rather than disabled.
