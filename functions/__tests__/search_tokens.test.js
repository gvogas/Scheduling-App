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
  test("carries every token under all and each assignee scope", () => {
    const scopes = appointmentHistoryScopes({
      clientName: "Tremblay",
      clientPhone: "5145554321",
      employeeIds: ["emp1"],
      employeeNames: ["Marc"],
    });
    expect(scopes).toContain("all:t:tremblay");
    expect(scopes).toContain("emp:emp1:t:tremblay");
    expect(scopes).toContain("all:t:marc");
    // Reachable in every scope; appending it last silently lost it.
    expect(scopes).toContain("all:p:5145554321");
    expect(scopes).toContain("emp:emp1:p:5145554321");
    expect(scopes.length).toBeLessThanOrEqual(TOKEN_FIELD_LIMIT);
  });

  test("stays inside the field cap for a large crew", () => {
    const employeeIds = [];
    const employeeNames = [];
    for (let i = 0; i < 20; i++) {
      employeeIds.push(`emp${i}`);
      employeeNames.push(`Technicien${i}`);
    }
    const scopes = appointmentHistoryScopes({
      clientName: "Tremblay",
      clientPhone: "5145554321",
      employeeIds,
      employeeNames,
    });
    expect(scopes.length).toBeLessThanOrEqual(TOKEN_FIELD_LIMIT);
    expect(scopes).toContain("all:p:5145554321");
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
  // Shared value-for-value with the Dart twin's `historyEntryMatches` seam
  // test: the two sides must not disagree about whether a query may span the
  // join between the client name and a crew name.
  const appointment = {
    clientName: "Marie Tremblay",
    employeeNames: ["Marc Dubois"],
    clientPhone: "5145554321",
  };

  test("does not match across the client/employee seam", () => {
    expect(recordMatchesQuery(appointment, "tremblay marc")).toBe(false);
  });

  test("still matches within either field", () => {
    expect(recordMatchesQuery(appointment, "marie tremblay")).toBe(true);
    expect(recordMatchesQuery(appointment, "marc dubois")).toBe(true);
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
