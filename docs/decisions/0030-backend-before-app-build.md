# 0030. Backend additions go live before the app build that needs them

**Date:** 2026-09-04, 2026-09-23, 2026-09-29 · **Rules file:** `CLAUDE.md`

## Context
`assertPayloadShape` rejects unknown keys, so a client that sends a new field to an old backend fails;
and a new callable, trigger, index or backfill is absent until deployed. Three recent additions each
gated an app build (all now deployed — see the `docs/DEPLOYMENT.md` log):
- **2026-09-04, 25 → 29 exports:** `searchClients`, `searchHistory`, `findAppointmentConflicts`
  (`indexed_search.js`) and `restoreAppointmentStatus` (`appointment_actions.js`). The first three
  needed their composite indexes deployed FIRST and READY, and the `searchTokens` /
  `historySearchScopes` backfill run, before the app build that calls them shipped.
- **2026-09-23, 29 → 30:** `syncClientBuilding`, a `clients` trigger maintaining the `clientBuildings`
  catalog and each client's `buildingKey`. Its rules, the nine client composites and
  `backfill-client-buildings.js` had to be live before the app build that reads them; the ordering and
  the `accountOperations` lock recovery are in `docs/audits/AUDIT_ROLLOUT_2026-09-23.md`.
- **2026-09-29, 30 → 32:** `resetEmployeePassword` (admin, `assertAdminCall`, `employee_accounts_admin.js`)
  and `completePasswordReset` (self-service, `assertActiveCall`, `employee_accounts_self.js`), with
  `passwordResetRequired` added to the `/users` create and update denylists. Deploy
  `functions,firestore:rules` before the app build; new callables, so no payload-superset concern, and
  no backfill (an absent flag means "not required").

## Decision
Deploy the backend BEFORE the app build. `docs/DEPLOYMENT.md` holds the ordering, the
old-build-compatibility check, rollback and the deploy log of what production actually runs.

## Consequences
Read the runbook before any deploy that touches a callable payload or a rules cap.
