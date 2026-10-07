# Remote Config Kill Switches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four Remote Config kill switches (address autocomplete, presence/live map, Live Activities, Wave sync) plus a `min_supported_build` forced-update gate, enforced in the app and in Cloud Functions, all failing OPEN.

**Architecture:** One Remote Config template is the single source of truth. Functions read it through `firebase-admin`'s server-side Remote Config behind a 60 s per-instance cache (`feature_flags_policy.js` owns the decisions, `feature_flags.js` the admin call). The app reads it through `RemoteConfigService` → `featureFlagsProvider`, and each feature gates at the one place it already decides on/off.

**Tech Stack:** Flutter / Riverpod 3 / `firebase_remote_config` (new); Node 24 / `firebase-functions` v2 / `firebase-admin` 14 (`firebase-admin/remote-config`); Jest; flutter_test + mocktail.

**Spec:** `docs/plans/2026-10-06-remote-config-kill-switches-design.md`

---

## Deviations from the spec

1. **Forced update is ONE gate, not two.** The spec put a check in `SplashScreen` and a separate mid-session listener. Splash's `pushReplacementNamed` would race a listener's push. Instead `UpdateGate` wraps the app inside `MaterialApp.builder` (where `AppLock` already sits) and swaps the whole navigator for `UpdateRequiredScreen` whenever the running build is below the minimum. That covers cold start AND mid-session, with nothing to race.
2. **`RemoteConfigService` starts lazily on first listen** (the first `featureFlagsProvider` read in `PaulApp.build`) rather than from `main()`. Same effect as "not awaited before `runApp`", and `main()` stays untouched.
3. **Missing-default protection uses `ValueSource`.** If `setDefaults` fails, `getBool` on an unknown key returns `false`, which would be fail-CLOSED. `FeatureFlags.fromRemoteConfig` therefore treats a `ValueSource.valueStatic` value (no remote value and no default installed) as the code default.

## Prerequisite (owner input)

- [ ] **Step 0: Get the numeric Apple ID** from App Store Connect → the app → App Information → "Apple ID" (a 9-10 digit number). Task 15 needs it for `kAppStoreUrl`. Nothing in the repo records it today.

## File map

**Functions**
- Create `functions/feature_flags_policy.js`: keys, defaults, parsing, the 60 s fail-open cache. Pure, injectable.
- Create `functions/feature_flags.js`: the real `firebase-admin/remote-config` loader, `getFeatureFlags()`, `assertFeatureEnabled()`.
- Modify `functions/places.js`: gate the three callables before the rate limiter.
- Modify `functions/live_activity_dispatch.js`: `_sendToRow` skips while paused, never deleting a token.
- Modify `functions/wave/dispatch.js`: `drainQueue` returns `paused` before claiming anything.
- Modify `functions/wave/callables.js`: `waveBootstrap`, `waveImportCustomers`, `waveRetryFailedJobs` refuse while paused.
- Tests: `functions/__tests__/feature_flags_policy.test.js`, `feature_flags.test.js`, `places_feature_flag.test.js`, `live_activity_feature_flag.test.js`, `wave_feature_flag.test.js`.

**App**
- Create `lib/core/remote_config/feature_flags.dart`: `FeatureFlags` value class, keys, defaults.
- Create `lib/core/remote_config/remote_config_service.dart`: wraps `FirebaseRemoteConfig`.
- Create `lib/core/remote_config/feature_flags_providers.dart`: the providers.
- Create `lib/core/remote_config/update_gate.dart`: `UpdateGate` and the pure `isUpdateRequired`.
- Create `lib/core/remote_config/update_required_screen.dart`.
- Create `lib/core/constants/app_store.dart`: `kAppStoreUrl`.
- Create `lib/shared/widgets/feature_paused_notice.dart`: one "temporarily paused" row used by three surfaces.
- Modify: `address_autocomplete_field.dart`, `presence_sync_controller.dart`, `live_activity_registration_controller.dart`, `app_sync_listeners.dart`, `drawer_catalog.dart`, `app_nav_drawer.dart`, `live_map_screen.dart`, `location_sharing_view.dart`, `wave_settings_section.dart`, `analytics_events.dart`, `main.dart`, both ARBs, `pubspec.yaml`.
- Tests under `test/core/remote_config/` and beside each gate.

**Docs**: `docs/DEPLOYMENT.md`, `docs/CLOUD_FUNCTIONS.md`, `CLAUDE.md`, `.claude/rules/error-handling.md`, `functions/CLAUDE.md`.

---

## Part A: Functions

### Task 1: The flag policy (pure)

**Files:**
- Create: `functions/feature_flags_policy.js`
- Test: `functions/__tests__/feature_flags_policy.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

const {
  FLAG_DEFAULTS,
  FLAG_KEYS,
  readFlags,
  createFlagCache,
} = require("../feature_flags_policy");

describe("FLAG_DEFAULTS", () => {
  test("every feature is on and no build is blocked", () => {
    expect(FLAG_DEFAULTS).toEqual({
      feature_address_autocomplete: true,
      feature_presence: true,
      feature_live_activities: true,
      feature_wave_sync: true,
      min_supported_build: 0,
    });
    expect(FLAG_KEYS).toEqual(Object.keys(FLAG_DEFAULTS));
  });
});

describe("readFlags", () => {
  test("reads booleans and the number through the evaluated config", () => {
    const config = {
      getBoolean: (k) => k !== "feature_wave_sync",
      getNumber: () => 93,
    };
    expect(readFlags(config)).toEqual({
      feature_address_autocomplete: true,
      feature_presence: true,
      feature_live_activities: true,
      feature_wave_sync: false,
      min_supported_build: 93,
    });
  });

  test("a non-finite build number falls back to 0", () => {
    const config = {getBoolean: () => true, getNumber: () => NaN};
    expect(readFlags(config).min_supported_build).toBe(0);
  });
});

describe("createFlagCache", () => {
  const logger = () => ({warn: jest.fn(), info: jest.fn()});

  test("reuses a load within the TTL and reloads after it", async () => {
    let t = 0;
    const loader = jest.fn(async () => ({...FLAG_DEFAULTS}));
    const cache = createFlagCache({loader, now: () => t, ttlMs: 60_000,
      logger: logger()});
    await cache.get();
    t = 59_999;
    await cache.get();
    expect(loader).toHaveBeenCalledTimes(1);
    t = 60_000;
    await cache.get();
    expect(loader).toHaveBeenCalledTimes(2);
  });

  test("a failed FIRST load fails open to the defaults and warns", async () => {
    const log = logger();
    const cache = createFlagCache({
      loader: async () => {
        throw new Error("no app");
      },
      now: () => 0, ttlMs: 60_000, logger: log,
    });
    await expect(cache.get()).resolves.toEqual(FLAG_DEFAULTS);
    expect(log.warn).toHaveBeenCalledTimes(1);
  });

  test("a failed reload keeps the last good values", async () => {
    let t = 0;
    const loader = jest.fn()
        .mockResolvedValueOnce({...FLAG_DEFAULTS, feature_wave_sync: false})
        .mockRejectedValueOnce(new Error("timeout"));
    const cache = createFlagCache({loader, now: () => t, ttlMs: 60_000,
      logger: logger()});
    await cache.get();
    t = 60_000;
    await expect(cache.get()).resolves.toMatchObject({
      feature_wave_sync: false,
    });
  });

  test("a failure is cached for the TTL too, so it is not retried per call",
      async () => {
        const loader = jest.fn().mockRejectedValue(new Error("down"));
        const cache = createFlagCache({loader, now: () => 0, ttlMs: 60_000,
          logger: logger()});
        await cache.get();
        await cache.get();
        expect(loader).toHaveBeenCalledTimes(1);
      });

  test("concurrent first calls share one load", async () => {
    const loader = jest.fn(async () => ({...FLAG_DEFAULTS}));
    const cache = createFlagCache({loader, now: () => 0, ttlMs: 60_000,
      logger: logger()});
    await Promise.all([cache.get(), cache.get(), cache.get()]);
    expect(loader).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/feature_flags_policy.test.js`
Expected: FAIL, `Cannot find module '../feature_flags_policy'`.

- [ ] **Step 3: Write the implementation**

```js
"use strict";

/**
 * @fileoverview Kill-switch keys, defaults and the fail-open cache. Pure: the
 * Remote Config call is injected, so this is unit-testable.
 * @module feature_flags_policy
 */

const FLAG_DEFAULTS = Object.freeze({
  feature_address_autocomplete: true,
  feature_presence: true,
  feature_live_activities: true,
  feature_wave_sync: true,
  min_supported_build: 0,
});

const FLAG_KEYS = Object.keys(FLAG_DEFAULTS);

/**
 * Reads every flag from an evaluated server config.
 * @param {{getBoolean: function(string): boolean,
 *   getNumber: function(string): number}} config
 * @return {!Object}
 */
function readFlags(config) {
  const flags = {};
  for (const key of FLAG_KEYS) {
    if (typeof FLAG_DEFAULTS[key] === "boolean") {
      flags[key] = config.getBoolean(key);
    } else {
      const n = config.getNumber(key);
      flags[key] = Number.isFinite(n) ? n : FLAG_DEFAULTS[key];
    }
  }
  return flags;
}

/**
 * A per-instance cache that never throws: a failed load returns the last good
 * flags, or the defaults when there are none.
 * @param {{loader: function(): !Promise<!Object>, now: function(): number,
 *   ttlMs: number, logger: !Object}} deps
 * @return {{get: function(): !Promise<!Object>}}
 */
function createFlagCache({loader, now, ttlMs, logger}) {
  let value = null;
  let loadedAt = -Infinity;
  let pending = null;

  /**
   * Loads once, falling back on failure.
   * @return {!Promise<!Object>}
   */
  async function load() {
    try {
      value = await loader();
    } catch (err) {
      logger.warn("FLAGS load failed; failing open", {err: String(err)});
      value = value || {...FLAG_DEFAULTS};
    }
    loadedAt = now();
    return value;
  }

  return {
    get() {
      if (value && now() - loadedAt < ttlMs) return Promise.resolve(value);
      if (!pending) {
        pending = load().finally(() => {
          pending = null;
        });
      }
      return pending;
    },
  };
}

module.exports = {FLAG_DEFAULTS, FLAG_KEYS, readFlags, createFlagCache};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && npx jest __tests__/feature_flags_policy.test.js`
Expected: PASS, 8 tests.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint && cd ..
git add functions/feature_flags_policy.js functions/__tests__/feature_flags_policy.test.js
git commit -m "Add the fail-open kill-switch flag policy for functions"
```

### Task 2: The Remote Config loader and the callable guard

**Files:**
- Create: `functions/feature_flags.js`
- Test: `functions/__tests__/feature_flags.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

const mockEvaluate = jest.fn();
jest.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({
    getServerTemplate: jest.fn(async () => ({evaluate: mockEvaluate})),
  }),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const {
  loadFromRemoteConfig,
  assertFeatureEnabled,
  _resetForTest,
} = require("../feature_flags");

beforeEach(() => {
  mockEvaluate.mockReset();
  _resetForTest();
});

test("loadFromRemoteConfig evaluates the server template", async () => {
  mockEvaluate.mockReturnValue({
    getBoolean: (k) => k !== "feature_presence",
    getNumber: () => 90,
  });
  await expect(loadFromRemoteConfig()).resolves.toMatchObject({
    feature_presence: false,
    feature_wave_sync: true,
    min_supported_build: 90,
  });
});

test("assertFeatureEnabled passes while the feature is on", async () => {
  mockEvaluate.mockReturnValue({getBoolean: () => true, getNumber: () => 0});
  await expect(assertFeatureEnabled("feature_wave_sync", "waveBootstrap"))
      .resolves.toBeUndefined();
});

test("assertFeatureEnabled refuses with failed-precondition when off",
    async () => {
      mockEvaluate.mockReturnValue({
        getBoolean: (k) => k !== "feature_wave_sync",
        getNumber: () => 0,
      });
      const call = assertFeatureEnabled("feature_wave_sync", "waveBootstrap");
      await expect(call).rejects.toBeInstanceOf(HttpsError);
      await expect(call).rejects.toMatchObject({
        code: "failed-precondition",
        message: "feature-disabled",
      });
    });

test("an unknown key is a programming error, not a silent pass", async () => {
  await expect(assertFeatureEnabled("feature_nope", "x"))
      .rejects.toThrow(/unknown flag/);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/feature_flags.test.js`
Expected: FAIL, `Cannot find module '../feature_flags'`.

- [ ] **Step 3: Write the implementation**

```js
"use strict";

/**
 * @fileoverview Server-side kill switches read from Remote Config. The admin
 * module is required lazily so a jest `require()` of a gated module never
 * touches admin at load (see functions/CLAUDE.md).
 * @module feature_flags
 */

const {HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {
  FLAG_DEFAULTS,
  readFlags,
  createFlagCache,
} = require("./feature_flags_policy");

const FLAG_TTL_MS = 60_000;

/**
 * Loads and evaluates the Remote Config server template.
 * @return {!Promise<!Object>}
 */
async function loadFromRemoteConfig() {
  // eslint-disable-next-line global-require
  const {getRemoteConfig} = require("firebase-admin/remote-config");
  const template = await getRemoteConfig().getServerTemplate({
    defaultConfig: {...FLAG_DEFAULTS},
  });
  return readFlags(template.evaluate());
}

let cache = createFlagCache({
  loader: loadFromRemoteConfig, now: Date.now, ttlMs: FLAG_TTL_MS, logger,
});

/**
 * The current flags, at most 60 s stale. Never throws.
 * @return {!Promise<!Object>}
 */
function getFeatureFlags() {
  return cache.get();
}

/**
 * Throws `failed-precondition` / `feature-disabled` when [key] is off.
 * @param {string} key A boolean key of FLAG_DEFAULTS.
 * @param {string} label The callable name, for the log line.
 * @return {!Promise<void>}
 */
async function assertFeatureEnabled(key, label) {
  if (typeof FLAG_DEFAULTS[key] !== "boolean") {
    throw new Error(`unknown flag ${key}`);
  }
  const flags = await getFeatureFlags();
  if (flags[key] === false) {
    logger.info("FLAGS blocked a call", {key, label});
    throw new HttpsError("failed-precondition", "feature-disabled");
  }
}

/**
 * Test hook: drops the cached flags.
 * @return {void}
 */
function _resetForTest() {
  cache = createFlagCache({
    loader: loadFromRemoteConfig, now: Date.now, ttlMs: FLAG_TTL_MS, logger,
  });
}

module.exports = {
  loadFromRemoteConfig,
  getFeatureFlags,
  assertFeatureEnabled,
  _resetForTest,
};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && npx jest __tests__/feature_flags.test.js`
Expected: PASS, 4 tests.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint && cd ..
git add functions/feature_flags.js functions/__tests__/feature_flags.test.js
git commit -m "Read kill switches from the Remote Config server template"
```

### Task 3: Gate the three Places callables before the rate limiter

**Files:**
- Modify: `functions/places.js` (imports at the top; each of `placesAutocomplete`, `placesGetDetails`, `placesReverseGeocode`)
- Test: `functions/__tests__/places_feature_flag.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  return {
    ...actual,
    assertAdminCall: jest.fn(async (req) => req.auth.uid),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
});
jest.mock("../feature_flags", () => ({
  assertFeatureEnabled: jest.fn(),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const security = require("../security");
const {assertFeatureEnabled} = require("../feature_flags");
const {
  placesAutocomplete,
  placesGetDetails,
  placesReverseGeocode,
} = require("../places");

const ADMIN = {uid: "admin-uid"};
const CALLS = [
  ["placesAutocomplete", placesAutocomplete, {input: "123 Main"}],
  ["placesGetDetails", placesGetDetails, {placeId: "abc_1"}],
  ["placesReverseGeocode", placesReverseGeocode, {lat: 45.5, lng: -73.5}],
];

beforeEach(() => {
  jest.clearAllMocks();
  global.fetch = jest.fn();
  assertFeatureEnabled.mockRejectedValue(
      new HttpsError("failed-precondition", "feature-disabled"));
});

test.each(CALLS)("%s refuses while paused, before the limiter or a fetch",
    async (name, fn, data) => {
      await expect(fn.run({data, auth: ADMIN}))
          .rejects.toMatchObject({message: "feature-disabled"});
      expect(assertFeatureEnabled)
          .toHaveBeenCalledWith("feature_address_autocomplete", name);
      expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      expect(global.fetch).not.toHaveBeenCalled();
    });
```

Before running, check the real payload keys of `placesReverseGeocode` (`sed -n 239,270p functions/places.js`) and adjust the third row's `data` to match its `assertAdminCall` allowlist.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/places_feature_flag.test.js`
Expected: FAIL. `assertFeatureEnabled` is never called and the limiter runs.

- [ ] **Step 3: Implement**

Add the import under the existing `require("./params")` line:

```js
const {assertFeatureEnabled} = require("./feature_flags");
```

In **each** of the three handlers, insert one line immediately after the payload validation (after `readSessionToken` / the `PLACE_ID_PATTERN` check / the coordinate checks) and immediately before `await enforceDurableRateLimit(`. For `placesAutocomplete` that reads:

```js
      const input = requireString(req.data, "input", INPUT_MAX_LEN);
      const sessionToken = readSessionToken(req.data);
      await assertFeatureEnabled(
          "feature_address_autocomplete", "placesAutocomplete");

      await enforceDurableRateLimit(
```

and likewise with `"placesGetDetails"` and `"placesReverseGeocode"` as the label.

- [ ] **Step 4: Run the new test and the existing Places suites**

Run: `cd functions && npx jest __tests__/places`
Expected: PASS. The older suites don't mock `../feature_flags`, so they reach the real loader. It throws (no admin app in Jest), the cache fails open, and they behave exactly as before.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint && cd ..
git add functions/places.js functions/__tests__/places_feature_flag.test.js
git commit -m "Refuse Places lookups while address autocomplete is paused"
```

### Task 4: Live Activity pushes skip while paused and never delete a token

**Files:**
- Modify: `functions/live_activity_dispatch.js` (`_sendToRow`, around line 155)
- Test: `functions/__tests__/live_activity_feature_flag.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

jest.mock("../apns_client", () => ({sendLiveActivityPush: jest.fn()}));
jest.mock("../live_activity_registry", () => ({
  listPushToStartTokens: jest.fn(),
  listUpdateTokens: jest.fn(),
  deleteActivityToken: jest.fn(),
  writeCardMarker: jest.fn(),
  readCardMarker: jest.fn(),
  setCardStart: jest.fn(),
  clearCardMarker: jest.fn(),
}));

const {sendLiveActivityPush} = require("../apns_client");
const registry = require("../live_activity_registry");
const {
  startLiveActivity,
  updateLiveActivity,
} = require("../live_activity_dispatch");

const AUTH = {authKey: "-----KEY-----", keyId: "K1", teamId: "T1"};
const NOW = new Date("2026-07-19T11:30:00Z");
const CTX = {clientName: "Ada", address: "14 Elm St",
  startTime: new Date("2026-07-19T12:00:00Z")};
const ROW = {token: "tok-1", locale: "en", kind: "update",
  employeeDocId: "emp1", ref: {id: "act1"}};

/**
 * @param {boolean} on
 * @return {!Object}
 */
function deps(on) {
  const employee = {exists: true, data: () => ({colorValue: 1})};
  return {
    db: {collection: () => ({doc: () => ({get: async () => employee})})},
    logger: {warn: jest.fn(), info: jest.fn()},
    apnsAuth: AUTH,
    featureFlags: async () => ({feature_live_activities: on}),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  sendLiveActivityPush.mockResolvedValue({ok: true, gone: false});
  registry.listPushToStartTokens.mockResolvedValue([ROW]);
  registry.listUpdateTokens.mockResolvedValue([ROW]);
  registry.writeCardMarker.mockResolvedValue(true);
  registry.setCardStart.mockResolvedValue(true);
  registry.readCardMarker.mockResolvedValue(
      {employeeDocId: "emp1", appointmentId: "appt1", phase: "travel"});
});

test("paused: start sends nothing and deletes nothing", async () => {
  const started = await startLiveActivity(deps(false), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(started).toBe(0);
  expect(sendLiveActivityPush).not.toHaveBeenCalled();
  expect(registry.deleteActivityToken).not.toHaveBeenCalled();
});

test("paused: update sends nothing and deletes nothing", async () => {
  const updated = await updateLiveActivity(deps(false), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(updated).toBe(0);
  expect(sendLiveActivityPush).not.toHaveBeenCalled();
  expect(registry.deleteActivityToken).not.toHaveBeenCalled();
});

test("on: a push is sent as before", async () => {
  await updateLiveActivity(deps(true), {
    appointmentId: "appt1", employeeDocId: "emp1", ctx: CTX, nowDate: NOW,
  });
  expect(sendLiveActivityPush).toHaveBeenCalledTimes(1);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/live_activity_feature_flag.test.js`
Expected: FAIL. The paused tests see `sendLiveActivityPush` called.

- [ ] **Step 3: Implement**

Add near the other requires at the top of `live_activity_dispatch.js`:

```js
const {getFeatureFlags} = require("./feature_flags");
```

Replace the opening of `_sendToRow` (keep its JSDoc and add `deps.featureFlags` to the `deps` description):

```js
async function _sendToRow(deps, row, payload, label) {
  const auth = _authOf(deps);
  if (!auth || !row || !row.token) return 0;
  const flags = await (deps.featureFlags || getFeatureFlags)();
  if (flags.feature_live_activities === false) {
    // Skipped, NOT gone: a paused send must never prune the token.
    return 0;
  }
  const result = await sendLiveActivityPush({
```

The rest of the function is unchanged.

- [ ] **Step 4: Run the new test and the existing Live Activity suites**

Run: `cd functions && npx jest __tests__/live_activity`
Expected: PASS. Existing suites inject no `featureFlags`, hit the real loader, and fail open.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint && cd ..
git add functions/live_activity_dispatch.js functions/__tests__/live_activity_feature_flag.test.js
git commit -m "Skip Live Activity pushes while paused without pruning tokens"
```

### Task 5: Wave pauses the drain and refuses the three action callables

**Files:**
- Modify: `functions/wave/dispatch.js` (`drainQueue`, around line 258)
- Modify: `functions/wave/callables.js` (`waveBootstrap`, `waveRetryFailedJobs`, `waveImportCustomers`)
- Test: `functions/__tests__/wave_feature_flag.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  return {
    ...actual,
    assertAdminCall: jest.fn(async (req) => req.auth.uid),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
});
jest.mock("../feature_flags", () => {
  const {HttpsError} = require("firebase-functions/v2/https");
  return {
    getFeatureFlags: jest.fn(async () => ({feature_wave_sync: false})),
    assertFeatureEnabled: jest.fn(async () => {
      throw new HttpsError("failed-precondition", "feature-disabled");
    }),
  };
});

const security = require("../security");
const {assertFeatureEnabled} = require("../feature_flags");
const {drainQueue} = require("../wave/dispatch");
const {
  waveBootstrap,
  waveRetryFailedJobs,
  waveImportCustomers,
} = require("../wave/callables");

const ADMIN = {uid: "admin-uid"};

test("a paused drain claims nothing and reports paused", async () => {
  const db = {
    collection: jest.fn(() => {
      throw new Error("must not read the queue");
    }),
    runTransaction: jest.fn(),
  };
  const summary = await drainQueue({db, logger: {info: jest.fn()}});
  expect(summary).toMatchObject({paused: true, processed: 0, done: 0,
    dead: 0});
  expect(db.collection).not.toHaveBeenCalled();
  expect(db.runTransaction).not.toHaveBeenCalled();
});

test.each([
  ["waveBootstrap", waveBootstrap],
  ["waveRetryFailedJobs", waveRetryFailedJobs],
  ["waveImportCustomers", waveImportCustomers],
])("%s refuses while paused, before the limiter", async (name, fn) => {
  await expect(fn.run({data: {}, auth: ADMIN}))
      .rejects.toMatchObject({message: "feature-disabled"});
  expect(assertFeatureEnabled).toHaveBeenCalledWith("feature_wave_sync", name);
  expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/wave_feature_flag.test.js`
Expected: FAIL. The drain throws "must not read the queue", and the callables don't call `assertFeatureEnabled`.

- [ ] **Step 3: Implement the drain pause**

In `wave/dispatch.js` add with the other requires:

```js
const {getFeatureFlags} = require("../feature_flags");
```

In `drainQueue`, after `const summary = {...};` and before `const ctx = {`, insert:

```js
  const flags = await (deps.featureFlags || getFeatureFlags)();
  if (flags.feature_wave_sync === false) {
    // Before any claim, so no attempt is spent and nothing dead-letters.
    logger.info("FLAGS wave sync paused; drain skipped");
    return {...summary, paused: true};
  }
```

Add `deps.featureFlags` to the JSDoc's `deps` list and `paused` to the `@return` shape.

- [ ] **Step 4: Implement the callable refusals**

In `wave/callables.js` add:

```js
const {assertFeatureEnabled} = require("../feature_flags");
```

Insert as the line directly after `assertAdminCall` in each of the three handlers:

```js
      const uid = await assertAdminCall(req, new Set());
      await assertFeatureEnabled("feature_wave_sync", "waveBootstrap");
```

(and `"waveRetryFailedJobs"` / `"waveImportCustomers"`). `waveGetConnection` and `waveSetImportSchedule` stay ungated. `waveUpsertCustomer` (the trigger) stays ungated so the outbox keeps queuing; its inline drain goes through `drainQueue` and is skipped there.

- [ ] **Step 5: Run the new test and every Wave suite**

Run: `cd functions && npx jest __tests__/wave __tests__/drain_wave_queue`
Expected: PASS. Existing suites fail open through the real loader.

- [ ] **Step 6: Full functions gate, then commit**

Run: `cd functions && npm test && npm run lint`
Expected: all suites PASS and the coverage thresholds hold.

```bash
git add functions/wave/dispatch.js functions/wave/callables.js functions/__tests__/wave_feature_flag.test.js
git commit -m "Pause the Wave drain and refuse Wave actions while sync is paused"
```

---

## Part B: App core

### Task 6: Add the dependency and the `FeatureFlags` value class

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/remote_config/feature_flags.dart`
- Test: `test/core/remote_config/feature_flags_test.dart`

- [ ] **Step 1: Add the package**

Run: `flutter pub add firebase_remote_config`
Expected: resolves against the existing FlutterFire versions. If it fails, do not force a version. Stop and check the FlutterFire release train for the version matching `firebase_core ^4.14.0`. iOS picks it up through SPM; there is no Podfile.

- [ ] **Step 2: Write the failing test**

```dart
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

RemoteConfigValue _remote(String v) =>
    RemoteConfigValue(v.codeUnits, ValueSource.valueRemote);
RemoteConfigValue _static() => RemoteConfigValue(null, ValueSource.valueStatic);

void main() {
  test('defaults: every feature on, no build blocked', () {
    const d = FeatureFlags.defaults;
    expect(d.addressAutocomplete, isTrue);
    expect(d.presence, isTrue);
    expect(d.liveActivities, isTrue);
    expect(d.waveSync, isTrue);
    expect(d.minSupportedBuild, 0);
  });

  test('the five keys match functions/feature_flags_policy.js', () {
    expect(FeatureFlags.defaults.toRemoteConfigDefaults(), {
      'feature_address_autocomplete': true,
      'feature_presence': true,
      'feature_live_activities': true,
      'feature_wave_sync': true,
      'min_supported_build': 0,
    });
  });

  test('reads published remote values', () {
    final flags = FeatureFlags.fromValues({
      'feature_address_autocomplete': _remote('true'),
      'feature_presence': _remote('false'),
      'feature_live_activities': _remote('true'),
      'feature_wave_sync': _remote('false'),
      'min_supported_build': _remote('93'),
    });
    expect(flags.presence, isFalse);
    expect(flags.waveSync, isFalse);
    expect(flags.minSupportedBuild, 93);
  });

  test('a static value (no default installed) fails OPEN, not closed', () {
    final flags = FeatureFlags.fromValues({
      for (final key in FeatureFlags.keys) key: _static(),
    });
    expect(flags, FeatureFlags.defaults);
  });

  test('a missing key fails open', () {
    expect(FeatureFlags.fromValues(const {}), FeatureFlags.defaults);
  });
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `flutter test test/core/remote_config/feature_flags_test.dart`
Expected: FAIL, the file under test does not exist.

- [ ] **Step 4: Implement**

```dart
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Remote Config kill switches. Keys and defaults mirror
/// `functions/feature_flags_policy.js`.
@immutable
class FeatureFlags {
  const FeatureFlags({
    required this.addressAutocomplete,
    required this.presence,
    required this.liveActivities,
    required this.waveSync,
    required this.minSupportedBuild,
  });

  static const defaults = FeatureFlags(
    addressAutocomplete: true,
    presence: true,
    liveActivities: true,
    waveSync: true,
    minSupportedBuild: 0,
  );

  static const _addressAutocomplete = 'feature_address_autocomplete';
  static const _presence = 'feature_presence';
  static const _liveActivities = 'feature_live_activities';
  static const _waveSync = 'feature_wave_sync';
  static const _minSupportedBuild = 'min_supported_build';

  static const keys = [
    _addressAutocomplete,
    _presence,
    _liveActivities,
    _waveSync,
    _minSupportedBuild,
  ];

  final bool addressAutocomplete;
  final bool presence;
  final bool liveActivities;
  final bool waveSync;
  final int minSupportedBuild;

  /// A static value means no remote value AND no installed default, so the
  /// code default wins — `asBool()` would read it as false (fail closed).
  factory FeatureFlags.fromValues(Map<String, RemoteConfigValue> values) {
    bool readBool(String key, bool fallback) {
      final v = values[key];
      if (v == null || v.source == ValueSource.valueStatic) return fallback;
      return v.asBool();
    }

    int readInt(String key, int fallback) {
      final v = values[key];
      if (v == null || v.source == ValueSource.valueStatic) return fallback;
      return v.asInt();
    }

    return FeatureFlags(
      addressAutocomplete: readBool(
        _addressAutocomplete,
        defaults.addressAutocomplete,
      ),
      presence: readBool(_presence, defaults.presence),
      liveActivities: readBool(_liveActivities, defaults.liveActivities),
      waveSync: readBool(_waveSync, defaults.waveSync),
      minSupportedBuild: readInt(
        _minSupportedBuild,
        defaults.minSupportedBuild,
      ),
    );
  }

  Map<String, Object> toRemoteConfigDefaults() => {
    _addressAutocomplete: addressAutocomplete,
    _presence: presence,
    _liveActivities: liveActivities,
    _waveSync: waveSync,
    _minSupportedBuild: minSupportedBuild,
  };

  @override
  bool operator ==(Object other) =>
      other is FeatureFlags &&
      other.addressAutocomplete == addressAutocomplete &&
      other.presence == presence &&
      other.liveActivities == liveActivities &&
      other.waveSync == waveSync &&
      other.minSupportedBuild == minSupportedBuild;

  @override
  int get hashCode => Object.hash(
    addressAutocomplete,
    presence,
    liveActivities,
    waveSync,
    minSupportedBuild,
  );

  @override
  String toString() =>
      'FeatureFlags(addr: $addressAutocomplete, presence: $presence, '
      'liveAct: $liveActivities, wave: $waveSync, minBuild: $minSupportedBuild)';
}
```

- [ ] **Step 5: Run it to verify it passes, then commit**

Run: `flutter test test/core/remote_config/feature_flags_test.dart && flutter analyze`
Expected: 5 tests PASS, `No issues found!`.

```bash
git add pubspec.yaml pubspec.lock lib/core/remote_config/feature_flags.dart test/core/remote_config/feature_flags_test.dart
git commit -m "Add firebase_remote_config and the FeatureFlags value class"
```

### Task 7: `RemoteConfigService`

**Files:**
- Create: `lib/core/remote_config/remote_config_service.dart`
- Test: `test/core/remote_config/remote_config_service_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/remote_config_service.dart';

class _MockRemoteConfig extends Mock implements FirebaseRemoteConfig {}

class _MockLogger extends Mock implements AppLogger {}

RemoteConfigValue _remote(String v) =>
    RemoteConfigValue(v.codeUnits, ValueSource.valueRemote);

Map<String, RemoteConfigValue> _values({bool wave = true}) => {
  for (final k in FeatureFlags.keys) k: _remote(k == 'min_supported_build' ? '0' : 'true'),
  'feature_wave_sync': _remote(wave ? 'true' : 'false'),
};

void main() {
  late _MockRemoteConfig rc;
  late _MockLogger logger;
  late StreamController<RemoteConfigUpdate> updates;

  setUp(() {
    rc = _MockRemoteConfig();
    logger = _MockLogger();
    updates = StreamController<RemoteConfigUpdate>.broadcast();
    when(() => rc.setDefaults(any())).thenAnswer((_) async {});
    when(() => rc.activate()).thenAnswer((_) async => true);
    when(() => rc.fetchAndActivate()).thenAnswer((_) async => true);
    when(() => rc.onConfigUpdated).thenAnswer((_) => updates.stream);
    when(() => rc.getAll()).thenReturn(_values());
  });

  tearDown(() => updates.close());

  test('emits the activated values first', () async {
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    expect(await service.watch().first, FeatureFlags.defaults);
    verify(() => rc.setDefaults(FeatureFlags.defaults.toRemoteConfigDefaults()))
        .called(1);
  });

  test('a real-time update re-activates and emits again', () async {
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    final seen = <FeatureFlags>[];
    final sub = service.watch().listen(seen.add);
    await pumpEventQueue();
    when(() => rc.getAll()).thenReturn(_values(wave: false));
    updates.add(RemoteConfigUpdate({'feature_wave_sync'}));
    await pumpEventQueue();
    expect(seen.last.waveSync, isFalse);
    await sub.cancel();
  });

  test('a failed setDefaults/activate still emits, failing open', () async {
    when(() => rc.setDefaults(any())).thenThrow(Exception('boom'));
    when(() => rc.getAll()).thenReturn(const {});
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    expect(await service.watch().first, FeatureFlags.defaults);
    verify(() => logger.warn(any(that: startsWith('FLAGS')), any(), any()))
        .called(greaterThanOrEqualTo(1));
  });

  test('a failed background fetch is logged, not thrown', () async {
    when(() => rc.fetchAndActivate()).thenThrow(Exception('offline'));
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    await service.watch().first;
    await pumpEventQueue();
    verify(() => logger.warn('FLAGS fetch failed', any(), any())).called(1);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/core/remote_config/remote_config_service_test.dart`
Expected: FAIL, the file under test does not exist.

- [ ] **Step 3: Implement**

```dart
import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

/// Wraps [FirebaseRemoteConfig]: cached values first, then a background
/// fetch, then every real-time update. Every failure keeps the last values.
class RemoteConfigService {
  RemoteConfigService({FirebaseRemoteConfig? remoteConfig, AppLogger? logger})
    : _remoteConfig = remoteConfig ?? FirebaseRemoteConfig.instance,
      _logger = logger ?? AppLogger();

  final FirebaseRemoteConfig _remoteConfig;
  final AppLogger _logger;

  Stream<FeatureFlags> watch() {
    late final StreamController<FeatureFlags> controller;
    StreamSubscription<RemoteConfigUpdate>? updates;
    FeatureFlags? last;

    void emit() {
      if (controller.isClosed) return;
      final flags = FeatureFlags.fromValues(_remoteConfig.getAll());
      if (flags == last) return;
      if (last != null) _logger.breadcrumb('FLAGS changed: $flags');
      last = flags;
      controller.add(flags);
    }

    Future<void> start() async {
      try {
        await _remoteConfig.setDefaults(
          FeatureFlags.defaults.toRemoteConfigDefaults(),
        );
        await _remoteConfig.activate();
      } catch (e, st) {
        _logger.warn('FLAGS activate failed', e, st);
      }
      emit();
      unawaited(
        _remoteConfig
            .fetchAndActivate()
            .then((_) => emit())
            .catchError((Object e, StackTrace st) {
              _logger.warn('FLAGS fetch failed', e, st);
            }),
      );
      updates = _remoteConfig.onConfigUpdated.listen(
        (_) => _remoteConfig
            .activate()
            .then((_) => emit())
            .catchError((Object e, StackTrace st) {
              _logger.warn('FLAGS update activate failed', e, st);
            }),
        onError: (Object e, StackTrace st) =>
            _logger.warn('FLAGS update stream failed', e, st),
      );
    }

    controller = StreamController<FeatureFlags>(
      onListen: () => unawaited(start()),
      onCancel: () => updates?.cancel(),
    );
    return controller.stream;
  }
}
```

- [ ] **Step 4: Run it to verify it passes, then commit**

Run: `flutter test test/core/remote_config/remote_config_service_test.dart && flutter analyze`
Expected: 4 tests PASS, `No issues found!`. If mocktail can't match the `setDefaults` map argument, add `registerFallbackValue(<String, dynamic>{})` in `setUpAll`.

```bash
git add lib/core/remote_config/remote_config_service.dart test/core/remote_config/remote_config_service_test.dart
git commit -m "Add RemoteConfigService: cached values, fetch, real-time updates"
```

### Task 8: Providers

**Files:**
- Create: `lib/core/remote_config/feature_flags_providers.dart`
- Test: `test/core/remote_config/feature_flags_providers_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';

void main() {
  test('loading reads as the defaults (fail open)', () {
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith(
          (ref) => StreamController<FeatureFlags>().stream,
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(featureFlagsProvider), FeatureFlags.defaults);
  });

  test('an error reads as the defaults (fail open)', () async {
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith(
          (ref) => Stream<FeatureFlags>.error(Exception('x')),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(featureFlagsStreamProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(featureFlagsProvider), FeatureFlags.defaults);
  });

  test('a value passes through', () async {
    const paused = FeatureFlags(
      addressAutocomplete: true,
      presence: false,
      liveActivities: true,
      waveSync: true,
      minSupportedBuild: 0,
    );
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith((ref) => Stream.value(paused)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(featureFlagsStreamProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(featureFlagsProvider).presence, isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/core/remote_config/feature_flags_providers_test.dart`
Expected: FAIL, the file under test does not exist.

- [ ] **Step 3: Implement**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/remote_config_service.dart';

final remoteConfigServiceProvider = Provider<RemoteConfigService>(
  (ref) => RemoteConfigService(logger: ref.watch(loggerProvider)),
);

final featureFlagsStreamProvider = StreamProvider<FeatureFlags>(
  (ref) => ref.watch(remoteConfigServiceProvider).watch(),
);

/// The flags every gate reads. Loading and error are the defaults: fail open.
final featureFlagsProvider = Provider<FeatureFlags>(
  (ref) => ref.watch(featureFlagsStreamProvider).value ?? FeatureFlags.defaults,
);
```

- [ ] **Step 4: Run it to verify it passes, then commit**

Run: `flutter test test/core/remote_config/ && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/core/remote_config/feature_flags_providers.dart test/core/remote_config/feature_flags_providers_test.dart
git commit -m "Expose the kill switches through featureFlagsProvider"
```

### Task 9: Copy (ARB keys) and the shared paused notice

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Create: `lib/shared/widgets/feature_paused_notice.dart`
- Test: `test/shared/widgets/feature_paused_notice_test.dart`

- [ ] **Step 1: Add the keys to `app_en.arb`** (alphabetical placement within each bucket)

```json
"common_featurePaused": "This feature is temporarily unavailable.",
"@common_featurePaused": {"description": "Shown in place of a feature the business has temporarily switched off remotely."},
"common_updateRequiredTitle": "Update required",
"@common_updateRequiredTitle": {"description": "Title of the blocking screen shown when this app build is too old to keep using."},
"common_updateRequiredBody": "This version of the app is no longer supported. Update from the App Store to keep going.",
"@common_updateRequiredBody": {"description": "Body of the blocking update screen."},
"common_updateRequiredButton": "Open App Store",
"@common_updateRequiredButton": {"description": "Button on the blocking update screen that opens the app's App Store page."},
"settings_wavePaused": "Wave sync is temporarily paused. Client changes are queued and will sync when it resumes.",
"@settings_wavePaused": {"description": "Banner in Settings > Wave while Wave sync is switched off remotely."}
```

- [ ] **Step 2: Add the same keys to `app_fr.arb`**

```json
"common_featurePaused": "Cette fonction est temporairement indisponible.",
"common_updateRequiredTitle": "Mise à jour requise",
"common_updateRequiredBody": "Cette version de l'app n'est plus prise en charge. Mettez-la à jour depuis l'App Store pour continuer.",
"common_updateRequiredButton": "Ouvrir l'App Store",
"settings_wavePaused": "La synchronisation Wave est temporairement suspendue. Les modifications des clients sont en attente et seront synchronisées à la reprise."
```

Write the accented characters directly in the editor, not as `\u` escapes (an editor in this repo has mangled those before).

- [ ] **Step 3: Regenerate and confirm no drift**

Run: `flutter gen-l10n && cat lib/l10n/.gen/untranslated.json`
Expected: no error, and none of the five new keys listed.

- [ ] **Step 4: Write the failing widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/shared/widgets/feature_paused_notice.dart';

void main() {
  testWidgets('renders the message without overflow at 260 px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: FeaturePausedNotice(message: 'Paused for now, sorry'),
          ),
        ),
      ),
    );
    expect(find.text('Paused for now, sorry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 5: Implement**

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// One-row notice for a feature switched off remotely.
class FeaturePausedNotice extends StatelessWidget {
  const FeaturePausedNotice({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sp12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.pause_circle_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sp8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Run it, analyze, commit**

Run: `flutter test test/shared/widgets/feature_paused_notice_test.dart && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/l10n/app_en.arb lib/l10n/app_fr.arb lib/shared/widgets/feature_paused_notice.dart test/shared/widgets/feature_paused_notice_test.dart
git commit -m "Add the paused-feature and update-required copy and notice"
```

---

## Part C: App gates

All widget tests below override `featureFlagsProvider` with `overrideWithValue(...)`. Build a paused value with this helper, copied into each test file that needs it (no shared helper, per this repo's convention):

```dart
FeatureFlags _flags({
  bool addr = true,
  bool presence = true,
  bool liveAct = true,
  bool wave = true,
  int minBuild = 0,
}) => FeatureFlags(
  addressAutocomplete: addr,
  presence: presence,
  liveActivities: liveAct,
  waveSync: wave,
  minSupportedBuild: minBuild,
);
```

### Task 10: Address autocomplete falls back to a plain field

**Files:**
- Modify: `lib/shared/widgets/fields/address_autocomplete_field.dart` (`_onTextChanged`, around line 87)
- Test: `test/shared/widgets/fields/address_autocomplete_field_flag_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/address_autocomplete_field.dart';

class _MockPlaces extends Mock implements PlacesRepository {}

// _flags helper from the Part C preamble goes here.

void main() {
  testWidgets('paused: typing never calls Places, and the text still lands', (
    tester,
  ) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          placesRepositoryProvider.overrideWithValue(places),
          featureFlagsProvider.overrideWithValue(_flags(addr: false)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AddressAutocompleteField(controller: controller),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '123 Main Street');
    await tester.pump(const Duration(seconds: 2));
    expect(controller.text, '123 Main Street');
    verifyZeroInteractions(places);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/shared/widgets/fields/address_autocomplete_field_flag_test.dart`
Expected: FAIL. `verifyZeroInteractions` sees an autocomplete call. If the mock's unstubbed call throws first instead, that's also the expected red.

- [ ] **Step 3: Implement**

Add the import:

```dart
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
```

In `_onTextChanged`, after the `_suppressFetch` early return and before `_debounce.cancel();`:

```dart
    if (!ref.read(featureFlagsProvider).addressAutocomplete) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
```

This is synchronous, before any await, so the `ref.read` is safe.

- [ ] **Step 4: Run it plus the field's existing tests, then commit**

Run: `flutter test test/shared/widgets/fields/ && flutter analyze`
Expected: PASS (existing tests get the real provider, which falls back to defaults), `No issues found!`.

```bash
git add lib/shared/widgets/fields/address_autocomplete_field.dart test/shared/widgets/fields/address_autocomplete_field_flag_test.dart
git commit -m "Fall back to a plain address field while autocomplete is paused"
```

### Task 11: Presence stops when paused, and re-syncs on a flag change

**Files:**
- Modify: `lib/features/presence/application/presence_sync_controller.dart` (`shouldTrackPresence` around line 106; `_syncGuarded` around line 168)
- Modify: `lib/core/app/app_sync_listeners.dart`
- Test: `test/features/presence/presence_sync_gates_test.dart` (add a case)

- [ ] **Step 1: Write the failing test** (append inside `group('shouldTrackPresence', ...)`)

```dart
    test('a remotely paused feature stops tracking for everyone', () {
      expect(
        shouldTrackPresence(
          role: 'employee',
          status: 'active',
          signedIn: true,
          locationSharingEnabled: true,
          featureEnabled: false,
        ),
        isFalse,
      );
    });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/features/presence/presence_sync_gates_test.dart`
Expected: FAIL to compile, no parameter named `featureEnabled`.

- [ ] **Step 3: Implement the gate**

```dart
/// Pure gate; delegates to [shouldRegisterPush] so the audiences can't drift.
bool shouldTrackPresence({
  required String role,
  required String status,
  required bool signedIn,
  required bool locationSharingEnabled,
  bool featureEnabled = true,
}) =>
    featureEnabled &&
    locationSharingEnabled &&
    shouldRegisterPush(role: role, status: status, signedIn: signedIn);
```

In `_syncGuarded`, pass it (the read is before any await):

```dart
      if (!shouldTrackPresence(
        role: gate.role,
        status: gate.status,
        signedIn: gate.signedIn,
        locationSharingEnabled: gate.locationSharingEnabled,
        featureEnabled: _ref.read(featureFlagsProvider).presence,
      )) {
```

with `import 'package:scheduling/core/remote_config/feature_flags_providers.dart';`.

- [ ] **Step 4: Re-sync presence and Live Activities when the flags change**

In `app_sync_listeners.dart`, import `feature_flags.dart` and `feature_flags_providers.dart`, append `_featureFlagSync();` as the LAST call in `registerAll()` (registration order is load-bearing, so append and don't reorder), and add:

```dart
  void _featureFlagSync() {
    ref.listen<FeatureFlags>(featureFlagsProvider, (prev, next) {
      if (prev == null) return;
      if (prev.presence != next.presence) {
        _fireAndForget(
          'APP-SYNC presence sync failed',
          () => ref.read(presenceSyncControllerProvider).sync(),
        );
      }
      if (prev.liveActivities != next.liveActivities) {
        _fireAndForget(
          'APP-SYNC live activity sync failed',
          () => ref.read(liveActivityRegistrationControllerProvider).sync(),
        );
      }
    });
  }
```

- [ ] **Step 5: Run, analyze, commit**

Run: `flutter test test/features/presence/ test/core/app/ && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/features/presence/application/presence_sync_controller.dart lib/core/app/app_sync_listeners.dart test/features/presence/presence_sync_gates_test.dart
git commit -m "Stop location sharing while presence is paused remotely"
```

### Task 12: Live Activities tear down while paused

**Files:**
- Modify: `lib/features/live_activity/application/live_activity_registration_controller.dart` (`_syncGuarded`, around line 125)
- Test: find the controller's existing test with `ls test/features/live_activity/` and add the case there.

- [ ] **Step 1: Write the failing test**

Open the existing registration-controller test and copy its "stored opt-out tears down" case (search it for `setEnabled(value: false)` or `deleteTokensOfKind`). Duplicate it as `'a remote pause tears down like an opt-out'`, keeping the preference ON and adding `featureFlagsProvider.overrideWithValue(_flags(liveAct: false))` to its container overrides. Assert the same `deleteTokensOfKind(kind: LiveActivityTokenKind.pushToStart)` call and that the plugin's end-all was invoked, exactly as the opt-out case asserts.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/features/live_activity/`
Expected: the new case FAILS (no teardown), and the others pass.

- [ ] **Step 3: Implement**

Import `feature_flags_providers.dart`, then change the opt-out check (after the `ready` await and its staleness check):

```dart
    if (!_ref.read(liveActivityEnabledProvider) ||
        !_ref.read(featureFlagsProvider).liveActivities) {
```

The comment above it stays. The remote pause reuses the opt-out teardown on purpose, so re-enabling re-registers on the next `sync()` (Task 11 fires it).

- [ ] **Step 4: Run, analyze, commit**

Run: `flutter test test/features/live_activity/ && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/features/live_activity/application/live_activity_registration_controller.dart test/features/live_activity/
git commit -m "End Live Activities and drop tokens while paused remotely"
```

### Task 13: Hide the live map and show the paused note in Location sharing

**Files:**
- Modify: `lib/features/navigation/domain/drawer_catalog.dart:15`
- Modify: `lib/features/navigation/widgets/app_nav_drawer.dart:54`
- Modify: `lib/features/presence/screens/live_map_screen.dart` (`build`, line 128)
- Modify: `lib/features/settings/widgets/views/location_sharing_view.dart` (`build`, line 89)
- Test: `test/features/navigation/domain/drawer_catalog_test.dart` (add a case)

- [ ] **Step 1: Write the failing test** (append to `drawer_catalog_test.dart`)

```dart
  test('a paused live map leaves the admin drawer', () {
    final rows = drawerGroups(
      isAdmin: true,
      liveMapEnabled: false,
    ).expand((g) => g.rows).toList();
    expect(rows, isNot(contains(HubTab.liveMap)));
    expect(rows, hasLength(8));
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/features/navigation/domain/drawer_catalog_test.dart`
Expected: FAIL to compile, no parameter `liveMapEnabled`.

- [ ] **Step 3: Implement the drawer**

```dart
List<DrawerGroup> drawerGroups({
  required bool isAdmin,
  bool liveMapEnabled = true,
}) => [
```

and change the row to `if (isAdmin && liveMapEnabled) HubTab.liveMap,`. In `app_nav_drawer.dart:54`:

```dart
    final groups = drawerGroups(
      isAdmin: isLiveAdmin,
      liveMapEnabled: ref.watch(featureFlagsProvider).presence,
    );
```

The `HubTab.liveMap` member is NOT renamed or removed. Its `.name` is a tour storage key.

- [ ] **Step 4: Cover the screen and the settings view**

`LiveMapScreen.build`: as the first statement:

```dart
    if (!ref.watch(featureFlagsProvider).presence) {
      return Center(
        child: FeaturePausedNotice(message: context.l10n.common_featurePaused),
      );
    }
```

This covers a hub that already had the tab built, or a route or restored state reaching it. The screen keeps every other rule. In `location_sharing_view.dart`, read `final paused = !ref.watch(featureFlagsProvider).presence;` at the top of `build` and make the first `ListView` child:

```dart
        if (paused)
          FeaturePausedNotice(message: context.l10n.common_featurePaused),
```

Also find the view's sharing switch and set its `onChanged` to `null` when `paused` (`grep -n "onChanged" lib/features/settings/widgets/views/location_sharing_view.dart`).

- [ ] **Step 5: Run, analyze, commit**

Run: `flutter test test/features/navigation/ test/features/presence/ test/features/settings/ && flutter analyze`
Expected: PASS (the existing nine-row admin test still holds because the default is `true`), `No issues found!`.

```bash
git add lib/features/navigation/ lib/features/presence/screens/live_map_screen.dart lib/features/settings/widgets/views/location_sharing_view.dart test/features/navigation/domain/drawer_catalog_test.dart
git commit -m "Hide the live map and pause location sharing while presence is off"
```

### Task 14: Wave settings show the paused banner and disable actions

**Files:**
- Modify: `lib/features/wave/widgets/wave_settings_section.dart` (`build`, line 138)
- Test: `test/features/wave/widgets/wave_settings_section_flag_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/widgets/wave_settings_section.dart';
import 'package:scheduling/l10n/l10n.dart';

// _flags helper from the Part C preamble goes here.

void main() {
  testWidgets('paused: banner shown and Connect disabled', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(_flags(wave: false)),
          waveConnectionProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: WaveSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(WaveSettingsSection)),
    );
    expect(find.text(l10n.settings_wavePaused), findsOneWidget);
    final button = tester.widget<AnimatedLoadingButton>(
      find.byType(AnimatedLoadingButton),
    );
    expect(button.onPressed, isNull);
  });
}
```

Before running, check `waveConnectionProvider`'s type (`grep -n "waveConnectionProvider =" lib/features/wave/application/wave_providers.dart`) and match the override (`Stream.value(null)` for a StreamProvider, `(ref) async => null` for a FutureProvider). Copy the exact override from an existing Wave settings test if there is one.

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/features/wave/widgets/wave_settings_section_flag_test.dart`
Expected: FAIL, the banner text is not found.

- [ ] **Step 3: Implement**

At the top of `build`: `final paused = !ref.watch(featureFlagsProvider).waveSync;` and `final blocked = _busy || paused;`. Then:
- make the returned `Column`'s first child `if (paused) FeaturePausedNotice(message: context.l10n.settings_wavePaused),`
- `onRetryFailed: blocked ? null : _retryFailed,`
- `onPressed: blocked ? null : _connect,` and `onPressed: blocked ? null : _sync,`

Status rows and the outbox counts still render: `waveGetConnection` stays ungated so the admin can watch the backlog.

- [ ] **Step 4: Run, analyze, commit**

Run: `flutter test test/features/wave/ && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/features/wave/widgets/wave_settings_section.dart test/features/wave/widgets/wave_settings_section_flag_test.dart
git commit -m "Show the Wave paused banner and disable Wave actions while paused"
```

### Task 15: Forced update (`UpdateGate`)

**Files:**
- Create: `lib/core/constants/app_store.dart`
- Create: `lib/core/remote_config/update_gate.dart`
- Create: `lib/core/remote_config/update_required_screen.dart`
- Modify: `lib/core/analytics/analytics_events.dart:204` (one new action value)
- Modify: `lib/main.dart` (`MaterialApp.builder`, around line 430: wrap `AppLock`)
- Test: `test/core/remote_config/update_gate_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/remote_config/update_gate.dart';
import 'package:scheduling/core/remote_config/update_required_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

// _flags helper from the Part C preamble goes here.

Widget _app({required int minBuild, required int? build}) => ProviderScope(
  overrides: [
    featureFlagsProvider.overrideWithValue(_flags(minBuild: minBuild)),
    appBuildNumberProvider.overrideWith((ref) async => build),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const UpdateGate(child: Text('app body')),
  ),
);

void main() {
  group('isUpdateRequired', () {
    test('0 never blocks', () => expect(isUpdateRequired(build: 1, minSupported: 0), isFalse));
    test('equal does not block', () => expect(isUpdateRequired(build: 93, minSupported: 93), isFalse));
    test('below blocks', () => expect(isUpdateRequired(build: 92, minSupported: 93), isTrue));
  });

  testWidgets('a current build sees the app', (tester) async {
    await tester.pumpWidget(_app(minBuild: 93, build: 93));
    await tester.pumpAndSettle();
    expect(find.text('app body'), findsOneWidget);
  });

  testWidgets('an old build sees only the update screen', (tester) async {
    await tester.pumpWidget(_app(minBuild: 94, build: 93));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateRequiredScreen), findsOneWidget);
    expect(find.text('app body'), findsNothing);
  });

  testWidgets('an unreadable build number fails open', (tester) async {
    await tester.pumpWidget(_app(minBuild: 94, build: null));
    await tester.pumpAndSettle();
    expect(find.text('app body'), findsOneWidget);
  });

  testWidgets('update screen does not overflow at 260 px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: UpdateRequiredScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/core/remote_config/update_gate_test.dart`
Expected: FAIL, the files under test do not exist.

- [ ] **Step 3: Implement the constant and the analytics value**

`lib/core/constants/app_store.dart`, using the Apple ID from Step 0:

```dart
/// The app's App Store page, opened by the forced-update screen.
const kAppStoreUrl = 'https://apps.apple.com/app/id1234567890';
```

Replace `1234567890` with the real Apple ID from Step 0 before committing. Then check: `grep -n "id1234567890" lib/core/constants/app_store.dart` must print nothing.

In `AnalyticsContactActions` add:

```dart
  /// The App Store page, from the forced-update screen.
  static const String appStore = 'app_store';
```

- [ ] **Step 4: Implement the gate**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/remote_config/update_required_screen.dart';
import 'package:scheduling/features/settings/application/app_info_provider.dart';

/// Running build number, or null when it can't be parsed (fail open).
final appBuildNumberProvider = FutureProvider<int?>((ref) async {
  final info = await ref.watch(appInfoProvider.future);
  return int.tryParse(info.buildNumber);
});

bool isUpdateRequired({required int build, required int minSupported}) =>
    build < minSupported;

/// Swaps the whole app for [UpdateRequiredScreen] while this build is below
/// `min_supported_build` — at cold start and mid-session alike.
class UpdateGate extends ConsumerWidget {
  const UpdateGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minSupported = ref.watch(
      featureFlagsProvider.select((f) => f.minSupportedBuild),
    );
    final build = ref.watch(appBuildNumberProvider).value;
    if (build != null &&
        isUpdateRequired(build: build, minSupported: minSupported)) {
      return const UpdateRequiredScreen();
    }
    return child;
  }
}
```

- [ ] **Step 5: Implement the screen**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/constants/app_store.dart';
import 'package:scheduling/core/launchers/external_uri_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Blocking screen for a build below `min_supported_build`. No way past it.
class UpdateRequiredScreen extends ConsumerWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.sp24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 48),
                const SizedBox(height: AppSpacing.sp16),
                Text(
                  l10n.common_updateRequiredTitle,
                  style: textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sp8),
                Text(l10n.common_updateRequiredBody, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.sp24),
                FilledButton(
                  onPressed: () => launchExternalUri(
                    context,
                    ref,
                    Uri.parse(kAppStoreUrl),
                    tag: 'LAUNCH-URL',
                    errorMessage: l10n.error_somethingWentWrongPleaseTryAgain,
                    analyticsAction: AnalyticsContactActions.appStore,
                  ),
                  child: Text(l10n.common_updateRequiredButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

Check that every `AppSpacing` token used here exists (`grep -n "sp24\|sp16\|sp8" lib/core/theme/design_tokens.dart`).

- [ ] **Step 6: Wire it into `main.dart`**

In `MaterialApp.builder`, wrap the existing `AppLock(...)` so the line reads:

```dart
                  child: UpdateGate(
                    child: AppLock(
                      child: NoticeListener(
```

and close the extra parenthesis after `AppLock`'s closing one. Import `package:scheduling/core/remote_config/update_gate.dart`. This first watch of `featureFlagsProvider` in `PaulApp` is also what starts `RemoteConfigService` (Deviation 2).

- [ ] **Step 7: Run, analyze, commit**

Run: `flutter test test/core/remote_config/ && flutter analyze`
Expected: PASS, `No issues found!`.

```bash
git add lib/core/constants/app_store.dart lib/core/remote_config/update_gate.dart lib/core/remote_config/update_required_screen.dart lib/core/analytics/analytics_events.dart lib/main.dart test/core/remote_config/update_gate_test.dart
git commit -m "Block builds below min_supported_build with an update screen"
```

---

## Part D: Docs and final verification

### Task 16: Docs and registries

**Files:** `docs/DEPLOYMENT.md`, `docs/CLOUD_FUNCTIONS.md`, `CLAUDE.md`, `functions/CLAUDE.md`, `.claude/rules/error-handling.md`

- [ ] **Step 1: `docs/DEPLOYMENT.md`.** Add a section `## Flip a kill switch` containing:
  - the five-row key table from the design spec (key, default, what off means)
  - how to flip: Firebase console → Remote Config → edit the parameter → Publish. Open apps react within seconds (real-time listener); functions within 60 s.
  - rollback: Remote Config → the template's version history → roll back
  - the one-time IAM test: publish `feature_wave_sync = false`, run Wave → Sync in the app, confirm `FLAGS blocked a call {"key":"feature_wave_sync"}` in `firebase functions:log`, then publish it back to `true`. If no line appears, grant the functions runtime service account the "Firebase Remote Config Viewer" role (`roles/cloudconfig.viewer`).
  - **never publish a key set to an empty value**: booleans must be `true`/`false`, and `min_supported_build` an integer.
- [ ] **Step 2: `docs/CLOUD_FUNCTIONS.md`.** Add `feature_flags.js` / `feature_flags_policy.js` to the module list, and note on `placesAutocomplete`, `placesGetDetails`, `placesReverseGeocode`, `waveBootstrap`, `waveImportCustomers`, `waveRetryFailedJobs` that they refuse with `failed-precondition` / `feature-disabled` while paused.
- [ ] **Step 3: `functions/CLAUDE.md`.** One line in the module map: `feature_flags_policy.js` (pure) / `feature_flags.js` (lazy `firebase-admin/remote-config`), fail-open, 60 s cache. A Live Activity `skipped` must never prune a token.
- [ ] **Step 4: root `CLAUDE.md`.** One bullet under Critical invariants: **Kill switches FAIL OPEN** (`lib/core/remote_config/`, `functions/feature_flags*.js`). A fetch failure, an empty template or a static value means every feature on and `min_supported_build` 0. Keys and defaults are mirrored and both sides' tests pin them. A paused feature reuses its existing opt-out path. Runbook: `docs/DEPLOYMENT.md` § Flip a kill switch.
- [ ] **Step 5: `.claude/rules/error-handling.md`.** Add `FLAGS` to the log-only tags under "App shell / lifecycle".
- [ ] **Step 6: Commit**

```bash
git add docs/DEPLOYMENT.md docs/CLOUD_FUNCTIONS.md CLAUDE.md functions/CLAUDE.md .claude/rules/error-handling.md
git commit -m "Document the kill switches and the FLAGS log tag"
```

### Task 17: Full verification

- [ ] **Step 1:** `flutter analyze`. Expected: `No issues found!`
- [ ] **Step 2:** `dart run tool/test.dart`. Expected: every shard passes. Record the real counts in the commit or PR, not a remembered number.
- [ ] **Step 3:** `cd functions && npm test && npm run lint`. Expected: all pass, coverage thresholds hold.
- [ ] **Step 4:** BOM scan on new files: `for f in $(git diff --name-only main...HEAD -- '*.dart'); do head -c 3 "$f" | od -An -tx1 | grep -q "ef bb bf" && echo "BOM: $f"; done`. Expected: no output.
- [ ] **Step 5: Device check (owner, on the Mac).** With an emulator-free debug build: publish `feature_address_autocomplete = false` → the address field gives no suggestions; publish `min_supported_build = 99999` → the update screen appears mid-session within seconds; publish both back. Then the IAM test from Task 16 Step 1 after the functions deploy.

## Rollout

1. Merge. Deploy `functions` with the `deploy` skill. No ordering hazard: every default is "on".
2. Run the IAM test (Task 16, Step 1).
3. Ship the app in the next release (`release` skill). Until a build carrying `UpdateGate` is widespread, `min_supported_build` reaches only builds that have it, so it only becomes a real lever one release later.
