"use strict";

const MINUTE = 60000;
const BUDGETS = {leaveNow: 15 * MINUTE, reminder: 30 * MINUTE,
  doneCheck: 120 * MINUTE, digest: 12 * 60 * MINUTE,
  overdueReview: 24 * 60 * MINUTE};

/**
 * Clamps delivery to its useful occurrence window and a kind-specific budget.
 * @param {string} kind Notification kind.
 * @param {number} nowMillis Creation instant.
 * @param {number=} occurrenceDeadline Optional job start/end cutoff.
 * @return {number} Absolute last useful delivery instant.
 */
function notificationValidUntil(kind, nowMillis, occurrenceDeadline) {
  const budget = BUDGETS[kind] || 24 * 60 * MINUTE;
  const deadline = nowMillis + budget;
  return Number.isFinite(occurrenceDeadline) ?
    Math.min(deadline, occurrenceDeadline) : deadline;
}

module.exports = {notificationValidUntil};
