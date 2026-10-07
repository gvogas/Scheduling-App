"use strict";

jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  return {
    ...actual,
    assertAdminCall: jest.fn(async (req) => req.auth.uid),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
});
jest.mock("../feature_flags", () => ({
  assertFeatureEnabled: jest.fn(),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const security = require("../security");
const {assertFeatureEnabled} = require("../feature_flags");
const {
  placesAutocomplete,
  placesGetDetails,
  placesReverseGeocode,
} = require("../places");

const ADMIN = {uid: "admin-uid"};
const CALLS = [
  ["placesAutocomplete", placesAutocomplete, {input: "123 Main"}],
  ["placesGetDetails", placesGetDetails, {placeId: "abc_1"}],
  ["placesReverseGeocode", placesReverseGeocode,
    {lat: 45.5, lng: -73.5, locale: "en"}],
];

beforeEach(() => {
  jest.clearAllMocks();
  global.fetch = jest.fn();
  assertFeatureEnabled.mockRejectedValue(
      new HttpsError("failed-precondition", "feature-disabled"));
});

test.each(CALLS)("%s refuses while paused, before the limiter or a fetch",
    async (name, fn, data) => {
      await expect(fn.run({data, auth: ADMIN}))
          .rejects.toMatchObject({message: "feature-disabled"});
      expect(assertFeatureEnabled)
          .toHaveBeenCalledWith("feature_address_autocomplete", name);
      expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      expect(global.fetch).not.toHaveBeenCalled();
    });
