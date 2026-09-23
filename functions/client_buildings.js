"use strict";

const {createHash} = require("node:crypto");
const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {getFirestore} = require("firebase-admin/firestore");
const {streetFromAddress, splitApt} = require("./client_address_utils");
const {normalize} = require("./search_tokens");

/**
 * Mirrors buildingKeyFor in Dart, including legacy locality suffixes/units.
 * @param {?Object} data Client fields.
 * @return {?Object} Building identity and display label.
 */
function buildingFor(data) {
  if (!data || data.noFixedAddress === true) return null;
  const address = typeof data.address === "string" ? data.address.trim() : "";
  if (!address) return null;
  const line = streetFromAddress(address, data);
  const street = (splitApt(line)?.street || line).trim();
  if (!normalize(street)) return null;
  const city = typeof data.city === "string" ? data.city.trim() : "";
  return {key: `${normalize(street)}|${normalize(city)}`, street, city};
}

/**
 * Canonical fields needed for indexed filters to include legacy documents.
 * @param {!Object} data Source fields.
 * @return {!Object} Only fields that differ from the app's existing parsing.
 */
function filterPatchFor(data) {
  const patch = {};
  const key = buildingFor(data)?.key || "";
  if (data.buildingKey !== key) patch.buildingKey = key;
  if (typeof data.archived !== "boolean") {
    patch.archived = data.archived === true;
  }
  if (typeof data.type === "string") {
    const type = data.type.trim();
    if (type !== data.type &&
        ["", "residential", "commercial", "building"].includes(type)) {
      patch.type = type;
    }
  }
  return patch;
}

/**
 * Reconciles from LIVE source + persisted membership, never event deltas.
 * Duplicate/out-of-order delivery and a backfill running alongside triggers
 * therefore cannot double-count a client. All affected rows commit together.
 * @param {!Object} db Firestore.
 * @param {string} clientId Source id.
 * @return {!Promise<void>}
 */
async function reconcileClientBuilding(db, clientId) {
  const source = db.collection("clients").doc(clientId);
  const member = db.collection("clientBuildingMemberships").doc(clientId);
  const summary = (key) => db.collection("clientBuildings")
      .doc(createHash("sha256").update(key).digest("hex"));
  await db.runTransaction(async (tx) => {
    const [client, membership] = await Promise.all([
      tx.get(source), tx.get(member),
    ]);
    const data = client.exists ? client.data() : null;
    const building = buildingFor(data);
    const next = data && data.archived !== true ? building : null;
    const previous = membership.exists ? membership.data().key : null;
    const nextKey = next?.key || null;
    const changed = previous !== nextKey;
    const oldSummary = changed && previous ?
      await tx.get(summary(previous)) : null;
    const newSummary = changed && next ? await tx.get(summary(next.key)) : null;
    if (changed) {
      if (oldSummary?.exists) {
        const count = oldSummary.data().clientCount - 1;
        if (count > 0) tx.update(oldSummary.ref, {clientCount: count});
        else tx.delete(oldSummary.ref);
      }
      if (next) {
        tx.set(summary(next.key), {
          ...next, clientCount: (newSummary?.data()?.clientCount || 0) + 1,
        });
        tx.set(member, {key: next.key});
      } else if (membership.exists) {
        tx.delete(member);
      }
    }
    const patch = data ? filterPatchFor(data) : {};
    if (client.exists && Object.keys(patch).length > 0) {
      tx.update(source, patch);
    }
  });
}

const syncClientBuilding = onDocumentWritten(
    {document: "clients/{clientId}", retry: true},
    async (event) => {
      const before = event.data?.before;
      const after = event.data?.after;
      if (before?.exists && after?.exists) {
        const oldData = before.data();
        const newData = after.data();
        // Wave status/job-count edits and our own projection writes need no
        // transaction when membership and canonical filter fields agree.
        if ((oldData.archived === true) === (newData.archived === true) &&
            buildingFor(oldData)?.key === buildingFor(newData)?.key &&
            Object.keys(filterPatchFor(newData)).length === 0) return;
      }
      await reconcileClientBuilding(getFirestore(), event.params.clientId);
    },
);

module.exports = {
  buildingFor, filterPatchFor, reconcileClientBuilding, syncClientBuilding,
};
