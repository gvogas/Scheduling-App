# Remote Config kill switches — design

**Date:** 2026-10-06 · **Status:** approved design, not implemented

## Goal

Disable risky or expensive features in production **without an App Store
release**, and force stale builds to update. One Firebase Remote Config
template is the single source of truth, read by the app and by Cloud
Functions.

## Decisions

| Question | Decision |
|---|---|
| Features in v1 | Address autocomplete, presence/live map, Live Activities, Wave sync |
| Scope | App **and** functions (protects against builds that predate the flags) |
| Forced update | Included (`min_supported_build`) |
| Wave while off | Queue, drain later — nothing lost |
| Flag store | Firebase Remote Config (not a Firestore doc) |

## 1. Flags and safety rules

| Key | Type | Default | Off means |
|---|---|---|---|
| `feature_address_autocomplete` | bool | `true` | Address field is plain text; `places*` callables refuse |
| `feature_presence` | bool | `true` | Location sharing stops; live map destination hidden |
| `feature_live_activities` | bool | `true` | No new activities; active ones ended; APNs pushes skipped |
| `feature_wave_sync` | bool | `true` | Wave settings show "paused"; outbox keeps queuing, drain stops sending |
| `min_supported_build` | int | `0` | Builds with a lower build number see a blocking update screen |

- **Fail open.** A fetch/load failure, first launch, offline start, or an
  empty/deleted template all evaluate to the defaults above: every feature
  on, `min_supported_build` 0. Only an explicitly published `false` (or a
  raised minimum) changes behaviour.
- **Defaults live in code** on both sides, so the console template is optional.
- **One owner per side:** `lib/core/remote_config/feature_flags.dart` and
  `functions/feature_flags.js`. A parity test on each side asserts the same
  five key names and defaults.
- **Every flip is observable:** the app leaves a `FLAGS` breadcrumb on each
  change of the evaluated flags; functions log when a flag blocks work.
  `FLAGS` is a new log-only tag and joins the registry in
  `.claude/rules/error-handling.md`.

## 2. App

### Core — `lib/core/remote_config/`

- `FeatureFlags` — immutable value class with the five fields and
  `FeatureFlags.defaults`.
- `RemoteConfigService` — plain class, injectable `FirebaseRemoteConfig`
  (mirrors `AuthService`). On `init()`: `setDefaults` from
  `FeatureFlags.defaults`, `activate()` the persisted last-fetched values,
  then `fetchAndActivate()` in the background and subscribe to
  `onConfigUpdated` (activate on each event). Exposes
  `Stream<FeatureFlags> watch()` emitting the current values then each update.
  Every failure is logged (`FLAGS`) and leaves the previous values in place.
- `featureFlagsProvider` — `StreamProvider<FeatureFlags>` over `watch()`.
  Consumers read through a selector and treat loading/error as
  `FeatureFlags.defaults`.
- `main()` starts `init()` **without awaiting it before `runApp`**. Fetch
  interval stays the 12 h default; the real-time listener carries urgent
  flips.
- New dependency: `firebase_remote_config` (FlutterFire, same release train
  as the existing Firebase packages; SPM only, per `ios/CLAUDE.md`).

### Per-feature gates

Each gate sits where the feature already decides on/off.

- **Address autocomplete:** the address autocomplete field renders a plain
  `TextField` when off and makes no callable.
- **Presence:** `PresenceSyncController.sync()` treats flag-off as "not
  sharing" (same stop/deregister path as the user turning sharing off).
  `AppSyncListeners` re-runs `sync()` when the flag changes. The live map
  destination is hidden in the hub shell; its `AppDestination` member is
  **not** renamed (tour storage keys). The Location sharing settings view
  shows `common_featurePaused`.
- **Live Activities:** `liveActivityEnabledProvider` is ANDed with the flag.
  Turning off ends active activities and de-registers tokens through the
  existing preference-off path.
- **Wave:** `WaveSettingsSection` shows `settings_wavePaused` and disables
  Connect / Sync / Retry.

### Forced update

- `UpdateRequiredScreen` — blocking, no back navigation, one "Open App Store"
  button through `launchExternalUri` (`LAUNCH-URL`). Session untouched.
- Checked at **two** gates: `SplashScreen` (cold start, cached activated
  value) and a new `UpdateRequiredListener` in `lib/core/app/` beside
  `AccountExitListeners`, which pushes the screen mid-session when an update
  raises the minimum above the running build.
- Running build number from `package_info_plus` (already a dependency),
  compared as an int with `min_supported_build`. An unparseable build number
  fails open (no block).

### Copy

New keys in both ARBs with `@key` blocks: `common_updateRequiredTitle`,
`common_updateRequiredBody`, `common_updateRequiredButton`,
`common_featurePaused`, `settings_wavePaused`.

## 3. Functions

### Core — `functions/feature_flags.js` + `functions/feature_flags_policy.js`

- `getFeatureFlags()` loads the server template
  (`getRemoteConfig().getServerTemplate({defaultConfig})`), evaluates it and
  returns the five values.
- The policy module owns the cache and fallback with `loader` and `now`
  injected: a result is reused for **60 s per instance**; a failed load
  returns the last good values, or the code defaults if none, and logs a
  `warn`. A Remote Config outage never blocks work.

### Choke points

- **`placesAutocomplete`, `placesGetDetails`, `placesReverseGeocode`:** check
  the flag after the auth and payload guards and **before**
  `enforceDurableRateLimit`, so a refused call spends no rate-limit slot.
  Off ⇒ `HttpsError('failed-precondition', 'feature-disabled')`. Older
  builds already absorb a failed lookup via the `ADDR-PLACES` path.
- **Live Activities:** `live_activity_dispatch.js` skips
  `sendLiveActivityPush` when off and returns a `skipped` result. A `skipped`
  result must **never** be treated as an invalid token — otherwise a pause
  deletes every registered token.
- **Wave:** `drainQueue` (`wave/dispatch.js`) returns early with
  `{paused: true}` **before claiming any job**, so no attempt is spent and
  nothing dead-letters; the backlog drains on the first run after re-enable.
  `waveBootstrap`, `waveImportCustomers`, `waveRetryFailedJobs` refuse with
  `failed-precondition`. `waveGetConnection` keeps working (read-only, the
  paused banner needs it). `waveUpsertCustomer` still enqueues.
- **Presence:** no server gate. Presence is written client-direct to
  Firestore with no function in the path; pre-flag builds stop only when
  `min_supported_build` forces the update.

## 4. Rollout

- **No deploy-ordering hazard:** all defaults are "on", so new functions with
  no template, or an old app with no flags, behave exactly as today.
- **IAM check before the first real flip:** the functions runtime service
  account needs Remote Config read (`cloudconfig.configs.get`). Without it
  the loader fails open — safe, but the switch would do nothing server-side.
  The runbook includes a one-time test: publish a flag off, confirm the
  function's "blocked by flag" log line, publish it back on.
- **Docs:** a "Flip a kill switch" section in `docs/DEPLOYMENT.md` (keys,
  what each does, how to roll back via template history, the IAM test); a
  short bullet in `CLAUDE.md`; the two new modules in
  `docs/CLOUD_FUNCTIONS.md`; the `FLAGS` tag in the error-handling registry.

## 5. Testing

**Dart**
- `RemoteConfigService` with a fake instance: defaults before activate,
  activated values, update stream, fetch error keeps defaults.
- One test per gate: address field falls back to a plain field; presence
  `sync()` stops when off and resumes when on; Live Activities end on
  flag-off; Wave buttons disabled with the banner; live map destination
  hidden.
- `UpdateRequiredScreen` at 260 px wide with 2× text; splash gate and
  mid-session listener gate both route to it; unparseable build number does
  not block.
- Parity: the five keys and defaults.

**JS**
- Policy: cache hit within 60 s, reload after, failed load returns last good,
  failed first load returns defaults.
- Places: refusal happens before the rate limiter is called.
- Live Activities: `skipped` never deletes or invalidates a token.
- Wave: a paused drain claims nothing; the three callables refuse;
  `waveGetConnection` still answers.
- Parity: the five keys and defaults.

## Out of scope

Percentage rollouts, per-user targeting, A/B tests, server-side presence
enforcement, and flags for any feature not listed above.
