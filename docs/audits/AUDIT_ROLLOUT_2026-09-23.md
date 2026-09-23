# Audit rollout and recovery

These changes are local. No production deployment, backfill, or app release has
been performed. Follow the existing [release runbook](../DEPLOYMENT.md) as well
as this change-specific ordering.

## Release order

1. Run Flutter analysis/tests, Functions lint/coverage, and the local
   [emulator checks](../../functions/__tests__/emulator/README.md).
2. Deploy Firestore and Storage rules first. Appointment creation and client
   relinking must respect `clients/{id}.deletionToken` before the new delete
   callable is used. Existing linked history remains editable; personal jobs
   with an empty client link remain supported. The rules also reserve
   `users.setupRequiresPassword` and client projection fields for the server.
3. Deploy the nine added client composite indexes and wait until they are READY.
   Existing TTL policies and index exemptions remain intact. Do not use `--force`.
4. Deploy Functions, including `syncClientBuilding`: **30 source exports**.
   Deploy both account callables in the same maintenance window. Avoid client
   deletion and invitation password reissue during rollout; ensure invocations
   of the previous non-coordinating handlers have drained before resuming them.
5. Preview and apply the building backfill against the explicitly verified
   target project, using the repository's usual credential setup:

   ```sh
   node functions/scripts/backfill-client-buildings.js --dry-run
   node functions/scripts/backfill-client-buildings.js
   node functions/scripts/backfill-client-buildings.js --dry-run
   ```

   The script prints the target before reading and never writes in dry-run.
   It pages by document ID, reconciles membership and counts transactionally,
   fills `buildingKey`, normalizes missing/non-boolean `archived` using the
   app's existing parsing, and trims recognized legacy type values. It can run
   alongside the trigger and can be rerun after interruption. Verify the final
   preview reports zero `projectionsChanged`, and sample catalog counts.
   Also verify the existing client sort-field and search-token backfills are
   complete: indexed ordering/search excludes documents missing those fields.
6. Ship the app after backend readiness and an iPhone smoke test. Check setup,
   reissue of an invitation, all three client sorts under each filter, scoped
   search, deletion with/without history, and photo upload permissions.

`buildingKey` and catalog counts update asynchronously. A just-edited building
may require refreshing after the trigger finishes; reopening the filter sheet
reloads its catalog. The trigger does no transaction for irrelevant edits once
the projection is current. The catalog is bounded at 5,000 shared buildings;
search still has its existing 200-candidate / 25-result bounds. Client lists
themselves now page through the selected server filter without a 5,000-client
scan ceiling.

## Account compatibility and recovery

`completeEmployeeSetup` accepts the optional `newPassword` field. The new app
sends it; the server validates and writes it before activation under the same
per-UID lock used for admin password resets. The app then reauthenticates to
replace its refresh credential. No password is stored in Firestore or logs.

Older apps can still activate an untouched invitation. Reissuing an invitation
sets `setupRequiresPassword: true` before resetting its password. A legacy setup
request for that invitation now receives `setup-upgrade-required` and must use
the new build. Do not remove this guard to make an old setup request succeed:
its password write occurred outside the coordination protocol.

`accountOperations/{uid}` serializes setup/reset. An additional
`accountOperations/email_<sha256>` lock serializes duplicate account creation
before Auth is minted. They are server-only and have **no TTL or automatic
takeover**, because Auth cannot enforce a Firestore lock version. Normal success
and errors release the lock. A killed process, or a failed release, leaves it
in place and later calls fail with `account-operation-in-progress`.

For a retained lock, an operator must inspect the operation's timestamp/logs,
confirm the owning invocation has ended and no credential write remains in
flight, and inspect the current Auth user plus `users` profile. Remove only that
specific stale lock after reconciling the account, then retry. Never bulk-delete
the lock collection or add TTL expiration. A release failure is logged without
turning a successful creation into a destructive rollback.

Auth and Firestore remain separate services. If the password write succeeds but
activation fails, the chosen password remains valid and the account may still
be invited. Sign in with that password and finish setup, choosing a different
password if the app's current-password check refuses reuse. No rollback resets
a chosen password automatically.

## Interrupted client deletion

A retry takes a new deletion token, checks live appointment history, and deletes
only while it still owns that token. An older attempt cannot delete the client
or release a newer barrier. A history refusal or ordinary failure releases its
own barrier. After process termination, retry the admin delete action: clients
with history are retained and unblocked; clients without history are deleted.
The barrier also blocks ordinary client edits while deletion is in progress.

## Rollback

An older backend rejects the new app's `newPassword` and search filter keys.
Preserve the expanded allowlists and coordination behavior while any new build
is installed. Do not remove the booking rules while the deletion callable relies
on them. Leave the catalog, membership ledger and indexes in place during an app
rollback; older builds ignore them. Deleting either half of the catalog ledger
manually would require a separate repair, not an ordinary rerun of this backfill.

Physical-device measurements are tracked in the
[iPhone profiling worksheet](IPHONE_PERFORMANCE_2026-09-23.md).
