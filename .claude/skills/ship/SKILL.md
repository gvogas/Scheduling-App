---
name: ship
description: >-
  Verify-and-ship checkpoint for this repo — analyzer, tests, and BOM scan,
  then commit and push to the current branch. Use whenever the user says
  "commit it", "commit this", "commit and push", "push it", "ship it", or
  asks for a final check before committing. Also use as the closing step
  after a fix or feature when the user asks to wrap it up.
---

# Ship Checkpoint

One pass that replaces the usual "final check → commit → push" exchange.
Never commit red — fix and rerun instead.

**A push runs CI** (`.github/workflows/ci.yml`, on `main` and `dev`), and
CI runs `flutter analyze`, `dart run tool/test.dart`, `npm run lint` and `npx jest` on
every push regardless of what changed. So the checks below are not a courtesy:
anything skipped here comes back as a failed run minutes later. Run the full
set unless the change is docs-only.

## 1. What changed

`git status` + `git diff --stat`. Bucket the changes: Dart in `lib/`/`test/`,
`functions/`, ARB files, rules, docs. Docs-only is the one case that may skip
straight to step 3.

## 2. Verify

- **BOM scan** on every changed `.dart` file — this repo has been bitten by
  editors saving UTF-8-with-BOM:
  ```bash
  git diff --name-only HEAD -- '*.dart' | while read -r f; do
    [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && echo "BOM: $f"
  done
  ```
  Strip any hit with `tail -c +4 "$f" > tmp && mv tmp "$f"`.
- **Analyzer**: `flutter analyze` must print **`No issues found!`**. That is the
  repo's baseline and CI gates on the command's exit code, so there is no lint
  floor to filter against — any line it prints is yours. (An older version of
  this skill said to grep out "~1000 info lints"; that noise floor has not
  existed for a long time and grepping hid real findings from the run.)
- **Tests**: `dart run tool/test.dart` — the whole suite, because CI runs the
  whole suite. Running only the touched files here just moves the failure to
  the push. It shards files into a shared isolate (~3 min against ~10 for bare
  `flutter test`), and CI runs the same runner — so ALSO run
  `flutter test <touched test files>`, one isolate per file. Nothing else
  checks that a test passes on its own, and a test that only passes because a
  shard-mate set something up for it fails the day the shards rebalance.
- **ARB changes**: `flutter gen-l10n` succeeds and
  `lib/l10n/.gen/untranslated.json` shows no EN/FR drift.
- **`functions/` changes**: `cd functions && npm run lint && npx jest`.

Report the real counts you observed (e.g. "3387 flutter / 1785 jest"). Don't
carry a count forward from a plan doc or an earlier session — a recorded green
is a claim, not a fact, and this repo has shipped a bug behind one.

## 3. Commit

- Stage the files belonging to this piece of work; the tree sometimes carries
  parked work, so don't blanket `git add -A` when unrelated modifications are
  present — ask only if it's genuinely ambiguous what belongs.
- Message: short imperative line matching the repo's existing style, and
  **no double quotes inside the message** (PowerShell 5.1 native-arg quoting
  mangles them). Use a single-quoted here-string for multi-line messages.
- Include the attribution trailers the session is configured with.
- `dev/firebase.local.json`, `dev/.env`, `google-services.json`,
  `ios/GoogleService-Info.plist` and anything under `android/` are gitignored
  — if one ever shows as staged, **stop and tell the user**. `android/` is the
  live hazard: `flutter` regenerates it on any Android-touching command and it
  carries a real `MAPS_API_KEY`, which is how a secret reached this repo once.

## 4. Push

Push to the **current** branch — `dev` is the long-lived active one.
Never push to `main` unless explicitly asked.

Finish by reporting: the checks run and their observed results, the commit
hash, the branch pushed, and that CI will now run on it. If anything was
deliberately not run, say which and why.
