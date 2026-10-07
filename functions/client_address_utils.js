"use strict";

/**
 * @fileoverview The street-vs-locality rule for `clients/{id}.address`, and the
 * JS half of a hand-mirrored pair.
 * `city`/`province`/`postalCode`/`country` are their own fields, so an
 * `address` that ALSO carries them stores each one twice and lets the two
 * copies drift. The field is the STREET LINE; everything that shows a whole
 * address composes it back.
 * The collection holds both shapes and always will — the Wave import writes a
 * street line, the app wrote the whole picked string until 2026-08-28, and the
 * console can write either. So `composeFullAddress` reduces through
 * `streetFromAddress` BEFORE it rejoins: skip that and a legacy doc renders its
 * city twice.
 * Hand-mirrors `AddressParser.streetOnly` / `composeFull`
 * (`lib/features/maps/domain/address_parser.dart`). Their tests share worked
 * examples, so a divergence fails a test on one side.
 * `streetFromAddress` lived in `wave/mappers.js`, which is where the rule was
 * first needed — the Wave push has always had to reduce `address` down to an
 * `addressLine1`. It moved here when `client_propagation.js` needed the same
 * rule: a propagation module must not import from `wave/`, and a second copy
 * of a rule this sharp is how the two answers drift apart.
 * @module client_address_utils
 */

/**
 * Collapses inner whitespace and case so two spellings of the same locality
 * compare equal.
 * @param {*} value Any value; non-strings read as empty.
 * @return {string}
 */
function localityKey(value) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

/**
 * The street line alone — [stored] with any trailing segments that merely
 * repeat the doc's structured locality fields removed.
 * @param {string} stored Stored `address` value.
 * @param {!Object} f The client document fields (for city/province/etc.).
 * @return {string} The street line.
 */
function streetFromAddress(stored, f) {
  if (!stored) return "";
  const segments = String(stored).split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  if (segments.length <= 1) return segments[0] || "";

  const d = f || {};
  const city = localityKey(d.city);
  const province = localityKey(d.province);
  const postalCode = localityKey(d.postalCode);
  const country = localityKey(d.country);
  const localityTails = new Set([
    city, province, postalCode, country,
    province && postalCode ? `${province} ${postalCode}` : "",
  ].filter(Boolean));

  // No structured locality fields to identify a tail (legacy docs): keep the
  // historical behaviour (first segment) so a full display address doesn't dump
  // the city into line1.
  if (localityTails.size === 0) return segments[0];

  let end = segments.length;
  while (end > 1 && localityTails.has(localityKey(segments[end - 1]))) {
    end -= 1;
  }
  return segments.slice(0, end).join(", ");
}

// Hand-mirrors `AddressParser`'s four apt patterns, IN ORDER — the order is the
// rule, since a value can match more than one.
const SAVED_APT = /^Apt-?\s*([^-]+)\s*-\s*(.+)$/i;
// eslint-disable-next-line max-len
const LABELED_APT = /^\s*(?:apt|apartment|unit|suite|ste|#)\s*[-#: ]*\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*[-,]\s*(.+)$/i;
const DASH_APT = /^\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*-\s*(\d+.+)$/;
// eslint-disable-next-line max-len
const TRAILING_APT = /^\s*(.+?)\s+(?:#|apt\.?|apartment|unit|suite|ste\.?)\s*[-#: ]*\s*([A-Za-z0-9][A-Za-z0-9 /]*)\s*(,.*)?$/i;
const LEADING_HASHES = /^#+/;
const EMBEDDED_APT_TOKEN =
    /\s+(#|apt\.?|apartment|unit|suite|ste\.?)\s*[-#: ]*\s*[A-Za-z0-9 /]+/i;

/**
 * Splits a street line into its apt and street halves, or null when it has no
 * apt.
 * @param {string} rawAddress
 * @return {?{apt: string, street: string}}
 */
function splitApt(rawAddress) {
  const value = (rawAddress || "").trim();
  if (!value) return null;

  const saved = SAVED_APT.exec(value);
  if (saved) return {apt: saved[1].trim(), street: saved[2].trim()};

  const labeled = LABELED_APT.exec(value);
  if (labeled) return {apt: labeled[1].trim(), street: labeled[2].trim()};

  const dash = DASH_APT.exec(value);
  if (dash) return {apt: dash[1].trim(), street: dash[2].trim()};

  const trailing = TRAILING_APT.exec(value);
  if (trailing) {
    const beforeUnit = trailing[1].trim();
    const afterUnit = (trailing[3] || "").trim();
    return {
      apt: trailing[2].trim(),
      street: afterUnit ? `${beforeUnit}${afterUnit}` : beforeUnit,
    };
  }

  return null;
}

/**
 * Renders the apt the way the APP does — "1234 Rue X #4", never "4-1234 Rue X".
 * @param {string} street
 * @param {string} apt
 * @return {string}
 */
function formatAptForDisplay(street, apt) {
  const cleanStreet = (street || "").replace(EMBEDDED_APT_TOKEN, "").trim();
  const cleanApt = (apt || "").trim().replace(LEADING_HASHES, "");
  if (!cleanStreet || !cleanApt) return cleanStreet;

  const commaIndex = cleanStreet.indexOf(",");
  if (commaIndex === -1) return `${cleanStreet} #${cleanApt}`;

  const firstLine = cleanStreet.slice(0, commaIndex).trim();
  const rest = cleanStreet.slice(commaIndex);
  return `${firstLine} #${cleanApt}${rest}`;
}

/**
 * The stored canonical spelling rendered the way the app shows it.
 * @param {string} stored
 * @return {string}
 */
function canonicalToDisplay(stored) {
  const parts = splitApt(stored);
  return parts ? formatAptForDisplay(parts.street, parts.apt) : stored;
}

/**
 * The whole address on one line, rebuilt from the street plus the structured
 * fields — "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada".
 * @param {!Object} f The client document fields.
 * @return {string} The composed address, or "" when there is nothing to show.
 */
function composeFullAddress(f) {
  const d = f || {};
  const stored = typeof d.address === "string" ? d.address.trim() : "";
  const street = canonicalToDisplay(streetFromAddress(stored, d));
  const text = (value) => (typeof value === "string" ? value.trim() : "");
  // Province and postal code share a segment, the way an address is written.
  const region = [text(d.province), text(d.postalCode)]
      .filter(Boolean).join(" ");
  return [street, text(d.city), region, text(d.country)]
      .filter(Boolean).join(", ");
}

// splitApt is shared by the building projection.
// canonicalToDisplay stays private.
module.exports = {
  splitApt,
  streetFromAddress,
  composeFullAddress,
};
