"use strict";

// ---------------------------------------------------------------------------
// Fakes / helpers
// ---------------------------------------------------------------------------

/** Stable timestamp sentinel — lets test assertions be precise. */
const TS = {__serverTimestamp: true};

// now() factory that returns the sentinel.
const now = () => TS;

/**
 * Builds a minimal logger fake that records calls.
 * @return {{error: jest.Mock, warn: jest.Mock, info: jest.Mock}}
 */
function fakeLogger() {
  const lg = {
    error: jest.fn(),
    warn: jest.fn(),
    info: jest.fn(),
  };
  return lg;
}

/**
 * Creates a fake Firestore doc snapshot.
 * @param {string} id Document id.
 * @param {Object|null} data Document data (null = missing).
 * @param {!Object} ref The doc ref this snapshot belongs to.
 * @return {!Object}
 */
function snap(id, data, ref) {
  return {
    id,
    exists: data !== null,
    data: () => data,
    ref,
  };
}

/**
 * Fake doc ref that records `set` and `update` calls. It exposes a mutable
 * `_data` field you can mutate in place, mimicking real Firestore writes.
 * @param {string} id Document id.
 * @param {Object|null} initialData Initial snapshot data.
 * @return {!Object}
 */
function fakeRef(id, initialData) {
  const ref = {
    id,
    _data: initialData,
    updates: [],
    sets: [],
    /** @param {Object} u */
    update: jest.fn((u) => {
      ref.updates.push(u);
      // Mutate _data so the next read sees the updated state.
      if (ref._data !== null) Object.assign(ref._data, u);
      return Promise.resolve();
    }),
    /**
     * @param {Object} d
     * @param {Object=} opts
     */
    set: jest.fn((d, opts) => {
      ref.sets.push({data: d, opts});
      if (opts && opts.merge) {
        ref._data = ref._data ? Object.assign({}, ref._data, d) : {...d};
      } else {
        ref._data = {...d};
      }
      return Promise.resolve();
    }),
  };
  return ref;
}

module.exports = {TS, now, fakeLogger, snap, fakeRef};
