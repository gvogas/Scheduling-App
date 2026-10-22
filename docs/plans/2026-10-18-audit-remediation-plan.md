# Audit remediation plan — priority and delivery order

**Status (swept 2026-10-20): BUILT IN CODE, NOT DEPLOYED, NOT SHIPPED.** The work landed in `33cde361` ("review and cleanup"), hardened by the 2026-10-19 audit (`a851d238`) and the 1.65.0+97 release pass; local runs 4,214 Flutter / 2,324 jest (113 suites). Nothing is live: `saveAppointmentEdits`, the batched `findAppointmentConflicts`, the `propagateClientEdits` rewrite and the new indexes await a `Deploy backend` run (last deploy `0ab3f05c`, 2026-10-11), which must precede the 1.65.0+97 app build. Still open: native/device checks (CI's simulator job only), creation ambiguity, the edit migration / minimum-supported-client policy, and the remaining T13/T14 work. The execution ledger below is the record of each package.

Prepared October 18, 2026 from the [combined audit](../audits/2026-10-18-performance-reliability-review.md). Workspace HEAD at planning: `f19548428066869711cf7eecb6ce9f97e635027a`; the workspace also contains unrelated uncommitted documentation changes. Recheck affected code and deployment/settings before each task. Audit IDs below refer to that dated review, not to confirmed production incidents.

## Decision

The user subsequently expanded authorization to **all audit packages T00–T14, including delivery safeguards and measured optimization**. Continue implementation and validation autonomously. Keep unavailable iOS/device and deployment evidence explicitly pending; preparing a release is distinct from deploying or approving production.

The user authorized continuing through items 1–5 of the progress summary: finish photo/session safety (T03/T04), appointment-write correctness (T05), conflict/push recovery (T06/T07), backend convergence/Wave (T08/T09), and freshness/address/search correctness (T10–T12). Work through these autonomously with regression tests and update this ledger. Readiness is based on verified checks; no arbitrary percentage substitutes for unresolved native/device or deployment gates. T01/T13 safeguards and T14 optimization remain separately tracked.

First protect user data and account boundaries, restore accessible form actions, and make scheduling answers trustworthy. Next repair background synchronization and delivery. Then improve freshness and responsiveness. Database cost tuning and larger architectural work come after correctness and measurements.

This plan consolidates **42 audit findings into 15 work packages**. It is the execution order for the combined audit; the audit's individual priority labels remain evidence of potential impact rather than a requirement to implement every P1 in one release. No emergency production outage or actively exploited defect was established. Several native/session races are code traces that need a failing regression scenario before selecting the final implementation.

## Highest priorities

| Rank | Outcome | Why it comes early | Packages |
| --- | --- | --- | --- |
| 1 | Keep pending/uploaded photos recoverable | Local originals can be deleted before durable linking or during sign-out | T04 |
| 2 | Preserve newer appointment changes | An older form can overwrite a completed status or someone else's edit | T05 |
| 3 | End sessions promptly and keep prior-user data out of the next session | Cleanup can stall, and delayed callbacks/shared snapshots can outlive their owner | T03 |
| 4 | Make date/status pickers usable with a screen reader | Missing semantic activation was reproduced on the real widgets | T02 |
| 5 | Return complete or explicitly inconclusive conflict answers | Truncated candidates can incorrectly appear conflict-free | T06 |
| 6 | Recover notification registration after a transient failure | A failed write can be remembered as successful for the session | T07 |

Ranking expresses impact. **Actual delivery starts with T00, then the small T02 fix**, while tests/design for the larger first three packages are prepared. Do not hold a verified accessibility fix until an upload/session redesign is finished. T01 begins early to protect all later changes.

## Phase 0 — Establish trustworthy checks

### T00 — Reproduce and baseline the critical cases

**Audit coverage:** CI8, CI10. **Owner:** Flutter/backend implementation; Mac verification for native scenarios. **Size:** small initial setup; regression additions travel with each fix.

- [x] Correct the isolated `widget_payload_provider_test.dart` binding/lifecycle setup failure reported in the audit. Run it directly and through the normal shard runner.
- [ ] Move each audit demonstration into its appropriate permanent test suite as its fix is implemented, changing expectations to correct behavior. A script that asserts the defect is not a release regression gate.
- [ ] Add deferred-future and reversed-order test helpers for session changes, stalled cleanup, upload interruption, stale edits, and retry eligibility.
- [ ] Run the existing relevant Flutter/backend suites and emulator authorization checks; record commands, source SHA, and outcomes. Existing passing counts in the audit are historical, not a baseline for a new commit.

**Done when:** the isolated known test passes; each selected fix has a scenario that fails before the change and passes after it; checks remain deterministic without weakened thresholds. Add real rules behavior tests where writes/permissions change, retaining useful existing source-contract tests.

### T01 — Put merge and native-build safeguards in place

**Audit coverage:** CI1, CI2. **Size:** medium; macOS/toolchain availability required for the native half.

- [ ] Recheck effective `main` rules and the existing CI check names. Prepare required PR/status checks with a documented, limited bypass policy that works for a solo maintainer.
- [ ] Add a pinned-toolchain macOS simulator build and `RunnerTests` job, including extensions and sanitized configuration. Capture test-result bundles on failure.
- [ ] Make native verification a release requirement for affected app/native/plugin/shared-contract changes. Design changed-path handling so required check contexts still resolve for unaffected changes.
- [ ] Keep signing/archive, App Check, CarPlay entitlement, and physical-device validation in the app release runbook; simulator success does not replace them.

**Done when:** a failing ordinary PR cannot merge through the normal path; a clean PR can; Swift compile/test errors are caught before the affected app release. Repository settings and production actions are separate execution steps, not changes already made by this document.

### T02 — Restore accessible picker actions and error descriptions

**Audit coverage:** A1, A2. **Size:** small initial fix; broader device check follows.

- [x] Restore `SemanticsAction.tap` to the date/status picker controls, with one consistent enabled callback for semantic and pointer activation.
- [x] Inspect similar employee/date wrappers individually. Include field errors and localized photo position/action labels without duplicate announcements.
- [x] Add tests invoking the semantic action, checking selected/disabled states, and reading validation content.
- [ ] Verify the booking flow with VoiceOver, large text, and EN/FR on iOS.

**Done when:** a screen-reader user can select a date/status and hear why validation failed; pointer behavior still works. Keep status-pill scaling changes evidence-led rather than enlarging every control blindly.

## Phase 1 — Prevent loss and unsafe session carryover

### T03 — Make account exit and asynchronous UI work session-safe

**Audit coverage:** O1, S1, S2, W1, W4, W6. **Size:** large; split into three reviewable changes.

**T03a: session fencing and bounded local exit.**

- [x] Define a shared session generation tied to UID changes and exit start. Capture it before asynchronous work; discard obsolete completions before they display, subscribe, or write shared state.
- [x] Fence appointment/deep-link results after every await, including overdue routing. Mounted checks alone are insufficient.
- [x] Stop/fence push-refresh callbacks at teardown entry and recheck generation after registration writes.
- [x] Give remote deregistration a bounded wait budget and ensure local sign-out/cache clearing proceeds under the chosen policy. Timed-out operations still require stale-completion protection.

**T03b: native scene and detail cleanup.**

- [ ] On sign-out/account switch, dismiss sensitive CarPlay details/alerts immediately. Ordinary content refreshes can retain their current scroll/tab behavior.
- [ ] Fence native phone-lookups and status UI completions by scene generation and latest selection, including disconnect/reconnect.

**T03c: ownership of shared widget/snapshot writes.**

- [ ] Define an additive envelope with owner/session generation, schema, source revision, coverage, and freshness semantics.
- [ ] Reject wrong-session/older background widget writes and invalidate ownership durably on logout. Account for background-isolate writes when deduplicating foreground state.
- [ ] Roll out compatible readers/writers and define handling of legacy ownerless payloads. Do not let a parser migration silently expose retained prior-user data.

**Done when:** held network operations cannot delay local exit beyond its budget or display/reinstall old-user state after A → logout → B; CarPlay reconnect cannot consume an old selection; delayed pushes cannot restore cleared/wrong-owner widget content. The new user must retain their own valid device registration.

**Dependencies:** T00; T01 native checks before shipping T03b/c. T04 must participate in exit handling so the session fix does not silently discard pending work.

### T04 — Make photo uploads durable and account-exit behavior explicit

**Audit coverage:** R1, O2. **Size:** large; split durable storage, recovery, and exit UI.

- [x] Give each queued file a stable upload ID/object path, persisted before upload. Define states for staged, uploaded, linked, and cleanup-pending.
- [x] Persist successful upload receipts before deleting local bytes; checkpoint each completed chunk before starting the next one.
- [x] Recover the ambiguous case where Storage succeeded just before the receipt was persisted; link idempotently.
- [x] Migrate existing queue entries and recover append-only entries. Keep owner checks and add generation invalidation for a drain that overlaps exit.
- [x] Before voluntary exit, offer a clear pending-work choice: finish/retry or explicitly discard. Define secure owner-bound retention only if the product chooses to support it.
- [ ] Define forced-exit and seven-day expiry outcomes; report discarded/expired work. Failed sign-out must not pretend previously deleted files were restored.

**Done when:** restart at every upload/link/delete boundary produces one recoverable or linked image, not silent loss/duplicates; retained work never uploads under another account; voluntary exit does not discard unnoticed work. Test real app termination on iOS as well as fault-injected unit cases.

**Dependencies:** T03 session/exit contract; do not wait for all native work to implement the durable queue itself.

### T05 — Prevent stale and ambiguous appointment writes

**Audit coverage:** R2, W5, O3. **Size:** large; split field updates/revisions from pending-outcome presentation.

- [ ] Define a business revision and legal status transitions. Separate intentional dirty fields from whole-record serialization.
- [ ] Compare the expected revision/current state transactionally for conflicting edits, including series rewrites and CarPlay status actions.
- [ ] Preserve terminal statuses unless reopening is explicitly requested and authorized. Define safe merges for unrelated edits and a useful conflict/reload UI.
- [ ] Represent confirmed success, confirmed rejection, and unknown/pending outcomes. A timeout must not trigger blind recreation or claim a queued write was cancelled.
- [ ] Preserve drafts through connection loss; keep appointment creation server-confirmed until a safe offline conflict policy exists.
- [ ] Plan rules/schema/backward compatibility for already shipped clients. Enforcing a new revision only in upgraded UI does not establish a system-wide invariant.

**Done when:** an admin editing notes cannot undo a crew completion; two editors cannot silently overwrite shared fields; an acknowledgment arriving after timeout does not produce duplicate creation or a misleading final failure. Include existing app payloads in emulator/device compatibility checks.

## Phase 2 — Restore scheduling and background correctness

### T06 — Make conflict results complete

**Audit coverage:** R3. **Size:** medium initially; larger only if atomic reservations are required.

- [ ] First implement complete pagination or an explicit inconclusive result that cannot be interpreted as clearance. Keep work bounded with an honest incomplete response.
- [ ] Test the only genuine conflict beyond candidate 500, terminal-heavy history, employee chunks, and exact boundaries.
- [ ] Decide whether the business requires advisory preflight or a hard no-double-booking guarantee. If the latter, design a server-authoritative reservation protocol as a separate change; query completeness alone does not serialize simultaneous bookings.
- [ ] Add a scheduling-blocking field only if measured query work warrants it, with all-writer enforcement, backfill verification, and compatible index deployment before switching readers.

**Done when:** a capped/failed scan never means “no conflict”; correctness holds during migrations. Ship the completeness fix before the optional field/index optimization.

### T07 — Recover notification registration and expire stale nudges

**Audit coverage:** N1, N2. **Size:** medium; two independent changes.

- [ ] Return an observable registration result; cache success only after server acknowledgment. Retry a dirty registration with bounded backoff on resume/reconnection without reprompting permission.
- [ ] Test first-write failure followed by an identical-token retry using the real repository error behavior, not only a successful mock.
- [ ] Define kind-specific validity windows and Apple-platform expiration. Include event/revision/valid-until metadata where needed; cancellation/change notices must not inherit a departure alert's short lifetime blindly.

**Done when:** registration repairs itself within the documented recovery window and expired timed nudges are not presented as current instructions. Confirm delayed APNs behavior on a device.

**Dependencies:** T03 registration ownership fences; the failure-result correction can be implemented before the full snapshot envelope.

### T08 — Make client propagation and counters converge

**Audit coverage:** R4, R6. **Size:** medium to large; separate contact propagation and recount changes.

- [ ] Reconcile current client state with a source revision and conditional target updates; re-read/recompute on contention and preserve custom appointment values.
- [ ] Serialize derived-count reconciliation with a dirty generation/recheck, or use transactional contributions if that is simpler for the entity. Do not discard events arriving during a lock.
- [ ] Test reverse/duplicate events, delayed older writes, deletes, and concurrent user edits. Include image counts as well as client job totals.

**Done when:** old events cannot restore old phone/name data; the final count agrees with source records after concurrent updates and retries. Use a dry-run discrepancy report before any production repair/backfill.

### T09 — Bound Wave work and honor current retry state

**Audit coverage:** R7, R8, R9. **Size:** medium; keep configuration and queue/transport changes independently reviewable.

- [ ] Set explicit trigger concurrency consistent with the intended drain limit, then verify the deployed value. Account for other Wave entry points when considering upstream limits.
- [ ] Recheck `nextAttemptAt` inside the claim transaction and return authoritative claimed attempts/data to outcome calculation.
- [ ] Apply request/body/retry deadlines within the overall drain budget, preserving time to record an outcome and existing idempotency handling for ambiguous upstream success.

**Done when:** stale snapshots cannot retry early/reset attempt budgets; a hung fetch cannot consume the whole drain unchecked; deployed concurrency matches intent and queue age stays acceptable.

**Dependencies:** T13's configuration verification before or with production rollout. Keep existing production serialization and export-removal safeguards.

## Phase 3 — Make visible data current and responsive

### T10 — Correct time-based widget, Siri, calendar, and dashboard presentation

**Audit coverage:** W2, W3, W7, W8, W9, R12. **Size:** large overall; implement as four small surface-specific changes.

- [ ] Resolve CarPlay selections from current data by ID; include appearance-dependent state in image refresh and respond to head-unit day/night changes.
- [ ] Resolve home-widget jobs/day labels at each timeline entry's time, including midnight and stale/out-of-window coverage. Define timed-in-progress versus “up next” behavior explicitly.
- [ ] Add snapshot total/truncation/coverage metadata so Siri never presents capped counts as exact or absent data as an empty schedule.
- [ ] Define phase-specific Live Activity freshness deadlines and display staleness; validate countdown/end transitions under missed pushes on hardware.
- [ ] Drive calendar/dashboard time-dependent presentation from an observable clock; invalidate mutation-sensitive dashboard caches. Keep database listeners stable across display-only ticks.

**Done when:** frozen-payload clock tests cross job start/end/midnight correctly, a 31-job day is reported honestly, current CarPlay details are opened, and device tests confirm supported redraw behavior. A promise of an exact WidgetKit refresh time is not an acceptance criterion.

**Dependencies:** T03 snapshot/session contract; T01 native validation. Share optional metadata/fixtures between writers and readers to avoid repeated schema migrations.

### T11 — Fix stale address results

**Audit coverage:** W10. **Size:** small.

- [x] Invalidate requests on text edits before the debounce and on keyboard deletion below minimum query length.
- [x] Fence selected-place details by controller/selection generation; capture apartment text for that selection.
- [x] Test deferred responses after deletion, new typing, and replacement during details loading; preserve session-token behavior.

**Done when:** a late response cannot restore old suggestions or overwrite current input. This can ship earlier as an independent verified fix if users report the symptom.

### T12 — Return complete and honest client search results

**Audit coverage:** R5. **Size:** medium.

- [ ] Correct filtering-after-cap with cursor-based candidate scanning/continuation and honest incomplete-result metadata.
- [ ] Add normalized exact-phone lookup where appropriate, retaining existing filters and authorization.
- [ ] Test the only full match after candidate 200 and common multiword queries; measure examined versus returned candidates.

**Done when:** a valid client cannot silently disappear solely because broad OR matches consumed the first page. Do not add a separate search platform without evidence it is needed.

## Phase 4 — Complete delivery safeguards and measured optimization

### T13 — Strengthen the rest of CI/deployment verification

**Audit coverage:** CI3, CI4, CI5, CI6, CI7, CI9. **Size:** medium; independent small workflow changes.

- [ ] Add target-specific read-only permission preflight. Recheck the historical Storage failure before changing IAM.
- [ ] Verify critical deployed configuration and healthy state, preserving name checks. Upload sanitized attempt logs/snapshots on failure/partial success; never upload authentication files.
- [ ] Establish an authoritative last-verified deployment baseline with a documented bootstrap path; do not silently skip compatibility when the baseline is absent.
- [ ] Enforce lockfile and generated-model reproducibility with the pinned SDK, including new untracked model output.
- [ ] Add caller-safe superseded-PR cancellation and explicit timeouts; keep deployment verification isolated from ordinary CI cancellation.
- [ ] Extend dependency maintenance to backend npm and application Pub packages. Keep native plugin/major changes deliberately reviewed.

**Done when:** missing prerequisite/configuration drift is actionable; a partial release is visible; stale generated models fail; superseded CI cancels without cancelling a release. Complete the configuration-verification slice early for T09; the remaining efficiency slices can follow later.

### T14 — Optimize measured bottlenecks and scaling limits

**Audit coverage:** R10, R11, N3; database/UI optimization candidates.

- [ ] Make photo loading progressive, prioritize visible content, and bound widget-retained bytes as well as loader cache bytes. Measure first-visible-photo latency and memory.
- [ ] Batch repeated-booking conflict windows with a proportional work/rate budget after T06 establishes correctness. Compare request/read counts and latency.
- [ ] Page overdue candidates so delivered first-page jobs cannot starve later ones. This is a correctness fix at higher volume; promote it if cap hits occur in production.
- [ ] Inspect index fanout and TTL-only exemptions against actual consumers, retaining queried expiry indexes and TTL policies.
- [ ] Profile reminder empty sweeps, dense calendar layout, and formatter allocation before introducing new summaries/caches. Preserve alert timing and correctness.

**Done when:** before/after results show the intended improvement without extra stale data, unbounded work, or changed reminder timing. Savings must be based on measured usage/invoice evidence, not a promised percentage.

## First five reviewable changes

1. **T00 baseline:** isolated widget-provider test setup plus reusable deferred-operation fixtures.
2. **T02 accessibility:** semantic activation/error regression tests and small picker fixes.
3. **T03a session safety:** session generation, deep-link result fencing, push-refresh fencing, and bounded cleanup; split the cleanup portion if the change grows.
4. **T04 upload durability:** stable IDs and receipt-before-delete, with restart/failure injection; separate exit-choice UI after the lifecycle contract is verified.
5. **T05 stale edits:** dirty-field patches and revision/current-status checks, with two-editor tests and backward-compatibility handling.

Begin T01 alongside this sequence. Promote T06/N1 correction immediately if conflict cap hits or missing-registration incidents are observed. Do not bundle unrelated changes just to meet this numbered sequence.

## Validation and release gates

Every fix needs a reproducible before/after scenario, the relevant existing tests, and checks appropriate to changed contracts. Full required CI should pass at the release commit. Native changes require simulator/RunnerTests plus targeted device checks; infrastructure changes require post-deploy inspection. No new tests were run merely to create this planning document.

Before each release:

- [ ] Record exactly which task slices and audit IDs are addressed, and the tested source SHA.
- [ ] Deploy additive backend/rules/index support before the app that relies on it. Verify required indexes and any restartable backfill before switching readers.
- [ ] Check an already shipped app against changed payload/rules contracts; data revision and snapshot ownership migrations need explicit legacy behavior.
- [ ] Verify on-device scenarios relevant to the slice: process death, A → logout → B, offline exit, VoiceOver, widget midnight, or CarPlay reconnect.
- [ ] Record the rollback and data-recovery method. Keep old additive schemas readable; reverting a binary does not restore deleted photos or undo a backfill. Never restore a defect merely to make a test pass.
- [ ] Observe errors, cap hits, pending upload age, stale-write conflicts, token-registration failures, queue age, and any changed latency. Use privacy-safe identifiers and a baseline appropriate to actual traffic.

A task is complete only when its acceptance checks and relevant deployment/device gates pass. Code merged, function deployed, and app shipped are separate status fields. If a Mac is unavailable, continue Dart/backend work and leave native verification explicitly pending.

## Decisions to settle during implementation

These do not block preparing regression tests or independent fixes:

| Decision | Proposed starting policy | Needed before |
| --- | --- | --- |
| Pending photos on voluntary logout | Offer finish/retry or explicit discard; retaining for later requires owner-bound storage design | T04 exit UI |
| Forced logout with queued photos | Complete exit promptly; decide secure original-owner retention versus disclosed discard | T03/T04 release |
| Scheduling guarantee | Preserve honest preflight; decide whether simultaneous booking needs atomic reservation | T06 reservation design |
| Session cleanup budget | Choose a short measured total budget; UI stops waiting while obsolete operations remain fenced | T03a tests |
| Snapshot age versus offline usefulness | Carry coverage/last-confirmed information and show stale data honestly | T03c/T10 contract |
| Notification delivery policy | Retain ADR-0103 best-effort policy initially; improve registration/expiry/observability | Any durable delivery-outbox proposal |

## Deferred work

Defer a database migration, generic repository/state-management rewrite, new dashboard summary collections, a dedicated search service, a guaranteed-delivery notification outbox, and wider test sharding until a measured requirement justifies them. Review backup/restore objectives separately; disabled PITR alone does not prove backups are absent. Keep critical behavior tests early even when the broad refactor is deferred.

The audit found modest database volume and roughly three-minute CI in the inspected sample. The next meaningful investment is trustworthy behavior and releases. Cost changes should follow the measurements, with no dollar estimate attached to this plan.

## Coverage and status tracking

| Audit IDs | Work package | Initial status |
| --- | --- | --- |
| CI8, CI10 | T00 | In progress — isolated widget-provider setup fixed; see execution record below |
| CI1, CI2 | T01 | Planned |
| A1, A2 | T02 | Implemented and tested locally — iOS VoiceOver/device gate pending |
| O1, S1, S2, W1, W4, W6 | T03 | In progress — T03a session/routing/push guards implemented; bounded cleanup and T03b/c pending |
| R1, O2 | T04 | In progress — durable identities, receipts, staged recovery and voluntary exit choice implemented; forced-exit/expiry and device gates pending |
| R2, W5, O3 | T05 | Planned |
| R3 | T06 | Planned |
| N1, N2 | T07 | Planned |
| R4, R6 | T08 | Planned |
| R7, R8, R9 | T09 | Planned |
| W2, W3, W7, W8, W9, R12 | T10 | Planned |
| W10 | T11 | Planned |
| R5 | T12 | Planned |
| CI3, CI4, CI5, CI6, CI7, CI9 | T13 | Planned |
| R10, R11, N3 | T14 | Planned |

Update this table with links to implementation changes and actual verification evidence as work proceeds. Historical audit test passes do not mark any package complete.

### Execution record — October 18, 2026

Started T00 on source HEAD `f19548428066869711cf7eecb6ce9f97e635027a` plus the existing uncommitted documentation changes and the test setup change below. Toolchain: Flutter 3.47.2 / Dart 3.13.2 on Windows.

- Reproduced the isolated failure with `flutter test test/features/home_widget/widget_payload_provider_test.dart --reporter expanded`: 3 passed, 1 failed because `currentDayProvider` constructed `AppLifecycleListener` before binding initialization.
- Added `TestWidgetsFlutterBinding.ensureInitialized()` in the test's `main()`, retaining the real lifecycle dependency and all existing assertions and container disposal.
- Verified with `flutter test test/features/home_widget/widget_payload_provider_test.dart --no-pub --reporter expanded`: **4 passed**.
- `dart run tool/test.dart --no-pub --reporter expanded`: **4,066 passed**, exit 0, through the normal six-shard runner. Log: `build/audit-t00-flutter-tests.log` (local build artifact).
- From `functions/`, `npm test -- --runInBand`: **105 suites passed, 1 skipped; 2,217 tests passed, 3 skipped**, exit 0. Initial sandbox attempts could not access SDK/Jest caches; those environment errors are not application regression results.
- Emulator authorization baseline attempted with `tools/deploy/node_modules/.bin/firebase emulators:exec --project demo-scheduling-review --only auth,firestore,storage "node functions/__tests__/emulator/storage_rules.smoke.js"`: **blocked before tests**. Firestore emulator exited with code 1 and left an empty `firestore-debug.log`; startup output is in `build/audit-t00-emulator.log`. No authorization result can be inferred.

T00 remains open for regression migrations and deferred/reversed-order fixtures accompanying the selected fixes. No production settings, deployment, or native/device verification has been performed.

### T02 execution — October 18, 2026

Implemented on the same source HEAD plus workspace changes; no commit or release has been created.

- Restored semantic activation in `SheetFieldRow`, `AppointmentStatusPicker`, `EmployeePicker`, and enabled `InlineMonthCalendar` dates. Pointer and semantic actions use the same callback. Read-only/unavailable crew and out-of-range dates remain inactive; a crew picker without a callback no longer advertises a button.
- Included picker validation errors in the replacement semantic label and marked errored rows as live regions. Descendant labels remain excluded to prevent duplicate error descriptions.
- Added `AppointmentPhotoSemantics` to editable thumbnails and read-only carousel slides. EN/FR descriptions identify position/count, loading/unavailable state, and full-screen action. Photo nodes retain their own semantic boundary, keeping removal controls separate even during loading. Existing viewer indexing and refusal behavior remain intact.
- Permanent regression coverage lives in `test/features/calendar/picker_accessibility_test.dart`, `test/features/calendar/widgets/fields/employee_picker_test.dart`, and `test/features/calendar/widgets/sections/photo_picker_section_test.dart`. The dated audit demonstration remains historical evidence, not a release regression gate.
- The initial regression run reproduced absent picker tap actions and the omitted field error. Harness issues found during test development (extra semantics handles and a zero-size MediaQuery) were corrected before final verification.
- Focused picker/employee/photo suites: **33 passed** via `flutter test test/features/calendar/picker_accessibility_test.dart test/features/calendar/widgets/fields/employee_picker_test.dart test/features/calendar/widgets/sections/photo_picker_section_test.dart --no-pub --reporter expanded`. Status choices were exercised at 2× text in EN/FR. Local log: `build/audit-t02-tests.log`.
- Additional editable-photo semantic activation assertions: **2 passed** (EN/FR), using `flutter test test/features/calendar/widgets/sections/photo_picker_section_test.dart --plain-name "editable photos have positions" --no-pub --reporter expanded`. This verifies opening the second photo at viewer index 1 and independently activating removal. Log: `build/audit-t02-photo-actions.log`.
- `dart analyze lib test`: **No issues found**. Whole-workspace `flutter analyze` had identified the pre-existing `file_names` info on the dated audit demonstration; the new local-variable lint was corrected. A subsequent Flutter analysis wrapper stalled without output and was stopped before using Dart analysis directly. Log: `build/audit-t02-source-analyze-direct.log`.
- `dart run tool/check_rules.dart`: **0 rule violations**, exit 0. `git diff --check -- lib test` passed. Local rule log: `build/audit-t02-rules.log`.

T02's iOS VoiceOver booking flow, large-text device checks, and EN/FR verification remain pending on iOS hardware. No simulator/device result is claimed from Windows. T03a inspection confirms missing post-upsert fencing and refresh-subscription lifetime races in push registration; implementation must include deferred registration/teardown and account-switch scenarios before changing cleanup policy.

### T03a execution — session, routing, and push ownership

Implemented on source HEAD `f19548428066869711cf7eecb6ce9f97e635027a` plus the existing workspace changes. No commit, deployment, or native release is implied.

- Added shared `SessionFence`/`SessionLease` ownership tied to Firebase UID changes and exit start, with a synchronous UID check at each use. Failed exits restore eligibility with a new generation, keeping abandoned work invalid. Account teardown and direct sign-out paths use this same owner.
- Fenced appointment reads/retries, hub polling, unavailable notices, overdue routing, delayed initial push/widget/app-link delivery, and disposed link handlers. Newly received links can still route in the replacement session.
- Push registration rechecks ownership after registration acknowledgement and before refresh writes. Teardown detaches/captures old local state at entry and checks its owner after each awaited step; an old teardown cannot delete the replacement session's FCM token or clear its subscription/cache metadata. Cached registration includes its lease, and the real token repository also fences the get-then-set boundary.
- Device cleanup stops before subsequent steps after an account change. Forced/voluntary exit callers avoid signing out/deleting the replacement account, and a delayed account-deletion acknowledgement does not clear the replacement account's auth cache. Pending-upload behavior and cleanup timeouts are unchanged by this slice.
- Added held-future regressions for old appointment results, late notices, overdue hub polling, post-teardown registration acknowledgement, refresh during stalled removal, replacement-user registration, auth failure recovery, deferred account deletion, and device/forced-exit ownership. The three routing scenarios and three push lifecycle scenarios reproduced the defects before the fixes. Harness setup/type issues found while developing the tests were corrected separately.
- `dart analyze lib test`: **No issues found**, exit 0 (`build/audit-t03a-clean-analyze.log`). The subsequently updated splash harness also passed `dart analyze test/features/splash/splash_controller_disabled_test.dart` (`build/audit-t03a-splash-analyze.log`). Earlier directive/tearoff and cancellation diagnostics were corrected without suppressions.
- `dart run tool/check_rules.dart`: **0 violations**, exit 0 (`build/audit-t03a-final-rules.log`). `git diff --check -- lib test` passed.
- The first full shard run had **4,092 passes and 5 failures**, all in the splash harness's missing Firebase Auth stream stub. Added the actual stream stub while retaining every sign-out assertion. The corrected splash and push files then passed **22 tests**, including final explicit subscription cancellation (`build/audit-t03a-final-targeted.log`).
- Final `dart run tool/test.dart --no-pub --reporter expanded`: **4,097 passed**, exit 0, through the normal six-shard runner (`build/audit-t03a-verified-full-tests.log`). No test thresholds, assertions, or timeouts were weakened.

**Still open:** bounded local exit and in-flight native/registration cleanup policy, pending-photo exit coordination (T04), T03b native scene cleanup, T03c background snapshot ownership, and on-device A → logout → B/offline checks. A write already issued to Firestore is not cancelled by a Dart lease; this slice prevents subsequent stale work and completion effects. Registration success/retry reporting remains T07.

### T04 execution — persist receipts before deleting originals

- Moved original-file deletion after the queue checkpoint. Every completed chunk persists uploaded receipts, retryable paths, and not-yet-attempted paths before deleting successful/rejected originals or starting the next chunk. Appointment linking starts with the receipts already in the queue; an unsuccessful checkpoint stops deletion and linking.
- `PendingUploadStore` now treats a false preferences-write result as a failure rather than allowing destructive work to continue. Existing queue JSON, ownership fields, enqueue age, receipt timestamps, four-upload concurrency, and append-only retry behavior are preserved.
- Checkpoints update only an existing batch, so an upload finishing after queue clearing cannot resurrect that batch or proceed to linking. Regression coverage holds an upload across `clearPending`; separate checkpoint/requeue failures verify both original retention and receipt retention.
- Both initial regressions reproduced the original defects: no receipt while linking was held, and missing originals after a failed receipt write (`build/audit-t04-receipt-repro.log`). Added a later-chunk stall case and a rejected preferences-write case. The preferences test's initial platform mock was invalid and was replaced with an in-memory backend that rejects writes.
- Final focused upload-service and store suites: **39 passed**, exit 0 (`build/audit-t04-receipt-final-tests.log`). Source rules: **0 violations**, exit 0 (`build/audit-t04-receipt-rules.log`). `git diff --check` passed for the changed source, tests, and image rules.
- Final Dart analysis of the two changed source files and their tests: **No issues found**, exit 0 (`build/audit-t04-receipt-final-analyze.log`). Corrected the test's awaited-future lint and the store's collection-syntax lint without suppressions.

**Still open:** upload success before a receipt checkpoint remains ambiguous without persisted stable object IDs; interruption between checkpoint and original deletion still needs cleanup-pending recovery. Generation-fenced drains, explicit pending-photo exit choices, owner-safe forced-exit/expiry behavior, bounded device cleanup, and real iOS termination tests remain required. This slice does not change logout behavior or establish complete process-death recovery.

### T04 execution — stable upload identity and recovery

- Added `ImageUploadIntent`: UUID destination, original owner UID, exact upload timestamp, SHA-256 digest and byte length. Each owned legacy path receives an intent and the whole entry is checkpointed before any transfer. Retries retain the same path and timestamp, including after a receipt checkpoint fails. Existing append-only receipts retain their prior behavior; ownerless legacy entries are not adopted. Previously orphaned objects created by older builds without a persisted identity cannot be inferred by this migration.
- `uploadQueuedImage` authenticates a metadata read at the persisted path. It returns a matching object's original receipt without a second transfer; only `object-not-found` permits creation. Owner/digest/size/timestamp mismatches and permission/transport errors stop the attempt. Employee overwrite restrictions and Storage rules are unchanged, and no download URL is created or persisted.
- Queue states are represented by persisted fields: `paths` plus `intents` are staged work; `uploaded` contains receipts awaiting idempotent document linking; `cleanupPaths` tracks originals still requiring deletion. After confirmed linking, cleanup-only entries have no upload paths or receipts, and retry deletion without another transfer or link. Removing an entry completes its local lifecycle. A checkpoint that precedes deletion keeps cleanup reachable after interruption.
- Queue reads reload persisted preferences, preventing an unsuccessful backend write's in-memory cache mutation from becoming a trusted receipt on the next pass. A rejected queue removal also throws before original-file deletion.
- Staging and drains capture the shared session lease and queue generation. Rechecks before/after asynchronous boundaries prevent later chunks, linking, deletions and status changes after exit/account replacement; queue clearing invalidates an active drain. Staging no longer changes another drain's cached owner. Already-issued Firebase operations cannot be cancelled by a Dart lease.
- Focused storage/upload/store suites: **74 passed**, exit 0 (`build/audit-t04-identity-verified-tests.log`). Tests cover ambiguous transfer acknowledgements, failed receipt checkpoints with persisted identity reuse, metadata refusal, modified local bytes, queued legacy migration, cleanup-only recovery, A → B, and exit/resume while an upload is held. Persistence-cache and rejected-clear cases use the real preferences queue with a rejecting backend. Source-rule check: **0 violations**, exit 0 (`build/audit-t04-identity-rules.log`).
- Full app/test analysis: **No issues found**, exit 0 (`build/audit-t04-identity-full-analyze.log`). `git diff --check` passed for the changed source, tests, and image rules.
- Final normal six-shard run, `dart run tool/test.dart --no-pub --reporter expanded`: **4,119 passed**, exit 0 (`build/audit-t04-identity-full-tests.log`). No assertions or test timeouts were weakened.

**Still open:** explicit voluntary pending-photo choices, forced-exit/expiry disclosure and retention/discard policy, bounded device cleanup, staging interrupted before its queue entry is saved, and real iOS termination/Storage validation. These local tests simulate asynchronous and persistence boundaries; they do not claim a device process-termination result.

### T04 execution — recover staging and make voluntary exit explicit

- New batches persist a UUID `batchId`, planned private paths and `stagingSources`. A flushed journal is renamed into place before the preferences queue is updated or any original is copied. The drain imports journals only for their original UID; idempotent queue insertion keeps a replay from replacing an advanced receipt. A failed initial queue write leaves its journal and originals available for a later drain.
- Staging copies through `.part` files and renames completed copies, then checkpoints source cleanup before deleting originals. A partial copy failure keeps the source/destination mapping and completed copies. A new service instance can finish staging without re-moving or discarding earlier files. Existing batch identities remain readable and all progress checkpoints preserve the new identity.
- Voluntary Settings logout, account deletion, password-screen logout and setup-screen logout now inspect pending photos before account exit. The check waits for active enqueues, imports journals, pauses and invalidates drains, and counts unsent files plus uploaded receipts still awaiting linking. Cleanup-only records do not prompt. It performs local queue inspection without a new remote employee lookup.
- The shared EN/FR confirm dialog offers **Stay and retry** or **Discard photos and continue**. Staying cancels exit and resumes uploads; approval holds uploads through teardown. Stale or unmounted dialogs cannot authorize exit and release only their own pause. Forced/recovery exits do not display this voluntary dialog. Discard approval is not represented as reversible if sign-out later fails.
- Focused queue, dialog and account-screen suites: **97 passed**, exit 0 (`build/audit-t04-exit-complete-tests.log`). Coverage includes journal recovery after a failed queue write, replay over a newer append-only receipt, partial staging/restart, an enqueue overlapping exit inspection, stale dialogs, disposal, zero pending work, both logout choices, cancellation after deletion reauthentication, and setup/password-screen cancellation. EN/FR dialog actions run at 2× text in both Material and Cupertino variants.
- A new password-screen test initially timed out because its busy button intentionally keeps animating behind the modal. It now pumps the dialog's transition while busy and settles after cancellation; no production timeout or assertion was weakened. Final source-rule check: **0 violations**, exit 0 (`build/audit-t04-exit-release-rules.log`). Changed-source/test whitespace checks passed.
- The first full six-shard run passed **4,136 tests**, exit 0 (`build/audit-t04-exit-full-tests.log`), and app/test analysis was clean (`build/audit-t04-exit-full-analyze.log`). Final review then added a regression ensuring A's old exit pause cannot block B's queue: the pause now carries its session lease. Setup logout also starts an exit lease before local cleanup and resumes only its own failed exit.
- The next run passed **4,137 tests** (`build/audit-t04-exit-final-full-tests.log`). Follow-up owner-isolation checks now cover a switch while journal recovery is held and an already-superseded empty-queue approval. Discard removes only the captured UID through serialized `clearOwner`; an old cleanup cannot erase a replacement user's queue, and callers recheck the approval before teardown. The final focused set passed **101 tests**, exit 0 (`build/audit-t04-exit-owner-tests.log`).
- Final six-shard suite: **4,140 passed**, exit 0 (`build/audit-t04-exit-owner-full-tests.log`). Final `dart analyze lib test`: **No issues found** (`build/audit-t04-exit-owner-full-analyze.log`). Source-rule check: **0 violations**, exit 0 (`build/audit-t04-exit-owner-rules.log`). No commit, deployment, or iOS device result is implied.

**Still open:** forced-exit/expiry disclosure and retention/discard policy, bounded device cleanup, acknowledgement of photo handoff before the first durable staging journal, and real iOS termination/Storage checks. A failure before the journal can be written preserves picker originals and reports a failure but cannot promise restart recovery from that uncommitted handoff. This slice does not mark all of T04 complete.
