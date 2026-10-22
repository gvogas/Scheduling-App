# Database, performance, and long-term code review

Reviewed: 2026-10-18. Project: `schedulingapp-88727`.

**Implementation order:** see the [prioritized remediation plan](../plans/2026-10-18-audit-remediation-plan.md), which consolidates all 42 finding IDs into staged work packages with dependencies and acceptance checks. It takes precedence over the separate section-level execution suggestions below.

## Recommendation

Prioritize reliable appointment saves, durable photo uploads, complete conflict checks, and ordering-safe background processing. These changes offer more practical value at current usage than a database migration or a broad rewrite. Improve perceived photo speed and reduce repeated conflict requests next. Make database index changes selectively, using actual queries and measurements.

This is a review and implementation roadmap. Application fixes and production configuration changes have **not** been applied. Review additions include this document, supporting local reproductions, and the linked remediation plan. Existing unrelated workspace changes were preserved.

## Scope and evidence

Reviewed the appointment repository and editing flow, conflict checking, client search, photo loading and upload queue, dashboard providers, client propagation, derived counters, Wave queue/transport/trigger configuration, database indexes, and deployed functions/schedules. This is a focused deep review, not proof that every code path is defect-free.

Evidence labels:

- **Reproduced:** a deterministic local scenario exercises existing helpers with controlled data or fake database operations. It establishes the defect mechanism, not a production incident.
- **Code trace:** a concrete failure path is visible in the implementation, but was not reproduced on a device or against production.
- **Deployment verified:** configuration or monitoring was read from the deployed project.
- **Optimization candidate:** expected benefit must be measured before claiming a speed or cost improvement.

## Priorities

| ID | Priority | Improvement | Evidence |
| --- | --- | --- | --- |
| R1 | P1 | Persist upload progress before deleting local photos | Code trace |
| R2 | P1 | Prevent stale edit forms overwriting newer appointment changes | Code trace |
| R3 | P1 | Make conflict detection complete or explicitly inconclusive | Code trace |
| R4 | P1 | Make client propagation safe against reordered events | Reproduced |
| R5 | P2 | Correct client search truncation | Reproduced |
| R6 | P2 | Prevent older recounts overwriting newer totals | Reproduced |
| R7 | P2 | Match Wave deployment concurrency to the intended limit | Deployment verified + code trace |
| R8 | P2 | Enforce Wave request and drain deadlines | Code trace |
| R9 | P2 | Recheck retry eligibility when claiming Wave jobs | Reproduced |
| R10 | P2 | Render photos progressively and bound retained memory | Code trace + optimization candidate |
| R11 | P2 | Batch conflict checks for repeated bookings | Optimization candidate |
| R12 | P2 | Refresh dashboard date boundaries and mutation-sensitive data | Code trace |

P1 means address before investing heavily in optimization; P2 means schedule a focused improvement. Priorities reflect potential impact, not measured incident frequency.

## Detailed findings

### R1 — An interrupted upload can leave a photo unlinked and unrecoverable from the queue

Source: `lib/features/calendar/data/appointment_image_upload_service.dart`, `_uploadOne` around line 145 and `_attempt` around line 233.

After Storage upload succeeds, `_uploadOne` deletes the local file before its uploaded metadata is persisted. Metadata remains in memory while the other files finish and before `_appendLinks` runs. If the app terminates in that interval, the persistent queue still refers to the deleted file. On restart, `_attempt` can find neither existing files nor persisted uploaded metadata and remove the queue entry. The Storage object may exist, but the appointment has no link to it.

**Change:** use durable per-file upload state. Persist a stable upload ID/object path before upload; persist the successful upload receipt before deleting local bytes; link the image idempotently; then clean up the queue. Make recovery able to reconcile an upload that succeeded just before the receipt was written. Timestamp-generated paths on each retry are insufficient for that recovery contract.

**Verify:** simulate termination after every boundary: queue write, Storage completion, receipt persistence, link commit, and local cleanup. Restart and assert exactly one linked image, eventual cleanup, and no silent loss. Also exercise sign-out during an active upload so late completions cannot resurrect cleared queue state.

### R2 — Saving an old form can overwrite a newer appointment status or details

Source: `lib/features/calendar/data/firebase_appointments_repository.dart`, `updateAppointment` line 249, `updateAppointments` line 260, and series rewrite paths; the event details controller builds updates from its original appointment/editing state.

Single-record updates write the whole mapped record. Multi-record transactions check existence but do not compare the current business revision with the version the user edited. A transaction alone therefore does not prevent this lost update: an administrator opens a pending appointment, a crew member completes it, and the administrator saves a note from the old form, writing the old pending status back.

**Change:** submit intentional field patches and an expected business revision. Compare that revision transactionally and present a useful conflict response if the record changed. Define which unrelated edits may merge safely. For series edits, reconcile against current records and preserve terminal states unless a transition was explicitly requested. Consider a separate business revision if generic `updatedAt` also changes for photo metadata.

**Verify:** two editors changing different fields; two editors changing the same field; completion during an open form; concurrent series edits; appointment deletion during save. Assert that no unrelated status is reverted.

### R3 — A capped conflict query can return an incomplete answer

Source: `functions/indexed_search.js`, conflict query around lines 257–270.

The query limits each employee chunk to 500 candidates, then filters terminal statuses. A genuine blocking appointment beyond that window is never examined. Logging a cap hit does not make a returned conflict-free result safe.

**Change:** paginate the matching set completely, or return an explicit incomplete result that prevents the UI from treating it as clearance. Reduce irrelevant candidates with a queryable scheduling-blocking flag only after establishing a reliable invariant for all writers and historical records. An asynchronous trigger alone leaves a window where the flag is missing or stale.

Keep employee chunking compatible with Firestore query limits. Adding a status `in` filter multiplies disjunctions with `array-contains-any`; an equality flag avoids that multiplication. Do not simply raise the cap and call the correctness issue fixed.

**Verify:** more than 500 candidates with the only active conflict beyond the first page; terminal-heavy history; multiple employee chunks; exact time boundaries; old records during migration. Separately decide whether conflict checking must also reserve capacity atomically: a complete preflight query still does not serialize two simultaneous bookings.

### R4 — Reordered client events can restore old appointment contact details

Source: `functions/client_propagation.js`, patch construction around lines 125–150 and batch updates around line 218.

The handler writes name/phone values from the event without checking that the event is still current. Applying phone change `222 → 333` before older change `111 → 222` leaves the appointment at `222`. The local helper reproduction confirms this. A custom appointment address edited after a propagation snapshot is read can also be vulnerable to a precomputed patch.

**Change:** reconcile from current client state with a source revision and transactional or preconditioned target writes. On contention, reread and recompute the patch, including custom-address preservation. Use the repository's transactional building-reconciliation approach as a design reference. Absolute-value writes are repeatable but are not automatically safe against event reordering.

**Verify:** reversed events, duplicate events, deletion, and a user editing an appointment between propagation read and commit. Firestore events can arrive out of order and more than once: [Firebase trigger documentation](https://firebase.google.com/docs/functions/firestore-events).

### R5 — Client search can hide the only complete match

Source: `functions/indexed_search.js`, search query around lines 104–110 and subsequent `recordMatchesQuery` filtering.

The token query uses OR matching, orders candidates by name, and reads at most 200 before applying full-query matching. A valid match can be beyond the candidate cap even when the final result contains fewer than the requested 25 clients. The reproduction creates 200 broad matches followed by the only full match and demonstrates its omission.

**Change:** add an exact normalized-phone lookup where appropriate; use cursor-based candidate pagination; return continuation/incompleteness information when applying a work budget. Preserve full-query semantics. An additional index alone cannot correct filtering after truncation.

**Verify:** broad common-name tokens, multiword names, exact phone searches, archived/type/building filters, and a full match beyond candidate 200. Track cap-hit frequency before considering a dedicated search service.

### R6 — Overlapping recounts can overwrite correct totals with stale totals

Source: `functions/client_job_count.js`, `recountOne` line 110; analogous count-then-update in `functions/appointment_images.js` around line 173.

Aggregation and target update are separate operations. An older recount can compute 1, pause, and write after a newer recount computes and writes 2. The local reproduction exercises the real recount helper and ends at 1. The current claim flow does not serialize the entire reconciliation.

**Change:** implement per-entity reconciliation with a dirty generation and a final recheck, or maintain transactional contribution/membership records. Choose based on complexity and measured write volume. Merely holding a lock while ignoring later events can lose changes; ensure updates during processing trigger another pass. Client recount currently performs several count queries, so account for that work when estimating savings.

**Verify:** delayed older writes, duplicate events, updates during a held claim, worker failure, and a final comparison with source records. Apply the same invariants to image counts.

### R7 — Wave's deployed concurrency does not match the code's throughput assumption

Source: `functions/wave/triggers.js`, concurrency explanation around lines 69–100. Deployed `waveUpsertCustomer`: `maxInstanceCount: 2`, `maxInstanceRequestConcurrency: 80`.

The code explanation assumes one request per instance and uses two instances to bound simultaneous drains. The deployed configuration permits up to 80 concurrent requests per instance. Two instances therefore do not establish a two-drain ceiling; the nominal configuration ceiling is 160 requests, not observed traffic.

**Change:** explicitly configure concurrency 1 if two simultaneous trigger requests are the intended policy. Also consider other Wave entry points when enforcing a shared upstream budget. A concurrency cap does not itself enforce requests per minute, and a per-job claim only protects that job.

**Verify:** inspect deployed concurrency after release; load-test different queued jobs; monitor upstream throttling, queue age, and successful processing rate. Confirm that a lower cap does not create unacceptable backlog.

### R8 — Wave HTTP work can outlive the drain's intended deadline

Source: `functions/wave/client.js`, `postWithRetry` around line 142; `functions/wave/dispatch.js`, deadline checks.

The fetch path has no explicit abort signal, and body consumption can also wait. The drain checks its deadline between jobs, so an already-running upstream call can exceed the remaining budget. Platform termination can leave the job inflight until lease recovery and delay unrelated jobs.

**Change:** bound each request, including body reading, by the remaining drain budget. Bound retry delays too, leaving time to record an outcome. Use an explicit retriable timeout outcome and preserve existing idempotency/reconciliation handling for ambiguous upstream success.

**Verify:** fetch never resolves, headers arrive but body stalls, retry delay exceeds remaining budget, and upstream succeeds just before local timeout. Ensure recovery does not duplicate customer creation.

### R9 — A stale Wave query snapshot can bypass a newly scheduled retry delay

Source: `functions/wave/outbox_core.js`, `claimJob` line 270; outcome calculation in `functions/wave/dispatch.js`.

The transaction rereads the job but checks only `status === queued`. Worker A can retain an old query snapshot while worker B claims, fails, and requeues the job for later. A then claims the queued job immediately despite its fresh future `nextAttemptAt`. The dispatcher can also use the older snapshot's attempt data. The local reproduction confirms a claim succeeds with a retry time one hour in the future.

**Change:** check due time inside the claim transaction and return authoritative claimed data/version to the dispatcher. Calculate attempts and outcomes from that data, retaining ownership checks when committing.

**Verify:** requeue between query and claim, changed attempt count, transaction retries, and ownership loss during processing. Assert no premature retry and no reset of the retry budget.

### R10 — Photo rendering waits for the whole batch

Source: `lib/features/calendar/widgets/sections/photo_picker_section.dart` line 96; `lib/core/images/appointment_image_loader.dart` around line 85.

The widget awaits `loadAll` before updating its displayed bytes. A fast first image waits for slow siblings. The loader processes chunks of four, creating a barrier between chunks. The widget's retained `_loadedBytes` also sits outside the loader's 24 MiB cache budget.

**Change:** publish each image as it becomes available, prioritize visible images and nearby items, and replace chunk barriers with a bounded worker pool if measurements justify it. Bound retained widget bytes as well as cache bytes; consider thumbnail-sized decoding for grid previews.

**Verify:** time to first visible photo and time to all photos under variable network latency; memory while opening multiple appointments; navigation cancellation; failures among successful images. The UI allows ten images and uploads allow large files, but actual device memory and latency were not measured in this review.

### R11 — Repeated bookings generate repeated conflict callables

Source: `lib/features/calendar/application/appointment_conflict_checker.dart` around line 26; durable rate limiting in `functions/security.js` around line 172.

The client uses `Future.wait` over one callable per planned appointment. A supported single-day repetition can produce 16 requests, repeating authorization work and contending on the same user's rate-limit document.

**Change:** accept a bounded list of windows in one authorized request, enforce a proportional work budget, and return results by appointment/window. Reuse overlapping query results where practical and bound query concurrency. Do not replace discrete windows with a single years-long scan.

**Verify:** one and sixteen bookings, mixed employee assignments, overlapping windows, partial failures, and rate limiting. Compare request count, document reads, and p95 response time before and after.

### R12 — Dashboard ranges and cached values can become stale

Source: `lib/features/dashboard/application/dashboard_providers.dart`, date/range providers around lines 16–37 and history provider from line 42.

A provider that calls the current time does not emit again just because midnight passes. A long-lived screen can retain yesterday's range, while time-dependent statuses can also remain stale. History/new-client caching needs deliberate refresh after mutations; a past week is still editable.

**Change:** reuse the existing day provider with timer/resume handling for date boundaries. Use a lightweight clock for time-only presentation changes without forcing database rereads on every tick. Invalidate mutation-sensitive caches after relevant successful writes and define their freshness policy.

**Verify:** midnight with the app open, resume after several days, timezone changes, status time boundaries, and edits affecting cached historical totals.

## Database and deployed-resource review

### Verified snapshot

| Area | Observation | Implication |
| --- | --- | --- |
| Firestore | Default database, Native mode, `nam5`, PESSIMISTIC concurrency | Keep current database unless measured requirements justify migration |
| Composite indexes | 30 deployed; matched local definitions after normalizing implicit document-name ordering | No missing or extra composites found in this snapshot |
| Recovery | Point-in-time recovery disabled | Review recovery objectives and existing backup arrangements; this does not establish that backups are absent |
| Functions | 31 active gen2 functions, Node 24, 256 MiB | No broad runtime/memory change justified by this audit |
| Minimum instances | No function-level minimum configured | Service-level overrides were not exhaustively inspected |
| Maximum instances | Usually 10; Wave trigger 2; schedulers 1 | Review explicit concurrency as well as instance limits |
| Regions | Mostly `us-central1`; upload validator `us-east1` | Measure path latency/transfer before changing region placement |
| Artifact repositories | One-day deletion policy; CLI reported approximately 0 MB in both inspected repositories | Existing image cleanup is already configured |

Three deployed schedules use `America/Toronto`: upcoming-job reminders every five minutes, daily digest at 18:00, and history purge at 03:00 on January/April/July/October 1. Changing reminder cadence changes notification timing and should be a product decision.

### Usage and realistic savings

Monitoring window: approximately September 18–October 18, 2026, ending 22:18 UTC. Daily figures use 86,400-second metric alignment, not invoice billing-day boundaries.

| Metric | Observed |
| --- | ---: |
| Document reads | 91,550 |
| Query / lookup / not-found reads | 82,439 / 6,916 / 2,195 |
| Highest aligned daily read bucket | 14,598 |
| Document writes | 3,131 |
| Highest aligned daily write bucket | 2,162 |
| Deletes in the queried metric | 17 |
| Cloud Run requests | 12,007 |
| Billable instance time metric | 7,351 seconds |
| Reminder requests | 8,641, about 72% of requests |
| Reminder billable instance time | 4,727 seconds, about 64% of instance time |

The reminder function is the largest measured invocation/time contributor. Investigate empty sweeps, redundant lookups, and query selectivity while preserving notification behavior. Metrics here do not attribute Firestore reads to individual functions.

Current read/write volume is modest relative to the eligible database's daily free allowances. Billing is enabled, but an itemized invoice/export was not reviewed, so exact dollar savings are unknown. Index-entry reads, storage, transfer, TTL deletes, and billing-account-wide free-tier sharing prevent translating these totals directly into a bill. See [Firestore pricing](https://firebase.google.com/docs/firestore/pricing) and [Cloud Run pricing](https://cloud.google.com/run/pricing).

### Database changes worth evaluating

1. **Correct query completeness first (R3/R5).** Use pagination and explicit incomplete results. Measure returned versus examined candidates and cap-hit frequency.
2. **Reduce index fanout selectively.** TTL is enabled on eight collection fields with ordinary indexes: `appointmentOverduePrompts`, `appointmentRecountClaims`, `appointmentReminders`, `appointmentSeriesNotices`, `clientRecountClaims`, `liveActivityCards`, `liveActivityTokens`, and `rateLimits`. Inventory all query consumers before exempting any expiry field. Keep TTL enabled. `live_activity_registry.js` queries expiry, so its required indexes must remain. Exemptions can reduce index maintenance/storage; they do not reduce document write count. See [Firestore best practices](https://firebase.google.com/docs/firestore/best-practices).
3. **Evaluate conflict index ordering using representative data.** Equality constraints and the more selective range ordering influence scanned entries. Use query diagnostics and latency/read measurements before replacing a working index. See [multiple-range-field guidance](https://firebase.google.com/docs/firestore/query-data/multiple-range-fields).
4. **Make derived records converge reliably (R4/R6).** More summary collections add consistency obligations. Fix the existing ones before adding dashboard summaries for speculative savings.
5. **Batch repeated work (R11).** Reduce callable/auth/rate-limit overhead without removing per-user protection or creating unbounded backend work.
6. **Set recovery objectives.** Document acceptable data loss and restoration time, inspect backups, and evaluate PITR cost against those objectives. Do not enable billable recovery features solely as a performance change.

Avoid a blanket index deletion, global cache, database migration, or new summary layer at this usage level. Those changes need a measured problem and a clear freshness/consistency contract.

### Safe rollout for a scheduling-blocking field

- Define status-to-flag semantics and identify every writer, including older clients and administrative tools.
- Establish enforcement so new writes cannot violate the invariant; plan compatibility for clients that omit the field.
- Backfill existing documents with restartable progress and validate the results.
- Deploy required indexes and compare old/new query results on representative cases.
- Switch readers only when completeness is established; preserve a rollback path.
- Test concurrent status changes throughout the migration. Do not depend solely on an eventually running trigger to make a conflict disappear or appear correctly.

## Longer-term maintainability

- **Centralize invariants, not every implementation detail.** Document appointment revision semantics, legal status transitions, derived-field ownership, queue ownership, and reconciliation rules. Keep shared Dart/JavaScript contract fixtures where rules cross client/backend boundaries.
- **Use state machines for durable work.** Give uploads and outbox jobs explicit recoverable states and transition tests. Treat process termination as a normal recoverable event.
- **Separate operational explanations from executable code.** Move long historical narratives to decisions/runbooks and retain concise invariant comments beside the implementation. Correct comments that contradict actual deployment behavior.
- **Build on existing CI.** Flutter analysis/tests, backend checks, and emulator smoke coverage already exist. Add the missing concurrency, interruption, and ordering cases instead of replacing the test infrastructure.
- **Measure user-visible outcomes.** Track sampled, privacy-safe save latency, first-photo latency, conflict/search cap hits, queue age, retry counts, and stale-write rejections. The local opt-in performance tracing is useful but does not establish release p50/p95 performance.
- **Keep recovery runbooks explicit.** Account-operation locks intentionally protect external Auth side effects. Do not add automatic expiry without a fencing/recovery design. Document how to verify and recover a stranded operation.
- **Profile synchronous cache work before refactoring it.** Disk-cache metadata scans can affect responsiveness; measure them on representative devices and move work off the UI path only if the profile supports it.

## Implementation order and acceptance

1. **Protect user data:** implement R1 and R2 with restart and two-editor tests.
2. **Protect scheduling and denormalized data:** implement R3, R4, and R6; add reordering and contention tests.
3. **Harden Wave:** implement R7–R9 together; verify deployed concurrency and queue recovery under slow/upstream-failure scenarios.
4. **Improve responsiveness:** implement R5, R10–R12, recording before/after measurements.
5. **Tune database cost:** evaluate TTL-only exemptions and reminder empty-sweep work; compare observed reads, latency, storage, and invoice data.

Use small independently reviewable changes. Each production change should include regression tests, deployment verification where relevant, a rollback method, and a short observation period. Do not promise a percentage speedup or dollar saving before measuring it.

## CI and deployment workflow review

Added October 18, 2026. Reviewed `.github/workflows/ci.yml`, `.github/workflows/deploy.yml`, `.github/dependabot.yml`, `tool/test.dart`, backend coverage configuration, deploy helper scripts/tests, emulator smoke checks, and the native iOS test scheme. Also read GitHub run history and repository protection settings. No workflows, GitHub settings, IAM roles, or deployments were changed.

### What already works well

- Flutter and backend jobs run in parallel; Flutter SDK and action revisions are pinned. Checkout credentials are not persisted.
- Backend installs use a lockfile, and Jest enforces global coverage thresholds. Flutter coverage is retained as an artifact.
- The emulator suite exercises real Storage authorization plus Firestore/Auth account, deletion, and building-reconciliation scenarios. It is more than a syntax check.
- Production deployment verifies the resolved commit through the reusable CI workflow. The deploy job has a separate production environment and narrowly scoped GitHub permissions; dependency install scripts do not run with deployment credentials present.
- Production deployments are serialized and do not automatically cancel a running deployment. Index deployment precedes the remaining targets for an `all` release, and the workflow waits for indexes to become ready.
- Function removal checks, allowlist compatibility checks, and deploy helper tests already exist. Retain these protections.

### Measured baseline and repository settings

The latest inspected [CI run](https://github.com/gvogas/Scheduling-App/actions/runs/39165160078) started October 18 at 4:50 p.m. New York time and completed successfully in approximately 3 minutes 6 seconds. Its Flutter job took 3 minutes 2 seconds, including 2 minutes 4 seconds of testing and 30 seconds of analysis. The backend job took about 50 seconds, including 8 seconds of Jest and 21 seconds of emulator checks. All 13 CI runs in the latest 15-run sample succeeded; the other two entries were Dependabot maintenance runs. This is a small sample, not a long-term reliability estimate.

The sample includes adjacent push/PR runs on `dev`, including [push](https://github.com/gvogas/Scheduling-App/actions/runs/39160882180) and [pull request](https://github.com/gvogas/Scheduling-App/actions/runs/39160885045) runs starting two seconds apart. The workflow explicitly subscribes to both events.

GitHub's legacy protection endpoint returned `Branch not protected` for `main`, and the effective branch-rules endpoint returned no rules for `main` or `dev`. The production environment does have a required reviewer, permits self-review, and limits deployment branches to `main`. Environment approval therefore exists, but it does not require passing CI before code enters `main`.

### CI1 — P1: Enforce the existing checks before merge

**Evidence:** live GitHub settings described above; `ci.yml` has no authority to require its own results before merge.

**Recommendation:** configure a `main` ruleset requiring pull requests and the two existing CI checks, with an explicit and limited bypass policy. Require current-base verification or a merge queue only if the team's merge volume needs it. If introducing a merge queue, add its event trigger and verify the checks execute there before making them required. Decide whether `dev` also needs required checks. Do not require a second human reviewer if that would deadlock a solo-maintainer workflow.

**Acceptance:** a deliberately failing PR cannot merge through the normal path; a passing PR can; deployment approval still works independently. Required check names must match the emitted check names, not merely the workflow title.

### CI2 — P1: Add native iOS build and test coverage

**Evidence:** both CI jobs use Ubuntu and no workflow invokes Xcode. The repository contains Swift application/extension code and `RunnerTests`, including CarPlay tests; the shared Runner scheme includes the test target. Dart analysis and widget tests cannot detect Swift compilation, native linking, or target-membership errors.

**Recommendation:** add a macOS job using a deliberately selected Xcode toolchain. Build the iOS simulator app and run `RunnerTests`, with safe CI configuration values and no production credentials. Ensure extension targets are included. Begin with relevant changes (`ios/**`, Dart application code, plugin/lockfile changes, shared fixtures, and the workflow itself) plus a full release gate. Keep signing/archive and physical-device entitlement checks as separate release validation; a simulator build does not prove those.

**Acceptance:** a Swift compile error or failing native test makes the required release check fail. Record the toolchain version and upload the test result bundle on failure. Measure added macOS minutes before deciding to run it on every documentation-only change.

### CI3 — P2: Check target-specific deployment permissions before mutations

**Evidence:** [deployment run 38257420742](https://github.com/gvogas/Scheduling-App/actions/runs/38257420742), October 12 at 9:41 a.m. New York time, passed both verification jobs and failed during deployment with HTTP 403 for `firebasestorage.defaultBucket.get`. Its deployment-record job was skipped. This is a historical failure, not proof the permission remains missing today.

**Recommendation:** after authentication and before deploying any target, perform read-only preflight requests for the selected targets, including Storage bucket discovery when Storage is requested. Document the exact required permissions and grant only what is necessary if the problem persists. Keep tests independent of production IAM. A preflight detects known prerequisites; it cannot guarantee every later deploy operation succeeds.

**Acceptance:** missing discovery permission fails before index/rule/function mutations, with an actionable message. A permitted run reaches deployment. Do not solve the failure with blanket Owner access.

### CI4 — P2: Verify deployed configuration, not only exported names

**Evidence:** `deploy.yml`'s `Verify by name` calls `functions/scripts/deploy/export_diff.js`; this compares names, not concurrency, state, runtime, region, or trigger settings. It would not catch the Wave mismatch in R7.

**Recommendation:** retain name checks and add an explicit expected-configuration manifest for critical functions. Compare deployed state and relevant limits, especially Wave concurrency and max instances, runtime/region, trigger/retry settings, and schedules. Add safe smoke checks for critical callable paths using an isolated test identity/data strategy; do not create real appointments or send notifications as a generic smoke test.

**Acceptance:** a matching function name with incorrect concurrency or an unhealthy deployment fails verification. Persist the resolved source SHA and observed configuration in the release evidence.

### CI5 — P2: Preserve evidence of failed or partial deployments

**Evidence:** the `record` job depends on successful deployment. Deploy output and before/after snapshots are not uploaded as artifacts, and the after-deploy inspection normally skips when the deploy command fails. The compatibility baseline is read from manually merged deployment-log rows; if neither baseline resolves, the check only warns and proceeds.

**Recommendation:** upload explicitly allowlisted, sanitized deployment logs and snapshots on success or failure, using a short retention period. Never upload the workspace wholesale: authentication creates a credentials file. After an attempted mutation, run best-effort read-only state inspection without hiding the original failure. Record an attempt as failed/partial/verified rather than describing every attempt as a successful release. Maintain an authoritative last-verified deployment SHA, and fail a normal compatibility check when its baseline is unavailable; provide a documented bootstrap/recovery procedure.

**Acceptance:** force a simulated failure after one target completes and confirm the report identifies the mixed state. A pending deployment-log PR must not silently cause subsequent compatibility checks to compare against an obsolete release. The current historical 403 establishes a failed run, but does not establish which resources, if any, changed during it.

### CI6 — P2: Enforce dependency and generated-model reproducibility

**Evidence:** CI runs `flutter pub get` and `flutter gen-l10n`, but not Freezed generation, a generated-file diff check, or a lockfile-drift check. Freezed sources are committed; localization output is intentionally ignored.

**Recommendation:** enforce the committed Pub lockfile during CI dependency resolution, then run the pinned code generator and fail on changes to tracked generated model files. Check for newly generated untracked model files as well as tracked diffs. Continue generating ignored localization output without demanding it be committed. Validate the exact command with the pinned Flutter SDK; Dart documents the lockfile enforcement option in [pub get](https://dart.dev/tools/pub/cmd/pub-get).

**Acceptance:** editing a model while leaving its generated output stale fails CI, as does a dependency declaration incompatible with the lockfile. A clean checkout regenerates without tracked changes.

### CI7 — P2: Reduce redundant runs and bound stalled work

**Evidence:** push/PR overlap is visible in run history. `ci.yml` has no cancellation policy, and neither workflow declares job timeouts. The only explicit long-operation deadline is the deploy index-ready loop.

**Recommendation:** cancel superseded PR verification runs, but keep production deployment serialization/non-cancellation. Because CI is also called from deployment, isolate concurrency groups by event/caller purpose so a new ordinary CI run cannot cancel deployment verification. GitHub specifically documents [reusable-workflow concurrency collisions](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations). Preserve PR merge-result checks; decide whether separate `dev` push checks are needed when a PR already covers the work. Do not deduplicate blindly by source SHA because push and PR checkouts can differ.

Set explicit timeout budgets, initially about 15 minutes for Flutter and 10 minutes for the backend, then tune from history. Give deployment enough room for its existing 45-minute index wait plus deploy operations; do not copy the short CI timeout there. GitHub's default job timeout is 360 minutes: [workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

**Acceptance:** updating a PR cancels only its obsolete verification; a release remains unaffected. A deliberately stalled emulator exits within the chosen budget. Reduced duplicate work saves runner usage, but no invoice saving has been calculated.

### CI8 — P2: Expand behavior-based regression checks

**Evidence:** emulator integration coverage already exists, while several Dart security tests inspect rule text. `tool/check_rules.dart` enforces application coding conventions; it is not a Firebase authorization test runner. The Functions emulator is not started, and helper `.run()` calls in smoke tests do not exercise the full callable HTTP boundary.

**Recommendation:** add role/status/assignment allow-and-deny cases against actual Firestore rules for important appointment operations, especially employee updates and multi-field writes. Retain useful source-contract checks, but do not treat them as an authorization proof. Add the ordering, stale-write, upload interruption, and retry cases from R1–R9 to the appropriate unit/emulator/device layer. Add selected callable transport tests only where boundary behavior matters; do not move every fast unit test into an emulator.

**Acceptance:** changing a relevant allow/deny decision fails a behavioral test. The regression scenarios assert correct outcomes, not the intentionally faulty expectations in the review demonstration script.

### CI9 — P2: Extend dependency maintenance to application dependencies

**Evidence:** `.github/dependabot.yml` covers GitHub Actions and `/tools/deploy` npm dependencies only. `/functions` and root Pub dependencies are absent from this update configuration. This does not establish that repository vulnerability alerts are disabled.

**Recommendation:** add scheduled update coverage for backend npm and Pub packages, with manageable PR limits/grouping and deliberate major-version review. Keep exact SDK/runtime changes reviewed together with local tooling and CI. Do not auto-merge major plugin updates before native iOS checks exist. Report actionable dependency risks rather than adding a noisy blanket failure gate without a remediation policy.

**Acceptance:** backend and Flutter dependency updates receive automated PRs and the appropriate test/build checks. Lockfile changes remain reviewable.

### CI10 — P3: Improve test diagnostics before further sharding

**Evidence:** Flutter tests dominate the latest run, but total latency is already about three minutes. `tool/test.dart` combines test files into six shared isolates and resets two plugin stores. Other global state and per-file configuration may still need isolation. Flutter coverage is uploaded without a regression gate; upload steps warn rather than fail when coverage is missing.

**Recommendation:** retain the fast shard runner, add a periodic or manual isolated `flutter test` run to detect order/isolation differences, and test several shuffled orders when investigating flakes. Track slow tests before adding more runners. Add a baseline or changed-code coverage policy for testable business logic with explicit exclusions, rather than a blanket threshold over device-only paths. Require a coverage artifact after a successful test step; permit missing coverage following an earlier failure. Add workflow/shell validation and format checks as short early checks, and retain concise test reports for diagnosis.

**Acceptance:** shard and isolated runs agree, a missing successful-run coverage report is visible as a failure, and added checks stay within an agreed latency budget. The current global backend thresholds should remain in place.

### Recommended CI rollout

1. Enforce merge checks and add native iOS verification.
2. Add deployment permission preflight, configuration verification, and failure evidence.
3. Enforce model/lockfile reproducibility and add the high-risk behavioral tests.
4. Add scoped PR cancellation, timeouts, and dependency maintenance.
5. Measure again before introducing more caches, runners, or test sharding. In the inspected run, backend dependency install was only three seconds and deploy-tool install four seconds; those are not the primary bottleneck.

Validation for this CI review consisted of source inspection and read-only GitHub API/log inspection, plus official documentation checks for the proposed workflow semantics. No new workflow run, native build, or production permission test was executed. Repository settings and timings are point-in-time observations; the historical deployment failure should be rechecked before changing IAM.

## Widgets, CarPlay, Siri, Live Activities, and Flutter UI review

Added October 18, 2026. Reviewed the native schedule widget and timeline, Siri snapshot decoder/intents, CarPlay scene/store/template/image/bridge code, Dart mirror services and listeners, Live Activity presentation and registration, calendar cards/agendas/month grid, and address autocomplete. Findings below are code traces unless a test result is explicitly identified. Native execution requires macOS/Xcode and was not performed on this Windows host.

### Preserve these design choices

CarPlay and Siri read an App Group snapshot without requiring a Flutter engine or network connection. CarPlay installs its root once, updates list sections in place, limits rows, uses bounded image caching, and wraps engine-dependent callbacks in one-shot completions. Flutter agendas use lazy slivers and a cached day index; the month grid handles calendar arithmetic and larger text. These are useful foundations. A wholesale state-management or UI rewrite is not justified by this review.

### W1 — P1: Clear an open CarPlay detail when the session is cleared

**Source:** `ios/Runner/CarPlay/CarPlaySceneDelegate.swift`, `rebuild` around line 132; `CarPlayScheduleStore.swift`, `reload`; `lib/core/app/app_sync_listeners.dart`, `_snapshotSync`.

The Dart listener writes/clears the shared snapshot and then notifies CarPlay. The store reloads it, but the scene postpones every rebuild while a detail or alert is visible. Consequently, sign-out can clear the shared data while the detail still displays the previous user's appointment and retains its action closures. Ordinary appointment edits can also leave an open detail stale. This is a visible-data/session problem; backend authorization still controls writes.

**Change:** distinguish session invalidation from a routine list refresh. On sign-out, inactive-account transition, or account switch, dismiss sensitive details/alerts and render the cleared state immediately. For normal edits, reconcile the open detail by appointment ID, or close it with an informative message when removed. Include an owner/session identifier in the shared snapshot so a switch is distinguishable from a normal content update.

**Verify:** leave a detail open, sign out on the phone, and confirm names/addresses/actions disappear without a back tap. Repeat for account switching, assignment removal, appointment deletion, and an alert over the detail.

### W2 — P2: Keep reused CarPlay handlers synchronized with current data

**Source:** `CarPlayTemplateBuilder.swift`, `refreshToday` line 221, `refreshWeek` line 326, `row` around line 450, and `rowKey` line 483.

Refresh compares a rendering key and skips replacing sections when the key is unchanged. However, a retained row's selection closure captures the appointment used when it was created. Its key omits `endMillis`, multi-day metadata, and other nonvisible detail data. For example, changing the end of a later job while keeping its start/text/display state unchanged can preserve the old handler; tapping it opens the old time range. This can persist across minute ticks while the rendering key stays unchanged.

The rendering key also omits `presentation.style`, even though avatar/accessory images depend on it. A day/night change can build new images and then discard them because the comparison says nothing changed. The scene does not implement a dedicated content-style refresh path.

**Change:** resolve the latest appointment by ID when selecting a row. Keep visual equality separate from action-data equality, or refresh handlers independently. Include appearance-dependent state in the visual key and respond to appearance changes. Preserve the existing in-place update behavior and scroll position.

**Verify:** change only a later job's end time and tap its existing row; change multi-day metadata; toggle the head unit between day/night. Assert current detail data and image colors without resetting the selected tab.

### W3 — P2: Resolve widget jobs against each timeline entry's date

**Source:** `ios/ScheduleWidget/ScheduleWidget.swift`, `SchedulePayload.resolved` around line 98, `DaySchedule.nextJob`, and `Provider.getTimeline` around line 153; Dart/server widget payload builders.

The payload builders filter timed jobs against the time they build the payload. Swift seeds later timeline entries at job starts but reuses the same arrays without filtering them against the entry date. A widget built before a 09:00 and 11:00 visit can still select the 09:00 visit after it starts. Hourly timeline reloads reread the same stored bytes and do not fix this. If `rolloverAt` is null, an unchanged payload can also keep yesterday's jobs under the old date; if rollover is set, `isTomorrow` stays true even once that date becomes today.

**Change:** resolve the actual calendar day and job eligibility for every entry. Define whether a timed visit remains visible while in progress; include end times if that is the policy. Add midnight and relevant start/end boundaries, and show an explicit stale/out-of-window state when the payload cannot cover the current day. Retain all-day and multi-day semantics in both builders and Swift.

**Verify:** a frozen payload across 09:00, 11:00, midnight, and the end of the two-day window, with no foreground app or push. Check the small widget's deep-link target as well as text/counts. Apple's reload budget means a requested hourly reload is not a freshness guarantee: [WidgetKit guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

### W4 — P1: Guard background widget writes by session and revision

**Source:** `lib/core/notifications/fcm_background_handler.dart`; `writeWidgetPayloadJson`, `WidgetSyncService.sync/clear` in `widget_sync_service.dart`; snapshot writer in `schedule_snapshot_service.dart`.

The background handler accepts any nonempty `widgetPayload` string and writes it directly. It does not check its owner against the current session or compare versions. The widget payload itself carries no owner identifier. A delayed message can therefore replace newer stored data, including after a local clear/account switch if that message reaches the handler. This is a conditional delivery path, not evidence that such a message was observed in production.

Foreground deduplication remembers only its last successful signature in memory. If a background write changes the shared value, a later foreground sync with that remembered signature is skipped, leaving the externally written value in place. The two mirror services also have no explicit serialization/generation contract across overlapping apply/clear calls; verify actual native completion ordering before claiming an on-device race there.

**Change:** create one shared mirror envelope with owner/session generation, schema, source revision, and coverage dates. Reject older or wrong-session updates at the write boundary, and make logout invalidate that boundary durably. Account for cross-isolate/process writes when deduplicating; an in-memory signature is not an authority for shared storage. Serialize local desired-state changes and let clear/session change supersede obsolete work.

**Verify:** deliver old pushes after a newer foreground write, after logout, and after switching users. Alter shared storage externally, then resync an unchanged foreground payload. Assert no former-user data or stale payload wins.

### W5 — P2: Treat a CarPlay write timeout as an unknown outcome

**Source:** `ios/Runner/CarPlay/CarPlayBridge.swift`, ten-second write timeout; Dart `carplay_bridge.dart`, `_writeStatus`; `firebase_appointments_repository.dart`, `updateAppointmentStatus` around line 338.

Swift reports `false` at the timeout and unlocks the action, but it does not cancel the Dart/Firestore operation. The Dart offline precheck uses transport connectivity; a connected network can still fail to reach the backend or disappear after the check. A pending write can commit later, after the driver was told it failed. A stale Start action also sends only an ID and target status; for a permitted administrator it can overwrite a newer completion without checking the expected prior state.

**Change:** return distinct confirmed-success, confirmed-rejection, and pending/unknown outcomes. Reconcile a pending operation by ID rather than encouraging blind retries. Validate allowed transitions against current state and expected revision in a server-authoritative transaction. Do not equate a UI timeout with write cancellation. Firestore documents queued offline writes in its [offline-data guidance](https://firebase.google.com/docs/firestore/manage-data/enable-offline).

**Verify:** connectivity loss after the precheck, acknowledgment after ten seconds, retry before the first acknowledgment, and a remote completion before a stale Start tap. Assert no status regression or misleading confirmed failure.

### W6 — P2: Fence CarPlay callbacks to their scene and selection

**Source:** `CarPlaySceneDelegate.swift`, `showDetail`, `pushDetail`, `writeStatus`, and disconnect handling.

A phone lookup returns asynchronously and then pushes a detail if any scene is active. It carries no connection-generation or selection token. If the car disconnects and reconnects before the callback, the old selection can open in the new connection. Multiple quick taps can also let whichever lookup finishes first choose the detail. Status completion similarly operates on the delegate's current controller rather than the controller/operation that initiated it.

**Change:** use a scene generation incremented on connect/disconnect and a latest-selection generation. Capture them with each asynchronous operation and discard callbacks that no longer belong to the active scene/selection. Fence write UI completion separately from the backend operation's eventual reconciliation.

**Verify:** reconnect during phone lookup, select A then B with B's reply arriving first, and reconnect during a status write. Assert old callbacks do not push/pop templates or clear a newer operation's busy flag.

### W7 — P2: Distinguish snapshot age, coverage, and truncated counts

**Source:** `ios/SiriIntents/ScheduleSnapshot.swift`, `load` and `generatedAt`; Siri count/day intents; `lib/features/siri/domain/schedule_snapshot.dart`, per-day cap and serialization around lines 102–114.

The decoder accepts supported versions without an age/coverage policy. Siri treats a missing today's bucket as an empty day in several intents, although it can mean the app has not refreshed the snapshot for more than its lookahead window. The builder also truncates each day to 30 appointments without including the original total or truncation flag. `AppointmentCountIntent` counts the retained array, so 31 jobs can be reported as 30. CarPlay consumes the same capped snapshot before applying its own visible-row budget.

**Change:** carry coverage bounds, total counts, and truncation metadata. Say when data is unavailable or partial instead of claiming no jobs or an exact truncated count. Define an offline freshness policy and display when the schedule was last confirmed. Because signatures intentionally exclude `generatedAt`, decide whether it means content last changed or data last verified; use separate fields if both matter. Do not make an age cutoff that silently blanks a useful offline schedule.

**Verify:** more than 30 jobs in a day, an expired eight-day snapshot, a missing bucket within otherwise valid data, and unchanged data freshly confirmed by the app. Add compatible optional fields and native decode fixtures before changing readers.

### W8 — P2: Display Live Activity staleness and verify clock-boundary behavior

**Source:** `ios/ScheduleWidget/JobLiveActivity.swift`, `LockScreenCard` and countdown branches; `functions/live_activity_dispatch.js`, update payload around line 300.

The server supplies a stale date, but the native view never reads `context.isStale`. When expected updates are missed, the card continues to present its client/address/phase without a stale indication. Updates use the scheduled start as stale date, including updates produced after that instant, so simply adding a badge would risk labeling normal on-site cards stale immediately.

The amber/red choice and countdown-versus-elapsed branch use `Date()` during body evaluation. A system-updating timer text is useful, but does not establish that surrounding Swift conditions will reevaluate at the deadline. The source already acknowledges the unscheduled color transition.

**Change:** define phase-specific freshness deadlines server-side and render an appropriate stale state. Use supported system time presentation for deadlines; verify end-boundary behavior before promising an automatic countdown-to-elapsed switch. Add boundary updates only where operationally justified. See Apple's [Live Activity guidance](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

**Verify:** suppress APNs updates across departure, scheduled start, and scheduled end; wake the device later; reschedule while the card is visible. Check Lock Screen and each Dynamic Island presentation on hardware. Native redraw behavior remains unverified here.

### W9 — P2: Drive calendar display status from an observable clock

**Source:** `lib/features/calendar/domain/models/appointment_record.dart`, `displayStatus` line 131; `appointment_card.dart`; `main_calendar_screen.dart`, current-day watch around line 354.

Appointment cards derive status using `DateTime.now()` when they build. The calendar watches a day-boundary provider, but has no corresponding emission at an appointment's start/end. If data and UI state do not change, a visible pending card can remain pending after the start, or in-progress after the end, until another rebuild. Existing date-boundary handling does not solve within-day status transitions.

**Change:** share a presentation clock or schedule the next relevant transition for visible content and refresh on resume. Pass an explicit time to the display-status calculation. Limit rebuild scope to affected presentation and reuse existing data; do not reopen database streams every tick. Apply the same contract to dashboard timing in R12.

**Verify:** keep a calendar visible across start/end without touching it or emitting database updates; background and resume across the boundary; include multi-day work and personal/time-off rules.

### W10 — P2: Invalidate address lookups when the user changes the query

**Source:** `lib/shared/widgets/fields/address_autocomplete_field.dart`, `_onTextChanged`, `_fetch`, and `_selectSuggestion`.

The request ID increments when a debounced fetch starts, rather than immediately when text changes. Deleting a query to fewer than three characters clears suggestions but leaves the old request ID valid; its late result can repopulate the dropdown. Editing to a different query also leaves a debounce interval in which the old response is accepted. The explicit clear button correctly invalidates requests, which makes keyboard deletion behave differently.

The details request has a mounted check but no corresponding selection/query generation check before it writes the controller. Typing a replacement while details load can be overwritten by the old selection's response.

**Change:** invalidate immediately on meaningful text edits, including keyboard deletion, and separately fence details resolution to the selected suggestion and controller revision. Preserve the apartment text captured for that selection rather than reading mutable shared state after the request. Keep session-token reuse and successful-query deduplication.

**Verify:** hold autocomplete pending, backspace to an empty field, and complete the old response; edit during the debounce; hold place details pending, type a replacement, and finish the old request. Assert old requests cannot restore suggestions or replace current text. Existing stale-response tests cover a newer fetch already starting, not all of these gaps.

### UI optimization candidates to measure

- Profile `AppointmentCard`'s `IntrinsicHeight` on dense agenda scrolling; consider a layout that paints the crew rail without an intrinsic pass if layout cost is material. Current sliver laziness is already beneficial.
- Memoize native date formatters by language/calendar/timezone where profiling supports it. `CarPlayStrings` and widget time labels construct formatters repeatedly; row caps make this a bounded cost, so measure before introducing complex caches.
- Keep reduce-motion behavior consistent across tap/fade animations and test VoiceOver, long French strings, and accessibility text sizes on the actual surfaces. `FadeInItem` already avoids initial animation when reduce motion is set.
- Add shared JSON fixtures spanning Dart, server JavaScript, and Swift decoders. Include all-day/multi-day/overnight appointments, old supported schemas, missing optional fields, malformed dates, large schedules, and EN/FR data. Keep the `homeWidget` deep-link marker required by the current plugin.
- Treat lock-screen detail exposure as an explicit product policy. Siri intents deliberately use `alwaysAllowed`, and admin snapshots contain the broader business schedule; confirm that behavior is intended and test it on a locked device rather than assuming authentication or redaction.

### Validation for this extension of the review

Executed the existing focused Flutter command:

```text
flutter test --no-pub test/features/home_widget test/features/siri test/features/live_activity test/core/app/carplay_bridge_test.dart
```

Result: **126 passed, 1 failed**. The failure is `widget_payload_provider_test.dart`, “an admin payload is scoped to the admin own crew / a colleague job is absent from the payload.” It accesses `currentDayProvider` and constructs `AppLifecycleListener` without an initialized widgets binding. This is a reproducible test-isolation/setup defect, not a demonstrated production permission defect. Initialize `TestWidgetsFlutterBinding` in the test or override its time/lifecycle dependency. The earlier green sharded CI result and this isolated failure strengthen CI10's recommendation to verify isolated execution; the precise masking mechanism was not established.

An additional focused run of `address_autocomplete_field_test.dart`, `address_autocomplete_field_flag_test.dart`, `appointment_card_test.dart`, `calendar_month_grid_test.dart`, and `agenda_sliver_list_test.dart` passed **67 tests**. Across both runs, **193 tests passed and 1 failed**. The passing address tests do not exercise every edit-during-request scenario described in W10.

Native Swift tests and simulator/hardware scenarios above remain required before implementing or shipping these fixes. No UI frame-time, battery, or memory improvement is claimed without device measurements. The additional findings were documented; application implementation was not changed.

## Accessibility, notification delivery, offline recovery, and account switching

Added October 18, 2026. Reviewed semantic controls/photo navigation, token registration and teardown, notification fan-out and sweep claims, session exit and external-link handling, pending upload persistence, and connectivity/cache behavior. This extends W1–W10 and R1/R2; repeated mechanisms are cross-referenced instead of counted as new defects. No application fixes or production changes were made.

### Existing protections worth keeping

- Cached auth identity is UID-matched and does not cache a privileged role. Account-document streams follow the settled auth UID.
- Search/history caches use generations when asynchronous scans finish, and the photo disk cache invalidates late writes on clear. These are good models for the remaining session-sensitive operations.
- Upload entries include both owner UID and employee document ID. Unknown/legacy owners are not uploaded under another account.
- Notification recipients are checked for active status and permitted role; recipients are isolated so one failed send does not abort the rest. Invalid FCM tokens are pruned from send responses.
- Forced account exit has a reentrancy guard; cleanup errors are logged individually. Accessibility themes already support Bold Text/Increase Contrast, calendar cells carry date labels, and several animations respect Reduce Motion.

### A1 — P1: Restore accessible activation for custom picker controls

**Sources:** `lib/shared/widgets/fields/sheet_field_row.dart`, semantic wrapper around line 58; `lib/features/calendar/widgets/fields/appointment_status_picker.dart`, wrapper around line 30. Similar wrappers occur in employee/date controls and should be checked individually.

Both controls set `excludeSemantics: true` on a labeled parent but leave activation on a child gesture/ink widget. The parent does not supply `Semantics.onTap`. The review's semantic-tree checks confirm these rendered controls have no `SemanticsAction.tap`; the date-picker row still responds to a pointer tap. A label and button role alone do not provide screen-reader activation.

**Change:** give the semantic node the same enabled action as the visual control, or preserve/merge the child action without duplicating labels. Prefer standard accessible controls where they fit. Review disabled states and keyboard/switch focus as well as labels. Flutter defines [semantic onTap](https://api.flutter.dev/flutter/semantics/SemanticsProperties/onTap.html) as the handler for that action.

**Verify:** semantic-action tests activate the date/status controls, then a real VoiceOver user can select dates, employees, and statuses without touch exploration being the only route. Disabled choices must expose no active action. Inspect each similar wrapper rather than assuming every one has the same defect.

### A2 — P2: Include validation errors and photo actions in the accessible description

**Sources:** `sheet_field_row.dart`, semantic label around lines 60–65 and `errorText` rendering around line 118; `appointment_image_carousel.dart`, tappable image builder; `photo_picker_section.dart`, existing/new thumbnail builders.

The picker row excludes descendant semantics, but its replacement label contains label/value/trailing text only. Its visible validation error is therefore omitted from that semantic description. Photo thumbnails/carousel images have tap handlers but no useful application-provided image label such as “Photo 2 of 4, open full screen.” A generic image/tap announcement does not distinguish the user's photos.

**Change:** include the error in the field's semantic value/description and announce new validation failures appropriately. Provide localized photo index/count and action labels, loading/unavailable states, and meaningful focus order. Retain the existing labeled removal controls. Consider the explicit 1.3 text-scale cap on status pills as an accessibility tradeoff: test whether surrounding full-size labels provide an adequate alternative before keeping it.

**Verify:** trigger a required-field error under VoiceOver, navigate every photo and removal action, and test large text in EN/FR. Add semantic content/action tests alongside the existing layout/contrast tests. No full VoiceOver or contrast audit was performed on this Windows host.

### N1 — P1: Retry failed token registration instead of caching it as success

**Sources:** `lib/features/notifications/data/fcm_token_repository.dart`, `upsertToken`; `push_registration_controller.dart`, `_syncGuarded` and its registered-UID/locale fast path.

`FcmTokenRepository.upsertToken` catches read/write failures and returns normally. The caller then sets `_registeredUid`, `_registeredToken`, `_registeredLocale`, and a refresh subscription. Later sync calls return immediately for the same UID/locale/subscription, even if no token document was saved. An initial transient failure can therefore disable delivery for the session without making later account emissions repair it. Existing tests explicitly verify both swallowing write failure and the successful fast path, but not their combined recovery behavior.

**Change:** return a typed success/failure result or let the controller contain a retriable error. Mark registration successful only after acknowledgment; retain a dirty registration and retry with bounded backoff on suitable events such as resume/reconnection. Distinguish OS authorization, local token availability, and confirmed server registration in diagnostics. Avoid repeatedly prompting permission or churning tokens to recover a simple write failure.

**Verify:** fail the first real repository read/set, restore connectivity, and sync again with the identical token. Confirm a token row is eventually written and only then qualifies for the fast path. Also test APNs token initially unavailable and authorization changing in Settings. See [FCM registration guidance](https://firebase.google.com/docs/cloud-messaging/manage-tokens).

### N2 — P2: Expire time-sensitive notifications when they stop being useful

**Source:** `functions/notification_utils.js`, `sendToEmployee` around lines 131–171.

The common builder adds notification text, data, and APNs sound/content flags, but no explicit APNs expiration or business validity deadline. A departure nudge, overdue prompt, or digest can remain eligible for delayed delivery after its intended window. `time-sensitive` changes presentation priority; it does not encode the appointment's expiry.

**Change:** define validity by notification kind. Set the Apple-platform expiration header for this iOS app and appropriate TTLs for any supported additional platform. Include event ID/source revision/valid-until metadata so foreground and tap handling can identify obsolete events. Do not discard meaningful cancellation/change alerts using the same very short lifetime as departure reminders.

**Verify:** hold a device offline past departure/end/digest relevance, reconnect, and check what is displayed and opened. Preserve useful current messages. FCM documents message lifetime and default retention in its [lifespan guidance](https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan); platform delivery remains best effort.

### N3 — P2: Prevent capped overdue sweeps from starving older candidates

**Sources:** `functions/notification_sweeps.js`, `runOverduePromptSweep`; `functions/appointment_scan.js`; `notification_policy.js`, 500-candidate cap and two-hour lookback.

The sweep repeatedly selects the newest 500 open jobs by end time. Jobs already prompted remain open and remain in the next query; ledger deduplication happens after the capped read. An older eligible job beyond the cap can therefore remain excluded on every run until it ages out, even if no new jobs arrive. The log says the oldest jobs are deferred, but no cursor guarantees they will be reached. This requires a much larger candidate set than current measured traffic and is a scaling correctness issue, not evidence of present missed alerts.

**Change:** page through eligible candidates within a bounded run budget, retaining progress if needed, or query explicit pending reminder work. Distinguish deliberately skipped, already delivered, transiently failed, and not-yet-scanned work. A cap warning alone does not provide eventual processing.

**Verify:** more than 500 open eligible jobs, first page already delivered, no new activity, and repeated sweeps through the full lookback. Assert every eligible recipient is reached or explicitly reported as unprocessed before expiry.

### O1 — P1: Bound remote cleanup so offline sign-out can finish

**Sources:** `lib/core/app/device_deregistration.dart`, `deregisterThisDevice/_step`; `account_exit_controller.dart`, `exitAccount`; settings `delete_account_flow.dart`, `signOut`; push token deletion.

Teardown awaits push, presence, and Live Activity cleanup sequentially before local cache clearing and `AuthService.signOut`. `_step` contains exceptions but supplies no deadline. A future that remains pending does not throw: an offline token-document delete or stalled remote lookup can leave the user signed in and delay local cleanup indefinitely. The existing “never rethrows” test covers immediate failures, not unresolved futures.

**Change:** invalidate session-sensitive work immediately, give remote cleanup an explicit bounded budget, and ensure local exit proceeds under a clear policy. Keep the best-effort authenticated cleanup opportunity, but record/reconcile incomplete deregistration through a safe ownership-aware mechanism. Treat timeout as a limit on waiting, not proof the underlying operation was cancelled. Server recipient checks and device/session ownership remain necessary.

**Verify:** make the first teardown future never complete; the user still reaches a locally cleared signed-out state within the budget. Repeat for every cleanup stage, application suspension, and failed sign-out rollback. Ensure late completions cannot repopulate state for the next account.

### O2 — P1: Make loss of queued photos an explicit account-exit decision

**Sources:** `device_deregistration.dart`, unconditional `imageUploads.clearPending`; `appointment_image_upload_service.dart`, `clearPending`; `pending_upload_store.dart`, seven-day prune; settings sign-out flow.

Every normal device teardown clears pending uploads and deletes their staged files. The settings sign-out path does not first inspect the pending count or offer a pending-work choice. A user who signs out while a retryable photo batch exists loses those local photos. Automatic expiry also deletes staged files older than seven days without an explicit per-batch recovery outcome. This is distinct from R1's crash window: it affects successfully persisted pending work.

**Change:** before voluntary exit, show pending work and offer an explicit wait/retry or discard choice. If retaining across sessions is an approved product policy, keep it owner-bound and inaccessible to a different user. Forced/security exits must still complete promptly; define whether they discard or securely quarantine the original owner's work. Report expired/failed batches in a recovery surface rather than silently treating them as completed.

**Verify:** sign out with unsent and append-only pending photos, cancel an exit, fail sign-out after cleanup, sign back in as the original owner, then switch accounts. Assert the documented keep/discard behavior, and that no second user can publish the first user's photos. Exercise seven-day expiry with visible outcomes.

### O3 — P2: Distinguish cached reads and pending writes from confirmed saves

**Sources:** `connectivity_providers.dart`; calendar/client save controllers' offline guards; appointment status/update repository methods; image loader's refusal/transport fallback.

Forms correctly refuse writes when the platform explicitly reports no connection. Unknown connectivity is treated as online, and a working Wi-Fi/mobile interface does not establish backend reachability. If the network fails after the guard, a write can remain pending while UI awaits acknowledgment. The code does not expose a shared pending/confirmed/failed save contract. Cached Firestore data and transport-failed image loads can also look like current data or an unavailable image without explaining the recovery state.

**Change:** define the offline policy per operation: drafts retained locally, server-confirmed appointment saves, and durable photo retries. Preserve form input through connection loss and ambiguous outcomes. Surface cache/pending metadata where it changes user decisions; provide an explicit retry rather than inferring success from transport availability. Do not globally enable blind offline appointment creation without a conflict-resolution design. Reuse W5's unknown-outcome handling and R2's revision protection.

**Verify:** captive portal, connection loss during save, app termination with pending acknowledgment, permission rejection after reconnect, and cached reads after role/assignment changes. Avoid duplicate creation when retrying an ambiguous response. Firestore's [offline behavior](https://firebase.google.com/docs/firestore/manage-data/enable-offline) should inform these contracts.

### S1 — P1: Fence notification/deep-link results to the initiating session

**Source:** `lib/core/app/appointment_link_opener.dart`, `openAppointment` around line 201 and `_landOnCalendar`.

The handler checks `isSignedIn` before fetching. It then awaits hub startup and the record, checks only mounted/navigation state, and opens the captured record using the current shell's role. There is no same-UID/session check after either await. If an authorized read begins under account A and completes after logout or a switch, an app root that stays mounted can display A's fetched data over the new session's shell. This is a data-display race; it does not bypass backend rules for new reads or writes.

**Change:** capture a session generation/UID and selection ID at entry, recheck them after awaits and before navigation/display, and cancel/discard obsolete work. Apply the rule to overdue-review routing and other external-entry callbacks. A boolean “somebody is signed in” cannot distinguish A from B.

**Verify:** pause a record fetch, sign out or switch to another account, then release the response. Assert no old appointment detail, role-dependent action, or navigation appears. Also test two rapid notification taps and an opener disposed during cold start.

### S2 — P2: Extend token ownership fencing through refresh and teardown completion

**Source:** `push_registration_controller.dart`, `_syncGuarded`, `_subscribeRefresh`, and `unregisterCurrentDevice`; `ReentrantSync`.

The existing generation checks correctly protect many awaited registration stages. However, the token-refresh callback captures a user document/UID and calls `_upsert` without a generation/current-owner check. Teardown cancels that subscription only in `finally`, after awaited token lookup/deletion. A refresh during teardown can launch another upsert for the old owner. `_syncGuarded` also writes its remembered registration/subscription after awaiting `_upsert` without a final stale-generation check. Successful FCM token invalidation can mitigate delivery, but should not be the only ownership barrier.

**Change:** cancel/fence refresh work at teardown entry, recheck generation after the final await, and reconcile any registration that completed after it became obsolete. Scope device registration to an explicit current session. Verify server cleanup without touching other devices; do not replace the current device-only deletion with a user-wide token sweep.

**Verify:** hold upsert pending, start sign-out, emit a token rotation, and release operations in both orders. Repeat with failed token invalidation and rapid account switching. Assert no old-owner subscription/state is reinstalled and the new account retains its own registrations.

### Notification reliability decisions and operational improvements

ADR-0103 deliberately chooses best-effort change notifications without retry, favoring fewer duplicates over rare misses. The claim-before-send paths also have a crash window: a worker can persist a claim and stop before contacting FCM; a later attempt then sees the claim and suppresses work. Multi-device partial success retains the recipient claim even if another device had a transient failure. These are delivery tradeoffs, not newly discovered violations of the documented policy.

If stronger guarantees are required, use durable recipient/event delivery state with leases, retry budgets, stable event IDs, and clearly documented duplicate tolerance. FCM acceptance is not proof the device displayed the alert. Start by measuring registered/eligible recipients, attempted/accepted sends, invalid tokens, transient failures, cap hits, and aged pending work; keep notification content and full tokens out of diagnostic logs. Give critical schedule changes an in-app source of truth so a missed push does not become missed work.

### Validation and rollout

Prioritize A1, N1, O1/O2, and S1. Then add notification expiry and generation-safe registration, followed by the broader offline-state and sweep changes. Keep the existing ownership-aware queue/cache designs and build targeted failure tests around their boundaries.

The companion `accessibility_reproductions_2026_10_18_test.dart` records the original production-widget demonstrations. Permanent corrected semantic-action regressions now live in `test/features/calendar/picker_accessibility_test.dart`; the dated demonstration remains historical evidence.

Validation for this pass:

- **30 existing Flutter tests passed**, covering notification registration/token storage, device deregistration, offline-banner state, and accessibility themes.
- **Two accessibility reproduction tests passed**, confirming missing semantic tap actions on the actual rendered widgets. The first harness invocation had a semantics-handle cleanup error; it was corrected and both demonstrations were rerun successfully.
- **115 backend tests passed across three suites:** `notification_utils.test.js`, `notification_lifecycle.test.js`, and `notification_admin_fanout.test.js`. The initial sandbox run could not write Jest's transform cache; the successful rerun used the normal local environment.

These tests do not simulate all the new races. The token-storage failure and registration fast path are covered separately in existing tests; their combined recovery gap is established by code trace. Keep the previously reported isolated widget-provider failure in the earlier review as a separate outstanding test issue.

This review does not establish that former-user data or expired notifications were observed on a real device. The documented race paths need controlled device/emulator verification. VoiceOver/Switch Control, APNs delivery, captive-portal operation, and process-kill recovery remain hardware/runtime validation tasks.

## Validation performed and limits

The final focused backend run passed **5 suites / 131 tests**:

```text
cd functions
npm test -- --runInBand --silent --runTestsByPath __tests__/client_propagation.test.js __tests__/client_job_count.test.js __tests__/recount_claim.test.js __tests__/wave_dispatch.test.js __tests__/wave_outbox_queries.test.js
```

The accompanying local script confirmed four failure mechanisms:

```text
node docs/audits/2026-10-18-review-reproductions.cjs
REPRODUCED: search cap hides the only full match.
REPRODUCED: reversed events replace latest phone 333 with 222.
REPRODUCED: older recount overwrites count 2 with 1.
REPRODUCED: stale query can claim a job before its new retry time.
```

The script requires the existing backend dependencies and makes no network requests or production writes. It deliberately asserts current faulty behavior; it is a demonstration, not a permanent regression test. When fixing each issue, replace its expectations with the correct behavior in the normal test suite.

Passing existing tests does not invalidate the reproduced gaps. A complete backend suite, device-level Flutter performance benchmark, upload crash test, production concurrency stress test, and invoice-level cost analysis were not completed as part of this review. No production defect frequency or monetary saving is inferred from the local reproductions.
