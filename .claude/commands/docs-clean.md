---
description: Sweep docs/ against what the code actually does — archive shipped plans, refresh the indexes and stamps, fix contradictions
argument-hint: [area] (optional; e.g. "plans", "audits", "architecture")
---

Reconcile `docs/` with the current code. This is the standalone sweep the user
asks for as "clean up what's in docs based on what's been done in the code" and
"clean up all the plans and see what hasn't been done" — **not** the
release-time doc pass, which `/release` §6–§8 already owns and which works from
a diff. This one works from the repo as it stands.

Scope to `$ARGUMENTS` if given; otherwise sweep all of `docs/`.

## The layout, and which file is allowed to be authoritative

| Path | Role |
|---|---|
| `ARCHITECTURE.md`, `CLOUD_FUNCTIONS.md`, `DEPLOYMENT.md` | **Current state.** These three plus CLAUDE.md are the only docs that describe what the code does today. |
| `cost-breakdown.html`, `IOS_MAC_BUILD.md` | Current state, narrower. |
| `plans/` | **Live work only**, indexed by `plans/README.md`. |
| `audits/` | Dated snapshots, plus two `audit-*.js` scripts — those are code, leave them. |
| `archive/` | **Frozen.** History, indexed by `archive/README.md`. |
| `legal/*.html` | Published pages. Do not touch here — see Never, below. |

**A plan doc is never the source of truth for current state.** If a plan and
`ARCHITECTURE.md` disagree, the code decides and `ARCHITECTURE.md` gets fixed;
the plan is a record of a decision, not a description of the app.

## 1. Reconcile every live plan against the code

For each file in `docs/plans/`, decide **shipped / partly shipped / not
started / superseded** — and decide it from the code and `git log`, never from
the document.

Two traps, both of which have already produced wrong answers here:

- **Unticked checkboxes mean nothing.** Plans in this repo were executed
  without ticking. An unticked box is *unknown*, not *outstanding*. Read the
  status banner at the top of the file, then verify it against the code.
- **A plan's own "implemented" banner can be stale in the other direction** —
  written when the Dart landed, while the backend half is still undeployed.
  Check `docs/DEPLOYMENT.md`'s log before calling anything done.

Write the verdict into each plan's status banner, with the evidence (a commit,
a symbol, a deploy-log line). One banner per file, replacing the old one — never
append a second.

## 2. Archive what has shipped

Anything fully shipped **and** deployed moves to `docs/archive/`, and a
superseded audit snapshot moves with it.

- **Propose the move list and get one confirmation before moving anything.**
  Archiving a plan that is still live is the expensive mistake here.
- `git mv`, so history follows.
- Add each moved file to `archive/README.md` under the right section, one line
  saying what it was and when it shipped. A file moved but not indexed is lost.
- **Never delete a doc.** Archive is the only removal.
- **Before overwriting the rolling `docs/audits/CODEBASE_AUDIT.md`, copy the
  outgoing one into `archive/` first.** Two snapshots were overwritten in place
  once and had to be recovered from git history. (New audits are written to
  dated filenames now, which removes the hazard going forward — but the rolling
  file still exists.)

## 3. Refresh the two indexes

- `plans/README.md` — every file in `plans/` gets a row with its State, and the
  sweep stamp at the top gets today's date. **Check this every time:** the index
  goes stale silently as plans are added, and it has run 21 files behind.
- `archive/README.md` — same completeness check for what is in `archive/`.

## 4. Fix stamps and counts in the current-state docs

These drift quietly and are cheap to verify:

- `ARCHITECTURE.md` test count — `dart run tool/test.dart` (same count as bare
  `flutter test`) and `npx jest` in `functions/`.
  Use the runner's real number; do not copy one forward from a plan or a memory
  note. (It has been off by one against the live suite.)
- `CLOUD_FUNCTIONS.md` — the export count against
  `grep -cE "^exports\.[a-zA-Z]" functions/index.js`, and its "refreshed" date.
  Its stacked "Previously refreshed …" history block is the one thing here worth
  **trimming**: keep the current line and the last few, move the rest to
  `archive/`.
- `cost-breakdown.html` — the function count and its "as of" line.
- Any other `as of <date>` / "N functions" / "N tests" claim you touch.

## 5. Mechanical checks

- **Broken relative links** in the current-state docs and the two indexes: for
  every `](path)` that is not a URL, confirm the target exists.
- **Orphans** — a file in `docs/` referenced by nothing. Report it; do not
  delete it.
- **Contradictions** — where two current-state docs describe the same thing
  differently, fix in place so the stale version is gone. Never leave both.

## Never

- **Do not rewrite links inside `archive/`.** Those documents are frozen as
  written and several cite their old `docs/plans/` paths on purpose: a task list
  that said "edit `docs/plans/X`" was true when it ran, and correcting it
  falsifies the record. Read a bare filename there as "same folder".
- **Do not touch `docs/legal/*.html`.** They are published pages with their own
  republish step; changing wording here is a legal-content change, not a doc
  tidy.
- Do not edit CLAUDE.md or `.claude/rules/` — a durable fact belongs there, not
  in `docs/`, but moving it is `/release` §6's job and the revise-claude-md
  skill's method.
- Do not delete the `audits/*.js` scripts.
- Do not commit or push. That is `/ship`.

## Report

- Plans reclassified, with the new verdict for each.
- Files moved to `archive/` (or proposed, if not yet confirmed).
- Stamps and counts corrected, old value → new value.
- Broken links and orphans found.
- Contradictions fixed, and any you could not resolve without the user.
