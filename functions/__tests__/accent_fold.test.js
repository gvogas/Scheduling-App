"use strict";

const {folds} = require("../../test/fixtures/shared/accent_fold.json");
const {normalize} = require("../search_tokens");

describe("ACCENT_FOLD matches the Dart table entry by entry", () => {
  test("covers every Latin-1 letter from U+00C0 to U+00FF", () => {
    const expected = [];
    for (let c = 0xC0; c <= 0xFF; c++) expected.push(c);
    expect(folds.map((f) => f[0])).toEqual(expected);
  });

  test.each(folds)("U+%s folds to \"%s\"", (codePoint, fold) => {
    expect(normalize(String.fromCharCode(codePoint))).toBe(fold);
  });
});
