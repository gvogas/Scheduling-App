"use strict";

const {buildCustomerPayload, statePatch, verdictPatch, waveStateFields,
  isBlocked} = require("../wave/customer_contract");
const {IMPORT_FIELD_CAPS} = require("../wave/mappers");

/**
 * A client doc that the contract accepts, so each test can break exactly one
 * thing and attribute the problem to it.
 * @param {!Object=} over Fields to override.
 * @return {!Object} Client document fields.
 */
function client(over = {}) {
  return {
    name: "Vogas Plumbing",
    firstName: "",
    lastName: "",
    email: "",
    phone: "(514) 555-1234",
    mobile: "",
    address: "4450 Prom. Paton",
    addressLine2: "",
    apt: "",
    city: "Laval",
    province: "QC",
    country: "Canada",
    postalCode: "H7W 5J7",
    type: "commercial",
    ...over,
  };
}

describe("buildCustomerPayload", () => {
  test("accepts an ordinary client and returns a payload and a hash", () => {
    const out = buildCustomerPayload(client());
    expect(out.ok).toBe(true);
    expect(out.payload.name).toBe("Vogas Plumbing");
    expect(typeof out.hash).toBe("string");
    expect(out.hash).toHaveLength(64);
  });

  test("refuses a blank name", () => {
    // The 2026-08-30 dead-letter: composeStored's business branch reduced a
    // business named only by its own number to "", toWaveCustomerInput sends
    // `name` unconditionally, and Wave refuses a blank customer name. It was
    // non-retryable, so it died on every push forever.
    const out = buildCustomerPayload(client({name: ""}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
    expect(out.payload).toBeUndefined();
  });

  test("refuses a whitespace-only name", () => {
    const out = buildCustomerPayload(client({name: "   "}));
    expect(out.ok).toBe(false);
    expect(out.problems[0]).toEqual(
        {field: "name", code: "EMPTY", severity: "blocking", detail: null});
  });

  test("refuses a name past Wave's 200-character cap", () => {
    // firestore.rules permits 225 (sized for the old "<name> <phone>" shape,
    // and it must STAY there — a cap below a stored value makes that doc
    // permanently un-updatable). So the contract is what catches this.
    const out = buildCustomerPayload(client({name: "a".repeat(218)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "name", code: "TOO_LONG", severity: "blocking",
        detail: {length: 218, cap: 200}},
    ]);
  });

  test("accepts a name exactly at the cap", () => {
    expect(buildCustomerPayload(client({name: "a".repeat(200)})).ok)
        .toBe(true);
  });

  test("refuses an address past Wave's 500-character cap", () => {
    const out = buildCustomerPayload(client({address: "a".repeat(520)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "address", code: "TOO_LONG", severity: "blocking",
        detail: {length: 520, cap: 500}},
    ]);
  });

  test("blames `address` when apt + address together exceed the cap", () => {
    // addressLine1 is the two joined, so each can be legal alone and the
    // composed line still refused. The admin edits `address`, so that is what
    // the problem names.
    const out = buildCustomerPayload(
        client({apt: "1108", address: "a".repeat(498)}));
    expect(out.ok).toBe(false);
    expect(out.problems[0].field).toBe("address");
    expect(out.problems[0].code).toBe("TOO_LONG");
  });

  test("reports every over-long field, not just the first", () => {
    const out = buildCustomerPayload(client({
      name: "a".repeat(201),
      city: "b".repeat(129),
    }));
    expect(out.ok).toBe(false);
    expect(out.problems.map((p) => p.field).sort()).toEqual(["city", "name"]);
  });

  test("refuses an email Wave would reject", () => {
    for (const email of ["nope", "a@b", "a b@example.com", "@example.com"]) {
      const out = buildCustomerPayload(client({email}));
      expect(out.ok).toBe(false);
      expect(out.problems[0])
          .toEqual({field: "email", code: "INVALID_EMAIL", severity: "blocking",
            detail: null});
    }
  });

  test("accepts ordinary and plus-addressed email", () => {
    for (const email of ["marc@example.com", "marc+wave@sub.example.co.uk"]) {
      expect(buildCustomerPayload(client({email})).ok).toBe(true);
    }
  });

  test("an absent email is not a problem", () => {
    // `presence` omits an empty optional, so there is nothing to validate.
    expect(buildCustomerPayload(client({email: ""})).ok).toBe(true);
  });

  test("accepts every phone shape the app legitimately stores", () => {
    // The formatted NANP form, the bare form, an international number and an
    // extension all reach Wave today and are accepted.
    for (const phone of ["(514) 555-1234", "5145551234", "+33 1 42 68 53 00",
      "514-555-1234 x22"]) {
      expect(buildCustomerPayload(client({phone})).ok).toBe(true);
    }
  });

  test("still SYNCS a phone with no digits, but reports it", () => {
    // Client 2wcEiCNztsWYUYNXYBEm stores "Contact Person" in `phone` and Wave
    // has it SYNCED with that string as the customer's phone number — so
    // blocking it would strand a client Wave accepts. It is still wrong:
    // nothing can dial it. Advisory is what lets both be true.
    const out = buildCustomerPayload(client({phone: "Contact Person"}));
    expect(out.ok).toBe(true);
    expect(out.payload.phone).toBe("Contact Person");
    expect(out.problems).toEqual([
      {field: "phone", code: "NOT_DIALABLE", severity: "advisory",
        detail: null},
    ]);
  });

  test("an ordinary client reports no problems at all", () => {
    expect(buildCustomerPayload(client()).problems).toEqual([]);
  });

  test("an advisory alongside a blocking problem still blocks", () => {
    const out = buildCustomerPayload(
        client({name: "", phone: "Contact Person"}));
    expect(out.ok).toBe(false);
    expect(out.payload).toBeUndefined();
    expect(out.problems.map((p) => p.code).sort())
        .toEqual(["EMPTY", "NOT_DIALABLE"]);
  });

  test("still caps an over-long phone", () => {
    // Dropping the shape rule must not drop the LENGTH rule, which is a real
    // documented Wave limit rather than a guess.
    const out = buildCustomerPayload(client({phone: "5".repeat(33)}));
    expect(out.ok).toBe(false);
    expect(out.problems[0])
        .toEqual({field: "phone", code: "TOO_LONG",
          severity: "blocking", detail: {length: 33, cap: 32}});
  });
});

describe("historical incidents", () => {
  // Each case dead-lettered a real client permanently in production. They are
  // named so a regression cannot come back anonymously.

  test("2026-08-15: a New York client is never sent as CA-NY", () => {
    // provinceCode had an unconditional `CA-` prefix, so a US client shipped
    // as a subdivision of nowhere. Enums are not an inputErrors entry — the
    // whole $input fails to coerce, arriving as a non-retryable
    // WaveApiError(graphql). Nothing recovered it.
    const out = buildCustomerPayload(client({
      city: "Brooklyn", province: "NY", country: "United States",
      postalCode: "11201",
    }));
    expect(out.ok).toBe(true);
    expect(out.payload.address.countryCode).toBe("US");
    expect(out.payload.address.provinceCode).toBe("US-NY");
  });

  test("2026-08-15: an unknown province is omitted, never guessed", () => {
    const out = buildCustomerPayload(client({province: "Ontari"}));
    expect(out.ok).toBe(true);
    expect(out.payload.address.provinceCode).toBeUndefined();
  });

  test("2026-08-30: a business named only by its phone is refused", () => {
    // Client o0KcOnJSgjvMHYpmcZ44. `type: building` with a name that
    // composeStored had reduced to "". Wave refuses a blank customer name.
    const out = buildCustomerPayload(client({
      name: "", firstName: "", lastName: "", type: "building",
      phone: "(514) 458-6186",
    }));
    expect(out.ok).toBe(false);
    expect(out.problems).toContainEqual(
        {field: "name", code: "EMPTY", severity: "blocking", detail: null});
  });

  test("latent: a legacy 225-character name is refused, not dead-lettered",
      () => {
        const out = buildCustomerPayload(client({name: "a".repeat(225)}));
        expect(out.ok).toBe(false);
        expect(out.problems).toContainEqual({
          field: "name", code: "TOO_LONG", severity: "blocking",
          detail: {length: 225, cap: 200},
        });
      });

  test("latent: a legacy 533-character address is refused", () => {
    const out = buildCustomerPayload(client({address: "a".repeat(533)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toContainEqual({
      field: "address", code: "TOO_LONG", severity: "blocking",
      detail: {length: 533, cap: 500},
    });
  });
});

describe("statePatch", () => {
  test("records the problems AND blocks when a client cannot be sent", () => {
    expect(statePatch(client({name: ""}))).toEqual({
      "wave.problems": [
        {field: "name", code: "EMPTY", severity: "blocking", detail: null},
      ],
      "wave.syncState": "blocked",
      // A refused client never reaches Wave, so an error left from an earlier
      // push describes a push that will never be retried.
      "wave.syncError": null,
    });
  });

  test("records an ADVISORY problem WITHOUT blocking", () => {
    // The push is fine and the client syncs; the admin must still see it.
    // Collapsing the two severities strands a client Wave is happy with.
    expect(statePatch(client({phone: "Contact Person"}))).toEqual({
      "wave.problems": [
        {field: "phone", code: "NOT_DIALABLE", severity: "advisory",
          detail: null},
      ],
    });
  });

  test("clears the field when a client is fine", () => {
    // Explicitly null rather than omitted: a client REPAIRED since the last
    // write must not keep stale problems on its doc.
    expect(statePatch(client())).toEqual({"wave.problems": null});
  });

  test("leaves syncState alone for a clean client by default", () => {
    // A clean client's state belongs to the PUSH (`pending` -> `synced` /
    // `error`); stamping it here would fight the worker for it.
    expect(Object.keys(statePatch(client()))).toEqual(["wave.problems"]);
  });

  test("writes the cleared state when the caller asks for one", () => {
    // The import owns the doc it just wrote, so it names the state itself.
    expect(statePatch(client(), {clearedState: "synced"})).toEqual({
      "wave.problems": null,
      "wave.syncState": "synced",
      "wave.syncError": null,
    });
  });

  test("a blocking problem overrides the requested cleared state", () => {
    expect(statePatch(client({name: ""}), {clearedState: "synced"}))
        .toMatchObject({"wave.syncState": "blocked"});
  });

  test("every key is DOTTED, so a merge cannot replace the wave map", () => {
    // A nested `wave` object under `merge: true` replaces the whole map, which
    // is how the import erased `wave.problems` and un-blocked a client.
    for (const key of Object.keys(statePatch(client({name: ""})))) {
      expect(key.startsWith("wave.")).toBe(true);
    }
  });
});

describe("verdictPatch", () => {
  test("agrees with statePatch over the same client", () => {
    // The dispatcher blocks from a verdict it already holds. If the two ever
    // disagree, a client's recorded reason stops describing why it was
    // refused — so this equality is the point of the second entry point.
    for (const fields of [
      client(),
      client({name: ""}),
      client({phone: "Contact Person"}),
      client({email: "not-an-address"}),
    ]) {
      expect(verdictPatch(buildCustomerPayload(fields))).toEqual(
          statePatch(fields));
      expect(verdictPatch(buildCustomerPayload(fields),
          {clearedState: "synced"}))
          .toEqual(statePatch(fields, {clearedState: "synced"}));
    }
  });

  test("tolerates a verdict carrying no problems array", () => {
    expect(verdictPatch({ok: true})).toEqual({"wave.problems": null});
  });
});

describe("waveStateFields", () => {
  test("un-dots the same verdict the update branch merges", () => {
    // The create branch nests; it must nest exactly what an update would set,
    // or a client's Wave state depends on which path wrote it.
    const patch = statePatch(client({name: ""}), {clearedState: "synced"});
    expect(waveStateFields(patch)).toEqual({
      syncState: "blocked",
      syncError: null,
      problems: patch["wave.problems"],
    });
  });

  test("carries the cleared state through for a clean client", () => {
    const patch = statePatch(client(), {clearedState: "synced"});
    expect(waveStateFields(patch)).toEqual({
      syncState: "synced",
      syncError: null,
      problems: null,
    });
  });
});

describe("isBlocked", () => {
  test("is true only for a blocking problem", () => {
    expect(isBlocked(client({name: ""}))).toBe(true);
    expect(isBlocked(client({phone: "Contact Person"}))).toBe(false);
    expect(isBlocked(client())).toBe(false);
  });
});

describe("PAYLOAD_CAPS derives from IMPORT_FIELD_CAPS", () => {
  // The caps are not restated in `customer_contract.js` -- they are read from
  // the one map that owns them, which `text_limits_test.dart` already pins
  // against the firestore.rules caps. These assert the READ still resolves,
  // because the failure mode is silent and total: `overLongProblems` compares
  // `value.length <= rule.cap`, and that is false for an undefined cap, so a
  // field renamed in `mappers.js` would report EVERY client as TOO_LONG rather
  // than leaving one field unchecked.
  test("a value at exactly Wave's cap is accepted, one over is refused", () => {
    for (const [field, payloadField] of [
      ["name", "name"],
      ["email", "email"],
      ["address", "address"],
    ]) {
      const cap = IMPORT_FIELD_CAPS[field];
      expect(typeof cap).toBe("number");

      const atCap = buildCustomerPayload(client({[field]: "x".repeat(cap)}));
      expect(atCap.problems.filter((p) => p.code === "TOO_LONG")).toEqual([]);

      const overCap =
        buildCustomerPayload(client({[field]: "x".repeat(cap + 1)}));
      expect(overCap.problems).toContainEqual({
        field: payloadField,
        code: "TOO_LONG",
        severity: "blocking",
        detail: {length: cap + 1, cap},
      });
    }
  });

  test("mobile is capped, though the import map has no mobile entry", () => {
    // The import folds Wave's mobile into `phone`, so `IMPORT_FIELD_CAPS` has
    // no `mobile` key by design -- but the PUSH direction sends both, and an
    // uncapped one dead-letters. It borrows `phone`'s cap.
    expect(IMPORT_FIELD_CAPS.mobile).toBeUndefined();
    const cap = IMPORT_FIELD_CAPS.phone;

    expect(buildCustomerPayload(client({mobile: "5".repeat(cap)})).problems)
        .toEqual([]);
    expect(buildCustomerPayload(client({mobile: "5".repeat(cap + 1)})).problems)
        .toContainEqual({
          field: "mobile", code: "TOO_LONG", severity: "blocking",
          detail: {length: cap + 1, cap},
        });
  });
});
