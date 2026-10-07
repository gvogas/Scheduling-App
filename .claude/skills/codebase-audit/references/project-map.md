# Project map & load-bearing invariants

## Layout
- `lib/features/{auth,calendar,clients,dashboard,employees,feature_tour,
  home_widget,live_activity,maps,navigation,notifications,onboarding,presence,
  settings,siri,splash,wave}/`
  — feature-first. Each feature: `domain/` (entities, sealed `*_failure.dart`),
  `data/` (repositories), `presentation`/`screens`/`widgets`, `application`/providers.
- `lib/core/`, `lib/shared/` — cross-feature code (theme/design tokens, validators,
  errors, launchers, shared widgets). Promote here only when reused.
- `lib/l10n/` — `app_en.arb` (template) + `app_fr.arb`. Generated localizations
  live in `lib/l10n/.gen/` and are **gitignored** — never edit or "clean" them.
- `functions/` — Cloud Functions (Node.js). `index.js` + `functions/wave/*`.
  Google ESLint, 80-char lines. `functions/node_modules` is not yours to touch.
- `firestore.rules`, `storage.rules`, `firestore.indexes.json` — security-critical.
- `test/` — mirrors `lib/` structure.

## Tooling
```bash
flutter analyze 2>&1 | grep -E "error -|warning -"   # filter to real issues
dart fix --dry-run                                    # preview safe auto-fixes
dart fix --apply                                      # apply them
dart run tool/test.dart                               # full suite, sharded (~3 min)
flutter test test/<path>.dart                         # one file
cd functions && npm run lint                          # Functions ESLint
cd functions && npx eslint . --fix                    # Functions auto-fix
```
The repo is usually clean at the static level — `flutter analyze` may report
"No issues found" and `dart fix` "Nothing to fix". The grep filters out info-
level lints (there can be many or none); don't assume a number. A clean static
pass is normal here, not a sign you missed something — the real findings then
live in the deep review (bugs/security) and in dead weight the analyzer can't
see (unused dependencies, orphaned l10n keys).
Lint baseline is `very_good_analysis` (strict). It already flags `unused_import`,
`unused_element`, `unused_field`, `unused_local_variable`, `dead_code`,
`prefer_const_constructors`, and more — so the analyzer IS your primary dead-code
and mechanical-style detector. `analysis_options.yaml` excludes `**/*.freezed.dart`, `lib/l10n/.gen/**`,
`lib/firebase_options.dart`, `build/**` and `.dart_tool/**` — never report or
modify those.

## "Do not touch" — load-bearing invariants

These look removable, redundant, or refactor-able to a generic cleaner, but each
is intentional and load-bearing. If your scan flags one as dead/redundant/odd,
**put it in the report — do NOT auto-modify or auto-delete it.** Sources of
truth: `CLAUDE.md`, `.claude/rules/*.md`, `firestore.rules`.

**Security / correctness invariants:**
- `FirebaseAppCheck.instance.activate()` in `main()` — never remove.
- Appointment status allowlist — exactly FOUR values: `pending`/`in_progress`/
  `done`/`cancelled` (`confirmed` was retired 2026-07-09 and survives only as a
  legacy-tolerant READ; never re-add it to a write path). `overdue` is
  display-only and must never be stored. New appointments must be created
  `status: 'pending'`. Enforced in
  `firestore.rules` (`isValidAppointmentStatus`) AND `_allowedStatuses` in
  `firebase_appointments_repository.dart` — the duplication is deliberate, not DRY-able.
- Role/`isAdmin` is **always** read from Firestore, never SharedPreferences. Any
  "cache the role" refactor is a security regression.
- Image magic-byte validation (JPEG `FF D8 FF` / PNG `89 50 4E`) client- and
  server-side. Extension checks are not a substitute.
- Employee visibility filter: employees see only appointments whose doc id is in
  `employeeIds`. Don't drop this `.where`.
- Firestore **query** rules are checked against query *constraints*, not data —
  a `.where(...)` that mirrors a rule clause is required, not redundant. Removing
  a "pointless" `.where('status', isEqualTo: 'active')` breaks the query with
  `permission-denied`. See `watchEmployees()`.
- `ClientRecord.toMap` must NEVER emit `waveCustomerId`/`wave` — rules reject it.
  The `name ← businessName` fallback in `fromMap` and the `businessName` search
  index are intentional legacy back-compat. Keep both reads.
- Wave: the app's ONLY Wave read path is the `waveGetConnection` callable. Never
  add a client-side read of the rules-locked `wave` collection.

**Indirect references — analyzer/grep may call these "unused" but they are not:**
- **l10n keys** — used via generated getters (`context.l10n.someKey`), not direct
  references. An ARB key with no obvious call site is NOT dead; many are reached
  dynamically. Never strip ARB keys as "unused" in a code sweep — but DO report
  the orphaned-looking ones (with their ARB line) so the user can run a separate,
  deliberate l10n pass to confirm and prune them. Defer, don't delete; report,
  don't stay silent.
- **Riverpod providers** — referenced via `ref.watch/read(xProvider)`; some are
  `autoDispose.family` keyed by query string. Don't delete a provider just
  because grep shows few hits.
- **Route names** — `AppRoutes.onGenerateRoute` resolves by string; a route
  constant may be pushed via `Navigator.pushNamed`.
- **`TODO(pre-ship)` markers** — intentional temporary scaffolding, kept until
  pre-ship cleanup. Not dead code; leave them and their comments intact.
  (As of 2026-08-14 there are ZERO such markers in the tree — the last one,
  `kShowTestingDeleteClient`, went with the client archive/delete work. Verify
  before reporting a Pre-ship checklist section as non-empty.)
- Optional injected constructor deps (e.g. `AuthService`, repositories taking
  `auth`/`AppLogger`) exist for testability even if production passes nothing.

**Conventions a cleanup must preserve (flag violations, don't "simplify away"):**
- User feedback via `noticeServiceProvider.success/error/info` — not
  `ScaffoldMessenger.showSnackBar` (three sanctioned SnackBar sites excepted).
- Typed `Failure` families per feature; repos throw the typed failure. Don't
  collapse to `throw Exception(...)`.
- All Firestore writes go through service classes — never
  `FirebaseFirestore.instance` from UI/widgets.
- Design tokens (`AppColors`/`AppSpacing`/`AppRadius` via `ColorScheme`/theme
  extensions). Map through `Theme.of(context).colorScheme`; never branch on
  `isDark` for styling.
