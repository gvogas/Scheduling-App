# 0184. `waveSetImportSchedule` deleted

**Date:** 2026-10-09 · **Rules file:** `.claude/rules/wave.md` · **Supersedes:** ADR-0147's Consequences

## Context
ADR-0147 kept `waveSetImportSchedule` deployed as an accepted-and-ignored no-op (`#compat-1.61.0`) because the
1.61.0 Settings cadence picker still called it. On 2026-10-09 the owner confirmed every phone runs app build
1.63.0+93 (`cc38be5d`) or newer, so no build at or below 1.61.0 remains, and no build since 1.62.0 calls it
(the app has no reference to it).

## Decision
Delete the callable, its export (32 → 31) and the `schedule` allowlist with it. The Wave admin callables are now
four (`waveBootstrap`, `waveGetConnection`, `waveImportCustomers`, `waveRetryFailedJobs`), all durably
rate-limited. `WAVE-SCHED` survives only as the `runWaveDaily` drain's log labels in `functions/wave/triggers.js`.

## Consequences
Removing the source does not remove the function. The `Deploy backend` workflow's export diff
(`functions/scripts/deploy/export_diff.js`) refuses to deploy while prod runs a function `index.js` no longer
exports, so the owner deletes it from an owner shell (AI-agent env vars cleared, `docs/DEPLOYMENT.md` §5) with
`firebase functions:delete waveSetImportSchedule --region us-central1` after the merge to `main` and before the
workflow run; the allowlist step then only warns that the owner is gone. Rollback means redeploying a commit
that still exports it. Don't re-add the cadence (ADR-0147).
