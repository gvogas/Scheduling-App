"use strict";

const TOKEN_QUERY_LIMIT = 10;
const TOKEN_FIELD_LIMIT = 240;

// Hand-mirror of `ClientSearchPolicy._foldAccent`. Spelled as the same explicit
// table rather than NFD on purpose: NFD folds strictly more (every decomposable
// letter, so all of Latin Extended-A), and the app writes the index with the
// Dart fold while this side tokenizes the typed query — a character the two
// disagree about is a client nobody can find.
const ACCENT_FOLD = {
  "à": "a", "á": "a", "â": "a", "ã": "a",
  "ä": "a", "å": "a", "ç": "c", "è": "e",
  "é": "e", "ê": "e", "ë": "e", "ì": "i",
  "í": "i", "î": "i", "ï": "i", "ñ": "n",
  "ò": "o", "ó": "o", "ô": "o", "õ": "o",
  "ö": "o", "ù": "u", "ú": "u", "û": "u",
  "ü": "u", "ý": "y", "ÿ": "y",
};

/**
 * Normalizes text for prefix search.
 * @param {*} value Raw value.
 * @return {string}
 */
function normalize(value) {
  return String(value == null ? "" : value)
      .toLowerCase()
      .replace(/[À-ÿ]/g, (c) => ACCENT_FOLD[c] || " ")
      .replace(/[^a-z0-9]+/g, " ")
      .trim();
}

/**
 * Keeps only phone digits.
 * @param {*} value Raw phone-ish value.
 * @return {string}
 */
function digitsOnly(value) {
  return String(value == null ? "" : value).replace(/\D/g, "");
}

/**
 * Builds capped query tokens for array-contains-any.
 * @param {string} query User query.
 * @return {!Array<string>}
 */
function searchQueryTokens(query) {
  const tokens = new Set();
  for (const word of normalize(query).split(" ")) {
    if (word) tokens.add(`t:${word}`);
  }
  const digits = digitsOnly(query);
  if (digits) tokens.add(`p:${digits}`);
  return Array.from(tokens).slice(0, TOKEN_QUERY_LIMIT);
}

/**
 * Builds capped prefix/substr tokens for one stored document.
 *
 * Two ordering rules carry the whole design, because `limit` really does bite:
 * each word emits its WHOLE token before any of its prefixes, so an exact-word
 * query survives truncation; and the text and phone runs are INTERLEAVED, so a
 * long client name can never push the phone tokens past the cap. Appending the
 * phones after the texts is what silently broke search-by-phone.
 * @param {!Object} input Token inputs.
 * @param {!Array<*>} input.texts Text fields.
 * @param {!Array<*>} input.phones Phone fields.
 * @param {number=} input.limit Cap on the emitted tokens.
 * @return {!Array<string>}
 */
function searchIndexTokens(
    {texts = [], phones = [], limit = TOKEN_FIELD_LIMIT}) {
  const textTokens = new Set();
  for (const value of texts) {
    for (const word of normalize(value).split(" ")) {
      if (!word) continue;
      const max = Math.min(word.length, 24);
      textTokens.add(`t:${word.slice(0, max)}`);
      for (let i = 1; i < max; i++) textTokens.add(`t:${word.slice(0, i)}`);
    }
  }
  const phoneTokens = new Set();
  for (const phone of phones) {
    const digits = digitsOnly(phone);
    if (digits.length < 3) continue;
    phoneTokens.add(`p:${digits.slice(0, Math.min(digits.length, 12))}`);
    for (let start = 0; start < digits.length; start++) {
      const remaining = digits.length - start;
      if (remaining < 3) break;
      const max = Math.min(remaining, 12);
      for (let len = 3; len <= max; len++) {
        phoneTokens.add(`p:${digits.slice(start, start + len)}`);
      }
    }
  }
  const text = Array.from(textTokens);
  const phone = Array.from(phoneTokens);
  const out = [];
  for (let i = 0; i < text.length || i < phone.length; i++) {
    if (out.length >= limit) break;
    if (i < text.length) out.push(text[i]);
    if (out.length < limit && i < phone.length) out.push(phone[i]);
  }
  return out;
}

/**
 * The searchable text of one additional contact.
 * @param {*} c Contact entry.
 * @return {string}
 */
function contactText(c) {
  const contact = c || {};
  return `${contact.name || ""} ${contact.email || ""}`;
}

/**
 * Tokenizes one client document.
 * @param {!Object} data Client fields.
 * @return {!Array<string>}
 */
function clientSearchTokens(data) {
  const d = data || {};
  const contacts = Array.isArray(d.contacts) ? d.contacts : [];
  return searchIndexTokens({
    texts: [
      d.name,
      d.businessName,
      d.firstName,
      d.lastName,
      d.email,
      d.address,
      d.city,
      d.province,
      d.postalCode,
      d.country,
      ...contacts.map(contactText),
    ],
    phones: [
      d.phone,
      d.mobile,
      ...contacts.map((c) => c && c.phone),
    ],
  });
}

/**
 * Tokenizes one appointment document into all/employee history scopes.
 * @param {!Object} data Appointment fields.
 * @return {!Array<string>}
 */
function appointmentHistoryScopes(data) {
  const d = data || {};
  const employeeIds = Array.isArray(d.employeeIds) ? d.employeeIds : [];
  const employeeNames = Array.isArray(d.employeeNames) ? d.employeeNames : [];
  // The field carries every token once per scope, so the per-scope budget is
  // the field cap divided by the scope count — NOT the query-side limit.
  const scopeCount = 1 + employeeIds.length;
  const tokens = searchIndexTokens({
    texts: [d.clientName, ...employeeNames],
    phones: [d.clientPhone],
    limit: Math.max(1, Math.floor(TOKEN_FIELD_LIMIT / scopeCount)),
  });
  const scoped = [];
  for (const token of tokens) scoped.push(`all:${token}`);
  for (const employeeId of employeeIds) {
    for (const token of tokens) scoped.push(`emp:${employeeId}:${token}`);
  }
  return scoped.slice(0, TOKEN_FIELD_LIMIT);
}

/**
 * Verifies a token query still matches the full document text or digits.
 * @param {!Object} data Stored document.
 * @param {string} query User query.
 * @return {boolean}
 */
function recordMatchesQuery(data, query) {
  const q = normalize(query);
  const qDigits = digitsOnly(query);
  const d = data || {};
  const contacts = Array.isArray(d.contacts) ? d.contacts : [];
  // The client fields join into one blob (`ClientSearchPolicy.index` does the
  // same); the appointment seam stays per-field, as `historyEntryMatches` does.
  const texts = [
    normalize([
      d.name,
      d.businessName,
      d.firstName,
      d.lastName,
      d.email,
      d.address,
      d.city,
      d.province,
      d.postalCode,
      d.country,
      ...contacts.map(contactText),
    ].join(" ")),
    normalize(d.clientName),
    ...(Array.isArray(d.employeeNames) ? d.employeeNames : [])
        .map((name) => normalize(name)),
  ];
  const phones = [
    d.phone,
    d.mobile,
    d.clientPhone,
    ...contacts.map((c) => c && c.phone),
  ].map(digitsOnly).filter((n) => n.length > 0);
  return Boolean((q && texts.some((t) => t.includes(q))) ||
      (qDigits && phones.some((n) => n.includes(qDigits))));
}

module.exports = {
  TOKEN_FIELD_LIMIT,
  TOKEN_QUERY_LIMIT,
  appointmentHistoryScopes,
  clientSearchTokens,
  normalize,
  recordMatchesQuery,
  searchIndexTokens,
  searchQueryTokens,
};
