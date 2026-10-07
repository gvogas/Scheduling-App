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
 * Only `true`/`false` (any case, trimmed) count; anything else fails OPEN.
 * @param {string} raw The published string value.
 * @param {boolean} fallback The code default.
 * @return {boolean}
 */
function parseFlagBool(raw, fallback) {
  const v = String(raw).trim().toLowerCase();
  if (v === "true") return true;
  if (v === "false") return false;
  return fallback;
}

/**
 * Only a plain (optionally signed) integer counts; anything else falls back.
 * @param {string} raw The published string value.
 * @param {number} fallback The code default.
 * @return {number}
 */
function parseFlagInt(raw, fallback) {
  const v = String(raw).trim();
  if (!/^[+-]?\d+$/.test(v)) return fallback;
  const n = Number(v);
  return Number.isSafeInteger(n) ? n : fallback;
}

/**
 * Reads every flag from an evaluated server config.
 * @param {{getString: function(string): string}} config
 * @return {!Object}
 */
function readFlags(config) {
  const flags = {};
  for (const key of FLAG_KEYS) {
    const raw = config.getString(key);
    flags[key] = typeof FLAG_DEFAULTS[key] === "boolean" ?
      parseFlagBool(raw, FLAG_DEFAULTS[key]) :
      parseFlagInt(raw, FLAG_DEFAULTS[key]);
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

module.exports = {
  FLAG_DEFAULTS,
  FLAG_KEYS,
  parseFlagBool,
  parseFlagInt,
  readFlags,
  createFlagCache,
};
