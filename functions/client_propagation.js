"use strict";

/**
 * @fileoverview Propagates client-doc edits (name/phone/address) onto that
 * client's FUTURE denormalized appointment copies, so an edit doesn't leave
 * the calendar showing stale data (client-side finding C8).
 *
 * Semantics (mirrors the app's own rules):
 *   - `clientName` / `clientPhone` are always overwritten with the client's
 *     current values. `clientName` is the DISPLAY name — the stored
 *     `clients/{id}.name` carries the phone number on the end for Wave's
 *     benefit, and `clientDisplayName` (`client_name_utils.js`) takes it back
 *     off. Without that strip a client edit would fan "Marc Tremblay
 *     (514) 555-1234" onto every future appointment card, disagreeing with
 *     the clean name the app itself writes at booking time.
 *   - `address` follows the client only when the appointment's stored address
 *     still equals the client's previous (non-empty) address — a differing
 *     or empty address is treated as custom/none and left untouched.
 *     Both sides are the COMPOSED address (`composeFullAddress`), never the
 *     stored `clients/{id}.address`, and that is load-bearing twice over.
 *     An appointment carries ONE address string and no city/province/postal
 *     of its own, so fanning the stored street line onto it would strip the
 *     locality off a live job with nothing left to rebuild it from — and
 *     normalizing the client field (street-only) has to stay a NO-OP here,
 *     which it is, because both shapes compose to the same string. It also
 *     fixes a matching bug that predates the split, in BOTH its halves: a city
 *     or postal edit never touched `address` and so reached no appointment at
 *     all; and an apt-bearing client never matched `from`, because the app
 *     books the DISPLAY spelling ("1234 Rue X #4, …") while this side composed
 *     the canonical one ("4-1234 Rue X, …").
 *     The apt half needed `composeFullAddress` to re-spell the apt the way the
 *     app does — it does now, via `canonicalToDisplay`, and that is required
 *     rather than cosmetic BECAUSE the comparison below is verbatim. Composing
 *     on both sides was necessary but not sufficient; the two composers also
 *     have to agree character for character. Their tests share worked examples
 *     for exactly this reason — each side used to assert its own composer
 *     against itself, which is how the divergence survived a release.
 *   - Only appointments with WORK LEFT are rewritten — history records what
 *     was true at the time of the visit. That is `endTime >= now`, NOT
 *     `startTime >= now`: under the daily-window model a run started up to
 *     MAX_APPOINTMENT_SPAN_DAYS ago can still have days of work left, and
 *     gating on the start meant a client's corrected phone or suite number
 *     never reached a crew that was already on site. Firestore can only take
 *     the one inequality that matches the index, so the QUERY floor is widened
 *     by the span and the real endTime test is applied in code below.
 *
 * Every write is an absolute value, so this is idempotent and the trigger
 * runs with `retry: true`. Updates go out in WriteBatches of ≤500 (the
 * Firestore hard limit).
 *
 * Requires the composite index `(clientId ASC, startTime ASC)` on
 * `appointments` (declared in firestore.indexes.json).
 *
 * @module client_propagation
 */

const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {adminFirestore} = require("./admin_firestore");
const {appointmentHistoryScopes} = require("./search_tokens");
const {MAX_APPOINTMENT_SPAN_MS, hasWorkLeft} = require("./time_utils");
const {clientDisplayName} = require("./client_name_utils");
const {composeFullAddress} = require("./client_address_utils");

/** Firestore WriteBatch hard limit. */
const BATCH_LIMIT = 500;

/** Page size for the future-appointments query (one batch per page). */
const PAGE_SIZE = BATCH_LIMIT;

/**
 * Computes what (if anything) a client edit must propagate to appointments.
 * Pure — unit-testable without Firestore.
 *
 * @param {!Object} before Pre-edit client document fields.
 * @param {!Object} after Post-edit client document fields.
 * @return {?{clientName: (string|undefined), clientPhone: (string|undefined),
 *   address: (?{from: string, to: string})}} Null when nothing changed.
 *   `address` is set only when the client's address changed from a
 *   non-empty value — matching appointments get `to`.
 */
function relevantClientChange(before, after) {
  const b = before || {};
  const a = after || {};

  const change = {};
  let any = false;

  const nameBefore = clientDisplayName(b);
  const nameAfter = clientDisplayName(a);
  if (nameAfter !== nameBefore) {
    change.clientName = nameAfter;
    any = true;
  }

  const phoneBefore = typeof b.phone === "string" ? b.phone.trim() : "";
  const phoneAfter = typeof a.phone === "string" ? a.phone.trim() : "";
  if (phoneAfter !== phoneBefore) {
    change.clientPhone = phoneAfter;
    any = true;
  }

  // Composed, never the raw stored field — see the address note in the header.
  const addrBefore = composeFullAddress(b);
  const addrAfter = composeFullAddress(a);
  // Only propagate when the OLD address was non-empty — appointments with
  // an empty address are custom/none, and matching against "" would clobber
  // them.
  if (addrAfter !== addrBefore && addrBefore !== "") {
    change.address = {from: addrBefore, to: addrAfter};
    any = true;
  } else {
    change.address = null;
  }

  return any ? change : null;
}

/**
 * Builds the update patch for one appointment doc given a relevant change.
 * Pure — unit-testable without Firestore.
 * @param {!Object} change Result of `relevantClientChange` (non-null).
 * @param {!Object} apptData The appointment document fields.
 * @return {?Object} Field patch, or null when this appointment needs nothing.
 */
function buildAppointmentPatch(change, apptData) {
  const d = apptData || {};
  const patch = {};

  if (change.clientName !== undefined &&
      d.clientName !== change.clientName) {
    patch.clientName = change.clientName;
  }
  if (change.clientPhone !== undefined &&
      d.clientPhone !== change.clientPhone) {
    patch.clientPhone = change.clientPhone;
  }
  if (change.address) {
    const current = typeof d.address === "string" ? d.address.trim() : "";
    // This follows the client: only an address still equal to the client's
    // previous value gets updated. A differing address is custom and stays
    // untouched, and an already-propagated doc matches nothing so it's
    // skipped on retry.
    if (current === change.address.from) {
      patch.address = change.address.to;
    }
  }

  if (Object.keys(patch).length === 0) return null;
  // The history search index is built from `clientName`/`clientPhone`, so a
  // patch that changes either and leaves the tokens alone means the job stays
  // findable under the OLD name and vanishes under the corrected one — and
  // nothing rewrites it again before the job closes.
  if (patch.clientName !== undefined || patch.clientPhone !== undefined) {
    patch.historySearchScopes = appointmentHistoryScopes({...d, ...patch});
  }
  return patch;
}

/**
 * Fans a relevant client change out to that client's FUTURE appointments.
 * Injectable core (unit-testable); the trigger below is a thin wrapper.
 *
 * @param {string} clientId The client document id.
 * @param {Object} before Pre-edit client fields.
 * @param {Object} after Post-edit client fields.
 * @param {Object=} deps Injectable: `db` (default getFirestore()), `now`
 *   (Date for the startTime cutoff; default `new Date()`), `logger`.
 * @return {!Promise<{updated: number}>}
 */
async function propagateClientChange(clientId, before, after, deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  // eslint-disable-next-line global-require
  const logger = deps.logger || require("firebase-functions/logger");
  const now = deps.now || new Date();

  const change = relevantClientChange(before, after);
  if (!change) return {updated: 0};

  const nowMs = now.getTime();
  const queryFloor = new Date(nowMs - MAX_APPOINTMENT_SPAN_MS);

  // This loop runs to EXHAUSTION on purpose and must NOT gain a total cap: a
  // repeat series pre-books up to 120 occurrences out to a five-year horizon,
  // and truncating would leave stale denormalized `clientName`/`clientPhone`
  // on the future visits this trigger exists to keep correct. What it does
  // instead is overlap and report — see `pages` in the log line below, which
  // is what makes a pathological client visible.
  let updated = 0;
  let pages = 0;
  let cursor = null;
  for (;;) {
    let query = db.collection("appointments")
        .where("clientId", "==", clientId)
        .where("startTime", ">=", queryFloor)
        .orderBy("startTime")
        .limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    const docs = snap && Array.isArray(snap.docs) ? snap.docs : [];
    if (docs.length === 0) break;
    pages += 1;

    updated += await db.runTransaction(async (tx) => {
      const source = await tx.get(db.collection("clients").doc(clientId));
      if (!source.exists) return 0;
      const current = source.data() || {};
      const currentChange = relevantClientChange(before, current) || {};
      currentChange.clientName = clientDisplayName(current);
      currentChange.clientPhone = typeof current.phone === "string" ?
        current.phone.trim() : "";
      const freshDocs = await Promise.all(docs.map((doc) => tx.get(doc.ref)));
      let ops = 0;
      for (const doc of freshDocs) {
        if (!doc.exists) continue;
        const data = doc.data() || {};
        if (data.clientId !== clientId || !hasWorkLeft(data, nowMs)) continue;
        const patch = buildAppointmentPatch(currentChange, data);
        if (!patch) continue;
        tx.update(doc.ref, {
          ...patch,
          clientSourceUpdatedAt: source.updateTime,
        });
        ops += 1;
      }
      return ops;
    });

    if (docs.length < PAGE_SIZE) break;
    cursor = docs[docs.length - 1];
  }

  if (updated > 0) {
    logger.info("propagateClientEdits: appointments updated", {
      clientId,
      updated,
      // One edit on a client carrying several live series reads hundreds to
      // low-thousands of documents. Uncapped by design, so the page count is
      // the only signal that says so.
      pages,
      fields: Object.keys(change).filter((k) =>
        change[k] !== null && change[k] !== undefined),
    });
  }
  return {updated};
}

// This trigger fans client edits out to future appointments. It fires only
// on UPDATE, since creates have no appointments yet and deletes intentionally
// leave history intact. (`retry: true` is safe — see the idempotency note in
// the fileoverview.)
const propagateClientEdits = onDocumentUpdated(
    {document: "clients/{clientId}", retry: true},
    async (event) => {
      const before = event.data?.before?.exists ?
        event.data.before.data() : null;
      const after = event.data?.after?.exists ?
        event.data.after.data() : null;
      if (!before || !after) return;
      await propagateClientChange(event.params.clientId, before, after);
    },
);

module.exports = {
  propagateClientEdits,
  // Exported so the orchestrator can be driven with injected {db, logger,
  // now} — that injection is what makes the has-work-left gate testable
  // without touching firebase-admin.
  propagateClientChange,
  relevantClientChange,
  buildAppointmentPatch,
  clientDisplayName,
};
