"use strict";

const {
  bareNumber,
  clientDisplayName,
  composeStored,
  digitsOf,
  formatNanpNumber,
  isBusiness,
  liftPhoneFromName,
  stripPhone,
  looksLikeBusinessName,
} = require("../client_name_utils");

/**
 * These worked examples are DELIBERATELY the same ones
 * `test/features/clients/domain/client_name_policy_test.dart` uses. That file
 * and `client_name_utils.js` are hand-mirrors of one rule, so a divergence
 * between the two implementations has to fail a test rather than ship — the
 * same discipline `appointment_day_slice` / `day_slice_utils` already uses.
 * liftPhoneFromName reads test/fixtures/shared/client_name_lift.json.
 */
describe("stripPhone", () => {
  test("removes the number this app appended", () => {
    expect(stripPhone("Marc Tremblay (514) 555-1234",
        {phone: "(514) 555-1234"})).toBe("Marc Tremblay");
  });

  test("removes a legacy number typed in another shape", () => {
    expect(stripPhone("Marc Tremblay 514-555-1234",
        {phone: "(514) 555-1234"})).toBe("Marc Tremblay");
  });

  test("matches an 11-digit form against the stored 10-digit one", () => {
    expect(stripPhone("Marc Tremblay 1-514-555-1234",
        {phone: "(514) 555-1234"})).toBe("Marc Tremblay");
  });

  test("falls back to mobile when phone is empty", () => {
    expect(stripPhone("Marc Tremblay (514) 555-1234",
        {mobile: "(514) 555-1234"})).toBe("Marc Tremblay");
  });

  test("leaves a trailing number that is NOT this client's", () => {
    expect(stripPhone("Depanneur 5148889999",
        {phone: "(514) 555-1234"})).toBe("Depanneur 5148889999");
  });

  test("leaves the name alone when the doc has no number at all", () => {
    expect(stripPhone("Marc Tremblay 514-555-1234"))
        .toBe("Marc Tremblay 514-555-1234");
  });

  test("returns empty when the name is nothing but the number", () => {
    expect(stripPhone("(514) 555-1234", {phone: "(514) 555-1234"})).toBe("");
  });

  test("is idempotent", () => {
    const once = stripPhone("Marc Tremblay (514) 555-1234",
        {phone: "(514) 555-1234"});
    expect(stripPhone(once, {phone: "(514) 555-1234"})).toBe(once);
  });
});

describe("composeStored", () => {
  test("names a PERSON by their phone number, BARE", () => {
    // The `phone` field keeps its formatting; only the Wave customer name is
    // reduced (owner call 2026-08-16).
    expect(composeStored({
      baseName: "Marc Tremblay",
      phone: "(514) 555-1234",
    })).toBe("5145551234");
  });

  test("is idempotent", () => {
    // The backfill is re-runnable and every ordinary save goes through this,
    // so a second pass over an already-composed name must be a no-op.
    expect(composeStored({
      baseName: "5145551234",
      phone: "(514) 555-1234",
    })).toBe("5145551234");
  });

  test("reduces a name still stored in the formatted shape", () => {
    // `stripPhone` digit-matches, which is what carries the docs written
    // before the bare rule over to it.
    expect(composeStored({
      baseName: "(514) 555-1234",
      phone: "(514) 555-1234",
    })).toBe("5145551234");
  });

  test("keeps the country code of an international number", () => {
    // `digitsOf` sheds a leading 1 for COMPARISON; `bareNumber` must not, or a
    // country code the admin typed is silently dropped from a stored value.
    expect(composeStored({
      baseName: "Amelie Roy",
      phone: "+33 1 42 68 53 00",
    })).toBe("+33142685300");
  });

  test("keeps a BUSINESS name — that is its identity in Wave", () => {
    expect(composeStored({
      baseName: "Vogas Plumbing",
      phone: "(514) 555-1234",
      type: "commercial",
    })).toBe("Vogas Plumbing");
  });

  test("keeps a business recognisable only by its NAME", () => {
    // The Wave import sets no `type`, so these carry none.
    for (const name of ["3101-5696 qc inc.", "1505 Village de Bergerac",
      "Information technology group", "Condo 706",
      "Syndicat de copropriété du Parc"]) {
      expect(composeStored({baseName: name, phone: "(514) 555-1234"}))
          .toBe(name);
    }
  });

  test("leaves the name bare when there is no phone", () => {
    expect(composeStored({baseName: "Marc Tremblay", phone: ""}))
        .toBe("Marc Tremblay");
  });

  test("a nameless client is stored as its number, not as blank", () => {
    expect(composeStored({baseName: "", phone: "(514) 555-1234"}))
        .toBe("5145551234");
  });

  test("a BUSINESS named only by its own number keeps the number", () => {
    // `stripPhone` correctly reduces such a name to "" — it IS nothing but
    // this client's number — and the business branch used to return that
    // blank. An empty `name` is rejected by Wave on every push, so the
    // customer dead-letters permanently and "Retry failed" re-sends the same
    // refusal (client o0KcOnJSgjvMHYpmcZ44, 2026-08-30). A business has no
    // first/last to fall back on, so the number is the only identity left.
    for (const type of ["commercial", "building"]) {
      expect(composeStored({
        baseName: "5144586186",
        phone: "(514) 458-6186",
        type,
      })).toBe("5144586186");
    }
    expect(composeStored({
      baseName: "(514) 458-6186",
      phone: "(514) 458-6186",
      businessName: "3101-5696 qc inc.",
    })).toBe("5144586186");
  });

  test("never returns blank while a base name or a number exists", () => {
    // The invariant the case above is one instance of: `name` is the Wave
    // customer identity, so composing one away is never the right answer.
    for (const type of ["commercial", "building", "residential", ""]) {
      expect(composeStored({
        baseName: "514-458-6186",
        phone: "(514) 458-6186",
        mobile: "",
        type,
      })).not.toBe("");
    }
  });
});

describe("bareNumber", () => {
  test("takes the punctuation off a stored number", () => {
    expect(bareNumber("(514) 555-1234")).toBe("5145551234");
    expect(bareNumber("514-555-1234")).toBe("5145551234");
  });

  test("keeps a leading + so an international number stays dialable", () => {
    expect(bareNumber("+33 1 42 68 53 00")).toBe("+33142685300");
  });

  test("KEEPS the leading 1 that digitsOf sheds", () => {
    // The two are not interchangeable: `digitsOf` normalizes for comparison,
    // `bareNumber` produces a value that gets STORED and pushed to Wave.
    expect(bareNumber("1-514-555-1234")).toBe("15145551234");
    expect(digitsOf("1-514-555-1234")).toBe("5145551234");
  });

  test("hands back anything it cannot reduce", () => {
    // Better than blanking an entry the admin can still read.
    expect(bareNumber("  ext. only  ")).toBe("ext. only");
    expect(bareNumber("")).toBe("");
  });
});

describe("clientDisplayName — a PERSON shows their halves", () => {
  test("prefers the first/last halves over the stored name", () => {
    expect(clientDisplayName({
      name: "Marc Tremblay (514) 555-1234",
      phone: "(514) 555-1234",
      firstName: "Marc",
      lastName: "Tremblay",
      type: "residential",
    })).toBe("Marc Tremblay");
  });

  test("takes a single half on its own", () => {
    expect(clientDisplayName({
      name: "Marc (514) 555-1234",
      phone: "(514) 555-1234",
      firstName: "Marc",
    })).toBe("Marc");
  });

  test("falls back to the stored name with the number stripped", () => {
    expect(clientDisplayName({
      name: "Marc Tremblay (514) 555-1234",
      phone: "(514) 555-1234",
    })).toBe("Marc Tremblay");
  });

  test("a bare number beats an empty display name", () => {
    expect(clientDisplayName({
      name: "(514) 555-1234",
      phone: "(514) 555-1234",
    })).toBe("(514) 555-1234");
  });

  test("tolerates a missing or non-object doc", () => {
    expect(clientDisplayName({})).toBe("");
    expect(clientDisplayName(null)).toBe("");
  });
});

describe("clientDisplayName — a BUSINESS shows its business name", () => {
  test("a commercial client keeps its business name", () => {
    // The load-bearing case: first/last is the CONTACT PERSON here, so
    // preferring the halves would fan a person's name onto every appointment
    // booked for the company.
    expect(clientDisplayName({
      name: "Vogas Plumbing (514) 555-1234",
      phone: "(514) 555-1234",
      firstName: "Marc",
      lastName: "Tremblay",
      type: "commercial",
    })).toBe("Vogas Plumbing");
  });

  test("property management counts as a business", () => {
    expect(clientDisplayName({
      name: "Gestion Immobiliere ABC",
      firstName: "Marc",
      lastName: "Tremblay",
      type: "building",
    })).toBe("Gestion Immobiliere ABC");
  });

  test("a legacy businessName doc is a business even with no type", () => {
    expect(clientDisplayName({
      name: "Acme Industries",
      businessName: "Acme Industries",
      firstName: "Marc",
      lastName: "Tremblay",
    })).toBe("Acme Industries");
  });

  test("falls back to the legacy businessName when name is blank", () => {
    expect(clientDisplayName({name: "", businessName: "Acme Inc"}))
        .toBe("Acme Inc");
  });

  test("falls back to the contact person with no company name on file", () => {
    expect(clientDisplayName({
      name: "(514) 555-1234",
      phone: "(514) 555-1234",
      firstName: "Marc",
      lastName: "Tremblay",
      type: "commercial",
    })).toBe("Marc Tremblay");
  });
});

describe("isBusiness", () => {
  test("the two organization types", () => {
    expect(isBusiness({type: "commercial"})).toBe(true);
    expect(isBusiness({type: "building"})).toBe(true);
  });

  test("a residential or untyped client is a person", () => {
    expect(isBusiness({type: "residential"})).toBe(false);
    expect(isBusiness({})).toBe(false);
    expect(isBusiness(null)).toBe(false);
  });

  test("a legacy businessName makes it a business regardless of type", () => {
    expect(isBusiness({businessName: "Acme Inc"})).toBe(true);
  });
});

describe("formatNanpNumber", () => {
  // The full set lives in `backfill_client_phone_formatting.test.js`, which
  // reads this function back off the script that re-exports it. These are the
  // cases the Wave import leans on.
  test("renders a NANP number the way the app stores one", () => {
    expect(formatNanpNumber("5145551234")).toBe("(514) 555-1234");
    expect(formatNanpNumber("+1 514 555 1234")).toBe("(514) 555-1234");
  });

  test("null means leave it alone", () => {
    // Idempotence, and the bar that keeps a foreign number unmangled.
    expect(formatNanpNumber("(514) 555-1234")).toBeNull();
    expect(formatNanpNumber("+33 1 23 45 67 89")).toBeNull();
    expect(formatNanpNumber("")).toBeNull();
  });
});

describe("liftPhoneFromName", () => {
  const {cases} = require("../../test/fixtures/shared/client_name_lift.json");

  test.each(cases)("$name", (c) => {
    expect(["expectNull", "expectName", "expectPhone", "expectPhoneDigits"]
        .some((k) => k in c)).toBe(true);
    const lifted = liftPhoneFromName({name: c.input, phone: c.phone});
    if (c.expectNull) {
      expect(lifted).toBeNull();
      return;
    }
    expect(lifted).not.toBeNull();
    if ("expectName" in c) expect(lifted.name).toBe(c.expectName);
    if ("expectPhone" in c) expect(lifted.phone).toBe(c.expectPhone);
    if ("expectPhoneDigits" in c) {
      expect(lifted.phone.replace(/\D/g, "")).toBe(c.expectPhoneDigits);
    }
  });
});

describe("looksLikeBusinessName word boundary", () => {
  // The NEGATIVES are the point. If this boundary ever degrades to a bare
  // substring test, every Prince/Vince keeps a typed name instead of their
  // phone number — the direct inverse of the `clients/{id}.name` rule, and
  // the same shape as the destroyed-names incident in this repo's history.
  test.each([
    ["Prince Adjei"],
    ["Princess Ncube"],
    ["Vince Carter"],
    ["Incze Gabor"],
    ["Vincent Leblanc"],
    ["Lincoln Reyes"],
  ])("%s is a PERSON, not a business", (name) => {
    expect(looksLikeBusinessName(name)).toBe(false);
  });

  test.each([
    ["Groupe ABC"],
    ["Residences Soleil"],
    ["Ltee Inc"],
    ["Plomberie Inc."],
    ["Gestion Immobilier"],
  ])("%s reads as a BUSINESS", (name) => {
    expect(looksLikeBusinessName(name)).toBe(true);
  });

  test("an accented residence still matches after folding", () => {
    expect(looksLikeBusinessName("Résidences du Parc")).toBe(true);
  });

  test("any digit reads as a business", () => {
    expect(looksLikeBusinessName("3101-5696 qc")).toBe(true);
  });

  test("a blank or non-string name is not a business", () => {
    // `str()` rejects a non-string before the digit test runs, so a numeric
    // name is NOT treated as a business.
    expect(looksLikeBusinessName("")).toBe(false);
    expect(looksLikeBusinessName(null)).toBe(false);
    expect(looksLikeBusinessName(undefined)).toBe(false);
    expect(looksLikeBusinessName(42)).toBe(false);
  });
});
