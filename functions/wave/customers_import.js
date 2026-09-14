"use strict";

/**
 * @fileoverview The Wave → App half of customer sync: `importCustomers`
 * paginates Wave's customer list and seeds/refreshes Firestore `clients`
 * docs, idempotent on `waveCustomerId`.
 *
 * Split out of `customers.js` (which keeps the App → Wave push half) because
 * the two share no control flow — neither calls the other. They still share
 * one fact, and it is load-bearing: the `lastSyncedHash` the push half writes
 * on a successful push is the same projection `importOneCustomer` compares
 * against here, which is what stops an import clobbering a queued local edit.
 * See the comments inside `importOneCustomer`. The connection read and the
 * two listing documents both halves need live in the leaf
 * `./customer_queries`.
 *
 * `customers.js` re-exports `importCustomers`, so `require("./customers")`
 * keeps working for every existing call site.
 * @module wave/customers_import
 */

const {mappedFieldsHash, fromWaveCustomer} = require("./mappers");
const {clientSearchTokens} = require("../search_tokens");
const {statePatch, waveStateFields} = require("./customer_contract");
const {adminFirestore} = require("../admin_firestore");
const {
  readBusinessId, LIST_CUSTOMERS, LIST_CUSTOMERS_SINCE,
} = require("./customer_queries");
const {
  QUEUE_COLLECTION,
  OUTSTANDING_STATUSES,
  customerUpsertJobId,
} = require("./outbox_keys");

/** Firestore WriteBatch hard limit. */
const BATCH_LIMIT = 500;

/** Guarded client updates committed concurrently. */
const GUARDED_UPDATE_CHUNK = 25;

/**
 * Decides what one Wave customer means locally and stages that write.
 *
 * Extracted from [importCustomers]' page loop because every one of the five
 * counters it touches feeds the watermark logic afterwards, and a single
 * miscounted `skippedPending` silently loses Wave-side data — that decision
 * deserves to be readable on its own rather than buried three levels into a
 * paging loop.
 *
 * Mutates `ctx.summary`, stages creates onto `ctx.batch`, and holds updates to
 * an existing client in `ctx.guarded` for `commitGuardedUpdates`.
 *
 * @param {?Object} node One Wave customer node, or null.
 * @param {{db: !Object, batch: !Object, now: !Function, summary: !Object,
 *   skipClientIds: !Set<string>, existingByWaveId: !Map<string, !Object>,
 *   guarded: !Array<{ref: !Object, update: !Object}>}} ctx
 * @return {boolean} whether an operation was staged on the batch.
 */
function importOneCustomer(node, ctx) {
  const {db, batch, now, summary, skipClientIds, existingByWaveId, guarded} =
    ctx;
  if (!node) return false;
  if (node.isArchived === true) {
    summary.skippedArchived += 1;
    return false;
  }
  const fields = fromWaveCustomer(node);
  const hash = mappedFieldsHash(fields);

  // Everything below the skip gates is deliberately built LATE. Re-running the
  // contract and rebuilding the search index costs a field mapping, a
  // canonicalization and a sha256 each, and a steady-state import skips almost
  // every node it reads — that work was being spent on all of them.
  //
  // A NESTED `wave` map, never dotted keys: BOTH writes below go through
  // `set(..., {merge: true})`, and `set` merge does NOT parse a dot as a path
  // — `DocumentMask.fromObject` builds `new FieldPath(key)` from the whole
  // key. A dotted key there creates a literal top-level field named
  // "wave.syncState" and leaves the real one untouched. A nested map is
  // masked at its LEAVES (`wave.syncState`, `wave.problems`, ...), so it
  // merges per-key and cannot erase a sibling — dots are for `update()`.
  const stageWrite = () => {
    // Re-run the contract over the fields being written. The import has just
    // put Wave's values on the doc, so any stored problems describe the OLD
    // one — and a customer Wave hands back with a blank name must not land
    // reading `synced`.
    const verdict = statePatch(fields, {clearedState: "synced"});
    return {
      docFields: {
        ...fields,
        // The search index is normally written by the app on save, so a
        // server-created client would be absent from `searchClients` entirely
        // and a server-updated one would keep tokens built from its OLD name
        // and phone. Either way the admin searches for a client they can see
        // in the list and gets nothing back, with nothing logged.
        searchTokens: clientSearchTokens(fields),
      },
      // One shape for both branches, read back off the same verdict, so a key
      // added to the contract cannot reach one and miss the other.
      wave: {
        ...waveStateFields(verdict),
        lastSyncedHash: hash,
        lastSyncedAt: now(),
      },
    };
  };

  const waveId = fields.waveCustomerId;
  const existing = waveId ? existingByWaveId.get(waveId) : undefined;
  if (existing) {
    // Prefilter only: `commitGuardedUpdates` is the guarantee.
    if (skipClientIds.has(existing.ref.id)) {
      summary.skippedPending += 1;
      return false;
    }
    // Nothing to write: `hash` is taken over the SAME `toWaveCustomerInput`
    // projection that produced the stored `lastSyncedHash`, and the update
    // below sets the doc's mapped fields to exactly `fields` — so a match
    // means this write would be byte-identical. (That equality is already
    // load-bearing: it is what `shouldEnqueueClientWrite`'s Rule 2 uses to
    // stop an import feeding every client straight back into the outbox.)
    //
    // `hasCreatedAt` is NOT optional here. The branch below backfills a
    // missing `createdAt`, and the clients list orders by it — Firestore
    // excludes docs missing an orderBy field, so skipping one would leave
    // a legacy doc permanently invisible in the list.
    if (existing.hasCreatedAt && existing.lastSyncedHash === hash) {
      summary.skippedUnchanged += 1;
      return false;
    }
    // Preserve the original createdAt. Only backfill it when the
    // existing doc lacks one (e.g. a doc from an earlier import that
    // omitted it).
    const {docFields, wave} = stageWrite();
    const update = {...docFields, wave, updatedAt: now()};
    if (!existing.hasCreatedAt) update.createdAt = now();
    // Its create is still uncommitted in THIS batch, so no job can exist yet.
    if (existing.createdInBatch === batch) {
      batch.set(existing.ref, update, {merge: true});
      summary.updated += 1;
      return true;
    }
    guarded.push({ref: existing.ref, update});
    return false;
  }

  const {docFields, wave} = stageWrite();
  const newRef = db.collection("clients").doc();
  // createdAt/updatedAt are required: the clients list orders by
  // createdAt, and Firestore excludes docs missing that field. `archived`
  // is required for the same reason — the list FILTERS on it, so a doc
  // without it is invisible there while still turning up in search.
  // Deliberately create-only: setting it on the update branch above
  // would un-archive every archived client on every scheduled import.
  batch.set(newRef, {
    ...docFields,
    wave,
    archived: false,
    createdAt: now(),
    updatedAt: now(),
  });
  summary.imported += 1;
  // Cache so duplicate Wave ids within the same import collapse to one.
  if (waveId) {
    existingByWaveId.set(waveId,
        {ref: newRef, hasCreatedAt: true, createdInBatch: batch});
  }
  return true;
}

/**
 * Commits held client updates, each in a transaction that first reads that
 * client's outbox job — so an edit enqueued at any point before the write
 * aborts and retries it, and is left alone.
 *
 * A write held back by a job counts as `skippedPending`. So does one whose
 * transaction failed: it is logged, and counting it pending holds the
 * watermark so the next run retries that customer.
 *
 * @param {!Object} db Firestore instance.
 * @param {!Array<{ref: !Object, update: !Object}>} guarded Held updates.
 * @param {!Object} summary The import summary; `updated`/`skippedPending` move.
 * @param {!Object} logger Logging facade.
 * @return {!Promise<void>}
 */
async function commitGuardedUpdates(db, guarded, summary, logger) {
  for (let i = 0; i < guarded.length; i += GUARDED_UPDATE_CHUNK) {
    const chunk = guarded.slice(i, i + GUARDED_UPDATE_CHUNK);
    const outcomes = await Promise.all(
        chunk.map((held) => commitGuardedUpdate(db, held, logger)));
    for (const outcome of outcomes) {
      if (outcome === "updated") {
        summary.updated += 1;
      } else {
        summary.skippedPending += 1;
      }
    }
  }
}

/**
 * Writes one held client update unless that client has an outstanding job.
 * @param {!Object} db Firestore instance.
 * @param {{ref: !Object, update: !Object}} held The client ref and its update.
 * @param {!Object} logger Logging facade.
 * @return {!Promise<string>} `updated`, `pending` or `failed`.
 */
async function commitGuardedUpdate(db, {ref, update}, logger) {
  const jobRef = db.collection(QUEUE_COLLECTION)
      .doc(customerUpsertJobId(ref.id));
  try {
    return await db.runTransaction(async (tx) => {
      const job = await tx.get(jobRef);
      const status = job && job.exists ? (job.data() || {}).status : "";
      if (OUTSTANDING_STATUSES.includes(status)) return "pending";
      tx.set(ref, update, {merge: true});
      return "updated";
    });
  } catch (e) {
    logger.warn("WAVE-CUST guarded client update failed; held for next run", {
      clientId: ref.id,
      error: String(e),
    });
    return "failed";
  }
}

/**
 * One-time Wave → App seed. Paginates customers, skips archived ones, and
 * writes active ones to `clients`. Idempotent on `waveCustomerId` — we don't
 * use it as the doc id directly, since Wave Node ids are base64 and can
 * contain `/`, which isn't legal in a Firestore doc id.
 * @param {Object=} deps Injectable dependencies — `db`, `graphql`,
 *   `businessId`, `pageSize` (default 100), `now`, `logger`, `skipClientIds`
 *   (a Set of client ids with an un-pushed outbox job). No default touches
 *   real Firestore/network during a unit test.
 *
 *   `skipClientIds` is an optional PREFILTER that saves a transaction per
 *   known-pending client. It is not the guarantee: every update to an
 *   existing client commits through `commitGuardedUpdates`, which reads that
 *   client's job inside the write's own transaction, so a caller that omits
 *   the set — or reads it before an edit is enqueued — cannot clobber a queued
 *   edit.
 *
 *   `since` (an ISO-8601 string, optional) switches the run to a DELTA
 *   import: Wave filters by `modifiedAtAfter` server-side and returns only
 *   customers changed after that instant. Absent → full import. The caller
 *   owns the watermark, because it owns `wave/connection`; this function is
 *   deliberately stateless about it.
 * @return {!Promise<!Object>} Summary `{totalCount, imported, updated,
 *   skippedArchived, skippedPending, skippedUnchanged, pages, delta}`.
 *   `updated` counts only customers whose Wave-mapped fields actually
 *   differed. `skippedPending` also counts a guarded write that failed, so the
 *   caller holds the watermark. **`totalCount` is the size of the QUERIED set,
 *   so on a delta run it is the number of changed customers, not the roster
 *   size** — don't render it as "you have N clients".
 */
async function importCustomers(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const graphql = deps.graphql || require("./client").graphql;
  const now = deps.now || adminFirestore().FieldValue.serverTimestamp;
  // eslint-disable-next-line global-require
  const logger = deps.logger || require("firebase-functions/logger");
  const pageSize = typeof deps.pageSize === "number" && deps.pageSize > 0 ?
    deps.pageSize : 100;
  const businessId = deps.businessId || await readBusinessId(db);
  const skipClientIds = deps.skipClientIds || new Set();
  const since = typeof deps.since === "string" && deps.since ? deps.since : "";
  const isDelta = since !== "";

  // Single pass over existing clients → Map<waveCustomerId, docRef>, built
  // LAZILY (see the page loop): a delta run that finds nothing changed would
  // otherwise pay ~650 document reads to resolve zero customers. Note the
  // saving is inside THIS function — the sync around it still does its own
  // reads (connection doc, rate limiter, queue queries).
  let existingByWaveId = null;

  let batch = db.batch();
  let opsInBatch = 0;
  // `updated` counts REAL changes only — everything unchanged lands in
  // `skippedUnchanged`. Before that split it counted every existing customer
  // written, so a sync over an untouched roster told the admin "650 clients
  // updated in the app" on every single press.
  const summary = {
    totalCount: 0, imported: 0, updated: 0, skippedArchived: 0,
    skippedPending: 0, skippedUnchanged: 0, pages: 0, delta: isDelta,
  };

  const flushIfFull = async () => {
    if (opsInBatch >= BATCH_LIMIT) {
      await batch.commit();
      batch = db.batch();
      opsInBatch = 0;
    }
  };

  // Hoisted: the document and its extra variable are decided once, not
  // re-paired on every page.
  const listQuery = isDelta ? LIST_CUSTOMERS_SINCE : LIST_CUSTOMERS;
  const listArgs = isDelta ? {id: businessId, since} : {id: businessId};

  let page = 1;
  for (;;) {
    const data = await graphql(listQuery, {...listArgs, page, pageSize});
    const customers =
      data && data.business ? data.business.customers : null;
    const pageInfo = (customers && customers.pageInfo) || {};
    const edges = (customers && Array.isArray(customers.edges)) ?
      customers.edges : [];
    summary.pages += 1;
    // Built here rather than up front, so an empty delta page reads nothing.
    if (edges.length && !existingByWaveId) {
      existingByWaveId = await buildWaveIdIndex(db);
    }
    if (typeof pageInfo.totalCount === "number") {
      summary.totalCount = pageInfo.totalCount;
    }

    const guarded = [];
    for (const edge of edges) {
      const wrote = importOneCustomer(edge && edge.node, {
        db, batch, now, summary, skipClientIds, existingByWaveId, guarded,
      });
      if (!wrote) continue;
      opsInBatch += 1;
      await flushIfFull();
    }
    await commitGuardedUpdates(db, guarded, summary, logger);

    const current = typeof pageInfo.currentPage === "number" ?
      pageInfo.currentPage : page;
    const total = typeof pageInfo.totalPages === "number" ?
      pageInfo.totalPages : current;
    if (current >= total) break;
    page = current + 1;
  }

  if (opsInBatch > 0) await batch.commit();
  return summary;
}

/**
 * Builds a `Map<waveCustomerId, {ref, hasCreatedAt, lastSyncedHash}>` over the
 * `clients` collection in one pass, skipping docs without a `waveCustomerId`.
 * `hasCreatedAt` lets a re-run backfill a missing `createdAt` without
 * clobbering an existing one; `lastSyncedHash` is what lets the import skip a
 * customer whose Wave-mapped fields already match. It loads the whole
 * collection into memory, which is fine at the ~650-customer import scale
 * we're at now, but should move to a cursor if that grows.
 * @param {!Object} db Firestore instance.
 * @return {!Promise<!Map<string, {ref: !Object, hasCreatedAt: boolean,
 *   lastSyncedHash: string}>>}
 */
async function buildWaveIdIndex(db) {
  const index = new Map();
  // select(): only these fields are read, and a full client doc carries the
  // address family and the contacts array. Billed reads are per-document
  // either way, so this is pure transfer + parse + retained memory. `wave` is
  // taken whole rather than as a `wave.lastSyncedHash` field path — the map
  // is three small scalars, and a nested projection is the kind of thing that
  // silently returns undefined if the path is ever renamed.
  const snap = await db.collection("clients")
      .select("waveCustomerId", "createdAt", "wave")
      .get();
  const docs = (snap && Array.isArray(snap.docs)) ? snap.docs : [];
  for (const doc of docs) {
    const d = doc.data() || {};
    const id = typeof d.waveCustomerId === "string" ? d.waveCustomerId : "";
    if (!id) continue;
    const wave = (d.wave && typeof d.wave === "object") ? d.wave : {};
    index.set(id, {
      ref: doc.ref,
      hasCreatedAt: d.createdAt != null,
      lastSyncedHash: typeof wave.lastSyncedHash === "string" ?
        wave.lastSyncedHash : "",
    });
  }
  return index;
}

module.exports = {
  importCustomers,
  // Exported so the decisions the page loop delegates can be driven directly
  // from a unit test.
  importOneCustomer,
  commitGuardedUpdates,
  buildWaveIdIndex,
  BATCH_LIMIT,
};
