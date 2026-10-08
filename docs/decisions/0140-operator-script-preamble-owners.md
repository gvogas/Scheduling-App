# 0140. Operator scripts: one preamble, one paging loop, `main()` behind `require.main`

**Date:** 2026-08-31 (`bootstrapScript`), 2026-09-05 (`scanByName` fold-back) · **Rules file:** `functions/CLAUDE.md`

## Context
`_flags.js` rejects unknown arguments and `printTargetBanner` prints the banner, but nothing owned the
six lines wiring them together (resolve `dryRun` once, hand the same value to both). Thirteen scripts
spelled that out by hand; commit `56744d1f` is a banner that disagreed with its run, and repo history has
a backfill whose `--dry-run` wrote everything anyway. The document-id paging loop was hand-written six
times before `scanByName` was extracted, and `backfill-client-sort-fields.js` wrote a seventh copy on
2026-09-04 (folded back 2026-09-05) while already importing `_flags`, `_batch` and `_project`.
`audit-wave-contract.js` fired its whole audit at REQUIRE time against whatever credentials were
ambient, so no test could load it; its `audit` already took an injected `db`.

## Decision
`bootstrapScript(argv, {assertFlags})` (`scripts/_project.js`) owns the preamble, printing the banner
BEFORE the first read; pass the script's own `assertFlags` wrapper, not a flag list.
`for await (const doc of scanByName(collection, {pageSize}))` (`scripts/_scan.js`) owns paging. A script
that is also a module guards `main()` behind `require.main === module`.

## Consequences
`applicationDefault()` resolves ambient credentials and nothing on the command line names the project,
so a late banner is a blind prod write. The flag lists legitimately differ and each wrapper is pinned by
jest; re-passing lists would create a second spelling free to drift. A script without `--dry-run` in its
allowlist (`audit-wave-contract.js`, `count-multi-day-appointments.js`) never sees one, so `dryRun` is
structurally false. `scripts/backfill.js` deliberately skips `bootstrapScript`: it branches on
`FIRESTORE_EMULATOR_HOST` and hard-fails on missing credentials — a different preamble. Every omitted
cursor advance (page one forever) or short-page break is a wrong number this project decides on.
