"use strict";

/**
 * Worked examples are REAL upstream values — each was returned by
 * places:autocomplete and places/{id} for a `774 Lamontagne` lookup, with the
 * clean record for the same town alongside to show the corruption is
 * per-record.
 */

const {repairMojibake, repairMojibakeDeep} = require("../mojibake");

/** Every accented letter and ligature French spells, both cases. */
const FRENCH_LETTERS = [
  "à", "â", "ä", "ç", "é", "è", "ê", "ë", "î", "ï", "ô", "ö", "ù", "û", "ü",
  "ÿ", "œ", "æ",
  "À", "Â", "Ä", "Ç", "É", "È", "Ê", "Ë", "Î", "Ï", "Ô", "Ö", "Ù", "Û", "Ü",
  "Ÿ", "Œ", "Æ",
];

/**
 * Upstream's title-caser: lowercase throughout, capitalising whatever follows
 * a non-letter. Modelled, not guessed — the two real samples below pin it.
 * @param {string} text Text to title-case.
 * @return {string} The title-cased text.
 */
function titleCase(text) {
  let out = "";
  let atWordStart = true;
  for (const char of text) {
    out += atWordStart ? char.toUpperCase() : char.toLowerCase();
    atWordStart = !/\p{L}/u.test(char);
  }
  return out;
}

/**
 * What upstream did to [text]: read its UTF-8 bytes as Latin-1, then title-case
 * the result.
 * @param {string} text The true text.
 * @return {string} The corrupt text as Places serves it.
 */
function corrupt(text) {
  const misdecoded = Array.from(Buffer.from(text, "utf8"))
      .map((byte) => String.fromCharCode(byte))
      .join("");
  return titleCase(misdecoded);
}

describe("the corruption model", () => {
  // Everything below leans on `corrupt`, so it has to reproduce what Places
  // actually returned, byte for byte, before it can stand in for it.
  test("reproduces the real upstream values", () => {
    expect(corrupt("Calixa-Lavallée")).toBe("Calixa-Lavallã©E");
    expect(corrupt("Saint-Jérôme")).toBe("Saint-Jã©Rã´Me");
  });
});

describe("repairMojibake", () => {
  test("undoes the misdecode and the title-case behind the accent", () => {
    expect(repairMojibake("774 Rang Lamontagne, Calixa-Lavallã©E, QC, Canada"))
        .toBe("774 Rang Lamontagne, Calixa-Lavallée, QC, Canada");
  });

  test("repairs every run in a string, not just the first", () => {
    expect(repairMojibake("Saint-Jã©Rã´Me")).toBe("Saint-Jérôme");
    expect(repairMojibake("Cã´Tã©")).toBe("Côté");
  });

  // Every example here is already title-cased, the way a Places locality is,
  // so upstream's own capitalisation is a no-op on it and the repair has to
  // give the name back EXACTLY. A name upstream also re-cased (`des` to `Des`)
  // is covered separately below — that damage is independent of the encoding.
  test("restores every French letter", () => {
    for (const letter of FRENCH_LETTERS) {
      const name = `Rue B${letter}c`;
      expect(repairMojibake(corrupt(name))).toBe(name);
    }
  });

  test("restores the place names those letters actually appear in", () => {
    for (const name of [
      "Trois-Rivières", "Sainte-Thérèse", "Saint-Étienne", "Rue Du Cœur",
      "Boulevard Curé-Labelle", "Québec", "Montréal", "Rue Honoré-Mercier",
      "Saint-Jérôme", "Calixa-Lavallée", "Rue De L'Église", "Saint-Anicet",
    ]) {
      expect(repairMojibake(corrupt(name))).toBe(name);
    }
  });

  test("does not try to undo the word-casing upstream also applied", () => {
    // `des` came back `Des` whether or not the name carries an accent, and
    // nothing in the text says which it was. Restoring the CHARACTERS is the
    // whole job; guessing the casing back would be a second corruption.
    expect(repairMojibake(corrupt("Sainte-Anne-des-Plaines")))
        .toBe("Sainte-Anne-Des-Plaines");
  });

  test("leaves no trace of the misdecode in any French place name", () => {
    for (const name of ["Saint-Étienne", "Rue du Cœur", "Trois-Rivières"]) {
      // The letters are back, not merely rearranged into something else.
      expect(repairMojibake(corrupt(name))).not.toMatch(/[\u00c3\u00e3]/);
    }
  });

  test("leaves a clean record untouched", () => {
    expect(repairMojibake("774 Rue Lamontagne, Calixa-Lavallée, QC, Canada"))
        .toBe("774 Rue Lamontagne, Calixa-Lavallée, QC, Canada");
    expect(repairMojibake("Québec")).toBe("Québec");
    expect(repairMojibake("774 Boulevard Lamontagne, Sainte-Marie, QC"))
        .toBe("774 Boulevard Lamontagne, Sainte-Marie, QC");
  });

  test("leaves an accented letter followed by a plain one alone", () => {
    // A run needs a Latin-1 punctuation char behind the lead, so a genuine
    // `ã` in a name is never mistaken for half of a misdecoded pair.
    expect(repairMojibake("São Paulo")).toBe("São Paulo");
    expect(repairMojibake("Ação")).toBe("Ação");
  });
});

describe("repairMojibakeDeep", () => {
  test("repairs strings at every depth and keeps the shape", () => {
    const payload = {
      suggestions: [
        {placePrediction: {
          placeId: "ChIJu9M8yGXwyEwRsVfA4MlxuE8",
          text: {text: "774 Rang Lamontagne, Calixa-Lavallã©E, QC, Canada"},
        }},
      ],
    };

    expect(repairMojibakeDeep(payload)).toEqual({
      suggestions: [
        {placePrediction: {
          placeId: "ChIJu9M8yGXwyEwRsVfA4MlxuE8",
          text: {text: "774 Rang Lamontagne, Calixa-Lavallée, QC, Canada"},
        }},
      ],
    });
  });

  test("passes non-string leaves through untouched", () => {
    expect(repairMojibakeDeep({address: null})).toEqual({address: null});
    expect(repairMojibakeDeep({lat: 45.5017, ok: true, missing: undefined}))
        .toEqual({lat: 45.5017, ok: true, missing: undefined});
  });
});
