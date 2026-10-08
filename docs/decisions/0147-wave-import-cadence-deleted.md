# 0147. Auto-import cadence deleted; `waveSetImportSchedule` kept as a no-op

**Date:** 2026-09-13 (Wave Phase 4, Task 12) · **Rules file:** `.claude/rules/wave.md`

## Context
Production had the cadence `off` by owner choice. Removed: the Settings picker, the `WaveImportSchedule` enum,
`WaveConnection.importSchedule`, `WaveService.setImportSchedule`, the five `wave_autoImport*` ARB keys,
`isImportDue`/`SCHEDULE_VALUES`/`SCHEDULE_SET`, and `runWaveDaily`'s import rider. The 1.61.0 app still calls
`waveSetImportSchedule` from its picker.

## Decision
Keep the export and its `schedule` allowlist key (`#compat-1.61.0`); answer `{schedule: "off"}` with no `wave/connection`
read, no write and no rate limit; log `WAVE-SCHED ignored a retired cadence call`. `waveGetConnection` no longer returns
`importSchedule`, which 1.61.0's `WaveConnection.fromMap` reads as `off`; stored `importSchedule` /
`lastAutoImportAt` fields are inert.

## Consequences
Retire it only once the log line is quiet AND no build at or below 1.61.0 remains, in its own deploy
(`docs/DEPLOYMENT.md` §4a); removing the key early throws `unexpected-field` on every 1.61.0 device. Don't re-add the cadence. "No read" means
no `wave/connection` read: `assertAdminCall` still reads the caller's `usersByUid` row.
