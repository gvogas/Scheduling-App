# Firebase authorization and concurrency checks

From the repository root, with Firebase CLI and Java 21 installed:

```sh
firebase emulators:exec --project demo-scheduling-review --only "auth,firestore,storage" "node functions/__tests__/emulator/storage_rules.smoke.js"
```

The script refuses non-demo projects and non-local emulator hosts. It creates
temporary Auth users, authorization bridge rows, one appointment, and photo
objects inside the emulators. It checks employee creation, overwrite, metadata
updates, deletion and reads; unrelated, disabled and anonymous users; invalid
content types; and admin replacement, metadata updates and deletion.

It also runs six account-trigger assertions against real Firestore transactions
and the Auth emulator, checking delayed activation after disable/deletion and
delayed deactivation after reactivation.

`role_isolation_checks.js` exercises read and write isolation against the real
`firestore.rules`: unassigned, disabled and anonymous reads of a job; employee
reads of client PII; unconstrained list queries; self-promotion and
self-reactivation; a peer's emergency contact, location and FCM token; and
client writes to the bridge and every server-owned ledger.

In a sandbox whose JVM prints a `JAVA_TOOL_OPTIONS` banner or whose HTTP proxy
captures loopback traffic, the Storage rules runtime denies everything; run
with `env -u JAVA_TOOL_OPTIONS -u HTTPS_PROXY -u HTTP_PROXY` once the emulator
jars are downloaded.

Jest excludes this directory because these checks require running emulators.
No additional npm dependencies or production credentials are required.

The same runner now checks both booking/deletion commit orders, forged deletion
and setup barriers, per-UID setup/reset contention, the legacy setup barrier,
actual sign-in with the chosen password, and building catalog transactions
(including duplicate delivery, concurrent membership, archive, delete and dry-run). It also checks that no client can set or clear passwordResetRequired or create a doc carrying setupRequiresPassword, and runs an admin password reset followed by the employee's forced change against the Auth emulator.
CI runs it on PRs and pushes to main and dev.
