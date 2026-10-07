---
description: Implement every open finding in the newest audit report, verify, and mark them closed
argument-hint: [report path or finding ids] (optional; default = newest docs/audits report, all open ids)
---

Implement the findings from a codebase audit. This is the message that has
followed every audit in this repo's history — "do all the items from the
audit", "start all items, use sub agents", "finish the remaining audit items"
— so treat a bare invocation as meaning **all open findings**.

## 1. Find the report and build the list

`$ARGUMENTS` may name a report path or specific ids (`S1 B3 I12`). With no
argument, take the newest file matching `docs/audits/*AUDIT*.md` by date in the
filename, and say which one you picked before doing anything.

Extract every finding as `{id, severity, file:line, claim, suggested fix}` and
put each one in the todo list. Then split it into three buckets and **show the
buckets before starting**:

- **Doing now** — everything implementable in the working tree.
- **Needs your decision** — findings where the fix is a product choice, not a
  correctness one. Ask these as one batched question, not one at a time.
- **Left for you** — pre-ship switches (App Check flips, destructive
  `TODO(pre-ship)` scaffolding) and anything that needs a prod deploy, a
  Firestore index, or a backfill script to be run first. Never auto-run those.

## 2. Verify each finding before you build it

An audit finding is a claim, not a fact, and this repo has burned real time on
three specific ways they are wrong:

- **"There is no test for X"** is usually false — coverage here often lives
  under the *caller's* file name, not the subject's. Grep for the behaviour
  before writing a duplicate test.
- **"This guard is covered"** can be false even when a test names it. A mocked
  dependency that is never asserted on greps as covered; only deleting the
  guard and re-running tells you.
- **A suggested fix can be wrong as written.** Past audits produced a gate that
  wrongly excluded the series root, and an index that dropped documents because
  a prefix composite is `SPARSE_ALL`. If the suggestion is wrong, implement the
  *correct* fix and record the deviation — do not implement it as written and
  do not silently skip it.

If a finding does not reproduce, mark it `not-a-defect` with the evidence
rather than inventing a change.

## 3. Work through them

Go finding by finding, in severity order — security, then bugs, then
improvements. Small related findings in one file can share a pass.

For a large independent set, fan out subagents (this is what the user asks for
by default): routine mechanical fixes to Sonnet, harder reasoning to Opus,
cross-cutting design calls kept here. Send independent agents in one message so
they run concurrently. Do **not** fan out when findings touch the same files —
that produces conflicting edits, not speed.

Respect the standing rules while fixing: the `code-quality.md` anti-defaults
(no premature abstraction, no comment blocks restating a rule that belongs in
`.claude/rules/`), the load-bearing invariants in CLAUDE.md, and the
"Do not touch" list in the codebase-audit skill's `references/project-map.md`.

## 4. Verify

Run the four commands CI runs, and report the counts you actually observed:

```
flutter analyze          # baseline is: No issues found!
dart run tool/test.dart  # full suite, sharded (~3 min), as CI runs it
cd functions && npm run lint
cd functions && npx jest
```

If a fix broke something, fix it or revert that one finding back to open —
never leave the tree red and never carry a green count forward from the report.

## 5. Close the loop in the report

Edit the audit file in place. Keep every finding id and annotate it:
`DONE`, `DONE (deviated — <what and why>)`, `NOT A DEFECT — <evidence>`, or
`OPEN — needs <deploy / backfill / your decision>`. Do not delete rows; the
user comes back days later asking what is still open and the ids are the index.

## 6. Report

- Counts: implemented / deviated / not-a-defect / still open.
- Every deviation, in one line each.
- The **Left for you** list, restated, with the exact next action for each.
- Do not commit or push — that is `/ship`, and the user decides when.
