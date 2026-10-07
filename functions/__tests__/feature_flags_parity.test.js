"use strict";

const {
  FLAG_DEFAULTS,
  parseFlagBool,
  parseFlagInt,
} = require("../feature_flags_policy");
const {
  defaults,
  boolCases,
  intCases,
} = require("../../test/fixtures/shared/feature_flags.json");

test("in-code Remote Config defaults match the shared fixture", () => {
  expect(FLAG_DEFAULTS).toEqual(defaults);
});

test.each(boolCases)("bool %j", (c) => {
  expect(parseFlagBool(c.raw, c.default)).toBe(c.expect);
});

test.each(intCases)("int %j", (c) => {
  expect(parseFlagInt(c.raw, c.default)).toBe(c.expect);
});
