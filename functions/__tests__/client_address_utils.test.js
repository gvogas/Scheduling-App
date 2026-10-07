"use strict";

// The JS half of a hand-mirrored pair (AddressParser in lib/features/maps/).
// Both suites read test/fixtures/shared/address.json.

const {
  streetFromAddress,
  composeFullAddress,
} = require("../client_address_utils");
const fixture = require("../../test/fixtures/shared/address.json");

describe("streetFromAddress", () => {
  test.each(fixture.streetOnly)("$name", (c) => {
    expect(streetFromAddress(c.stored, c.locality)).toBe(c.expect);
  });

  test("an undefined address stays empty", () => {
    expect(streetFromAddress(undefined, {city: "Montréal"})).toBe("");
  });
});

describe("composeFullAddress", () => {
  test.each(fixture.composeFull)("$name", (c) => {
    expect(composeFullAddress({address: c.stored, ...c.locality}))
        .toBe(c.expect);
  });

  test("a null doc composes to nothing", () => {
    expect(composeFullAddress(null)).toBe("");
  });
});
