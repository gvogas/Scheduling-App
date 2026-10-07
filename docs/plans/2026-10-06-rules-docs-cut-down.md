# Rules Docs Cut-Down Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the rules corpus (`CLAUDE.md`, `.claude/rules/*.md`, nested `CLAUDE.md` files) from ~600 KB to ~170 KB of terse invariants, without losing a single rule, by moving history into dated ADRs and moving mechanically checkable bans into a CI script.

**Architecture:** Every rules file keeps its frontmatter and becomes a list of one-to-three-line imperative invariants. The "why / it used to be / retired on" prose moves to short ADRs under `docs/decisions/`, and each invariant links to its ADR by number. Five bans move into `tool/check_rules.dart`, which runs in CI after `flutter analyze`, and their prose shrinks to one line naming the check.

**Tech Stack:** Markdown, Dart (`dart:io` script plus a `flutter_test` unit test), GitHub Actions.

## Decisions (owner may veto any of these before Task 1)

1. **Targets.** Each rules file is at most **10 KB**. Root `CLAUDE.md` is at most **12 KB**.
2. **History moves to ADRs.** Any "used to be X, retired on date Y, don't restore Z" text moves to `docs/decisions/NNNN-<slug>.md` (Context / Decision / Consequences, each a few lines). The invariant that remains ends with `(ADR-NNNN)`.
3. **CONVENTION CHANGE: needs owner sign-off.** `.claude/rules/code-quality.md` currently says that a block explaining WHY a guard has its shape "belongs in these rules files" (owner call, 2026-09-03). Task 2 changes this so rationale lives in `docs/decisions/` ADRs linked from the rules. This is the only convention this plan changes. **Do not start Task 3 until the owner has signed off.**
4. **No invariant may be lost.** Every rewrite task inventories each never / always / must / don't / only sentence in the old file (`git show HEAD:<file>`). Each one must be accounted for in the new file, in an ADR, or in `tool/check_rules.dart`.
5. **Frontmatter is untouched.** `paths:` and `alwaysApply:` blocks stay byte-for-byte the same.
6. **Mechanical bans move to CI.** `tool/check_rules.dart` enforces five bans with a baseline of ZERO hits. Each one was measured on `0c57505e`:

   | Ban | Allowlist | Baseline |
   |---|---|---|
   | `package:firebase_analytics` import | `lib/core/analytics/analytics_service.dart` | 0 |
   | `FirebaseFirestore.instance` | `lib/core/providers/firebase_providers.dart`, `lib/main.dart`, `lib/features/auth/services/auth_service.dart` | 0 |
   | `as Map<String, dynamic>?` | none | 0 |
   | `Timer(` / `Timer.periodic(` under any `/widgets/` or `/screens/` dir | none (debounce goes through `Debouncer`) | 0 |
   | `ref.read(` inside a `catch` block (brace-depth heuristic) | none | 0 |

   The script scans `lib/` only and skips `lib/l10n/.gen/`, `*.g.dart` and `*.freezed.dart`.
7. **Order is largest first, one commit per file.** That order is appointments.md, employees.md, clients.md, notifications.md, CLAUDE.md, frontend.md, images.md, then the rest.

## Sizes (bytes, measured on `0c57505e`)

| File | Before | Target |
|---|---:|---:|
| `.claude/rules/appointments.md` | 83 428 | ≤ 10 000 |
| `.claude/rules/employees.md` | 68 289 | ≤ 10 000 |
| `.claude/rules/clients.md` | 65 093 | ≤ 10 000 |
| `.claude/rules/notifications.md` | 53 775 | ≤ 10 000 |
| `CLAUDE.md` | 48 955 | ≤ 12 000 |
| `.claude/rules/search.md` (**new**, split out of `CLAUDE.md`) | — | ≤ 10 000 |
| `.claude/rules/frontend.md` | 47 927 | ≤ 10 000 |
| `.claude/rules/images.md` | 38 879 | ≤ 10 000 |
| `functions/CLAUDE.md` | 35 250 | ≤ 10 000 |
| `.claude/rules/wave.md` | 35 172 | ≤ 10 000 |
| `lib/features/calendar/CLAUDE.md` | 31 554 | ≤ 10 000 |
| `.claude/rules/error-handling.md` | 25 721 | ≤ 10 000 |
| `.claude/rules/analytics.md` | 12 061 | ≤ 10 000 |
| `ios/CLAUDE.md` | 11 425 | ≤ 10 000 |
| `.claude/rules/security.md` | 10 780 | ≤ 10 000 |
| `lib/features/feature_tour/CLAUDE.md` | 10 639 | ≤ 10 000 |
| `.claude/rules/testing.md` | 9 092 | unchanged |
| `.claude/rules/firestore-indexes.md` | 5 640 | unchanged |
| `lib/core/navigation/CLAUDE.md` | 4 008 | unchanged |
| `.claude/rules/code-quality.md` | 2 901 | ~3 000 (Task 2 edit only) |
| **Total** | **600 589** | **≤ ~178 000** |

`docs/ARCHITECTURE.md`'s Test Strategy section mirrors `testing.md`. `testing.md` isn't rewritten, so the mirror is unaffected.

## File map

- Create: `tool/check_rules.dart`. A pure `scanRules(Map<String, String> files)` returning violations, plus a `main` that reads `lib/` and exits 1 on any violation.
- Create: `test/tool/check_rules_test.dart`. Unit tests on `scanRules` with synthetic file maps. `tool/test.dart` picks it up automatically, since it shards every `test/**/_test.dart`.
- Modify: `.github/workflows/ci.yml`. Add a "Check rules" step after "Analyze".
- Create: `docs/decisions/README.md` (index and template), then `docs/decisions/NNNN-<slug>.md`, one per moved rationale.
- Create: `.claude/rules/search.md`. The search block moves out of root `CLAUDE.md`.
- Modify: every file in the size table except the three marked unchanged.

## The rewrite procedure (used by Tasks 3 to 18)

Every rewrite task runs these exact steps on its file `$F`, with short name `$N` (for example `appointments`).

- **R1. Inventory the old rules.**
  ```bash
  mkdir -p build/rules_audit
  git show HEAD:$F > build/rules_audit/$N.old.md
  grep -niE "\b(never|always|must|don't|do not|only|exactly|one owner)\b" build/rules_audit/$N.old.md > build/rules_audit/$N.inventory.txt
  wc -l build/rules_audit/$N.inventory.txt
  ```
  `build/` is gitignored, so the audit files never get committed.
- **R2. Classify every bold-led bullet** (`grep -nE "^- \*\*" build/rules_audit/$N.old.md`) as exactly one of:
  - **INVARIANT** (a rule a future change could break): keep it as one to three imperative lines.
  - **RATIONALE / HISTORY** (dates, "used to", "was", "retired", "this said", worked incidents): move it to an ADR.
  - **ENFORCED** (one of the five Decision-6 bans): replace it with `Enforced by \`tool/check_rules.dart\` (<ban name>).`
  - **DUPLICATE** (restated in another rules file): keep the copy in the file whose `paths:` covers the code, and replace this one with `See \`.claude/rules/<file>.md\`.`
- **R3. Write the ADRs.** Get the next number with `ls docs/decisions | grep -E '^[0-9]{4}' | tail -1`. Use this template:
  ```markdown
  # NNNN. <Title>

  **Date:** <original decision date from the old text> · **Rules file:** `<$F>`

  ## Context
  <what went wrong or what forced the choice — 2-6 lines, keep the concrete incident>

  ## Decision
  <the rule, as stated in the rules file>

  ## Consequences
  <what breaks if it regresses; what NOT to "fix" — 1-4 lines>
  ```
  Group related history into one ADR per decision, not one per sentence. Add a row to `docs/decisions/README.md` for each ADR.
- **R4. Rewrite `$F`.** Keep the frontmatter byte-for-byte. Use a single `#` title and `##` sections grouped by subject. Every bullet starts with the imperative and names the owning symbol and file (`` `findBusyEmployees` (`firebase_appointments_repository.dart`) ``) and ends with `(ADR-NNNN)` when one exists.
- **R5. Check the frontmatter is unchanged.**
  ```bash
  diff <(awk '/^---$/{c++; print; if(c==2) exit; next} c==1' build/rules_audit/$N.old.md) <(awk '/^---$/{c++; print; if(c==2) exit; next} c==1' $F) && echo FRONTMATTER-OK
  ```
  Expected: `FRONTMATTER-OK`. For files with no frontmatter, both sides are empty and it still prints `FRONTMATTER-OK`.
- **R6. Verify no invariant was lost.** Walk `build/rules_audit/$N.inventory.txt` line by line. For each line, note where it now lives (`$F:<line>`, `ADR-NNNN`, `check_rules:<ban>`, or `dup:<file>`) in `build/rules_audit/$N.mapping.txt`, one line per inventory line. Then run:
  ```bash
  wc -l build/rules_audit/$N.inventory.txt build/rules_audit/$N.mapping.txt
  grep -c "UNMAPPED" build/rules_audit/$N.mapping.txt
  ```
  Expected: the two line counts are equal and `UNMAPPED` is `0`. Any line you cannot place is a lost invariant. Put it back in `$F`.
- **R7. Check the size and the links, then commit.**
  ```bash
  wc -c $F
  grep -oE "ADR-[0-9]{4}" $F | sort -u | while read a; do ls docs/decisions/${a#ADR-}-*.md >/dev/null 2>&1 || echo "MISSING $a"; done
  git add $F docs/decisions/
  git commit -m "Cut $N rules to invariants; history to ADRs"
  ```
  Expected: the size is at most the target, there are no `MISSING` lines, and the commit succeeds. End the commit message with the session's attribution lines.

---

### Task 1: `tool/check_rules.dart`, its test, and the CI step

**Files:**
- Create: `tool/check_rules.dart`
- Create: `test/tool/check_rules_test.dart`
- Modify: `.github/workflows/ci.yml` (after the `Analyze` step, around line 44)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_rules.dart';

void main() {
  group('scanRules', () {
    test('clean tree has no violations', () {
      expect(scanRules({'lib/features/a/widgets/x.dart': 'class X {}'}), isEmpty);
    });

    test('firebase_analytics outside the service is flagged', () {
      final v = scanRules({
        'lib/features/a/b.dart':
            "import 'package:firebase_analytics/firebase_analytics.dart';",
        'lib/core/analytics/analytics_service.dart':
            "import 'package:firebase_analytics/firebase_analytics.dart';",
      });
      expect(v.map((e) => e.rule), ['analytics-import']);
      expect(v.single.path, 'lib/features/a/b.dart');
    });

    test('FirebaseFirestore.instance outside the allowlist is flagged', () {
      final v = scanRules({
        'lib/features/a/screens/s.dart': 'final f = FirebaseFirestore.instance;',
        'lib/core/providers/firebase_providers.dart':
            '(ref) => FirebaseFirestore.instance,',
      });
      expect(v.map((e) => e.rule), ['firestore-instance']);
    });

    test('strict callable map cast is flagged', () {
      final v = scanRules({
        'lib/a.dart': 'final m = r.data as Map<String, dynamic>?;',
      });
      expect(v.map((e) => e.rule), ['strict-map-cast']);
    });

    test('Timer in a widget or screen is flagged, elsewhere is not', () {
      final v = scanRules({
        'lib/features/a/widgets/w.dart': 'final t = Timer(d, f);',
        'lib/features/a/screens/s.dart': 'final t = Timer.periodic(d, f);',
        'lib/features/a/application/c.dart': 'final t = Timer(d, f);',
      });
      expect(v.map((e) => e.rule), ['widget-timer', 'widget-timer']);
    });

    test('ref.read inside a catch block is flagged', () {
      final v = scanRules({
        'lib/a.dart': '''
void f() {
  final logger = ref.read(loggerProvider);
  try {
    g();
  } catch (e, st) {
    ref.read(loggerProvider).warn('X', e, st);
  }
}''',
      });
      expect(v.map((e) => e.rule), ['ref-read-in-catch']);
      expect(v.single.line, 6);
    });

    test('generated files are skipped', () {
      expect(
        scanRules({
          'lib/l10n/.gen/app_localizations.dart': 'as Map<String, dynamic>?',
          'lib/a.freezed.dart': 'as Map<String, dynamic>?',
          'lib/a.g.dart': 'as Map<String, dynamic>?',
        }),
        isEmpty,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `flutter test test/tool/check_rules_test.dart`
Expected: FAIL. `tool/check_rules.dart` doesn't exist yet, so the compile fails.

- [ ] **Step 3: Write the script**

```dart
import 'dart:io';

typedef RuleViolation = ({String rule, String path, int line, String text});

const _firestoreInstanceAllowed = {
  'lib/core/providers/firebase_providers.dart',
  'lib/main.dart',
  'lib/features/auth/services/auth_service.dart',
};

bool _isGenerated(String path) =>
    path.startsWith('lib/l10n/.gen/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart');

List<RuleViolation> scanRules(Map<String, String> files) {
  final out = <RuleViolation>[];
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    if (_isGenerated(path)) continue;
    final lines = files[path]!.split('\n');
    final inUi = path.contains('/widgets/') || path.contains('/screens/');
    var catchDepth = 0;
    var catchOpened = false;
    var inCatch = false;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      void hit(String rule) =>
          out.add((rule: rule, path: path, line: i + 1, text: text.trim()));
      if (text.contains('package:firebase_analytics/') &&
          path != 'lib/core/analytics/analytics_service.dart') {
        hit('analytics-import');
      }
      if (text.contains('FirebaseFirestore.instance') &&
          !_firestoreInstanceAllowed.contains(path)) {
        hit('firestore-instance');
      }
      if (text.contains('as Map<String, dynamic>?')) hit('strict-map-cast');
      if (inUi && RegExp(r'\bTimer(\.periodic)?\(').hasMatch(text)) {
        hit('widget-timer');
      }
      var scanFrom = 0;
      final catchMatch = RegExp(r'\bcatch\s*\(').firstMatch(text);
      if (!inCatch && catchMatch != null) {
        inCatch = true;
        catchDepth = 0;
        catchOpened = false;
        scanFrom = catchMatch.start;
      }
      if (inCatch) {
        if (text.substring(scanFrom).contains('ref.read(') &&
            catchMatch == null) {
          hit('ref-read-in-catch');
        }
        for (final ch in text.substring(scanFrom).split('')) {
          if (ch == '{') {
            catchDepth++;
            catchOpened = true;
          } else if (ch == '}') {
            catchDepth--;
          }
        }
        if (catchOpened && catchDepth <= 0) inCatch = false;
      }
    }
  }
  return out;
}

void main() {
  final files = <String, String>{
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart'))
        f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
  };
  final violations = scanRules(files);
  for (final v in violations) {
    stdout.writeln('${v.path}:${v.line}: [${v.rule}] ${v.text}');
  }
  stdout.writeln('${violations.length} rule violation(s).');
  if (violations.isNotEmpty) exitCode = 1;
}
```

- [ ] **Step 4: Run the test and check it passes**

Run: `flutter test test/tool/check_rules_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Check the real tree's baseline is zero**

Run: `dart run tool/check_rules.dart`
Expected: `0 rule violation(s).` with exit code 0. If anything is listed, it's either a real violation to report to the owner, or a pattern that needs narrowing. Do NOT widen the allowlist without the owner's agreement.

- [ ] **Step 6: Add the CI step** after `Analyze` in `.github/workflows/ci.yml`:

```yaml
      - name: Check rules
        run: dart run tool/check_rules.dart
```

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add tool/check_rules.dart test/tool/check_rules_test.dart .github/workflows/ci.yml
git commit -m "Add tool/check_rules.dart: CI-enforced rules bans"
```
Expected: `No issues found!`, and the commit succeeds.

### Task 2: ADR scaffolding and the convention change (OWNER SIGN-OFF GATE)

**Files:**
- Create: `docs/decisions/README.md`
- Modify: `.claude/rules/code-quality.md` (the "Comments: one line max" bullet)

- [ ] **Step 1: Create `docs/decisions/README.md`**

```markdown
# Architecture decision records

Why a rule in `.claude/rules/` or a `CLAUDE.md` has its shape. The rules file
states WHAT to do; the ADR it cites as `(ADR-NNNN)` records why, the incident
behind it, and what not to "fix". Number sequentially; never renumber.

| ADR | Title | Rules file |
|---|---|---|
```

- [ ] **Step 2: Change the convention.** In `.claude/rules/code-quality.md`, replace this sentence:

  `a comment block explaining WHY a guard has its shape belongs in these rules files, which is where an audit and a new session actually read it.`

  with:

  `a comment block explaining WHY a guard has its shape belongs in an ADR under \`docs/decisions/\`, cited from the rule as \`(ADR-NNNN)\`; the rules files state the invariant only.`

  Also replace `check whether the fact is recorded here first, and add it here if it is not.` with `check whether the fact is recorded in the rules or an ADR first, and add an ADR if it is not.`

- [ ] **Step 3: Commit, then STOP for owner sign-off**

```bash
git add docs/decisions/README.md .claude/rules/code-quality.md
git commit -m "Move rule rationale to docs/decisions ADRs"
```
Ask the owner to approve this convention change. Don't start Task 3 until they say yes.

### Task 3: `.claude/rules/appointments.md` (83 KB → ≤ 10 KB)

**Files:** Modify `.claude/rules/appointments.md`. Create `docs/decisions/NNNN-*.md`.

- [ ] **Step 1:** Run R1 with `F=.claude/rules/appointments.md`, `N=appointments`. The inventory is about 125 lines.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **INVARIANTS to keep (one bullet each):** quarter-hour snapping; the status allowlist and `displayStatusAt` ladder; mark-complete has no clock gate; `showActions` gating; all-day blocks store real instants; a personal save skips the busy prompt; the time-off clash alert is advisory and comes after the save; the conflict check is server-side; `findBusyEmployees` excludes the appointment being edited and chunks by 30; an assignee may write crew notes and photos only; "Start job" doesn't dismiss the sheet; the server owns the job time record; the edit merge keeps assignees not in the picker; templates are never stored; "Book again" copies who and what, never when; `usesCustomAddress` is the single owner; the overdue review is the one bulk close; the dashboard window is one listener plus one `.get()`; the 14-day multi-day span and `AppointmentDaySlice`.
  - **To ADRs:** each of the 61 dated passages. Expect about 15 ADRs grouped by the bullets above, for example "Conflict check moved server-side (2026-09-04)" or "Server owns the job time record".
  - **DUPLICATE:** the `dailyWindowsOverlap` / conflict-twin text that also appears in root `CLAUDE.md`'s search block. It belongs in `search.md` (Task 7), so here it's one line pointing there.
- [ ] **Step 3:** R3 (write the ADRs).
- [ ] **Step 4:** R4 (rewrite the file).
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: counts equal, 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, no `MISSING`, committed.

### Task 4: `.claude/rules/employees.md` (68 KB → ≤ 10 KB)

**Files:** Modify `.claude/rules/employees.md`. Create `docs/decisions/NNNN-*.md`.

- [ ] **Step 1:** R1 with `F=.claude/rules/employees.md`, `N=employees`. The inventory is about 109 lines.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **INVARIANTS:** authorization reads the live user doc; the admin password reset (`passwordResetRequired` is server-owned and in both denylists); the invite → setup flow; `EmployeeFormActivity` busy state is sets of doc IDs; `watchEmployees()` query constraints; `users.name` is composed; `jobTitle` ≠ `role`; `workingDays` is Sunday-indexed; phones are stored formatted; the emergency pair is its own section; employees are never deleted, only disabled; a disabled or invited employee's colour stays taken; an absent `travelAlertsEnabled` reads as ON; the roster's "jobs today" uses one listener.
  - **To ADRs:** the P4c history (the code flow, the `#compat-1.37.1` shim, the email-verified gate removal, the starting-password change). Expect about 12 ADRs.
  - **Keep the one-line pointer to** `.claude/rules/security.md` for credential fields (`kCredentialImePersonalizedLearning`), not a restatement.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: counts equal, 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 5: `.claude/rules/clients.md` (65 KB → ≤ 10 KB)

**Files:** Modify `.claude/rules/clients.md`. Create `docs/decisions/NNNN-*.md`.

- [ ] **Step 1:** R1 with `F=.claude/rules/clients.md`, `N=clients`. The inventory is about 85 lines.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **INVARIANTS:** `ClientRecord` legacy back-compat; archive, not delete; the filter button lives in the header row with no chips; the count line only states what it can prove; `ClientsListView` has no chrome; grouping is opt-in; `mostJobs` / `recentlyAdded` order by nullable fields; `jobCount` is recomputed absolutely; the contacts cap is surfaced; `mobile` self-heals into `phone`; `AddressParser.canonicalFrom` is the single owner; the add-job picker sends a slice of the number; complete answers are narrowed locally and truncated ones re-queried; `phoneDigits` has one entry per number; callable answers are re-ranked; a failed search must not render as empty; the `clients/{id}.name`-is-the-phone rule and `ClientNamePolicy`; inline add-client; the Job history section.
  - **To ADRs:** "Recent clients REMOVED 2026-09-06", "COLLAPSED match summary NOT built", and the dated filter / server-paging history. Expect about 10 ADRs.
  - **DUPLICATE:** search-ranking text that root `CLAUDE.md` also carries (`relevanceScore`, `ownPhoneDigits` / `contactPhoneDigits`). Its owner is `search.md` (Task 7).
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: counts equal, 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 6: `.claude/rules/notifications.md` (54 KB → ≤ 10 KB)

**Files:** Modify `.claude/rules/notifications.md`. Create `docs/decisions/NNNN-*.md`.

- [ ] **Step 1:** R1 with `F=.claude/rules/notifications.md`, `N=notifications`. Only about 18 imperative lines, so this file is mostly long explanatory prose.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **INVARIANTS:** the app never prompts for notification permission on its own; push token registration rules; `handleAppointmentWrite` runs `stampLifecycle`; `sendDailyJobDigest` carries the month-end review rider; the Live Activity content is built server-side per token locale; presence throttle and heartbeat constants stay under `PRESENCE_STALE_MINUTES`; widget payload and Siri snapshot `isUnsettled` rules.
  - **To ADRs / delete:** long walkthroughs of how each pipeline works. Move true rationale to ADRs. A plain description of the code that the code itself shows is neither an invariant nor rationale, so delete it, but only after R6 confirms it holds no imperative.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: counts equal, 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 7: Root `CLAUDE.md` (49 KB → ≤ 12 KB) and the new `.claude/rules/search.md`

**Files:** Modify `CLAUDE.md`. Create `.claude/rules/search.md`. Create `docs/decisions/NNNN-*.md`.

- [ ] **Step 1:** R1 with `F=CLAUDE.md`, `N=root`.
- [ ] **Step 2: Split out the search rules.** The whole "Entity search runs SERVER-SIDE now" bullet under `## Conventions` (from that bullet through the `pageToCap` / breadcrumb paragraph, about 20 KB) moves to `.claude/rules/search.md` with this frontmatter:

```markdown
---
paths:
  - "lib/core/search/**"
  - "lib/core/data/**"
  - "lib/features/clients/data/**"
  - "lib/features/clients/domain/**"
  - "lib/features/calendar/data/**"
  - "lib/features/calendar/domain/policies/**"
  - "functions/indexed_search.js"
  - "functions/search_tokens.js"
  - "functions/day_slice_utils.js"
  - "test/core/search/**"
  - "functions/__tests__/search_tokens.test.js"
---
```

  Then cut `search.md` itself down to ≤ 10 KB with R2–R4. **INVARIANTS:** the token-array index, the cap of 240, both ordering rules, field cap ÷ scope count, a token hit is a prefilter, the fold table is mirrored (not NFD), the read cap warns, every server write path maintains the index, the conflict twin, the `index()` / `entryMatches()` / `rawMatches()` matchers, the single owner of `rawTexts` / `rawPhones`, `firestoreStringList`, `_patchWindow` / `_notifyLocalWrite`, `SearchResultCache`, `pageToCap` (cap + 1, page size not equal to cap, breadcrumb versus warn).
- [ ] **Step 3: Cut the rest of root `CLAUDE.md`.**
  - Keep: Commands; Required environment, as a list of keys plus three one-line rules (define-only, `_requireDefine` const map, Maps key over the MethodChannel); Critical invariants, one to two lines each; Conventions; Cloud Functions deploy command plus "never `--force`"; Testing.
  - **To ADRs:** the Android deletion and resurrection story, the `dev/.env` retirement, the `#compat-1.37.1` and `email_verified` history, the `Debouncer.tagged` and `SettingsSaveDebouncer` history, the "callables ADDED on date" paragraphs (they belong in `docs/CLOUD_FUNCTIONS.md` / `docs/DEPLOYMENT.md` log, so a one-line pointer stays), and the "rules-files moved on 2026-08-19" lines (keep only a one-line index of which rules file covers what).
  - **ENFORCED:** the analytics import ban, the `FirebaseFirestore.instance`-in-UI ban, and the callable cast convention each become `Enforced by \`tool/check_rules.dart\` (...)`.
- [ ] **Step 4:** R3 (write the ADRs).
- [ ] **Step 5:** R5 on `CLAUDE.md` (no frontmatter, expected `FRONTMATTER-OK`). Then check the new file's frontmatter by eye against Step 2.
- [ ] **Step 6:** R6 for `root`. A line now living in `search.md` maps as `.claude/rules/search.md:<line>`. Expected: 0 `UNMAPPED`.
- [ ] **Step 7: Sizes and commit.**

```bash
wc -c CLAUDE.md .claude/rules/search.md
git add CLAUDE.md .claude/rules/search.md docs/decisions/
git commit -m "Cut root CLAUDE.md to invariants; split search rules out"
```
Expected: `CLAUDE.md` is at most 12 000 bytes and `search.md` at most 10 000.

### Task 8: `.claude/rules/frontend.md` (48 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/frontend.md`, `N=frontend`.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **Keep:** Design Tokens as a table of token names only; Layout; Notices; Forms & sheets; Accessibility; and Performance, cut to invariants.
  - **"Widget Framework" (lines 54–195) is the bulk.** Keep the rules (thin `initState`, `build()` under about 60 lines, `mounted` after await). Move worked examples and history to ADRs.
  - **ENFORCED:** the widget-layer `Timer` ban.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 9: `.claude/rules/images.md` (39 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/images.md`, `N=images`.
- [ ] **Step 2:** Classify using R2. Keep: magic-byte validation; the single-stage pick/compress pipeline; render-from-bytes; the two caches; the `appointments/{id}/images` subcollection contract; the offline upload queue; the `## Server side` purge ordering (images first). The subcollection migration and the legacy `url` retirement history go to ADRs.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 10: `functions/CLAUDE.md` (35 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=functions/CLAUDE.md`, `N=functions`.
- [ ] **Step 2:** Classify using R2. Keep: the module map as a table (module → exports, one line each); `*_policy.js` testability rule; JSDoc requirement; guard order. Per-function narrative belongs in `docs/CLOUD_FUNCTIONS.md`. Before deleting, confirm that file already says it. If it doesn't, move the text there rather than into an ADR.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7, also adding `docs/CLOUD_FUNCTIONS.md` if it was touched. Expected: at most 10 000 bytes.

### Task 11: `.claude/rules/wave.md` (35 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/wave.md`, `N=wave`.
- [ ] **Step 2:** Classify using R2. Keep: the app never reads Wave client-side; outbox, claim, lease and dead-letter rules; the contract as the sole producer; a stored cause never drains; the `WaveNetwork` carve-out. Import-cadence retirement and Phase 2–4 history go to ADRs.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 12: `lib/features/calendar/CLAUDE.md` (32 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=lib/features/calendar/CLAUDE.md`, `N=calendar`.
- [ ] **Step 2:** Classify using R2. Keep: the P2 month grid, pager and collapse rules; the `AppointmentCard` contract; the agenda's closed-job sink. Mockup-era history goes to ADRs.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 13: `.claude/rules/error-handling.md` (26 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/error-handling.md`, `N=error-handling`.
- [ ] **Step 2:** Classify using R2. File-specific guidance:
  - **Keep the log-tag registry** (both tables). It's an invariant: the exhaustive list. Compress the "shapes that hide a tag from grep" paragraph to a six-item list with no history.
  - **Keep:** `composeErrorNotice` / `composeErrorNoticeFor`; resolving the logger before the first await (ENFORCED by `ref-read-in-catch`, so one line plus a pointer); "A catch only reaches what is inside it" as four one-line rules; sealed outcomes; `Busy` is not an exception; typed failures; `isExpected` / `authFailure`; `isFatalUnhandledError`; a raw `listen` needs `onError`.
  - **To ADRs:** the "this paragraph previously claimed" corrections, the support-tag removal (2026-08-04), and the three-fatals incident (2026-08-31).
  - This file is `alwaysApply: true`, so every byte saved here is saved in every session.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 14: `.claude/rules/analytics.md` (12 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/analytics.md`, `N=analytics`.
- [ ] **Step 2:** Classify using R2. The import ban is ENFORCED. Keep: `AnalyticsParams.allParams`; the sanitizer asserts; `setUserId` is never called; events fire on success only; the observer versus hub-shell screen-view split.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 15: `ios/CLAUDE.md` (11.4 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=ios/CLAUDE.md`, `N=ios`.
- [ ] **Step 2:** Classify using R2. Keep: SPM only (no Podfile); iOS 18.0 floor; App Attest; the Crashlytics dSYM phases; `homeWidget` param. Move the Podfile-removal history to an ADR.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 16: `.claude/rules/security.md` (10.8 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=.claude/rules/security.md`, `N=security`.
- [ ] **Step 2:** Classify using R2. Keep every guard rule. Move the `#compat-1.47.0` worked example, the 2026-09-01 "three deletable gates" incident and the in-memory limiter history to ADRs, leaving the rules plus `(ADR-NNNN)`.
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 17: `lib/features/feature_tour/CLAUDE.md` (10.6 KB → ≤ 10 KB)

- [ ] **Step 1:** R1 with `F=lib/features/feature_tour/CLAUDE.md`, `N=feature_tour`.
- [ ] **Step 2:** Classify using R2. Keep: `TourScope`; the visibility gates; `isTargetRendered`; the `ready:` gate; the rule that a member name is the storage key; the widget-test caveat (`markFormToursSeen()`).
- [ ] **Step 3:** R3.
- [ ] **Step 4:** R4.
- [ ] **Step 5:** R5. Expected: `FRONTMATTER-OK`.
- [ ] **Step 6:** R6. Expected: 0 `UNMAPPED`.
- [ ] **Step 7:** R7. Expected: at most 10 000 bytes, committed.

### Task 18: Final check

- [ ] **Step 1: Total size**

```bash
wc -c CLAUDE.md .claude/rules/*.md functions/CLAUDE.md ios/CLAUDE.md $(git ls-files 'lib/**/CLAUDE.md') | sort -n
```
Expected: every file within its target, and a total of no more than about 178 000.

- [ ] **Step 2: Every ADR cited exists, and every ADR is in the index**

```bash
grep -rhoE "ADR-[0-9]{4}" CLAUDE.md .claude/rules functions/CLAUDE.md ios/CLAUDE.md lib --include=*.md | sort -u > build/rules_audit/cited.txt
ls docs/decisions | grep -oE "^[0-9]{4}" | sed 's/^/ADR-/' | sort -u > build/rules_audit/present.txt
comm -23 build/rules_audit/cited.txt build/rules_audit/present.txt
ls docs/decisions | grep -oE "^[0-9]{4}" | while read n; do grep -q "| $n " docs/decisions/README.md || echo "UNINDEXED $n"; done
```
Expected: no output from either command.

- [ ] **Step 3: Gates**

```bash
flutter analyze
dart run tool/check_rules.dart
dart run tool/test.dart
```
Expected: `No issues found!`, `0 rule violation(s).`, and all tests passing.

- [ ] **Step 4: Update the testing mirror note.** In root `CLAUDE.md`'s Testing section, update the rules-file list (it names `analytics.md` and the others) to include `search.md` as `paths:`-scoped. Then commit:

```bash
git add CLAUDE.md
git commit -m "Record search.md in the rules-file index"
```
