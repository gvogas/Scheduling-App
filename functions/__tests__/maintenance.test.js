"use strict";

/**
 * Tests for the pure magic-byte validator behind validateUploadedImage. This
 * is the server-side backstop we need because a direct REST/SDK caller can
 * lie about contentType, and the Storage rule has no way to catch that.
 *
 * HAND-MIRRORED by `hasValidImageMagic` in `lib/core/images/image_magic.dart`;
 * both suites read test/fixtures/shared/image_magic.json, because THIS side
 * deletes the object, a divergence is a photo that uploads then vanishes.
 */

const {hasValidImageMagic} = require("../image_magic");

describe("hasValidImageMagic", () => {
  const {cases} = require("../../test/fixtures/shared/image_magic.json");

  test.each(cases)("$name", (c) => {
    expect(hasValidImageMagic(Buffer.from(c.bytes))).toBe(c.expect);
  });

  test("rejects a missing buffer", () => {
    expect(hasValidImageMagic(null)).toBe(false);
  });
});
