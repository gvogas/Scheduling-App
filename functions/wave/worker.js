"use strict";

/**
 * @fileoverview The one import path for the `waveSyncQueue` outbox. It owns no
 * logic: it re-exports `enqueue.js`, `dispatch.js` and `outbox_queries.js`
 * (with `outbox_core.js` and `outbox_keys.js` beneath them), so every caller
 * and every `jest.mock("../wave/worker")` still intercepts by this one path.
 * The retry taxonomy lives in the pure `retry_policy.js`, and
 * `RATE_LIMITED_MAX_ATTEMPTS` is re-exported from here so downstream callers
 * see no change.
 * @module wave/worker
 */

const {RATE_LIMITED_MAX_ATTEMPTS} = require("./retry_policy");
const {
  shouldEnqueueClientWrite,
  enqueueCustomerUpsert,
  cancelCustomerUpsert,
} = require("./enqueue");
const {drainQueue} = require("./dispatch");
const {
  countQueuedJobs,
  countDeadJobs,
  requeueDeadJobs,
  listOutstandingClientIds,
} = require("./outbox_queries");

module.exports = {
  enqueueCustomerUpsert,
  cancelCustomerUpsert,
  drainQueue,
  countQueuedJobs,
  countDeadJobs,
  requeueDeadJobs,
  listOutstandingClientIds,
  shouldEnqueueClientWrite,
  RATE_LIMITED_MAX_ATTEMPTS,
};
