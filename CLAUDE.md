# CLAUDE.md

Flutter app (Dart `^3.10.7`) for appointments, clients and employees. Backend: Firebase (Auth, Firestore, Storage, App Check). **iOS only, App Store only.**

- Never re-add `android/`, Play-release work or an Android branch; keep `/android/` in `.gitignore` — `flutter` regenerates the tree, and a resurrected one carried a live `MAPS_API_KEY`. No `DefaultFirebaseOptions.android`; `currentPlatform` throws `UnsupportedError`. (ADR-0011)
- Keep the `fcmTokens` `platform` write (`push_registration_controller.dart`, `Platform.isIOS ? 'ios' : 'android'`) — live code, not a remnant. Leave `web/`, `windows/`, `linux/`, `macos/` alone: boilerplate, not support (`macos/Podfile` is scaffold). (ADR-0011)
- iOS: `ios/CLAUDE.md` (SPM-only, no Podfile ever; iOS 18.0; App Attest; dSYM phases). The `homeWidget` param and `home_widget` tap channel are live and retire together; the `app_links` dispatcher (`lib/core/deep_links/`) skips those URIs.
- Never re-run `flutterfire configure` — it rewrites `lib/firebase_options.dart` into literals and breaks the define setup.

## Commands

```bash
flutter analyze   # baseline is `No issues found!` — any lint you see is yours
dart run tool/test.dart   # full suite, sharded: ~3 min vs ~10 for bare `flutter test`
```

`tool/test.dart` bundles the ~400 test files into 6 shards under `build/test_shards/` (bare `flutter test` compiles ~1.4 s per file); extra args pass through (`--coverage`, `--reporter expanded`). One file: `flutter test <path>`. A shard shares an isolate — "Shard isolation" in `.claude/rules/testing.md`.

## Required environment

- Pass config as defines, never a bundled file: `--dart-define-from-file=dev/firebase.local.json` (copy `dev/firebase.local.example.json`; gitignored) or repeated `--dart-define=KEY=value`. Required: `IOS_API_KEY`, `IOS_APP_ID`, `MESSAGING_SENDER_ID`, `PROJECT_ID`, `STORAGE_BUCKET` (`lib/firebase_options.dart` fails fast naming a missing one), `IOS_MAPS_API_KEY`. Optional: `USE_FIREBASE_EMULATOR`, `EMULATOR_HOST`, `ANALYTICS_DEBUG` (analytics ON in debug; off by default so `flutter run` never hits production). (ADR-0012)
- Add a new REQUIRED Firebase key as a literal in `_requireDefine`'s `const` map (the five in `lib/firebase_options.dart`) — `String.fromEnvironment` is const, so a key read only through the map's argument resolves to `''` and fails fast at startup; never put an OPTIONAL define there, and never build the name dynamically (it silently yields empty). (ADR-0012)
- `main()` sends `IOS_MAPS_API_KEY` over `net.vogas.scheduling/native_config`, awaited before `runApp` so the key precedes any map; `AppDelegate.registerNativeConfigChannel` calls `GMSServices.provideAPIKey`. A missing or blank key leaves the map blank rather than crashing; don't reintroduce an asset read in `AppDelegate`. (ADR-0012)
- Keep server or unrestricted keys (Stripe, OpenAI, admin tokens, `GOOGLE_MAP_API_KEY`) in Secret Manager, never a define; `IOS_MAPS_API_KEY` is a RESTRICTED client key — a define is still extractable, so the Cloud Console restriction is what makes it safe. No `dev/.env`/`flutter_dotenv`. (ADR-0012)

## Critical invariants

- Sign out unless the `users` doc (matching `uid`) is `active` (`SplashScreen`); gate on `!employee.isActive`, since `isDisabled` misses `''` and future statuses.
- Route `invited` to `AccountSetupScreen` KEEPING the session at both gates (`splash_controller.dart`, `sign_in_controller.dart`) — signing out makes setup unreachable. Check exact `employee.isInvited` BEFORE the active gate, so an empty or unknown status still gets the old sign-out; tests pin both halves. (ADR-0013)
- Keep `SignInController.resumeAfterSignUp` restating the active gate — a stale cached read would walk a still-`invited` person into a hub where every rule denies them. (ADR-0013)
- Route `active` + `passwordResetRequired: true` to `ChangePasswordScreen`, session kept, AFTER the invited and active gates; sign-in clears the identity cache, so a cold start cannot fast-path past it. Server-owned (`resetEmployeePassword` / `completePasswordReset`), in both `/users` denylists. See `.claude/rules/employees.md`. (ADR-0013)
- Kick out only on a populated→empty transition: pass `previous` to `isAccountDeletionSignal` (`account_status_provider.dart`) from `AccountExitListeners._listenForDeletedAccount` (`core/app/account_exit_listeners.dart`, registered by `main.dart`). Never simplify to `doc.isEmpty` — a first empty doc is bootstrap (`uid == null` sign-in, or invited before `completeEmployeeSetup`); `SplashScreen` catches cold-start deletions.
- Kill switches FAIL OPEN (`lib/core/remote_config/`, `functions/feature_flags*.js`): failed fetch, empty template or static value = all on, `min_supported_build` 0. Flip BOTH templates (Client, Server). Keys and defaults are mirrored and pinned by both sides' tests; only case-insensitive `true`/`false` count (anything else = the default, ON), `min_supported_build` only as a plain integer; both parsers read `test/fixtures/shared/feature_flags.json`.
- Map a paused callable's `failed-precondition`/`feature-disabled` to `MapsFailurePaused`/`WavePaused`, logged as a breadcrumb — the client can read ON for up to 60 s. A paused feature reuses its opt-out path; a pause never prunes a Live Activity token (devices end cards once per pause; nothing re-emits push-to-start). Runbook: `docs/DEPLOYMENT.md` "Flip a kill switch".
- Show employees only appointments whose `employeeIds` holds their doc id, on every new appointment view.
- Offline: `add_event`, `event_details`, `client_form` controllers return a fabricated `SocketException('offline')` when `ref.read(isOfflineProvider)` is true, BEFORE the in-flight flag — an awaited write resolves only on server ack. `composeErrorNotice`/`error_cause.dart` keys on the `SocketException` type. Photos queue instead, deliberately. Keep `persistenceEnabled: true` in `main()` (serves cached reads).
- Keep `FirebaseAppCheck.instance.activate()` in `main()`.
- Analytics (`.claude/rules/analytics.md`): no `firebase_analytics` import outside `lib/core/analytics/analytics_service.dart` (`tool/check_rules.dart`, analytics-import); only keys in `AnalyticsParams.allParams` reach Firebase (the sanitizer asserts — no PII path); never `setUserId` (role is `user_role`); fire on the SUCCESS branch (`AddEventSubmitted`, `EventDetailsSaved`, `ClientSaved`, …), never `Busy`.
- Never add a client `runTransaction` on a concurrent path — the iOS plugin's unsynchronized `_transactions` (`FLTTransactionStreamHandler`) can EXC_BAD_ACCESS. Token repos use get-then-set — a double-upsert can only re-stamp `createdAt` (cosmetic); don't reintroduce transactions there. The two remaining (employee-edit uniqueness re-check, series update) are isolated one-at-a-time admin actions; add none that can run concurrently with them. A body can RE-RUN, so rebuild post-commit state inside it (`updateAppointments` clears `written`), or it names docs an abandoned attempt touched and this commit did not. (ADR-0014)
- Use iOS `first_unlock_this_device` in `SecureStorageService` — `unlocked` throws -25308 on a locked-phone push cold start and skips the app lock; `_this_device` also keeps the identity out of backups. Keep `_ensureMigrated` first in every public method (`ios_keychain_accessibility_v2`; backup slot, then delete-then-rewrite) and add new keys to `SecureStorageKeys.all` or they never migrate; `isKeychainLockedError` classifies residual -25308 (pre-first-unlock) as log-only at the three flag-read catch sites. (ADR-0015)
- Treat the app-lock flag as TRI-STATE (`AppLockController`, `isResolved`, `retryIfUnresolved()`): `AppLock` (`core/security/app_lock.dart`) retries BEFORE deciding on resume and LOCKS on background/`inactive` while unresolved (the switcher snapshot). `_afterRetry` releases; a persistent failure unlocks on purpose, so nobody who never enabled biometrics is trapped — the win is the switcher window, not a hard guarantee. Never gate on a bare `ref.read(appLockEnabledProvider)`. Pinned: `test/core/security/app_lock_test.dart`. (ADR-0016)
- Never read `isAdmin`/role from SharedPreferences — always Firestore.
- Route only via `AppRoutes.onGenerateRoute`, typed args through `Navigator.pushNamed(..., arguments: ...)`. Type-check with `_args<T>(settings)`, degrading to `InvalidRouteScreen` (`_invalidRoute`) — never `settings.arguments! as T`, a deep link can push anything. HOME uses least-privilege defaults instead, deliberately (every cold start reaches it). (ADR-0017)
- Give list queries the constraints a rule checks (`resource.data.status == 'active'` ⇒ `.where('status', isEqualTo: 'active')`), or the whole query is `permission-denied`; `doc.get()` is checked on data. See `watchEmployees()`.
- Satisfy one `users` read clause in a query's WHERE: admin, `status == 'active'`, or own doc (`uid == request.auth.uid`). Three, not four — never re-add an email-matched clause; an invited person reads their own doc via the third. (ADR-0018)
- Never rename an `AppDestination`/`TourForm` member: its name IS the tour's storage key, so a rename replays or orphans the tour.

## Rules index

Scoped files load only under their `paths:`; this says where a subject lives. (ADR-0024)

- `.claude/rules/appointments.md`: status allowlist + `displayStatusAt` ladder, `showActions`, personal / time-off / all-day blocks, 14-day span + `AppointmentDaySlice`, `findBusyEmployees`, assignee crew notes + job time record (their `allow update` disjuncts in `firestore.rules`/`storage.rules`), templates, overdue review, dashboard window, mark-complete, assignee-retaining edit merge, picker dimming + availability, technician History scope.
- `.claude/rules/clients.md`: `clients.name` IS the phone + `ClientNamePolicy` (also used from `lib/core/validators/phone_format.dart`, `functions/client_name_utils.js`), `ClientRecord` back-compat, archive-not-delete, `jobCount`, list filters + server paging, Job history, type filter, Wave sync badge, inline add-client, History rail + sections.
- `.claude/rules/employees.md`: P4c invite/setup, `changeEmployeeEmail`, starting password, `/users` two-branch `allow update` + rules caps, `watchEmployees`, `users.name`, `workingDays`, `private/emergency`, `EmployeeFormActivity`, `MyDetailsScreen`, `travelAlertsEnabled`, roster jobs-today count (one listener), credential handling.
- `.claude/rules/images.md`: magic bytes, pick/compress, render-from-bytes, two caches, `appointments/{id}/images`, offline upload queue, cascade + recount.
- `.claude/rules/search.md`: search callables, token index + fold table, fallback matchers, `_patchWindow`, `SearchResultCache`, `pageToCap`.
- `.claude/rules/notifications.md`: push permission + tokens, presence, home widget, Live Activities, Siri, `stampLifecycle`, daily digest.
- `.claude/rules/wave.md`: Wave outbox/worker, dead-letter, customer import, Settings UI, app never reads Wave.
- `.claude/rules/analytics.md`: `AnalyticsParams.allParams`, sanitizer, `user_role`, observer vs hub-shell screen views.
- `.claude/rules/firestore-indexes.md`: TTL policies (offset `0`), index exemptions, never `--force`.
- `.claude/rules/frontend.md`: design tokens, `GhostControl`, layout + responsive, notices, forms + sheets, accessibility, performance.
- `.claude/rules/testing.md`: shard isolation, hand-mirrored Dart/JS pairs, harness, device-only verification.
- `lib/features/calendar/CLAUDE.md`: P2 month grid/pager/collapse, `AppointmentCard`, closed-job sink, time-off strip, holidays.
- `lib/core/navigation/CLAUDE.md`: `AppDestination` (`.name` is the tour key), `navigateToDestination`/`selectAndReveal`, `_popToShell`.
- `lib/features/feature_tour/CLAUDE.md`: `TourScope`, visibility gates, `isTargetRendered`, `ready:` gate, `markFormToursSeen()`.
- `functions/CLAUDE.md`: module map, `*_policy.js` split, callable guards, recount claims.
- `ios/CLAUDE.md`: SPM-only, iOS 18.0 floor, App Attest, dSYM phases, `homeWidget`.

## Conventions

- Feature-first: `lib/features/{auth,calendar,clients,employees,settings,splash}/`; promote to `shared/` or `core/` only when reused across features.
- Services are plain classes, no DI container; inject optional deps for tests, as `AuthService` does.
- Normalize emails through `normalizeEmail()` (`core/validators/email_format.dart`) before any Firestore read/write, never a hand-spelled `.trim().toLowerCase()`.
- `initState` must be thin — extract heavy init to `_initStreams()`.
- Set `isSubmitting`/`isSaving` synchronously BEFORE a submit's first `await` (seed-settle, conflict check) and reset it on every early return and `catch` — else a double-tap writes twice or the button sticks. A view still mounted after its action (master-detail pane) resets after `onAction` under `mounted`.
- Write Firestore only through service classes, never `FirebaseFirestore.instance` in UI; `tool/check_rules.dart` (firestore-instance) flags it in EVERY non-generated `lib/` file outside `firebase_providers.dart`, `main.dart` and `auth_service.dart`. Always set `createdAt`/`updatedAt` server timestamps.
- Search rules: `.claude/rules/search.md`. Three apply everywhere:
- Maintain `searchTokens`/`historySearchScopes` on every SERVER write path that creates or edits a client or appointment, or the doc silently drops out of search (e.g. `functions/scripts/repair-client-address-mojibake.js:63`).
- Page any bounded scan through `pageToCap` (`core/data/paged_scan.dart`) with a cap AND a warn (a deliberate newest-N window breadcrumbs instead) — never an unbounded `while (true)` loop.
- Parse list fields through `firestoreStringList` (`core/utils/firestore_parsing.dart`) in any matcher that reads the raw map, never a private copy.
- Route widget offline guards through `guardedOffline` (`core/errors/error_cause.dart`), which pushes the offline notice and returns true; no `tag` param (tags live in the `logger.warn` label). Exactly three carve-outs: `AccountSetupScreen` and `ChangePasswordScreen` (both use their own `_bannerError`), `WaveSettingsSection._blockedOffline` (`WaveNetwork().toLocalizedMessage` — typed-Failure-first gives a better sentence than the generic cause vocabulary). Controller guards return a typed failure. (ADR-0025)
- Account exit: `AccountExitListeners` (disabled / role revoked / doc deleted) only call `AccountExitController.exitAccount` (`core/app/`), which owns teardown, navigation and guard. De-register push, presence and Live Activity BEFORE `signOut()` (each needs the credential). `_isHandlingAccountExit` is released post-frame on success, in `finally` only on failure — three listeners can fire for one event. (ADR-0026)
- Debounce only through `Debouncer` (`lib/core/utils/debouncer.dart`, one per State, `dispose()` it), built with `Debouncer.tagged(duration, logger:, tag:)` in `initState` — the handler can outlive the widget, where `ref.read` throws, so resolve the logger there, never inside the callback and never via a lazy `late final` touching `ref`; `onError` is required. Never a second wrapper or a raw `Timer` — `tool/check_rules.dart` (widget-timer) catches one only under `/widgets/` and `/screens/`; elsewhere the ban is this rule. (ADR-0027)
- Use the named dials, never a re-spelled interval: `kSearchDebounce`, `kAddressLookupDebounce` (700 ms — billed Places calls), `kSettingsSaveDebounce` (`settings_providers.dart`). (ADR-0027)
- Debounce a search over a `PagingController` with `DebouncedPagedSearch` (`clients/widgets/views/debounced_paged_search.dart`: `committedQuery`, `scheduleSearch`, `didUpdateWidget` diff, `notifyFirstPageSettled`), as `ClientsListView` and `AppointmentHistoryView` do. (ADR-0027)
- Localization (`gen_l10n`): source `lib/l10n/app_en.arb` (template) + `lib/l10n/app_fr.arb`; output `lib/l10n/.gen/` is gitignored — `flutter gen-l10n`, never hand-edit. Import only `package:scheduling/l10n/l10n.dart` (re-exports `AppLocalizations` + `context.l10n`), never `app_localizations.dart`. `context.l10n` is non-nullable (`nullable-getter: false`), no `!`. `MaterialApp` uses `AppLocalizations.localizationsDelegates`/`AppLocalizations.supportedLocales`, never a hand-built list.
- Every ARB key MUST carry a `@key` block (description + typed placeholders; `required-resource-attributes: true` in `l10n.yaml`). Name keys `feature_keyName` in a bucket: `calendar_`, `clients_`, `tour_`, `employees_`, `error_`, `settings_`, `common_`, `dashboard_`, `auth_`, `wave_`, `validation_`, `liveMap_` (the one lowerCamel), `onboarding_`, `nav_`, `status_`, `maps_`, `applock_`; no `app_`. Update both ARBs in lockstep; drift lands in `lib/l10n/.gen/untranslated.json`.
- Cast callable responses as `(value as Map?)?.cast<String, dynamic>()`, never `as Map<String, dynamic>?` (strict-map-cast check). (ADR-0028)
- Chunk `whereArrayContainsAny` ID lists into 30s (its hard limit) and merge in Dart — `findBusyEmployees` (`firebase_appointments_repository.dart`).

## Cloud Functions

- `functions/` (project `schedulingapp-88727`, `us-central1`): domain modules re-exported by a thin `index.js`; module map `functions/CLAUDE.md`, reference `docs/CLOUD_FUNCTIONS.md`.
- Put a Storage-bucket-at-load module's decisions in a pure `*_policy.js` sibling with injected deps — `onObjectFinalized` resolves the bucket at registration, so `maintenance.js` can't load in tests (its `getStorage()` handles are already lazy); a new unattended-deletion decision goes in the policy module, never the trigger module. (ADR-0029)
- Keep `purgeExpiredHistory`'s rules in `maintenance_policy.js`: purge only `done`/`cancelled` (live work must survive at any age); images FIRST, and keep a doc whose image cleanup failed, or its Storage bytes orphan with nothing pointing at them; end on a no-progress full page (no respin to 1800 s). (ADR-0029)
- Deploy the backend BEFORE the app build (`assertPayloadShape` rejects unknown keys); read `docs/DEPLOYMENT.md` before any deploy touching a callable payload or rules cap. (ADR-0030)
- Open a self-service callable with `assertActiveCall(req, allowedKeys)` (`functions/security.js`), twin of `assertAdminCall`, returning the profile (`role`/`docId`); see `.claude/rules/security.md`.
- Deploy via the `Deploy backend` workflow (`workflow_dispatch` from `main`; `production` approval is a human tap — an agent never approves). Fallback `firebase deploy --only functions,firestore:rules,firestore:indexes,storage` after clearing `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE`, or the audit log gets `agent-name/claude_code` (`docs/DEPLOYMENT.md` §5). `storage`, not `storage:rules`.
- Never pass `--force` — it deletes every prod TTL policy missing from `firestore.indexes.json` (`.claude/rules/firestore-indexes.md`).
- Run `cd functions && npm run lint` before deploying; one-off prod scripts via `node functions/scripts/run.js <name> [--live]`. `GOOGLE_MAP_API_KEY` is Secret Manager only.

## Testing

- Catch overflow at 260 logical px (`tester.view.physicalSize`) with `MediaQuery` `textScaler: TextScaler.linear(2)`, via each file's local `_harness` — there is no shared `_scaledHarness`.
- Harness, mocking and device-only caveats: **Test Strategy** in `docs/ARCHITECTURE.md`, mirrored by `.claude/rules/testing.md` — keep them in step.
- `.claude/` is committed except `.claude/settings.local.json`. `code-quality.md`, `error-handling.md`, `security.md` are `alwaysApply: true`; `testing.md`, `frontend.md`, `appointments.md`, `clients.md`, `employees.md`, `images.md`, `notifications.md`, `wave.md`, `firestore-indexes.md`, `analytics.md`, `search.md` are `paths:`-scoped (verified). (ADR-0024)
