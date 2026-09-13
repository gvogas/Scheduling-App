"use strict";

/**
 * @fileoverview Repairs the UTF-8-read-as-Latin-1 mojibake carried by some of
 * Google's own Places records: the locality of `Calixa-Lavallée` is stored as
 * `Calixa-Lavallã©E`, and it arrives identically from autocomplete, place
 * details and `formattedAddress` — so the corrupt spelling is what the admin
 * picks and what lands in Firestore, not merely what the dropdown shows.
 * Upstream title-cased the text AFTER misdecoding it, which is why the lead
 * `Ã` arrives lowered to `ã` and the letter behind the accent arrives
 * capitalised; both are undone here. Neighbouring records for the same town
 * are clean, so this is per-record corruption upstream — not something a
 * different field mask or language parameter can avoid.
 *
 * The two leads cover every French letter: `Ã` carries all of Latin-1
 * (`àâäçéèêëîïôöùûüÿæ` and their capitals) and `Å` carries the `œ`/`Œ`/`Ÿ`
 * that sit outside it. The `Â` lead is deliberately NOT handled — it holds no
 * letter, only symbols like `«»°½`, and it is the one lead that collides with
 * the first byte of a misdecoded 3-byte sequence.
 * @module mojibake
 */

/** The lead byte behind each spelling a sequence's first char can take. */
const LEAD_BYTES = new Map([
  ["Ã", 0xc3],
  ["ã", 0xc3],
  ["Å", 0xc5],
  ["å", 0xc5],
]);

// Lead, continuation, then the ASCII capital the upstream title-caser left
// behind the accent: `©` is not a letter, so `Lavallée` came back as
// `Lavallã©E`.
const MOJIBAKE_RUN = /([ÃãÅå])([-¿])([A-Z]?)/g;

/**
 * [text] with every mojibake run rewritten back to the character it encodes.
 * @param {string} text Any upstream string.
 * @return {string} The repaired text, unchanged where nothing matched.
 */
function repairMojibake(text) {
  return text.replace(MOJIBAKE_RUN, (run, lead, continuation, trailing) => {
    const decoded = Buffer.from([
      LEAD_BYTES.get(lead),
      continuation.charCodeAt(0),
    ]).toString("utf8");
    return decoded + trailing.toLowerCase();
  });
}

/**
 * [value] with every string inside it repaired and its structure untouched.
 * Walks rather than reaching for known fields: the callables hand the upstream
 * payload back without inspecting its shape, and a field-mask change must not
 * quietly leave a new text field uncorrected.
 * @param {*} value Any JSON-shaped value.
 * @return {*} The same shape, with repaired strings.
 */
function repairMojibakeDeep(value) {
  if (typeof value === "string") return repairMojibake(value);
  if (Array.isArray(value)) {
    return value.map((entry) => repairMojibakeDeep(entry));
  }
  if (value && typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value)) {
      out[key] = repairMojibakeDeep(value[key]);
    }
    return out;
  }
  return value;
}

module.exports = {repairMojibake, repairMojibakeDeep};
