"use strict";

// Examples shared with the Dart suite live in
// test/fixtures/shared/search_tokens.json.

const {
  TOKEN_FIELD_LIMIT,
  appointmentHistoryScopes,
  clientSearchTokens,
  normalize,
  recordMatchesQuery,
  searchIndexTokens,
  searchQueryTokens,
} = require("../search_tokens");

const fixture = require("../../test/fixtures/shared/search_tokens.json");

const expectTokens = (tokens, c) => {
  expect(["expect", "expectContains", "expectLength"].some((k) => k in c))
      .toBe(true);
  if ("expect" in c) expect(tokens).toEqual(c.expect);
  if ("expectContains" in c) expect(tokens).toContain(c.expectContains);
  if ("expectLength" in c) expect(tokens).toHaveLength(c.expectLength);
};

describe("searchQueryTokens", () => {
  test.each(fixture.queryTokens)("$name", (c) => {
    expectTokens(searchQueryTokens(c.query), c);
  });
});

describe("searchIndexTokens", () => {
  test.each(fixture.indexTokens)("$name", (c) => {
    const args = {texts: c.texts, phones: c.phones};
    if (c.limit != null) args.limit = c.limit;
    expectTokens(searchIndexTokens(args), c);
  });

  test("honours the field cap", () => {
    const texts = [];
    for (let i = 0; i < 200; i++) texts.push(`word${i}`);
    expect(searchIndexTokens({texts, phones: ["5145554321"]}))
        .toHaveLength(TOKEN_FIELD_LIMIT);
  });
});

describe("clientSearchTokens", () => {
  test("indexes name, an additional contact and both numbers", () => {
    const tokens = clientSearchTokens({
      name: "Plomberie Vogas",
      phone: "(514) 555-4321",
      mobile: "438 555 0000",
      contacts: [{
        name: "Sylvie",
        email: "sylvie@example.com",
        phone: "5140001111",
      }],
    });
    expect(tokens).toContain("t:plomberie");
    expect(tokens).toContain("t:sylvie");
    expect(tokens).toContain("p:5145554321");
    expect(tokens).toContain("p:4385550000");
  });
});

describe("appointmentHistoryScopes", () => {
  test.each(fixture.historyScopes)("$name", (c) => {
    const scopes = appointmentHistoryScopes(c.record);
    expectTokens(scopes, c);
    expect(scopes.every((t) => t.startsWith("all:"))).toBe(true);
    expect(scopes.length).toBeLessThanOrEqual(TOKEN_FIELD_LIMIT);
  });
});

describe("recordMatchesQuery", () => {
  test("re-verifies a token hit against the full stored text", () => {
    const client = {name: "Plomberie Vogas", phone: "5145554321"};
    expect(recordMatchesQuery(client, "vogas")).toBe(true);
    expect(recordMatchesQuery(client, "5554321")).toBe(true);
    expect(recordMatchesQuery(client, "tremblay")).toBe(false);
  });
});

describe("recordMatchesQuery client/employee seam", () => {
  const {record, cases} = fixture.historySeam;
  test.each(cases)("$name", (c) => {
    expect(recordMatchesQuery(record, c.query)).toBe(c.expect);
  });
});

describe("normalize", () => {
  test.each(fixture.normalize)("$input", (c) => {
    expect(normalize(c.input)).toBe(c.expect);
  });
});

describe("recordMatchesQuery phone seam", () => {
  const client = {
    name: "Marie Tremblay",
    phone: "5145628332",
    mobile: "4385551212",
    contacts: [{name: "Ana", phone: "5145550110"}],
  };

  it("does not match a query straddling two numbers", () => {
    // The old blob was '514562833243855512125145550110'.
    expect(recordMatchesQuery(client, "83324385")).toBe(false);
  });

  it("matches each number on its own", () => {
    expect(recordMatchesQuery(client, "5145628332")).toBe(true);
    expect(recordMatchesQuery(client, "4385551212")).toBe(true);
    expect(recordMatchesQuery(client, "5145550110")).toBe(true);
  });

  it("still matches a substring inside one number", () => {
    expect(recordMatchesQuery(client, "5628332")).toBe(true);
  });

  it("still matches text", () => {
    expect(recordMatchesQuery(client, "tremblay")).toBe(true);
  });
});
