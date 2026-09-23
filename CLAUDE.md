# CLAUDE.md

Flutter app (Dart `^3.10.7`) for managing appointments, clients, and employees.
Backend: Firebase (Auth, Firestore, Storage, App Check). **iOS is the only
platform.**
**Ships to the App Store ONLY (decision 2026-07-08), and `android/` was
DELETED on 2026-08-05** (owner call) once development moved from a Windows box
to a Mac and iOS could build and run locally — Android had only ever been the
dev/test harness that gave that Windows box something runnable, and it was
never published to Play. Don't re-add it, don't restore Play-release work
(keystore, Data Safety, Play Integrity), and don't "fix" an iOS-only assumption
by reintroducing an Android branch. Recover the tree from git history if it is
ever genuinely needed. **`/android/` is now in `.gitignore`, and that entry is
load-bearing** (2026-08-08): a merge (`33715f82`) silently resurrected the tree
and brought `android/local.properties` with it, which carries a live
`MAPS_API_KEY` — a committed secret. `flutter` regenerates that directory on any
Android-touching command, so ignoring it is the only thing that stops a second
resurrection; deleting the files alone does not. Don't remove the entry to
"restore" an Android build. **`DefaultFirebaseOptions.android` is GONE**
(2026-09-04, with the `dev/.env` retirement below): the shared `FIREBASE_API_KEY`
/`APP_ID` pair that fed it was the only reason it survived, and
`currentPlatform` now throws `UnsupportedError` on Android rather than handing
back options nothing builds. Don't restore it. ONE Android remnant survives
**deliberately** and is not dead code to clean up:
the `platform: 'ios' | 'android'` field on `fcmTokens` docs, which the
CURRENT build still writes — `push_registration_controller.dart` stamps
`Platform.isIOS ? 'ios' : 'android'`, so on an iOS-only fleet the value is
always `'ios'` but the write is live code, not a legacy row. (An earlier note
here credited the 1.37.1 App Store build for it; that was wrong even then, and
retiring the shim on 2026-08-08 changed nothing about this field.)
**`web/`, `windows/`, `linux/` and `macos/` STAY** (owner call, 2026-08-05,
asked and answered when `android/` went). They are untouched `flutter create`
boilerplate for platforms nothing targets or builds — leave them alone; their
presence is not evidence that any of those platforms is supported. In
particular `macos/Podfile` is scaffold, not a CocoaPods setup, and does not
contradict the SPM-only rule in `ios/CLAUDE.md`.

iOS notes live in `ios/CLAUDE.md` (loads when working under `ios/`) — SPM-only
(there is no Podfile and never will be), iOS 18.0 deployment floor, App Attest,
the Crashlytics dSYM run-script phases, and the `homeWidget` deep-link param.
Since P4b a real `app_links` dispatcher exists (`lib/core/deep_links/`), but the
`homeWidget` param and the `home_widget` tap channel are **both still live** and
retire together — the dispatcher skips those URIs rather than replacing them.
**Do NOT re-run `flutterfire configure`** — `lib/firebase_options.dart` already
builds the iOS options from `--dart-define` values; re-running it rewrites the
file into the literal-values style and breaks the define-based setup.

## Commands

```bash
flutter analyze   # baseline is `No issues found!` — any lint you see is yours
```

## Required environment

**Build-time `--dart-define` values, NOT a bundled file** (changed 2026-09-04).
Copy `dev/firebase.local.example.json` to `dev/firebase.local.json` (gitignored)
and pass it with `--dart-define-from-file=dev/firebase.local.json`, or spell the
keys out with repeated `--dart-define=KEY=value`. 6 required keys:
`IOS_API_KEY`, `IOS_APP_ID`, `MESSAGING_SENDER_ID`, `PROJECT_ID`,
`STORAGE_BUCKET` (read in `lib/firebase_options.dart`, which fails fast naming
any missing one) plus `IOS_MAPS_API_KEY`. `USE_FIREBASE_EMULATOR` and
`EMULATOR_HOST` are the optional pair `main()` reads, plus `ANALYTICS_DEBUG`
(turns analytics collection ON in a debug build for DebugView work — it is OFF
there by default so `flutter run` never reaches the production property).
`IOS_MAPS_API_KEY` is a RESTRICTED CLIENT key — distinct from the server-side
Secret-Manager `GOOGLE_MAP_API_KEY`, which must never ship in the app.

- **`String.fromEnvironment` is a CONST expression, so a define cannot be read
  by a runtime string.** `_requireDefine` therefore holds a `const` map of the
  five Firebase keys and looks up in that; adding a key means adding the literal
  there too, not just to the JSON. A key read only through the map's argument
  resolves to `''` and fails fast at startup, which is the intended shape —
  don't "fix" it by building the name dynamically, which silently yields empty.
- **The iOS Maps key crosses a MethodChannel, it is no longer parsed natively.**
  `main()` sends `IOS_MAPS_API_KEY` over `net.vogas.scheduling/native_config`
  and `AppDelegate.registerNativeConfigChannel` answers by calling
  `GMSServices.provideAPIKey`. It is awaited before `runApp` on purpose, so the
  key is installed before any map widget can be constructed; a missing or blank
  key leaves the live map blank rather than crashing. `AppDelegate` no longer
  reads any asset — don't reintroduce one.
- **`dev/.env` and `flutter_dotenv` are RETIRED, and the asset entry with them.**
  The file shipped inside the IPA as a readable asset, so every key in it was
  extractable from the binary with no tooling; a define is compiled in instead.
  A restricted client key is still recoverable from a binary by someone who
  tries, so the app-side restriction (bundle ID + API restrictions in the Google
  Cloud Console) is still what makes it safe — the change removes the trivially
  greppable copy, not the need to restrict. Server-side or unrestricted keys
  (Stripe, OpenAI, admin tokens, `GOOGLE_MAP_API_KEY`) must live in Google
  Secret Manager and be read from a Cloud Function — never in a define.

## Critical invariants

- **Auth:** Every signed-in user needs a Firestore `users` doc with matching
  `uid`, and it must be `active` — with ONE exception. `SplashScreen` signs out
  otherwise. Don't break this. Gate with `!employee.isActive` — `isDisabled`
  only matches `'disabled'`, so it misses `''` and any future status.
  **The exception is `invited` (P4c, 2026-08-02): it routes to
  `AccountSetupScreen` and KEEPS the session**, at both gates
  (`splash_controller.dart`, `sign_in_controller.dart`). The admin created that
  account with a generated starting password and handed it over, and this is the
  person's first
  sign-in — signing them out makes setup unreachable, since the credential they
  just used is the one it needs. The test is `employee.isInvited`, an **exact**
  match checked BEFORE the active gate, so an empty or unknown status still
  gets the old sign-out. Tests pin both halves.
- **Live account-deletion signal (kick-out) needs a populated→empty transition.**
  `isAccountDeletionSignal` (`account_status_provider.dart`) fires the runtime
  sign-out only when the current doc is a *settled* empty following a
  previously-populated one — so pass `previous` (the prior emission) from the
  `ref.listen` in `AccountExitListeners._listenForDeletedAccount`
  (`core/app/account_exit_listeners.dart`), which `main.dart` only registers. A first-seen empty doc is a bootstrap window
  (fresh-sign-in `uid == null` branch, or an invited account signed in before
  `completeEmployeeSetup` activates its doc), NOT a deletion. Never simplify back to
  `doc.isEmpty` alone, or invited employees get wrongly kicked out mid-activation
  (cold-start already-deleted accounts are caught earlier by `SplashScreen`).
- **Employee visibility:** Employees see only appointments where their doc id is
  in `employeeIds`. Apply this filter on any new appointment view.
- **Photo and image-upload rules live in `.claude/rules/images.md`** (moved
  2026-08-19) — magic-byte validation, the single-stage pick/compress pipeline,
  render-from-bytes, the two caches, the `appointments/{id}/images` migration
  and the offline upload queue. Loads when working under `lib/core/images/`,
  `lib/features/calendar/` or the image functions.
- **Offline write guard:** the appointment/client submit controllers
  (`add_event`, `event_details`, `client_form`) fail fast when
  `ref.read(isOfflineProvider)` is true by returning a fabricated
  `SocketException('offline')` **before** the in-flight flag is set; the widget
  maps it to the offline notice via `composeErrorNotice`/`error_cause.dart`
  (which keys on the `SocketException` *type*, so the message string is cosmetic).
  An awaited Firestore write only resolves on server ack, so without this Save
  spins until reconnect. Deliberate asymmetry: entity writes fail fast offline
  while photos retry via the queue above. `persistenceEnabled: true` is pinned in
  `main()` (serves cached reads) — don't remove it.
- **App Check:** `FirebaseAppCheck.instance.activate()` in `main()`. Do not remove.
- **Analytics: NOTHING outside `lib/core/analytics/analytics_service.dart` may
  import `firebase_analytics`, and no parameter reaches Firebase unless its key
  is declared in `AnalyticsParams.allParams`.** The sanitizer drops an
  undeclared key and asserts in debug, which is what makes a PII leak
  structurally impossible in an app full of client phones, addresses and job
  notes — a leak arrives through one call site passing a convenient
  `'client_name': record.name`, never through a decision. `setUserId` is never
  called; the role travels as the `user_role` user property. An event fires on
  the sealed SUCCESS branch only (`AddEventSubmitted`, `EventDetailsSaved`,
  `ClientSaved`, …) — a `Busy` member is the reentrancy guard's no-op and wrote
  nothing. Full rules in `.claude/rules/analytics.md` (loads under
  `lib/core/analytics/`), including the observer-vs-hub-shell screen-view split
  that keeps the four tabs from double-counting.
- **Appointment rules live in `.claude/rules/appointments.md`** (moved
  2026-08-19; the assignee and job-record set moved 2026-09-02) — the status
  allowlist and `displayStatusAt` ladder, mark-complete, `showActions`, personal
  jobs, all-day blocks, the 14-day multi-day span and `AppointmentDaySlice`, and
  the `findBusyEmployees` conflict check; plus an assignee's own field record
  (crew notes and photos), the server-owned job time record and crew status, the
  assignee-retaining edit merge, the picker's dimming and availability rules,
  job templates, the split dashboard window and the technician's History scope.
  Loads when working under `lib/features/calendar/` or `functions/` — and, since
  several of those own `allow update` disjuncts, on `firestore.rules` and
  `storage.rules` too.
- **No client `runTransaction` on routine/concurrent paths.** The
  cloud_firestore iOS plugin mutates an unsynchronized NSMutableDictionary from
  the transaction queue (`FLTTransactionStreamHandler` → `_transactions`), so
  concurrent client transactions can EXC_BAD_ACCESS (seen fatal in 1.34.1;
  unfixed upstream as of 6.7.0). The FCM + Live Activity token repos therefore
  use plain get-then-set (a double-upsert can only re-stamp `createdAt` —
  cosmetic); don't reintroduce transactions there. The two remaining client
  transactions (employee edit uniqueness re-check, series update) are isolated
  one-at-a-time admin actions — don't add new transaction call sites that can
  run concurrently with them or each other.
- **Secure storage is iOS `first_unlock_this_device`** (`SecureStorageService`):
  the default `unlocked` Keychain class made every read throw -25308 when a
  content-available push cold-started the app on a locked phone — Crashlytics
  noise AND the biometric app-lock silently not engaging that session — and
  `..._this_device` additionally keeps the cached identity out of
  device/iCloud backups (cache self-rebuilds on next sign-in after a restore).
  The service lazily migrates old items (backup-slot then delete-then-rewrite,
  marker `ios_keychain_accessibility_v2`) before any operation — keep
  `_ensureMigrated` first in every public method, and add new keys to
  `SecureStorageKeys.all` or they never migrate. `isKeychainLockedError`
  classifies residual -25308 (pre-first-unlock) as log-only at the three
  flag-read catch sites.
- **The app-lock flag is TRI-STATE, and BOTH lifecycle gates must honour it.**
  `AppLockController` (`app_lock_provider.dart`) holds `false` until a read
  actually settles, so "off" and "we could not find out" are the same value —
  `isResolved` tells them apart and `retryIfUnresolved()` re-reads. That
  distinction is the whole point: reading the bare bool meant ONE transient
  keychain error (the pre-first-unlock -25308 window above) disabled biometrics
  for the entire session with no sign anything was wrong. `AppLock`
  (`core/security/app_lock.dart`) therefore **retries BEFORE deciding on
  resume**, and — the half that was missed first time — **locks on
  background/`inactive` while UNRESOLVED**, since that is the gate the OS grabs
  its app-switcher snapshot behind and "we don't know yet" must not read there
  as "no lock". A defensive lock is released by `_afterRetry` once the retry
  settles: **a persistent read failure still degrades to unlocked**, on purpose
  — someone who never enabled biometrics must never be trapped behind a prompt
  they cannot satisfy — so the win is the switcher window, not a hard
  guarantee. Don't write it up as one, and don't "simplify" either gate back to
  a plain `ref.read(appLockEnabledProvider)`. Pinned by
  `test/core/security/app_lock_test.dart`.
- **Role cache:** Never read `isAdmin`/role from SharedPreferences — always Firestore.
- **Routing:** `AppRoutes.onGenerateRoute` is the single source of truth.
  Pass typed arg classes via `Navigator.pushNamed(..., arguments: ...)`.
  **An arg-required route TYPE-CHECKS its arguments and degrades to
  `InvalidRouteScreen`** — `_args<T>(settings)` returns null rather than
  force-casting, and `_invalidRoute` renders a screen the user can leave. The
  seven `settings.arguments! as T` casts red-screened the app on a malformed or
  argless push, which a deep link can produce. The HOME route keeps its own,
  DIFFERENT answer — least-privilege defaults rather than a recovery screen,
  because it is reached from every cold start and back stack; that asymmetry is
  deliberate and documented at the site.
- **Firestore query rules vs. get rules:** For list/query operations, security rules are
  evaluated against query *constraints*, not document data. If a rule checks
  `resource.data.status == 'active'`, queries must also `.where('status', isEqualTo: 'active')`
  or Firestore rejects the whole query with `permission-denied`. Direct `doc.get()` calls
  ARE evaluated against actual document data. See `watchEmployees()` for a corrected example.
- **Users collection read rule** has three clauses (see `firestore.rules`):
  admin, `status == 'active'`, or `uid == request.auth.uid` (own doc). New
  queries on `users` must satisfy one clause via their WHERE constraints or
  they'll be rejected. **Three, not four** — a fourth
  `email_verified && status == 'invited' && email == token.email` clause existed
  only because the retired code flow left `uid` empty until redemption, and it
  was deleted 2026-08-08 with the rest of the `#compat-1.37.1` shim. (That was a
  `firestore.rules` READ clause and is unrelated to `completeEmployeeSetup`'s
  `email_verified` callable guard, which was removed separately on 2026-08-21 —
  two different `email_verified` checks, both gone, for different reasons.) P4c mints
  the Auth account up front, so an invited person reads their own doc through
  clause 3; don't re-add an email-matched clause. An ordinary
  employee still cannot see a pending account: clause 2 requires `active`.
- **Employee, account and `users`-doc rules live in `.claude/rules/employees.md`**
  (moved 2026-08-19) — the P4c invite/setup flow, `changeEmployeeEmail`,
  the generated starting password and credential handling, `EmployeeFormActivity`,
  `watchEmployees`, `users.name` composition, `workingDays`, the rules caps, the
  `private/emergency` subcollection, `MyDetailsScreen`, the two-branch
  `allow update` on `/users`, the roster's one-listener jobs-today count, and
  `travelAlertsEnabled`. Loads when working under
  `lib/features/employees/`, `lib/features/settings/` or the account functions.
- **Client rules live in `.claude/rules/clients.md`** (moved 2026-08-19) —
  `ClientRecord` legacy back-compat, archive-not-delete, the type filter, the
  Wave sync badge, `jobCount`, the `clients/{id}.name` IS-the-phone rule and
  `ClientNamePolicy`, inline add-client, the client detail's Job history
  section, and the History screen's rail/sections.
  Loads when working under `lib/features/clients/`, `functions/clients.js`,
  `functions/client_*.js` or `functions/wave/`.
- **Calendar UI rendering rules live in `lib/features/calendar/CLAUDE.md`**
  (moved 2026-08-14) — the P2 month grid/pager/collapse rules, the
  `AppointmentCard` contract, and the agenda's closed-job sink. They are pure
  Flutter with no `functions/` twin, so they load only when working under that
  directory. Everything with a server-side mirror stayed here.
- **Navigation rules live in `lib/core/navigation/CLAUDE.md`** (moved
  2026-08-19) — the sealed `AppDestination` family, why `.name` is load-bearing
  for tour storage keys, `navigateToDestination`/`selectAndReveal`, and the
  `_popToShell` caveat.
- **Feature-tour rules live in `lib/features/feature_tour/CLAUDE.md`**
  (moved 2026-08-14) — `TourScope`, the visibility gates, `isTargetRendered`,
  the `ready:` gate for data-dependent tabs, and the widget-test caveat.
  Remember here: an `AppDestination`/`TourForm` member name IS the tour's
  storage key, so renaming one replays or orphans that tour.

## Conventions

- Feature-first: `lib/features/{auth,calendar,clients,employees,settings,splash}/`.
  Promote to `shared/` or `core/` only when reused across features.
- Services are plain classes; no DI container. `AuthService` accepts optional
  injected deps for testability — mirror this pattern.
- Normalize emails through `normalizeEmail()`
  (`core/validators/email_format.dart`) before any Firestore read/write — never
  a hand-spelled `.trim().toLowerCase()`, which had nine copies and a private
  `_norm` twin.
- `initState` must be thin — extract heavy init to `_initStreams()`.
- **Submit/save reentrancy:** in a controller's submit/save, set the in-flight
  flag (`isSubmitting`/`isSaving`) synchronously BEFORE the first `await` —
  including any pre-validation seed-settle await or conflict-check round-trip —
  and reset it on every early-return and `catch`. Awaiting before the flag is
  set leaves the button enabled, so a double-tap starts a concurrent write
  (duplicate appointment / series rewrite); an un-caught pre-check throw with
  the flag already set leaves the button stuck. A detail view that stays mounted
  after its action (master-detail pane — only a delete clears the selection)
  must also reset its busy flag after `onAction` under a `mounted` guard; the
  sheet variant unmounts there, so the guard covers both.
- All Firestore writes via service classes (never direct `FirebaseFirestore.instance` in UI).
  Always set `createdAt`/`updatedAt` server timestamps.
- **Entity search runs SERVER-SIDE now** (2026-09-04). Client search, appointment
  history search and the booking conflict check go through the callables
  `searchClients` / `searchHistory` / `findAppointmentConflicts`
  (`functions/indexed_search.js`), because the old capped client-side scan
  windows went silently incomplete as the business grew: the clients window is
  `orderBy('name')`, so at its cap it was the alphabetically FIRST N clients and
  everything past that point vanished from search, the type-filter chips and the
  Archived chip at once, with no error anywhere. **This replaces the old rule
  that said to keep matching in Dart and never "fix" it into a server query** —
  that rule was written when there was no index to query.
  - **The index is a TOKEN ARRAY the CLIENT writes on every entity write**:
    `clients.searchTokens` and `appointments.historySearchScopes`, both built by
    `searchIndexTokens` (`core/search/search_tokens.dart`), both capped at 240
    entries by `firestore.rules`. A doc written before 2026-09-04 carries
    neither until `functions/scripts/backfill-search-tokens.js` has run against
    it — **that backfill is a prerequisite for the release, not a follow-up**,
    or search returns nothing for every existing client and closed job.
  - **`searchIndexTokens` is hand-mirrored by `functions/search_tokens.js`** —
    the app writes the tokens and the server queries them, so a divergence is a
    search that silently returns nothing. `test/core/search/search_tokens_test.dart`
    and `functions/__tests__/search_tokens.test.js` share their worked examples
    value-for-value; change both sides in one commit and keep the examples equal.
  - **Two ordering rules inside it are load-bearing.** Each word emits its WHOLE
    token before any of its prefixes, so an exact-word query survives
    truncation; and the text and phone runs are INTERLEAVED, so a long client
    name can never push the phone tokens past the cap. Appending phones after
    texts is what made appointment search-by-phone index nothing at all —
    the per-scope budget is ~10 tokens and a two-word client name fills it.
  - **The per-scope budget is the FIELD cap divided by the scope count, not the
    QUERY limit.** `historySearchScopes` carries every token once per scope
    (`all:` plus `emp:<id>:` per assignee), so the divide is what keeps it under
    240; clamping to `kSearchTokenQueryLimit` (10) instead — the number a
    QUERY may send — starves everything after the client's first name.
  - **A token hit is a PREFILTER, never the answer.** Both callables re-verify
    with `recordMatchesQuery` over the full stored document before returning,
    because a prefix token matches more than the query does.
  - **`normalize` is hand-mirrored as an explicit fold TABLE on both sides, not
    NFD.** The app writes the index with `ClientSearchPolicy._foldAccent` and
    the server tokenizes the typed query with `functions/search_tokens.js`; NFD
    folds strictly more (all of Latin Extended-A), so a JS side using it made
    "Muñoz" storable as `t:mu`/`t:oz` and queryable as `t:munoz` — a client
    nobody can find. Add a letter to both tables or to neither, and keep the
    shared accent examples in the two suites equal.
  - **The read cap is a KNOWN bound and it warns.** A phone query tokenizes to
    every 3-12 digit substring, so `514` matches most of the roster; the
    callable reads 200 `orderBy('name')` and returns 25, which means the answer
    to a very broad query is the alphabetically first slice. It logs at the cap
    so the truncation is visible rather than silent — never remove that warn,
    and don't raise the cap without also giving the result a real relevance
    order (the client-side path it replaced had `relevanceScore`; the server
    does not).
  - **A SERVER write path must maintain the index too.** The tokens are written
    by the app on save, so a document created or edited server-side keeps stale
    tokens or none at all — and the admin then searches for a client they can
    SEE in the list and gets nothing, with nothing logged. Two sites already do
    it and any new one must: the Wave import (`wave/customers_import.js` sets
    `searchTokens`) and client propagation (`buildAppointmentPatch` rebuilds
    `historySearchScopes` whenever it moves `clientName`/`clientPhone`).
  - **The conflict rule has a server twin now.** `findAppointmentConflicts`
    filters through `dailyWindowsOverlap` in `functions/day_slice_utils.js`,
    hand-mirrored from `appointment_day_slice.dart` — a DAILY-window overlap,
    not a raw instant test. It shipped as a raw instant test and reported a
    9-5 run across a week as clashing with a 7 pm job inside it; pinned now by
    `functions/__tests__/indexed_search_conflicts.test.js`. It also keeps the
    fail-closed half: a doc whose stored times don't parse clashes
    unconditionally.
  - **The old local scan windows are STILL THERE as the injected-`FirebaseFunctions`-
    absent fallback**, which in practice means tests only — `firebaseFunctionsProvider`
    is non-nullable, so production always takes the callable path. Everything
    below about those windows still describes the fallback; don't delete it, and
    don't add a THIRD matcher rather than routing through the two named pairs.
  Clients/history search read a bounded window
  (`_historySearchScanLimit` 5000 / `_clientScanLimit` 5000) via `clientSearchProvider` /
  `historySearchProvider` (`autoDispose.family` keyed by query) and match across
  all fields in Dart; the loaded-page filter fills the gap until the debounced
  read settles. `ClientSearchPolicy.normalize` (accent-fold) + `digitsOnly`
  (phone) are the matching primitives. **The client-side matchers are
  `index()` + `entryMatches()` (the loaded-page filter) and `rawMatches()` (the
  debounced server scan) — route new client matching through those.**
  `matchesClient` is a convenience wrapper over the first pair with NO
  production caller: the split exists FOR performance, since `index` is hoisted
  to run once per data change while `matchesClient` rebuilds the projection per
  candidate per keystroke.
  **`ClientSearchPolicy.rawTexts` / `rawPhones` are the ONE owner of the raw-map
  field list**, read by `rawMatches` AND by the `searchTokens` builder in
  `firebase_clients_repository`: what is INDEXED and what MATCHES cannot be
  allowed to drift, and they were two hand-written copies of the same ten
  fields. `index()` keeps its own `ClientRecord`-shaped copy on purpose.
  **A client's OWN numbers and its CONTACTS' are separate owners**
  (`ownPhoneDigits`/`contactPhoneDigits` and their `raw*` twins, 2026-09-05),
  because `relevanceScore` treats them differently — only the client's own may
  score an exact or prefix hit — and `rawPhones` is now just their
  concatenation, already reduced to digits. Spelled at the call site instead,
  it drifted immediately: `scoreRecord` passed the contacts in BOTH lists (so a
  contact's number could score exact, and every contact was compared twice at
  the weakest tier) while the repository's local-fallback matcher kept them out
  of the own list, which is two answers to one question. Note `searchIndexTokens`
  runs `digitsOnly` itself, so handing it digits changes no token.
  **The appointment side has the same pair**:
  `historyEntryOf` + `historyEntryMatches` (`calendar/domain/policies/history_search_policy.dart`),
  which `matchHistoryDocs` and `appointment_history_view.dart`'s loaded-page
  filter BOTH route through — they are the same search at two layers, and a
  field added to one used to change results visibly when the debounce settled,
  with nothing logged. The repository's fallback calls `matchHistoryDocs`; it
  briefly carried a third hand-written matcher that also read `title`, which
  neither twin does.
  **A matcher that reads the RAW map to skip building a record must parse list
  fields through `firestoreStringList`** (`core/utils/firestore_parsing.dart`,
  beside `firestoreDateTime`/`firestoreInt`), never a private copy: the history
  filter reads `employeeNames` before there is a record, so a second spelling
  that accepted less would silently reject documents the record itself would
  have matched — a search that quietly stops finding a crew member, with
  nothing logged.
  `FirebaseAppointmentsRepository` keeps a bounded LRU of recent `searchHistory`
  results on the long-lived singleton. **Every write path must call
  `_patchWindow(...)` or `_notifyLocalWrite()`** — a method that calls neither
  serves stale results, including a just-deleted appointment that opens a
  detail view for a doc that no longer exists, and
  `firebase_appointments_repository_invalidation_test.dart` reads the source
  back to make that a test failure rather than a silent one. **It replaced
  `_invalidateSearchCache()`, which THREW THE WINDOW AWAY** (2026-09-01): the
  window is the full paged terminal-status archive capped at 5000, and nine
  write paths dropped it outright, so an admin who searched History, opened a
  result and marked it complete re-paged the entire archive behind the sheet —
  thousands of billed reads and four sequential round trips for a one-field
  write, growing with the archive. `_patchWindow` merges the changed docs by id
  instead, the same treatment `firebase_clients_repository`'s own `_patchWindow`
  already had. Two rules inside it are load-bearing: a doc whose status is no
  longer terminal is REMOVED rather than merged (the window is
  `status whereIn terminalStatusQueryValues`, so a create or a reopen does not
  belong in it), and a new doc is inserted at its `startTime` position, because
  the window is `startTime` DESC and `searchHistory` returns it unsorted.
  `_notifyLocalWrite()` is the narrow alternative, for a write that provably
  changes no field `matchHistoryDocs` reads — the two photo paths.
  **The LRU itself is `SearchResultCache<T>` (`core/data/search_result_cache.dart`),
  shared with the clients repository**: the two carried byte-identical
  `_isFresh`/`_cacheSearch` pairs over identical dials (50 entries, 2 min), and
  neither copy had a test for expiry or eviction. Invalidation policy stays
  per-repo — they legitimately differ on the `_localWrites` poke.
  Cache reads refresh recency without extending the original TTL. Searches
  use `getOrLoad` to share pending requests; cache generations prevent reads
  started before a local write or sign-out from restoring invalidated results.
  Client and history scan windows apply the same generation check and share
  their pending reads, with history still keyed by employee/admin scope.
  **Both scan windows PAGE to their cap and then WARN**, the same posture
  `_mapRangeSnapshot` takes for the range streams. Paging is what stops a
  window truncating at one page; the cap is what stops it walking the whole
  collection, and the two are not alternatives — the 2026-08-19 cleanup
  commits deleted every ceiling and every warn when they added the paging, and
  both were restored the same day at 5000. It matters most on clients: that
  window is `orderBy('name')`, so at the cap it is the alphabetically FIRST N
  clients, and everything past that point goes invisible to search, to the
  type-filter chips and to the Archived chip at once, with no error anywhere.
  It arrives gradually as the roster grows, which is the kind of failure
  nobody reports. Never add a bounded read here without the warn, and never
  replace a ceiling with an unbounded `while (true)` paging loop —
  `fetchClientHistory` (`_clientHistoryScanLimit`, 1000) and
  `fetchClientsCreatedSince` carry the same pair.
  **The loop itself has ONE owner: `pageToCap` (`core/data/paged_scan.dart`),
  2026-08-19** — the four call sites had a hand-written copy each, which is
  four chances to omit the cap or the warn on the next one. The caller still
  supplies its own cap, page size and warn text (each names a different
  user-visible consequence); only the loop is shared. **Page size is NOT the
  display bound** — `fetchClientHistory` used its `limit` (50) as both against
  a 1000 cap, so one client-detail open cost up to 20 sequential round-trips;
  it pages at 500 like the other two windows. **Nor may page size EQUAL the
  cap**: `pageToCap` asks for `cap + 1 - fetched`, so a full first page always
  costs a second round trip whose only job is to decide whether to warn. A
  caller wanting the newest N passes `limit: N + 1, cap: N`
  (`clientBookingHistoryProvider`), which answers "is there more than N" in the
  one query. **Such a caller BREADCRUMBS at the cap rather than warning.** The
  warn exists for a SILENT truncation of a list meant to be complete; a
  deliberate window reaches its bound as the normal case — for the booking
  form, on exactly the repeat clients it is for — so warning there files a
  Crashlytics non-fatal per form open and buries the real one.
  `fetchClientHistory` keys that on whether an explicit `cap` was passed.
- **Every widget-layer offline write guard goes through `guardedOffline`**
  (`core/errors/error_cause.dart`, beside `composeErrorNotice`) — it reads
  `isOfflineProvider`, pushes the standard offline notice and returns true so
  the caller returns. The block was copy-pasted at six sites. It takes no
  `tag`: notices carry no support code (2026-08-04), so a tag now lives only in
  the `logger.warn` label at the same site. **There are exactly TWO carve-outs,
  and this list is meant to be exact** — a stale entry here is what made the
  previous version read as drift. `AccountSetupScreen` surfaces offline through
  its own banner (`_bannerError`) rather than a notice; and
  `WaveSettingsSection._blockedOffline` surfaces
  `WaveNetwork().toLocalizedMessage` instead of `composeErrorNotice`, because
  the typed-`Failure`-branch-first rule gives it a better sentence than the
  generic cause vocabulary can. (This named "the two `accept_invite_*` screens"
  until 2026-08-11, both of which P4c deleted, so the rule pointed at nothing;
  the Wave carve-out was added 2026-08-15 for the same reason — it existed and
  went unnamed.) Controller-layer guards (`add_event`,
  `event_details`, `client_form`) keep returning a typed failure instead.
- **Account exit is SPLIT: `AccountExitListeners` detects, `AccountExitController`
  tears down** (`core/app/`, siblings of `AppSyncListeners`; the controller was
  split out 2026-08-19). The listeners are three `ref.listen` wire-ups
  (disabled / role revoked / doc deleted) and nothing else; every one of them
  calls `AccountExitController.exitAccount`, which owns the teardown, the
  navigation and the guard. Don't put teardown back in a listener — that is
  what made the order and the guard untestable. The ORDER is load-bearing:
  push, presence and Live Activity de-register BEFORE `signOut()`, because each
  needs the credential sign-out revokes. The controller's
  `_isHandlingAccountExit` guard is released by the post-frame callback on
  success and by the `finally` only on failure — three listeners can fire for
  one underlying event.
- Per-keystroke search debounces through `Debouncer` (`lib/core/utils/debouncer.dart`,
  own one per State, `dispose()` it) at the shared `kSearchDebounce` beside it.
  **The debounced-search-over-a-`PagingController` block has ONE owner,
  `DebouncedPagedSearch`** (`clients/widgets/views/debounced_paged_search.dart`,
  2026-09-01), mixed into `ClientsListView` and `AppointmentHistoryView`: it
  builds the `Debouncer.tagged` in `initState`, owns `committedQuery`,
  `scheduleSearch`, the `didUpdateWidget` trimmed-query diff and
  `notifyFirstPageSettled`, and disposes the debouncer. Don't re-spell those
  in a new paged list — they were byte-identical in two files.
  `kSearchDebounce` itself is one cost dial, not a per-surface taste, and it lives in
  `core/` rather than on `ClientSearchPolicy` because its callers span features
  — the appointment sheets debounce a CLIENT search, History an APPOINTMENT
  one. **`Debouncer` is the ONLY one** — `SettingsSaveDebouncer` was deleted
  2026-08-19: making `onError` required (below) turned `Debouncer` into a
  strict superset, and a second wrapper whose `onError` stayed OPTIONAL voids
  exactly the guarantee that change buys. Its interval survives as
  `kSettingsSaveDebounce` beside `settings_providers.dart`, which is a
  different cost dial from `kSearchDebounce`. Don't add a second wrapper or a
  raw `Timer`, and don't re-spell an interval at a call site (it had already
  split 300 ms / 250 ms across four).
  **`Debouncer`'s `onError` is REQUIRED** (2026-08-19). It was optional, and
  five of the six call sites omitted it — the action runs from a `Timer`
  callback, so a throw inside a debounced search had no caller left to catch it
  and the search just returned nothing, with nothing logged and nothing in
  Crashlytics. Requiring it is what makes that omission impossible at a NEW
  call site.
  **Build one through `Debouncer.tagged(duration, logger:, tag:)`, not the raw
  constructor** (2026-08-22). All five sites use it (six until
  `DebouncedPagedSearch` merged two). Requiring `onError` closed
  the omission case; what it could not close is *where the logger is resolved*
  — the handler can fire after dispose, and Riverpod 3 `ref.read` on an
  unmounted consumer throws (see `.claude/rules/error-handling.md`), so the
  logger has to be read where the `Debouncer` is CONSTRUCTED (`initState`),
  never inside the callback and never via a lazy `late final` touching `ref`.
  Prose cannot enforce that; a required `AppLogger` PARAMETER can, because an
  argument is evaluated at the construction site. Five of the six sites carried
  a restatement of this paragraph as a comment, and the sixth — the one that
  deviated — is the one that shipped a FATAL. `tag` is the Crashlytics warn tag.
  **`kAddressLookupDebounce` (700 ms) lives beside `kSearchDebounce`** for the
  one caller that needs a different interval: every address lookup is a BILLED
  Places call behind a per-uid rate limit, where a client search spends a
  Firestore read the app already pays for. Two dials, compared in one place,
  rather than a number re-spelled at a call site.
- Localization (`gen_l10n`):
  - Source of truth: `lib/l10n/app_en.arb` (template) + `lib/l10n/app_fr.arb`.
  - Generated `app_localizations*.dart` live in `lib/l10n/.gen/` and are
    **gitignored**. Regenerate with `flutter gen-l10n`; never hand-edit them.
  - Single canonical import: `package:scheduling/l10n/l10n.dart` (re-exports
    `AppLocalizations` + the `context.l10n` extension). Don't import
    `app_localizations.dart` directly.
  - `context.l10n` is non-nullable (`nullable-getter: false`) — no `!`.
  - `MaterialApp` uses `AppLocalizations.localizationsDelegates` and
    `AppLocalizations.supportedLocales`; don't hand-build the delegates list.
  - Every key MUST carry a `@key` metadata block (description + typed
    placeholders). Enforced by `required-resource-attributes: true` in
    `l10n.yaml` — `flutter gen-l10n` fails on a bare key.
  - Key naming: `feature_keyName`. Prefix buckets: `calendar_`, `clients_`,
    `tour_`, `employees_`, `error_`, `settings_`, `common_`, `dashboard_`,
    `auth_`, `wave_`, `validation_`, `liveMap_`, `onboarding_`, `nav_`,
    `status_`, `maps_`, `applock_`. `liveMap_` is the one lowerCamel prefix —
    every other bucket is all-lowercase, so don't add a key by pattern-matching
    a random existing one. `app_` is not a real bucket (zero keys) — drop it
    if it resurfaces from an old copy of this list.
  - Adding a key: update both ARBs in lockstep, add the `@key` block in EN,
    run `flutter gen-l10n`. EN/FR drift surfaces in
    `lib/l10n/.gen/untranslated.json`.
- Cast callable responses loosely: `(value as Map?)?.cast<String, dynamic>()`,
  never `as Map<String, dynamic>?`. This started as an Android-only `TypeError`
  (that plugin returned nested objects as `Map<dynamic, dynamic>`), so it can no
  longer bite now that Android is gone — but it stays the convention: it is the
  same cost, and it doesn't depend on a plugin's choice of map type.
- `whereArrayContainsAny` has a hard limit of 30 items. When querying by a
  list of IDs (e.g. employee IDs), chunk into batches of 30 and merge results
  in Dart. See `findBusyEmployees` in `firebase_appointments_repository.dart`
  for the reference implementation.

## Cloud Functions

Functions live in `functions/` (project `schedulingapp-88727`, region
`us-central1`), split into domain modules re-exported by a thin `index.js`.
The module map and the per-function notes are in `functions/CLAUDE.md`, which
loads when working under `functions/`. Three subject areas were split out of
it on 2026-08-19 because each spans more than that one directory:
`.claude/rules/notifications.md` (push, presence, widget, Live Activities,
Siri — JS + Dart + Swift), `.claude/rules/wave.md` (`functions/wave/**` plus
the Settings UI) and `.claude/rules/firestore-indexes.md` (TTL policies and
index exemptions — scoped to `firestore.indexes.json`, which
`functions/CLAUDE.md` never covered). Per-function reference:
`docs/CLOUD_FUNCTIONS.md`.

**A module that resolves a Storage bucket at load can't be tested, so
its decisions live in a pure `*_policy.js` sibling.** `maintenance.js` throws on
`require()` outside the emulator, but NOT from an admin `getStorage()` handle —
both of its calls resolve lazily inside the function bodies. The throw is
`onObjectFinalized`'s own bucket-name resolution at **trigger registration**
("Missing bucket name", `firebase-functions/lib/v2/providers/storage.js`), which
happens the moment the module is evaluated. Same conclusion, so don't go looking
for a load-time `getStorage()` that isn't there — and don't "fix" it by making
the handles lazier, because they already are. That untestability is why the only
unattended, irreversible deletion in the repo
(`purgeExpiredHistory`) had ZERO tests until 2026-08-04. Its orchestration now
lives in `maintenance_policy.js`, taking `db`/`deleteImages`/`now` injected,
the same split `notification_policy.js` ↔ `notification_utils.js` already uses.
Three rules there destroy data if they regress and are each pinned: the status
gate (only `done`/`cancelled` are ever purged — live work must survive at any
age), the ordering (images FIRST; a doc whose image cleanup failed is kept, or
the Storage bytes orphan with nothing pointing at them), and loop termination
(a full page that made no progress must end the loop, not respin it to the
1800 s timeout). Put a new unattended-deletion decision there, never in the
trigger module.

**Release deploy runbook: `docs/DEPLOYMENT.md`** — ordering (backend BEFORE the
app build, because `assertPayloadShape` rejects unknown keys), the
old-build-compatibility check, rollback, and the deploy log recording what
production actually runs. Read it before any deploy that touches a callable
payload or a rules cap.

**Four callables were ADDED 2026-09-04** — `searchClients`, `searchHistory`,
`findAppointmentConflicts` (`indexed_search.js`) and `restoreAppointmentStatus`
(`appointment_actions.js`), taking the export list 25 → 29. The first three need
their composite indexes deployed FIRST and READY, and the `searchTokens` /
`historySearchScopes` backfill run, before the app build that calls them ships.

**A self-service callable opens with `assertActiveCall(req, allowedKeys)`**
(`functions/security.js`), the twin of `assertAdminCall`: auth → payload shape →
the `usersByUid/{uid}` bridge row, refusing anyone not `active`, returning the
profile because every site needs `role`/`docId` next to scope what it may reach.
It exists for the same reason the admin one does — a guard nobody has looked at
is the one that silently loses a clause, and this one was already written twice,
having drifted on its logging in the first week.

Deploy: `firebase deploy --only functions,firestore:rules,firestore:indexes,storage`
(clear `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` in the shell first, or the CLI
stamps `agent-name/claude_code` into the audit log — see `docs/DEPLOYMENT.md` §5.)
(`storage:rules` is **not** a valid deploy target — use `storage`.)
**Never pass `--force`** — it deletes any prod Firestore TTL policy missing from
`firestore.indexes.json` (this removed all 5 live policies once, 2026-07-21).
Always run `cd functions && npm run lint` before deploying.

`GOOGLE_MAP_API_KEY` lives in Secret Manager only — it is **not** in `dev/.env`.

## Testing

- Catch overflow by pumping at a small-phone size with 2× text: set
  `tester.view.physicalSize` (260 logical px wide is the usual worst case) and
  wrap in a `MediaQuery` with `textScaler: TextScaler.linear(2)`. Each test file
  owns a local `_harness` helper for this — **there is no shared
  `_scaledHarness`**, despite what older plan docs call the pattern.
- Harness requirements, mocking rules and device-only caveats: the **Test
  Strategy** section of `docs/ARCHITECTURE.md`, mirrored by
  `.claude/rules/testing.md` — keep the two in step. **`.claude/` is COMMITTED
  as of 2026-08-14** (private repo, worked from both a Windows box and the Mac),
  so the rules, skills, agents, commands and hooks now reach every clone;
  before that date `.claude/` was gitignored and `docs/ARCHITECTURE.md` was the
  only copy anyone else could read. Only `.claude/settings.local.json` stays
  ignored, because it is machine-local. `code-quality.md`, `error-handling.md` and
  `security.md` are `alwaysApply: true`; the other ten
  (`testing.md`, `frontend.md`, the 2026-08-19 additions
  `appointments.md`, `clients.md`, `employees.md`, `images.md`,
  `notifications.md`, `wave.md`, `firestore-indexes.md`, and `analytics.md`,
  added 2026-09-07) are `paths:`-scoped,
  so they load only when Claude touches a matching file. That scoping is verified working — a
  `paths:` rule is absent from context until its paths are touched — and it
  is what took this file from ~155k chars to ~31k.
