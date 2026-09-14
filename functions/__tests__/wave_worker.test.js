"use strict";

/**
 * `worker.js` is the one import path every caller and every
 * `jest.mock("../wave/worker")` uses, so it must hand out the SAME functions
 * the four outbox modules define — a stale copy would test one and ship
 * another.
 */

const worker = require("../wave/worker");
const enqueue = require("../wave/enqueue");
const dispatch = require("../wave/dispatch");
const queries = require("../wave/outbox_queries");
const {RATE_LIMITED_MAX_ATTEMPTS} = require("../wave/retry_policy");

describe("worker re-exports the outbox modules", () => {
  test("each export is the owning module's function, by identity", () => {
    expect(worker.shouldEnqueueClientWrite)
        .toBe(enqueue.shouldEnqueueClientWrite);
    expect(worker.enqueueCustomerUpsert).toBe(enqueue.enqueueCustomerUpsert);
    expect(worker.cancelCustomerUpsert).toBe(enqueue.cancelCustomerUpsert);
    expect(worker.drainQueue).toBe(dispatch.drainQueue);
    expect(worker.countQueuedJobs).toBe(queries.countQueuedJobs);
    expect(worker.countDeadJobs).toBe(queries.countDeadJobs);
    expect(worker.requeueDeadJobs).toBe(queries.requeueDeadJobs);
    expect(worker.listOutstandingClientIds)
        .toBe(queries.listOutstandingClientIds);
    expect(worker.RATE_LIMITED_MAX_ATTEMPTS).toBe(RATE_LIMITED_MAX_ATTEMPTS);
  });

  test("it exports nothing the modules do not", () => {
    expect(Object.keys(worker).sort()).toEqual([
      "RATE_LIMITED_MAX_ATTEMPTS",
      "cancelCustomerUpsert",
      "countDeadJobs",
      "countQueuedJobs",
      "drainQueue",
      "enqueueCustomerUpsert",
      "listOutstandingClientIds",
      "requeueDeadJobs",
      "shouldEnqueueClientWrite",
    ]);
  });
});
