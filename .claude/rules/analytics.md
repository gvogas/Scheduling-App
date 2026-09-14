---
paths:
  - "lib/core/analytics/**"
  - "test/core/analytics/**"
  - "lib/core/app/analytics_identity_listener.dart"
---

# Analytics (Firebase Analytics, iOS only)

Added 2026-09-07. Root context: `../../CLAUDE.md`, which carries the two
invariants that have to be visible from every feature.

- **`lib/core/analytics/` is a four-file module and each file owns one thing.**
  `analytics_events.dart` is the vocabulary (event names, the parameter
  ALLOWLIST, user properties, and the canonical `source`/`surface`/`scope`
  values); `analytics_privacy.dart` is the sanitizer and the bucketing;
  `analytics_screens.dart` maps a route or a hub tab to a canonical screen
  name; `analytics_service.dart` is the only file in the repo allowed to import
  `firebase_analytics`. `analytics_providers.dart` holds the two providers and
  the build-mode constants.
- **The parameter ALLOWLIST is the privacy guarantee, not the doc comments.**
  `sanitizeAnalyticsParams` drops any key absent from
  `AnalyticsParams.allParams` and asserts in debug. That is what makes a leak
  structurally impossible rather than merely discouraged: this app holds client
  phone numbers, street addresses, job notes and employee emails, and those
  never escape by deliberate decision — they escape through one call site
  passing a convenient `'client_name': record.name`. Adding a parameter means
  adding it to that set FIRST, which is the moment somebody has to decide
  whether it is safe to transmit. The sanitizer also narrows types: only `num`,
  `bool` (sent as 1/0 — Firebase has no boolean parameter) and `String`
  survive, and anything else is DROPPED rather than `toString()`-ed, because
  `toString()` on a domain model is exactly how a whole client record reaches a
  wire.
- **A parameter VALUE has an owner too, not just the parameter NAME.**
  `AnalyticsSources`, `AnalyticsSurfaces`, `AnalyticsScopes`,
  `AnalyticsContactActions`, `AnalyticsFilters`, `AnalyticsSettings`,
  `AnalyticsDirections` and `AnalyticsArchiveActions` are the closed value
  sets, all in `analytics_events.dart`. The last four were added 2026-09-10,
  when ~22 `direction`/`filter_name`/`setting_name`/`action` values were still
  bare literals across eight files while the module header claimed to own
  "every event name, parameter name and parameter value". Nothing REJECTS an
  undeclared value — the sanitizer gates keys, not values — so `'app_lock'` vs
  `'applock'` silently becomes a second console row that nobody notices until
  a report is wrong. A value spelled at a call site is the whole failure. The
  employee-status value is the exception that proves the shape: it goes out as
  `UserStatus.active.name`, because that vocabulary already had an owner and a
  second copy here would drift from what the doc actually stores.
- **Counts are BUCKETED and a query is never sent.** `bucketCount` collapses
  the long tail (an exact `result_count` of 4173 describes one business on one
  day) and `bucketQueryLength` reports a query's shape only — a client search
  here is somebody's surname or phone number by definition.
- **`setUserId` is never called, anywhere.** The role goes out as the
  `user_role` user property and nothing else identifies a person. App version,
  device model and OS version are deliberately NOT declared as user properties:
  Firebase reports all three as automatic dimensions, so declaring them would
  spend a property slot on data the console already has.
- **`user_role` follows the LIVE Firestore doc**, through
  `AnalyticsIdentityListener` (`core/app/`, a sibling of `AppSyncListeners`,
  registered from `main.dart`'s `build`). An empty or unsettled role CLEARS the
  property rather than holding the last one — that covers sign-out AND the
  bootstrap window a fresh sign-in passes through, where attributing events to
  the previous session's role is the misattribution the live read exists to
  avoid. A stale role here would mis-label every event for the rest of the
  session, and the resulting report ("employees use the dashboard heavily")
  reads perfectly plausible.
- **Sign-out does NOT call `resetAnalyticsData`.** That would mint a new app
  instance id, and retention — "do people come back?" — is measured against
  that id. `user_role` is cleared instead. The tradeoff is real and was taken
  deliberately: two people signing in on one handed-over device share an
  instance id. Nothing identifying is attached to it.
- **The route observer and the hub shell SPLIT the screen views, and the split
  is the duplicate guard.** `analyticsScreenForRoute` returns null for the four
  routes in `kShellOwnedRoutes`, so `FirebaseAnalyticsObserver` ignores them and
  `HubShellState` reports those tabs itself (`initState` for the opening tab, a
  `tab != _current` check in `select`). Without that, `HubTabRedirectRoute` —
  which pushes a NAMED route and then hands off to the live shell — would count
  one arrival path twice and the other two once, so the four tabs would read
  busier than they are by an amount that depends on the user's back stack. The
  two halves move together; changing one alone silently double- or
  under-counts.
- **iOS reports a screen view of its OWN, and it is turned OFF in `Info.plist`**
  (`FirebaseAutomaticScreenReportingEnabled=false`, 2026-09-10). Firebase's
  native automatic reporting fires on `UIViewController` appearance, which in a
  Flutter app means one anonymous `screen_view` per launch carrying
  `ga_screen_class=FlutterViewController` and NO `ga_screen` at all — a third
  source of screen views, below Flutter, that the split above cannot see or
  guard. It inflated `screen_view` by one per session and put a nameless row in
  the Screens report, describing the one "screen" that is not one. It hid on
  the first debug run because the automatic event fires BEFORE
  `setCollectionEnabled` settles and was dropped as "Analytics is disabled.
  Event not logged"; it appeared on the very next launch. Don't remove the key
  to restore the iOS default.
- **A sheet reports itself.** A `showModalBottomSheet` route carries no name,
  so the observer skips it — the add-appointment, appointment-details,
  add/edit-client and invite/edit-person sheets each call `logScreenView` from
  their own `initState`. Without that, the create funnels have no entry step and
  only their successful completions are visible.
- **An event fires on the SEALED SUCCESS branch, never before the write.**
  `AddEventSubmitted`, `EventDetailsSaved`, `EventDetailsActionOk`,
  `ClientSaved`, `EmployeeAccountCreated`. The `Busy` members are the
  reentrancy guard's no-op and wrote nothing, so counting one would report jobs
  and clients that never existed — the same reason those branches surface no
  notice.
- **`AnalyticsService` methods return `void` and CANNOT throw.** Every send is
  wrapped; a failure is a `logger.warn` under the `ANALYTICS` tag and nothing
  more. `void` rather than `Future<void>` is deliberate: a future would make
  every call site — most of them inside an `async` widget handler — either
  `await` a round trip in the middle of a user action or wrap it in
  `unawaited(...)`, and `unawaited_futures` is on in this repo.
- **`FirebaseAnalytics.instance` is resolved LAZILY and returns null when
  `Firebase.apps.isEmpty`.** That is the normal state of a widget test.
  Resolving in the constructor would make merely READING
  `analyticsServiceProvider` throw, so all ~20 instrumented widgets would need
  a provider override to stay testable — and the first suite that forgot one
  would fail with a Firebase error pointing nowhere near the analytics call.
  Returning null rather than throwing-and-catching is what keeps the whole
  suite quiet: a throw would print a `logger.warn` from every instrumented
  widget in it. Consequence: no existing test needed an analytics override.
- **Collection is OFF in debug unless `--dart-define=ANALYTICS_DEBUG=true`**
  (`kAnalyticsCollectionEnabled`, `analytics_providers.dart`), the same posture
  `main()` takes for Crashlytics. Every `flutter run` would otherwise file real
  events against the production property, and that noise is indistinguishable
  from real usage precisely because it comes from a real device doing
  real-looking things. `build_env` (`release`/`debug`) is set as a user
  property so DebugView traffic stays filterable in the console.
- **DebugView needs the `-FIRDebugEnabled` launch argument on the Xcode
  scheme**, which is separate from the define above: the define decides whether
  events are COLLECTED at all, the launch argument decides whether they stream
  to DebugView in real time. Both are needed to watch events live in a debug
  build.
- **`FIREBASE_ANALYTICS_WITHOUT_ADID=true` swaps `FirebaseAnalytics` for
  `FirebaseAnalyticsCore`** in the plugin's `Package.swift`, dropping IDFA / ad
  identifier collection. This app sells no ads and has no attribution need, so
  the ad id buys nothing and costs a heavier App Store privacy disclosure (and
  a potential ATT prompt). Set it in the environment for any `flutter build
  ios` that ships.
- **The plugin is SPM-safe** (`ios/firebase_analytics/Package.swift`), which is
  a precondition here — there is no Podfile and never will be. Vet any future
  analytics dependency the same way.
- **Every send checks MEMBERSHIP, not merely shape.** `_log` asserts
  `isKnownEvent`, `_setUserProperty` asserts `isKnownUserProperty`, and
  `logScreenView` asserts `AnalyticsScreens.allScreens.contains(...)`. That
  last one checked only that the name was well-formed until 2026-09-10, so
  `allScreens` was a 20-entry list with no production reader — a new sheet
  passing an undeclared name compiled, passed, and shipped an orphan screen
  row with the suite still green, because the test walks the SET rather than
  the call sites. A declared set that nothing asserts against is the drift the
  module says it exists to prevent.
- **`analytics_events.dart` names are pinned by tests, because Firebase drops a
  malformed name SILENTLY** — the event simply never appears in the console,
  which is discovered weeks into a reporting window. `analytics_events_test.dart`
  walks every declared name through `AnalyticsNames`, which also encodes that
  the user-property cap (24) is SHORTER than the event cap (40): a name valid
  as an event can be too long as a property.
- **`overdue_review_applied`** (2026-09-13) fires on the review screen's
  `OverdueReviewApplied` branch only, never on `Busy`, with `action`
  (`AnalyticsOverdueReviewActions.complete` / `not_done`) and `count`, a new
  `allParams` key sent through `bucketCount`. The screen reports as
  `overdue_review` through the route observer, and a job opened from it reports
  `AnalyticsSources.overdueReview`. A new parameter must be registered as a
  custom dimension in GA before it shows in reports.
