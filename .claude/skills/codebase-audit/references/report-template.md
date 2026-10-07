# Audit report format

Save the full report to a DATED file, `docs/audits/CODEBASE_AUDIT_<YYYY-MM-DD>.md`.
There is no rolling `CODEBASE_AUDIT.md` any more — overwriting one in place is how
two snapshots were lost. Give the user a tight inline
summary too (counts per severity + the top 3 things to look at first). Order
findings by severity, highest first. Every finding needs a concrete location and
a suggested fix the user can act on. Never include secrets, tokens, or PII —
describe the location, not the value.

Use this structure:

```markdown
# Codebase Audit — <YYYY-MM-DD>

Scope: <whole repo | paths>. Baseline: <git ref / "working tree">.

## Summary
- Scanned: <N files across lib/ functions/ rules>
- Auto-fixed (safe, in the diff): <N> — <one-line gist, e.g. "12 unused imports,
  3 dead methods, 5 const/token cleanups">
- Reported for your decision: <N>  (⚠️ <p> pre-ship · 🔴 <s> security · 🟠 <b> bugs · 🔵 <i> improvements)
- Verification: flutter analyze <pass/fail vs baseline> · flutter test <x/y> ·
  functions lint <pass/fail>

## Auto-applied cleanups (review the diff)
| File:line | Change | Why |
|---|---|---|
| lib/... | Removed unused import `foo.dart` | unused_import |
| lib/... | `Color(0xFF6750A4)` → `scheme.primary` | design token |
> Full detail is in `git diff`. Nothing below this line was auto-changed.

## ⚠️ Pre-ship checklist (act before release)
Items that are intentional today but MUST be handled before production — surfaced
here, near the top, so they're not buried. Include destructive `TODO(pre-ship)`
scaffolding (e.g. a real delete wired into the UI for testing), the pre-ship App
Check flips, and anything gated on store launch. Omit this section only if there
are genuinely none.
- [ ] `path:line` — <what it is, why it must change before ship, e.g. "testing-only
  delete-employee button wires a real irreversible delete into the admin UI">

## 🔴 Security findings (review required)
### S1 — <title>  · severity: critical/high/medium/low · confidence: high/med/low
- **Where:** `path:line`
- **Risk:** <what an attacker/misuse could do, concretely>
- **Fix:** <suggested change; if it needs a rules deploy, say so>

(repeat S2, S3, …)

## 🟠 Bug findings (review required)
### B1 — <title>  · severity · confidence
- **Where:** `path:line`
- **Problem:** <what goes wrong and when>
- **Fix:** <suggested change>

(repeat B2, B3, …)

## 🔵 Areas to improve (review required)
Proactive improvement opportunities — refactors, complexity hotspots, duplication,
test-coverage gaps, and performance wins. Not defects, so always report-only (the
fix reshapes code or adds tests). Order by payoff, highest first.
### I1 — <title>  · impact: high/medium/low · confidence
- **Where:** `path:line` (or file + approx line count)
- **Opportunity:** <what would make it better and why it matters — maintainability,
  robustness, or measured cost>
- **Suggested improvement:** <concrete, proportionate change; no premature
  abstraction — flag duplication only at 3+ instances>

(repeat I2, I3, …)

## 🟡 Code-quality suggestions (optional)
Convention drift and refactors that need a real edit (so they're not auto-applied):
- `path:line` — <e.g. SnackBar → noticeServiceProvider; Exception → typed Failure;
  direct FirebaseFirestore.instance in widget → route via service>

## Notes / uncertainties
- <anything you couldn't fully verify, assumptions, or follow-ups — e.g.
  "skipped generated files", "N ARB keys look orphaned — flagged for a separate
  l10n pass rather than deleted">
```

Severity guide: **critical** = exploitable now / data exposure / auth bypass;
**high** = likely bug or security gap with real impact; **medium** = correctness
risk under some conditions; **low** = minor / defense-in-depth. Confidence
reflects how sure you are it's real (a static guess vs. a traced data path).
