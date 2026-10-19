"use strict";

const {HttpsError} = require("firebase-functions/v2/https");
const {Timestamp} = require("firebase-admin/firestore");
const {toMillis} = require("./time_utils");

const TEXT_CAPS = {title: 200, clientId: 128, clientName: 401,
  clientPhone: 40, address: 500, notes: 4000, fieldNotes: 4000,
  materialsNeeded: 2000, status: 32, repeat: 32, seriesId: 128};
const FLAGS = ["isPersonal", "isAllDay", "isDayOff"];
const LISTS = ["employeeIds", "employeeNames"];
const TIMES = ["startTime", "endTime"];
const LABELS = ["dayIndex", "dayCount"];
const FIELDS = [...Object.keys(TEXT_CAPS), ...FLAGS, ...LISTS,
  ...TIMES, ...LABELS];

/**
 * Reads only editable fields, converting the callable's date representation.
 * @param {!Object} raw Client record.
 * @return {!Object} Validated record.
 */
function readEditableRecord(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw) ||
      Object.keys(raw).some((key) => !FIELDS.includes(key))) {
    throw new HttpsError("invalid-argument", "invalid-appointment-fields");
  }
  const out = {};
  for (const field of FIELDS) {
    const value = raw[field];
    if (TIMES.includes(field)) {
      if (!Number.isSafeInteger(value) || value < Date.UTC(2020, 0, 1) ||
          value > Date.UTC(2100, 0, 1)) {
        throw new HttpsError("invalid-argument", "invalid-appointment-time");
      }
      out[field] = Timestamp.fromMillis(value);
    } else if (field in TEXT_CAPS) {
      const text = value ?? (field === "status" ? "pending" :
        field === "repeat" ? "none" : "");
      if (typeof text !== "string" || text.length > TEXT_CAPS[field]) {
        throw new HttpsError("invalid-argument", "invalid-appointment-text");
      }
      if (["clientId", "seriesId"].includes(field) &&
          (text.includes("/") || [".", ".."].includes(text))) {
        throw new HttpsError("invalid-argument", "invalid-appointment-link");
      }
      out[field] = text;
    } else if (FLAGS.includes(field)) {
      if (value !== undefined && typeof value !== "boolean") {
        throw new HttpsError("invalid-argument", "invalid-appointment-flag");
      }
      out[field] = value ?? false;
    } else if (LISTS.includes(field)) {
      const list = value ?? [];
      if (!Array.isArray(list) || list.length > 500 ||
          list.some((entry) => typeof entry !== "string" ||
            entry.length > (field === "employeeIds" ? 128 : 200))) {
        throw new HttpsError("invalid-argument", "invalid-appointment-crew");
      }
      if (field === "employeeIds" && list.some((id) => !id ||
          id.includes("/") || [".", ".."].includes(id))) {
        throw new HttpsError("invalid-argument", "invalid-appointment-crew");
      }
      out[field] = list;
    } else {
      if (value !== undefined && (!Number.isInteger(value) ||
          value < 0 || value > 120)) {
        throw new HttpsError("invalid-argument", "invalid-appointment-day");
      }
      if (value !== undefined) out[field] = value;
    }
  }
  return out;
}

/**
 * Canonical comparison including missing legacy defaults and Firestore dates.
 * @param {string} field Editable field.
 * @param {*} value Stored or proposed value.
 * @return {string} Stable comparison key.
 */
function fieldValue(field, value) {
  if (TIMES.includes(field)) return String(toMillis(value));
  const fallback = LISTS.includes(field) ? [] : FLAGS.includes(field) ?
    false : LABELS.includes(field) ? 0 : field === "status" ? "pending" :
      field === "repeat" ? "none" : "";
  return JSON.stringify(value ?? fallback);
}

/**
 * Merges only intentional changes, rejecting conflicting same-field edits.
 * @param {!Object} base Form's original record.
 * @param {!Object} desired Form's edited record.
 * @param {!Object} current Current server record.
 * @return {!Object} Dirty-field patch.
 */
function appointmentEditPatch(base, desired, current) {
  const patch = {};
  for (const field of FIELDS) {
    const original = fieldValue(field, base[field]);
    const proposed = fieldValue(field, desired[field]);
    if (original === proposed) continue;
    const stored = fieldValue(field, current[field]);
    if (stored !== original && stored !== proposed) {
      throw new HttpsError("aborted", "appointment-edit-conflict", {field});
    }
    if (stored !== proposed) patch[field] = desired[field];
  }
  return patch;
}

/**
 * Validates merged records while allowing an unwidened legacy span.
 * @param {!Object} record Merged appointment.
 * @param {?Object} previous Existing appointment, or null for create.
 * @return {void}
 */
function validateEditedAppointment(record, previous) {
  const statuses = ["pending", "in_progress", "done", "cancelled"];
  if (!statuses.includes(record.status)) {
    throw new HttpsError("invalid-argument", "invalid-appointment-status");
  }
  const span = toMillis(record.endTime) - toMillis(record.startTime);
  const oldSpan = previous ?
    toMillis(previous.endTime) - toMillis(previous.startTime) : -1;
  if (!Number.isFinite(span) || span < 0 ||
      (span > 14 * 86400_000 + 2 * 3600_000 && span > oldSpan)) {
    throw new HttpsError("invalid-argument", "invalid-appointment-span");
  }
}

module.exports = {readEditableRecord, appointmentEditPatch,
  validateEditedAppointment, fieldValue, FIELDS};
