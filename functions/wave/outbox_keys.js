"use strict";

/**
 * @fileoverview The `waveSyncQueue` names shared by the outbox and the import.
 * A leaf that requires nothing, so `customers_import.js` can read a job inside
 * its write transaction without closing a cycle back through `customers.js`.
 * @module wave/outbox_keys
 */

/** Firestore collection that holds outbox jobs. */
const QUEUE_COLLECTION = "waveSyncQueue";

/** Job statuses whose client edit has not reached Wave. */
const OUTSTANDING_STATUSES = ["queued", "inflight", "dead"];

/**
 * The deterministic outbox job id for one client's customer upsert.
 * @param {string} clientId Firestore `clients` document id.
 * @return {string} The `waveSyncQueue` document id.
 */
function customerUpsertJobId(clientId) {
  return `customerUpsert__${clientId}`;
}

/**
 * Extracts the clientId from a `refPath` like `'clients/<id>'`.
 * @param {string} refPath The `refPath` stored in the job doc.
 * @return {string} The client id segment, or empty string on a bad path.
 */
function clientIdFromRefPath(refPath) {
  if (typeof refPath !== "string") return "";
  const parts = refPath.split("/");
  return parts.length >= 2 ? parts[parts.length - 1] : "";
}

module.exports = {
  QUEUE_COLLECTION,
  OUTSTANDING_STATUSES,
  customerUpsertJobId,
  clientIdFromRefPath,
};
