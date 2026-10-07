---
description: Run a functions/scripts one-off against prod — exact command, dry run first, then live
argument-hint: [what you want to do, or a script name] (e.g. "search tokens backfill")
---

Give the user the exact command for a one-off script in `functions/scripts/`
and walk the dry-run → review → live sequence. This exchange has happened
dozens of times in this repo ("what is the command", "what do i run", "what
script do i need to run"), always in the same shape, and it touches production
data — so run it the same way every time.

## 1. Pick the script and read it

List `functions/scripts/` and match `$ARGUMENTS` to one. If two could fit, ask
which — do not guess when the answer writes to prod.

Then **read the script** before quoting any command. Two things must come from
the source, never from memory:

- **Its `EXACT_FLAGS` / `PREFIX_FLAGS`.** Every script keeps its own list and
  they legitimately differ (some take `--since=`, most don't). `_flags.js`
  rejects any argument not on that list, which is deliberate: a typo'd
  `--dryrun` would otherwise read as false and write to prod LIVE.
- **Whether it takes `--dry-run` at all.** The read-only `audit-*` / `count-*`
  scripts have no such flag by design, so don't offer one for them.

Say in one line what the script will change and roughly how many documents.

## 2. Dry run

`run.js` is dry-run by default; `--live` is the only way to write, and it
re-runs the dry run first.

Give one copy-pasteable PowerShell line, run from the repo root:

```powershell
node functions/scripts/run.js <name>
```

Tell the user to check the banner line the script prints **before** anything
else in the output:

```
[dry-run] target: schedulingapp-88727 (LIVE)
```

`(unknown — check your credentials)` means ADC did not resolve — stop, do not
proceed. A `via emulator` suffix means it is not pointed at prod at all.

## 3. Read the pasted output back

The user will paste the dry-run output. Interpret it concretely:

- The count of documents that would change, and whether that is plausible
  against what is actually in the collection.
- Any sample rows that look wrong. A wrong-looking sample is a reason to fix
  the script, not to proceed — a bad bulk rewrite here has needed a repair
  script before, and a repair script means the live write path still has the
  bug.
- Zero changes is a real answer. Say so plainly rather than suggesting a live
  run "to be sure".

## 4. Live run — only after the user says go

```powershell
node functions/scripts/run.js <name> --live
```

`--live` re-runs the dry run and asks for its count typed back; a count from
an earlier run is refused, by design.

Never run this on the user's behalf without an explicit go-ahead on the numbers
they just reviewed.

## 5. After it lands

- Have the user paste the live output and confirm the counts match the dry run.
- **Re-running an idempotent script is a measurement, not a mistake** — identical
  numbers days apart is how this repo proved nothing was still writing the old
  shape. Offer it when the question is "has everything migrated?".
- Record it: the deploy log in `docs/DEPLOYMENT.md` for anything release-gating,
  or the plan/audit doc that asked for it. An unrecorded prod script is
  indistinguishable from one that was never run.
- If the script was a **release prerequisite** (the search-token and
  client-sort-field backfills are), say explicitly whether the app build is now
  unblocked.
