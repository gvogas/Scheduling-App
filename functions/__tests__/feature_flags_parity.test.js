"use strict";

const {FLAG_DEFAULTS} = require("../feature_flags_policy");
const {defaults} = require("../../test/fixtures/shared/feature_flags.json");

test("in-code Remote Config defaults match the shared fixture", () => {
  expect(FLAG_DEFAULTS).toEqual(defaults);
});
