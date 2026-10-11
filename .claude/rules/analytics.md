---
paths:
  - "lib/core/analytics/**"
  - "test/core/analytics/**"
  - "lib/core/app/analytics_identity_listener.dart"
---

# Analytics (Firebase Analytics, iOS only)

Root context: `../../CLAUDE.md`, which carries the two invariants every feature must see.

## Module

- Keep `lib/core/analytics/` one owner per file: `analytics_events.dart` (event names, the parameter ALLOWLIST, user properties, the closed `source`/`surface`/`scope` and other value sets), `analytics_privacy.dart` (sanitizer, bucketing), `analytics_screens.dart` (route/tab → screen name), `analytics_providers.dart` (the two providers, build-mode constants), `analytics_service.dart`.
- Import `firebase_analytics` only in `analytics_service.dart`. Enforced by `tool/check_rules.dart` (analytics-import).
- Keep every `AnalyticsService` method `void` and non-throwing: each send goes through `_guard`, a failure is only a `logger.warn` under `ANALYTICS`. Not `Future<void>` — call sites would `await` mid-action or need `unawaited(...)` (`unawaited_futures` is on). (ADR-0166)
- Resolve `FirebaseAnalytics.instance` LAZILY for sends (`_analytics`), returning null when `Firebase.apps.isEmpty` (every widget test) — resolving in the constructor makes reading `analyticsServiceProvider` throw, and throw-and-catch would `warn` from all ~20 instrumented widgets. `navigationObserver` resolves eagerly; only `main.dart`'s `build` reads `analyticsObserverProvider`, so keep it out of tests. (ADR-0166)

## Privacy

- Treat `AnalyticsParams.allParams` as the privacy guarantee: `sanitizeAnalyticsParams` drops any undeclared key and asserts in debug. Add a new parameter to the set FIRST — that is where someone decides it is safe to send. (ADR-0163)
- Let only `num`, `bool` (sent as 1/0) and `String` (trimmed, capped at `kAnalyticsMaxValueLength`) through; DROP anything else, never `toString()` it — that is how a whole domain model reaches the wire. (ADR-0163)
- Spell every parameter VALUE from its closed set in `analytics_events.dart` (`AnalyticsSources`, `AnalyticsSurfaces`, `AnalyticsScopes`, `AnalyticsContactActions`, `AnalyticsFilters`, `AnalyticsSettings`, `AnalyticsDirections`, `AnalyticsArchiveActions`, `AnalyticsOverdueReviewActions`, `AnalyticsBuildEnvs`), never a call-site literal — the sanitizer gates keys, not values, so a misspelling is a silent second console row. A value with an existing owner reuses it (`UserStatus.active.name`). (ADR-0163)
- Send counts through `bucketCount` and a query only as `bucketQueryLength`, never the query text — a client search is a surname or phone number. (ADR-0163)
- Never call `setUserId`. The role goes out as the `user_role` user property only; don't declare app version, device model or OS version as properties (Firebase reports them automatically). (ADR-0165)

## Identity

- Drive `user_role` from the LIVE Firestore doc via `AnalyticsIdentityListener` (`core/app/`, registered in `main.dart`'s `build` after `AppSyncListeners`). A settled EMPTY role CLEARS it (sign-out, and the fresh-sign-in bootstrap window); a loading or error read HOLDS the last value — a stale role mislabels every event for the session, plausibly. (ADR-0165)
- Never call `resetAnalyticsData` on sign-out — it mints a new app instance id and breaks retention; clear `user_role` at the sign-out site instead (`delete_account_flow.dart`, `change_password_screen.dart`), not waiting for the listener, so the `sign_out` event and anything after it stay off the old role. Accepted: two people on one handed-over device share an instance id. (ADR-0165)

## Events

- Fire on the sealed SUCCESS branch, never before the write and never on `Busy` (a no-op that wrote nothing), e.g. `AddEventSubmitted`, `EventDetailsSaved`, `EventDetailsActionOk`, `ClientSaved`, `EmployeeAccountCreated`, `EmployeeUpdated`, `EmployeeStatusChanged`, `OverdueReviewApplied`. (ADR-0168)
- Assert membership on every send, not just shape: `_log` → `isKnownEvent`, `_setUserProperty` → `isKnownUserProperty`, `logScreenView` → `AnalyticsScreens.allScreens.contains` — a declared set nothing asserts against lets an orphan name ship with the suite green. (ADR-0164)
- Keep every declared name walked through `AnalyticsNames` by `analytics_events_test.dart` — Firebase drops a malformed name SILENTLY. The user-property cap (24) is shorter than the event cap (40). (ADR-0163)
- Leave these ABSENT — don't "complete" them: `has_notes` on `job_completed` (`fieldNotes` is the legacy path; `note_added` covers it), a result count on `search_used` (results aren't fetched at the debounce commit; a later send is a second event), `source` on `contact_action` (the shared launch helpers can't know the calling screen). (ADR-0168)
- Send `overdue_review_applied` with `action` (`complete`/`not_done`) and `count` via `bucketCount`, on the review screen's success branch only; the screen reports as `overdue_review` through the route observer, and a job opened from it as `AnalyticsSources.overdueReview`. Register a new parameter as a GA custom dimension before it shows in reports. (ADR-0168)

## Screen views

- Split screen views between the route observer and the hub shell, and move both halves together: `analyticsScreenForRoute` returns null for the four `kShellOwnedRoutes`, and `HubShellState` reports those tabs itself (`initState`, and `select` only when `tab != _current`) — else `HubTabRedirectRoute`'s named push double-counts one arrival path. (ADR-0164)
- Keep `FirebaseAutomaticScreenReportingEnabled=false` in `ios/Runner/Info.plist`; don't remove it to restore the iOS default — native reporting adds a nameless `FlutterViewController` `screen_view` per launch that the split can't guard. (ADR-0164)
- Have any surface the observer can't see call `logScreenView` from its own `initState`: the unnamed `showModalBottomSheet` sheets (add-appointment, add/edit-client, invite/edit-person), `EventDetailsView` (`_logView`), `ClientDetailView` (also the two-pane pane, so a tile-side event would miss tablet opens) and `OnboardingScreen` (built inline by `OnboardingGate`; `analyticsScreenForRoute` has no onboarding case) — else the create funnels lose their entry step. (ADR-0164)

## Build and iOS

- Keep collection OFF in debug unless `--dart-define=ANALYTICS_DEBUG=true` (`kAnalyticsCollectionEnabled`), or every `flutter run` files real-looking events against production; `build_env` (`release`/`debug`) is a user property so DebugView traffic stays filterable. Live DebugView also needs `-FIRDebugEnabled` on the Xcode scheme. (ADR-0167)
- Build every shipping `flutter build ios` with `FIREBASE_ANALYTICS_WITHOUT_ADID=true` (swaps `FirebaseAnalytics` for `FirebaseAnalyticsCore` in the plugin's `Package.swift`) — no ads, so the ad id only costs privacy disclosure and a possible ATT prompt. (ADR-0167)
- Vet any new analytics dependency for SPM support, as `firebase_analytics` was — there is no Podfile, ever. (ADR-0167)
