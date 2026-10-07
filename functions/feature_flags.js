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
