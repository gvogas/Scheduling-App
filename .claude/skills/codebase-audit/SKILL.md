---
name: codebase-audit
description: >-
  Whole-codebase health sweep for this Flutter + Firebase Scheduling App: scans
  for dead/unused code, messy code, bugs, security vulnerabilities, and areas to
  improve (refactor/maintainability/test-coverage/performance opportunities),
  then AUTO-FIXES the safe stuff (unused imports, dead code, mechanical/design-
  token cleanups) and REPORTS the risky stuff (logic bugs, security findings,
  improvement opportunities) for you to decide on. Use whenever the user wants
  to audit, scan, clean up, tidy, or
  health-check the code across the project: "find dead code", "remove unused
  code", "scan for bugs", "any security holes?", "is my code safe", "review the
  whole project", "tighten this up". Trigger even when only ONE concern is named
  (just dead code, just security) or the word "audit" never appears — any broad
  cleanup/quality/safety request spanning more than one diff. Do NOT use it for a
  single scoped task better served elsewhere: reviewing one diff/PR
  (/code-review, /security-review), debugging one error, formatting, upgrading a
  dependency, writing tests, explaining code, fixing one known bug, or setting up
  tooling/CI.
---

# Codebase Audit & Cleanup

Sweep the codebase for five things — **dead code, messy code, bugs, security
vulnerabilities, and areas to improve** (refactor / maintainability / complexity
/ test-coverage / performance opportunities) — and split what you find by how
safe it is to act on:

- **Auto-fix the safe stuff.** Unused imports, provably-dead code, mechanical
  style, obvious design-token swaps — apply these directly, then prove you
  didn't break anything (`flutter analyze` + `flutter test` stay green).
- **Report the risky stuff.** Logic bugs, security findings, AND improvement
  areas (refactors, complexity hotspots, test-coverage gaps, performance
  opportunities) get a severity/impact-ranked report with `file:line`, the risk
  or payoff, and a suggested fix. You do not change behavior or touch security-
  sensitive paths without the user deciding — and improvement refactors always
  reshape code, so they are report-only too, never auto-applied. The user
  explicitly chose this split — honor it.

"Areas to improve" is the proactive lens on top of the four defect classes: not
"is this broken?" but "what would make this code better?" — over-long `build()`
methods and god files, substantial duplication (only when repeated 3+ times —
respect the `code-quality.md` anti-defaults, never recommend premature
abstraction), missing tests on important logic, and real performance/read-cost
wins. Surface these every run, ranked by payoff, even when nothing is broken.

The reason for the split: removing an unused import is reversible and obvious;
changing a Firestore rule or "fixing" a suspected bug can break a load-bearing
invariant or change behavior in ways only the human can sign off on. Cheap-and-
reversible → just do it. Semantic-or-security → surface it.

## This codebase has load-bearing code that LOOKS removable

Before deleting anything, read `references/project-map.md` → "Do not touch".
This app has intentional patterns a naive cleaner would wrongly "tidy away":
`App Check activation`, the appointment status allowlist, role-from-Firestore
(never cache), image magic-byte validation, Wave back-compat reads,
`TODO(pre-ship)` scaffolding, l10n keys, Riverpod providers, and route names —
many are referenced indirectly (by string, by generated getter) so static
analysis reports them as unused when they are not. **If something looks dead or
redundant but appears in that list, REPORT it — never auto-remove it.**

## Workflow

Work the steps in order. Adapt the scale to the request: a whole-codebase sweep
warrants the parallel deep-review fan-out (step 2); "clean up `lib/features/wave`"
can skip straight to a focused pass over those files.

### 0. Scope and make changes reviewable
- Confirm the scope: whole repo (`lib/`, `functions/`, `firestore.rules`,
  `storage.rules`, `test/`) or a named subset. Default to whole-repo.
- Check `git status` is clean (or note what's already dirty) so your auto-fixes
  land as a separate, reviewable diff. Do **not** auto-commit — the user reviews
  the diff. If the tree is dirty, tell the user and keep your edits distinct.

### 1. Deterministic static scan (cheap, high-signal — do this first)
Run `scripts/static_scan.sh` from the repo root. It collects, read-only:
`flutter analyze` filtered to real errors/warnings (info-level lints are noise —
there may be few or none), the `dart fix --dry-run` preview of automated fixes,
the Cloud Functions ESLint report, an unused-file heuristic, and an **unused-
dependency** heuristic (pubspec/`package.json` entries with no `package:<name>/`
or `require` reference). This is your ground truth for dead code, dead weight,
and mechanical style before you reason about anything. Read its output fully —
and treat the dependency hits as candidates to verify, not facts (transitive-
only, codegen-annotation, and native auto-init packages are false positives;
see `safe-vs-risky.md`).

### 2. Parallel deep review (for bugs + security + cleanliness + improvements)
Static tools miss logic bugs, security holes, convention violations, and the
proactive "what would make this better" lens. Fan out independent reviewers so
each concern gets full attention — dispatch these in ONE message so they run
concurrently:
- **security** → the `security-reviewer` agent, pointed at `references/security-checklist.md`
- **bugs** → the `code-reviewer` (or `general-purpose`) agent
- **dead code + cleanliness** → a `general-purpose` agent told to verify
  suspected-dead code against `references/project-map.md` → "Do not touch" and
  to find convention drift (hardcoded colors/spacing, raw SnackBars, untyped
  failures, direct `FirebaseFirestore.instance` in UI)
- **areas to improve** → a `performance-reviewer` agent (rebuild waste, Firestore
  read cost, hot-path computation, leaked subscriptions) AND a `general-purpose`
  agent for maintainability (over-long `build()`/god files with line counts,
  substantial 3+-instance duplication, test-coverage gaps comparing `lib/` to
  `test/`, robustness gaps like missing `mounted` checks). Tell the
  maintainability agent to honor the `.claude/rules/code-quality.md`
  anti-defaults — NO premature abstraction, flag duplication only at 3+
  instances — so it proposes proportionate improvements, not over-engineering.

Give each agent the scope, the relevant reference file, and ask for findings as
`{file:line, what, why it matters, severity/impact, confidence, suggested fix}`.
For a small scope you can do this inline instead of spawning agents.

### 3. Apply ONLY the safe fixes
Use `references/safe-vs-risky.md` as the line. Safe = apply now:
- `dart fix --apply` for the automated lint fixes (unused imports, `const`, …).
- Remove dead code the analyzer flagged (`unused_element`/`unused_field`/
  `unused_local_variable`) **after** confirming zero references (see the
  dead-code rules in `safe-vs-risky.md` — l10n keys, providers, and route names
  are reference-by-string traps).
- Mechanical, behavior-preserving cleanups with an unambiguous target (e.g. a
  hardcoded `Color(0xFF...)` that maps to an existing `ColorScheme`/token).
- For Cloud Functions, `eslint --fix` the auto-fixable rules.

Anything that changes behavior, touches a "Do not touch" invariant, or needs a
judgment call does NOT get applied here — it goes in the report (step 4).

### 4. Compile the report for the risky findings
Write the report using `references/report-template.md`. It covers: what you
auto-fixed (point at the diff), then severity-ranked **security** and **bug**
findings, then impact-ranked **areas to improve** (refactor / test-coverage /
performance opportunities) and optional code-quality suggestions. Save it to the dated
file named below (the project keeps audit docs in `docs/audits/`) and give the
user a tight inline summary — counts per severity and the top 3 things to look
at first. Never paste secrets, tokens, or PII into the report.

**Save it to a DATED file, `docs/audits/CODEBASE_AUDIT_<YYYY-MM-DD>.md`**, and
give every finding a stable id (`S1`, `B3`, `I12`) in a heading. The
`/audit-do` command finds the newest file by that name and works the ids, and
the user routinely comes back days later asking what is still open — a report
that overwrote its predecessor cannot answer that. Leave the id in place when
a finding is closed and mark it, rather than deleting the row.

**Don't let "do not touch" become "stay silent."** Items you correctly leave
un-removed because they're load-bearing or intentional — `TODO(pre-ship)`
scaffolding (especially anything destructive, like a real delete wired into the
UI for testing), the pre-ship App Check flips, orphaned-looking l10n keys —
still belong in the report, surfaced by importance. Put genuinely ship-blocking
ones (a live destructive action behind a `TODO(pre-ship)`) in a dedicated
**Pre-ship checklist** section near the top, not buried in a footnote. Reporting
≠ whispering; the user needs to see the thing they have to act on before launch.

### 4b. Offer (or run) the implement pass
After **every** past audit — seventeen times across the transcript history —
the user's next message has been some form of **"do all the items from the
audit"**: "do everything in the audit", "start all items, use sub agents",
"finish the remaining audit items". Assume it is coming.

- If the invocation already asked for it (args mention "implement", "do all",
  "do everything"), roll straight from the report into `/audit-do` rather than
  stopping to present findings the user has pre-approved.
- Otherwise end the report with exactly that offer, and name the two escape
  hatches so a blanket "do all" is still safe: **pre-ship items** (App Check
  flips, destructive `TODO(pre-ship)` scaffolding, launch-time switches) and
  **anything needing a prod deploy or backfill** are never auto-implemented.
- Findings the user should decide on individually go in a short **Decide
  first** list at the top of the report, so "do all" has an unambiguous
  meaning and the user is not asked to re-read everything to find the choices.

### 5. Verify before you claim done
Re-run `flutter analyze` — the baseline is **`No issues found!`**, so any line
it prints is yours — and the relevant `flutter test` targets: full suite for a
broad sweep, the touched test files for a scoped one. For Functions changes,
`cd functions && npm run lint && npx jest`. These are the same four commands CI
runs on push, so a green pass here is also what keeps the push green. If a
fix broke something, revert that fix and move it to the report rather than
leaving the tree red. State the actual results — don't assert green you didn't
observe.

## Reference files
- `references/project-map.md` — codebase layout, tooling commands, and the
  **"Do not touch" load-bearing invariants** (read before deleting anything).
- `references/safe-vs-risky.md` — the auto-fix vs. report taxonomy and the
  dead-code "verify before deleting" rules.
- `references/security-checklist.md` — Firebase/Flutter security audit checklist
  tailored to this app (App Check, Firestore rules, secrets, callable payloads…).
- `references/report-template.md` — the findings-report format.
- `scripts/static_scan.sh` — the read-only static-analysis collector for step 1.
