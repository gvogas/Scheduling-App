"use strict";

/**
 * Tests for the pure core of the client -> future-appointments propagation
 * trigger, propagateClientEdits. The actual Firestore fan-out
 * (propagateClientChange) is integration-heavy, so it isn't covered here.
 */

const {
  clientDisplayName,
  relevantClientChange,
  buildAppointmentPatch,
  propagateClientChange,
} = require("../client_propagation");

const {MAX_APPOINTMENT_SPAN_MS} = require("../time_utils");

/**
 * Minimal Firestore double: one page of appointment docs, capturing the
 * query's startTime floor and every batch update.
 * @param {!Array<!Object>} docs Appointment doc data, each with an `id`.
 * @return {!Object}
 */
function makeDb(docs) {
  const captured = {floor: null, updates: []};
  const snapDocs = docs.map((data) => ({
    data: () => data,
    ref: {id: data.id},
  }));
  const query = {
    where(field, op, value) {
      if (field === "startTime") captured.floor = value;
      return query;
    },
    orderBy: () => query,
    limit: () => query,
    startAfter: () => query,
    get: async () => ({docs: snapDocs}),
  };
  return {
    captured,
    collection: () => query,
    batch: () => ({
      update: (ref, patch) => captured.updates.push({id: ref.id, patch}),
      commit: async () => {},
    }),
  };
}

describe("clientDisplayName", () => {
  test("uses name when present, trimmed", () => {
    expect(clientDisplayName({name: "  Ada  "})).toBe("Ada");
  });

  test("falls back to businessName when name is blank", () => {
    expect(clientDisplayName({name: "", businessName: "Acme Inc"}))
        .toBe("Acme Inc");
  });

  test("returns empty string when both are blank or missing", () => {
    expect(clientDisplayName({})).toBe("");
    expect(clientDisplayName(null)).toBe("");
  });
});

describe("relevantClientChange", () => {
  test("returns null when nothing relevant changed", () => {
    const doc = {name: "Ada", phone: "555", address: "1 St"};
    expect(relevantClientChange(doc, {...doc})).toBeNull();
  });

  test("detects a name change", () => {
    const change = relevantClientChange({name: "Ada"}, {name: "Bea"});
    expect(change).toEqual({clientName: "Bea", address: null});
  });

  test("detects a phone change", () => {
    const change = relevantClientChange({phone: "111"}, {phone: "222"});
    expect(change).toEqual({clientPhone: "222", address: null});
  });

  // The stored `name` IS the Wave customer name — a phone number on a person —
  // so what propagates onto an appointment must be the DISPLAY name. Without
  // these two, a "cleanup" dropping the strip would put phone numbers on every
  // appointment card with nothing failing.
  test("propagates the DISPLAY name, never the stored number", () => {
    const change = relevantClientChange(
        {name: "(514) 555-1234", phone: "(514) 555-1234",
          firstName: "Marc", lastName: "Tremblay"},
        {name: "(514) 555-1234", phone: "(514) 555-1234",
          firstName: "Marc", lastName: "Gagnon"});
    expect(change).toEqual({clientName: "Marc Gagnon", address: null});
  });

  test("a phone-only edit produces NO clientName patch", () => {
    // The number moves, but a person's display name is their halves — so the
    // denormalized `clientName` on every appointment must stay put.
    const change = relevantClientChange(
        {name: "(514) 555-1234", phone: "(514) 555-1234",
          firstName: "Marc", lastName: "Tremblay"},
        {name: "(438) 555-9876", phone: "(438) 555-9876",
          firstName: "Marc", lastName: "Tremblay"});
    expect(change).toEqual({clientPhone: "(438) 555-9876", address: null});
    expect(change.clientName).toBeUndefined();
  });

  test("detects a name change via the legacy businessName fallback", () => {
    const change = relevantClientChange(
        {name: "", businessName: "Old Co"},
        {name: "", businessName: "New Co"});
    expect(change).toEqual({clientName: "New Co", address: null});
  });

  test("propagates an address change from a NON-EMPTY previous value", () => {
    const change = relevantClientChange(
        {address: "1 Old St"}, {address: "2 New Rd"});
    expect(change).toEqual({address: {from: "1 Old St", to: "2 New Rd"}});
  });

  test("normalizing `address` to the street line propagates NOTHING", () => {
    // The safety property the address backfill rests on. An appointment holds
    // ONE address string and no city/province/postal of its own, so fanning a
    // stripped street onto it would destroy the locality with nothing left to
    // rebuild from. Both shapes compose to the same string, so the change is
    // invisible here.
    const locality = {
      city: "Montréal", province: "QC", postalCode: "H2X 1Y4",
      country: "Canada",
    };
    const change = relevantClientChange(
        {address: "1234 Rue Principale, Montréal, QC H2X 1Y4, Canada",
          ...locality},
        {address: "1234 Rue Principale", ...locality});
    expect(change).toBeNull();
  });

  test("an apt-bearing client MATCHES what the app actually books", () => {
    // The values below are the DISPLAY spelling, which is what the app writes
    // into `appointments.address` (it seeds `client.fullAddress`, and did the
    // equivalent before the split). `buildAppointmentPatch` compares `from`
    // to that string verbatim, so this is the case that decides whether an
    // apt-bearing client's address correction reaches their jobs at all.
    // Until 2026-08-28 this composed "4-1234 ..." and asserted it against
    // itself, so it passed while the propagation silently matched nothing.
    const locality = {city: "Montréal", province: "QC"};
    const change = relevantClientChange(
        {address: "4-1234 Rue Principale", ...locality},
        {address: "4-1234 Rue Sherbrooke", ...locality});
    expect(change.address.from)
        .toBe("1234 Rue Principale #4, Montréal, QC");
    expect(change.address.to)
        .toBe("1234 Rue Sherbrooke #4, Montréal, QC");
  });

  test("an apt-bearing client's booked address is PATCHED, end to end", () => {
    // The regression this whole pair exists for: the appointment holds the
    // display spelling, so the patch must fire.
    const locality = {city: "Montréal", province: "QC"};
    const change = relevantClientChange(
        {address: "4-1234 Rue Principale", ...locality},
        {address: "4-1234 Rue Sherbrooke", ...locality});
    const patch = buildAppointmentPatch(
        change, {address: "1234 Rue Principale #4, Montréal, QC"});
    expect(patch).toEqual({address: "1234 Rue Sherbrooke #4, Montréal, QC"});
  });

  test("a CITY edit alone now reaches the appointment", () => {
    // The stored `address` is untouched by this edit, so comparing it raw saw
    // no change and the appointment kept the old city forever.
    const change = relevantClientChange(
        {address: "1 Rue Peel", city: "Laval"},
        {address: "1 Rue Peel", city: "Montréal"});
    expect(change.address).toEqual(
        {from: "1 Rue Peel, Laval", to: "1 Rue Peel, Montréal"});
  });

  test("does NOT propagate when the previous address was empty", () => {
    // An empty stored appointment address means custom/none. Matching on ""
    // would clobber those, so an empty-from change carries no instruction.
    expect(relevantClientChange({address: ""}, {address: "2 New Rd"}))
        .toBeNull();
  });
});

describe("buildAppointmentPatch", () => {
  test("patches clientName only when it differs", () => {
    const change = {clientName: "Bea"};
    const patch = buildAppointmentPatch(change, {clientName: "Ada"});
    expect(patch.clientName).toBe("Bea");
    expect(buildAppointmentPatch(change, {clientName: "Bea"})).toBeNull();
  });

  test("rebuilds the history tokens when the name or phone moves", () => {
    // Otherwise the job stays findable under the OLD name and vanishes under
    // the corrected one, with nothing rewriting it before it closes.
    const patch = buildAppointmentPatch(
        {clientName: "Bea"},
        {clientName: "Ada", employeeIds: ["emp1"]},
    );
    expect(patch.historySearchScopes).toContain("all:t:bea");
    expect(patch.historySearchScopes).toContain("emp:emp1:t:bea");
    expect(patch.historySearchScopes).not.toContain("all:t:ada");
  });

  test("patches clientPhone alone and indexes the phone tokens", () => {
    const patch = buildAppointmentPatch(
        {clientPhone: "5145554321"},
        {clientPhone: "5140000000", clientName: "Ada", employeeIds: ["e1"]},
    );
    expect(patch.clientPhone).toBe("5145554321");
    expect(patch.clientName).toBeUndefined();
    expect(patch.historySearchScopes).toContain("all:p:5145554321");
    expect(patch.historySearchScopes).not.toContain("all:p:5140000000");
  });

  test("leaves the tokens alone for an address-only patch", () => {
    const patch = buildAppointmentPatch(
        {address: {from: "1 Old St", to: "2 New Rd"}},
        {address: "1 Old St", clientName: "Ada"},
    );
    expect(patch.historySearchScopes).toBeUndefined();
  });

  test("follows the client address when the stored one matches from", () => {
    const change = {address: {from: "1 Old St", to: "2 New Rd"}};
    expect(buildAppointmentPatch(change, {address: "1 Old St"}))
        .toEqual({address: "2 New Rd"});
  });

  test("leaves a per-appointment custom address untouched", () => {
    const change = {address: {from: "1 Old St", to: "2 New Rd"}};
    expect(buildAppointmentPatch(change, {address: "Custom Site"})).toBeNull();
  });

  test("is idempotent: an already-propagated address is not re-patched", () => {
    const change = {address: {from: "1 Old St", to: "2 New Rd"}};
    expect(buildAppointmentPatch(change, {address: "2 New Rd"})).toBeNull();
  });
});

describe("propagateClientChange has-work-left gate", () => {
  const now = new Date("2026-08-04T12:00:00Z");
  const before = {name: "Ada", phone: "555"};
  const after = {name: "Bea", phone: "555"};
  const logger = {info: () => {}};

  test("queries back a full appointment span, not from now", async () => {
    const db = makeDb([]);
    await propagateClientChange("c1", before, after, {db, now, logger});
    expect(db.captured.floor.getTime())
        .toBe(now.getTime() - MAX_APPOINTMENT_SPAN_MS);
  });

  test("patches a run started days ago that is still under way", async () => {
    // Started Aug 1, runs through Aug 8 — the crew is on site right now.
    const db = makeDb([{
      id: "mid-run",
      startTime: new Date("2026-08-01T13:00:00Z"),
      endTime: new Date("2026-08-08T21:00:00Z"),
      clientName: "Ada",
    }]);

    const result =
        await propagateClientChange("c1", before, after, {db, now, logger});

    expect(result.updated).toBe(1);
    expect(db.captured.updates[0].id).toBe("mid-run");
    expect(db.captured.updates[0].patch.clientName).toBe("Bea");
  });

  test("leaves a finished run inside the widened window alone", async () => {
    // Pulled in by the wider floor, but its work ended yesterday — history
    // records what was true at the time of the visit.
    const db = makeDb([{
      id: "finished",
      startTime: new Date("2026-07-28T13:00:00Z"),
      endTime: new Date("2026-08-03T21:00:00Z"),
      clientName: "Ada",
    }]);

    const result =
        await propagateClientChange("c1", before, after, {db, now, logger});

    expect(result.updated).toBe(0);
    expect(db.captured.updates).toHaveLength(0);
  });

  test("falls back to startTime when endTime is missing", async () => {
    const db = makeDb([
      {id: "past-no-end", startTime: new Date("2026-08-01T13:00:00Z")},
      {id: "future-no-end", startTime: new Date("2026-08-06T13:00:00Z")},
    ]);

    const result =
        await propagateClientChange("c1", before, after, {db, now, logger});

    expect(result.updated).toBe(1);
    expect(db.captured.updates[0].id).toBe("future-no-end");
  });
});
