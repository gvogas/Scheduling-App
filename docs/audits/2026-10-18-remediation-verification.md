# Audit remediation verification

This records local evidence for the uncommitted remediation work. It is not a production deployment or an iOS release approval. The active checklist remains [the remediation plan](../plans/2026-10-18-audit-remediation-plan.md).

## Verified local baselines

- Six-shard Flutter suite: **4,164 passed** (`build/audit-progressive-full-flutter.log`), followed by clean whole-workspace analysis and zero source-rule violations. This baseline includes progressive photo loading, the shared display clock, address races, guarded edits, search completeness and bounded session cleanup. Later photo-outcome/mirror changes require their own full rerun.
- Backend baseline: **2,256 passed**, coverage gates satisfied (`build/audit-backend-coverage-current.log`). Subsequent full coverage found one exact-payload email-change assertion needing the additive `validUntil` field. That assertion was updated; the affected delivery suites then passed **160 tests**. A final full coverage run remains required after the mirror envelope changes.
- Progressive photo regressions: **48 passed**, including rendering the first photo of a 30-photo job without loading the rest. The following full run also verifies that four held old-session transfers cannot block replacement-session photos.
- Photo expiry/forced exit: **70 passed** (`build/audit-photo-outcome-verified-tests.log`), clean analysis. Expiry outcomes are recorded before removing queue entries, hidden until removal commits, durable across restart, owner-bound and acknowledged after presentation. Failed queue persistence does not announce removal. Known pending photos are disclosed during forced exit. Scheduling an exit frame is explicit, so an idle screen cannot strand navigation.
- Shared mirrors: **95 passed** in the initial ownership integration suite (`build/audit-mirror-ownership-tests.log`). This covers durable owner/session epochs, wrong-owner/old-epoch/older background rejection, serialized foreground writes and stale clear rejection. Further CarPlay changes and final integration are still being verified.
- Notification windows, widget serialization and deployment configuration checks: **170 passed** (`build/audit-validity-verified-tests.log`); per-token envelope integration: **189 passed** (`build/audit-mirror-backend-tests.log`). Backend lint passed for those sources.
- Native CI configuration helper: **2 passed**, confined to workspace temporary directories, including refusal to overwrite existing Firebase configuration. CI/deploy/dependency YAML parsed. No simulator build has run on this Windows host.

## Read-only production observations

- Repository: `gvogas/Scheduling-App`. `main` has no branch protection or active ruleset. Existing check names are `Flutter analyze + test` and `Cloud Functions lint + test`. The new native check must first run successfully before making it required.
- `waveUpsertCustomer` is ACTIVE, maximum instances 2, timeout 300 seconds, retry enabled, but deployed request concurrency is **80**. Local source now explicitly sets **1**. The deployment verifier rejects the observed drift. No production setting was changed.
- All **8** declared TTL policies are ACTIVE; all **30** composite indexes are READY. The prepared configuration removes 12 unused ascending/descending expiry indexes from six TTL-only collections while retaining all TTL declarations and the queried Live Activity expiry indexes. No index or TTL deployment occurred.

## Native and external gates

- The local Firestore emulator fails before loading rules: Java cannot initialize its selector loopback socket (`UnixDomainSockets.connect0`, `Invalid argument: connect`). Direct jar execution reproduces it. Explicit socket temp-directory and Windows-selector attempts also failed. Java itself launches successfully. Linux CI remains the authorization/concurrency execution gate; none of these failed attempts count as a rules pass.
- Swift changes require the pinned macOS simulator/RunnerTests job, then VoiceOver EN/FR, physical-device App Check/signing, delayed APNs, Live Activity freshness and CarPlay lifecycle checks. WidgetKit redraw timing cannot be guaranteed by application code.
- The backend and additive FCM token rules must deploy before the new app. Background widget payloads without a token session epoch are withheld; ordinary notifications remain compatible. Upgraded readers reject retained ownerless snapshots until foreground synchronization.
- Appointment edit migration/minimum supported client policy, durable ambiguous creation recovery, repeated-conflict batching, remaining deployment/IAM baseline work, and device performance measurements remain open. Do not describe all audit packages or release readiness as complete.
