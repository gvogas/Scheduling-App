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
