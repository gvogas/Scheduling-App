"use strict";

/**
 * Tests the response shaping for placesAutocomplete and placesGetDetails — the
 * defensive `Array.isArray(...) ?
 */
jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  const mock = {
    ...actual,
    assertAdmin: jest.fn().mockResolvedValue(undefined),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
  // The callables open with `assertAdminCall`, which COMPOSES the auth check,
  // `assertAdmin` and `assertPayloadShape`.
  mock.assertAdminCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new (require("firebase-functions/v2/https").HttpsError)(
          "unauthenticated", "auth-required");
    }
    await mock.assertAdmin(req.auth.uid);
    actual.assertPayloadShape(req.data, allowedKeys);
    return req.auth.uid;
  });
  return mock;
});

const {placesAutocomplete, placesGetDetails} = require("../places");

const AUTH = {uid: "admin-uid"};

/**
 * A fetch-compatible OK response around a decoded JSON body.
 * @param {object} body
 * @return {{ok: boolean, status: number, json: function(): !Promise<object>}}
 */
function okResponse(body) {
  return {ok: true, status: 200, json: async () => body};
}

const runAutocomplete = (data) =>
  placesAutocomplete.run({data, auth: AUTH});
const runDetails = (data) => placesGetDetails.run({data, auth: AUTH});

describe("placesAutocomplete response shaping", () => {
  test("passes through the upstream suggestions array", async () => {
    const suggestions = [
      {placePrediction: {placeId: "p1", text: {text: "14 Elm St"}}},
    ];
    global.fetch = jest.fn().mockResolvedValue(okResponse({suggestions}));

    const result = await runAutocomplete({input: "14 Elm"});
    expect(result).toEqual({suggestions});
  });

  test("coerces a missing suggestions field to an empty array", async () => {
    global.fetch = jest.fn().mockResolvedValue(okResponse({}));

    const result = await runAutocomplete({input: "nowhere"});
    expect(result).toEqual({suggestions: []});
  });

  test("coerces a non-array suggestions field to an empty array", async () => {
    global.fetch = jest.fn()
        .mockResolvedValue(okResponse({suggestions: "unexpected"}));

    const result = await runAutocomplete({input: "weird"});
    expect(result).toEqual({suggestions: []});
  });

  test("repairs upstream mojibake in a prediction", async () => {
    global.fetch = jest.fn().mockResolvedValue(okResponse({suggestions: [
      {placePrediction: {placeId: "p1", text: {text: "Saint-Jã©Rã´Me, QC"}}},
    ]}));

    const result = await runAutocomplete({input: "saint-j"});
    expect(result.suggestions[0].placePrediction.text.text)
        .toBe("Saint-Jérôme, QC");
  });

  test("rejects a missing input before any upstream call", async () => {
    global.fetch = jest.fn();
    await expect(runAutocomplete({})).rejects.toThrow();
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe("placesGetDetails response shaping", () => {
  test("returns formattedAddress + addressComponents", async () => {
    const body = {
      formattedAddress: "14 Elm St, Montréal, QC",
      addressComponents: [{longText: "14"}],
    };
    global.fetch = jest.fn().mockResolvedValue(okResponse(body));

    const result = await runDetails({placeId: "ChIJ_abc123"});
    expect(result).toEqual({
      formattedAddress: "14 Elm St, Montréal, QC",
      addressComponents: [{longText: "14"}],
    });
  });

  test("defaults a missing/mistyped body to empty values", async () => {
    global.fetch = jest.fn().mockResolvedValue(
        okResponse({formattedAddress: 42, addressComponents: "nope"}),
    );

    const result = await runDetails({placeId: "ChIJ_abc123"});
    expect(result).toEqual({formattedAddress: "", addressComponents: []});
  });

  test("repairs upstream mojibake in the address it hands back", async () => {
    global.fetch = jest.fn().mockResolvedValue(okResponse({
      formattedAddress: "774 Rang Lamontagne, Calixa-Lavallã©E, QC",
      addressComponents: [
        {longText: "Calixa-Lavallã©E", types: ["locality"]},
      ],
    }));

    const result = await runDetails({placeId: "ChIJ_abc123"});
    expect(result).toEqual({
      formattedAddress: "774 Rang Lamontagne, Calixa-Lavallée, QC",
      addressComponents: [
        {longText: "Calixa-Lavallée", types: ["locality"]},
      ],
    });
  });

  test("rejects a placeId that fails the id pattern", async () => {
    global.fetch = jest.fn();
    await expect(runDetails({placeId: "bad id/../x"}))
        .rejects.toThrow(/invalid-placeId/);
    expect(global.fetch).not.toHaveBeenCalled();
  });
});
