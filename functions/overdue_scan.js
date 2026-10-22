"use strict";

const {toMillis} = require("./time_utils");
const {OPEN_STATUSES, OVERDUE_LOOKBACK_MS,
  OVERDUE_SWEEP_MAX, recordOf} = require("./notification_policy");

/**
 * Reads a rotating page so delivered jobs cannot starve its tail.
 * @param {!Object} db Firestore handle.
 * @param {!Date} now Sweep time.
 * @return {!Promise<{records: !Array<!Object>, commit: function(): !Promise}>}
 */
async function scanOverduePage(db, now) {
  const state = db.collection("notificationSweepCursors").doc("overdue");
  const previous = await state.get();
  const cursor = previous.exists ? previous.data() : {};
  const floor = new Date(now.getTime() - OVERDUE_LOOKBACK_MS);
  const query = db.collection("appointments")
      .where("status", "in", OPEN_STATUSES)
      .where("endTime", ">", floor)
      .where("endTime", "<=", now)
      .orderBy("endTime", "asc")
      .orderBy("__name__", "asc");
  const valid = Number.isFinite(cursor.endMillis) &&
      cursor.endMillis > floor.getTime() &&
      cursor.endMillis <= now.getTime() && typeof cursor.id === "string" &&
      cursor.id.length > 0 && !cursor.id.includes("/");
  const pageQuery = valid ?
    query.startAfter(new Date(cursor.endMillis), cursor.id) : query;
  let page = await pageQuery.limit(OVERDUE_SWEEP_MAX).get();
  if (valid && page.docs.length === 0) {
    page = await query.limit(OVERDUE_SWEEP_MAX).get();
  }
  const last = page.docs[page.docs.length - 1];
  const next = last && page.docs.length === OVERDUE_SWEEP_MAX ? {
    endMillis: toMillis(last.data().endTime), id: last.id,
  } : {endMillis: null, id: null};
  return {
    records: page.docs.map(recordOf),
    commit: () => state.set({...next, updatedAt: now}),
  };
}

module.exports = {scanOverduePage};
