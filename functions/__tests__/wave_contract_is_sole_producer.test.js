"use strict";

/**
 * @fileoverview The contract is the ONLY producer of a Wave customer payload.
 *
 * That is the mechanism the whole rearchitecture rests on: if any other module
 * can build a payload, one can be built that skipped validation, and the
 * permanent dead-letter comes back. The design proposed enforcing it by making
 * `toWaveCustomerInput` private to `customer_contract.js`.
 *
 * It stays exported instead, and this file is why that is still safe.
 * `wave/mappers.js` owns the projection and ~50 of its own unit tests drive it
 * directly — including `null`/`undefined` inputs the contract refuses outright,
 * which cannot be expressed through `buildCustomerPayload`. Re-pointing them
 * would couple the mapping layer's tests to the contract's verdicts and delete
 * coverage in the process.
 *
 * So the boundary is enforced by READING THE SOURCE back, the same way
 * `firebase_appointments_repository_invalidation_test.dart` enforces its own
 * write-path rule: a new production call site is a test failure, not a silent
 * hole. `mappers.js` itself is exempt (it owns the function) and so is
 * `customer_contract.js` (it is the sanctioned consumer).
 */

const fs = require("fs");
const path = require("path");

const FUNCTIONS_DIR = path.join(__dirname, "..");

/** Modules allowed to call `toWaveCustomerInput`. @const {!Set<string>} */
const ALLOWED = new Set([
  path.join("wave", "mappers.js"),
  path.join("wave", "customer_contract.js"),
]);

/**
 * Every production `.js` file under `functions/`, excluding tests, scripts and
 * dependencies.
 * @param {string} dir Directory to walk.
 * @param {!Array<string>=} out Accumulator.
 * @return {!Array<string>} Absolute file paths.
 */
function productionFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (["node_modules", "__tests__", "scripts", "coverage"]
          .includes(entry.name)) {
        continue;
      }
      productionFiles(full, out);
    } else if (entry.name.endsWith(".js")) {
      out.push(full);
    }
  }
  return out;
}

describe("the customer contract is the sole payload producer", () => {
  const files = productionFiles(FUNCTIONS_DIR);

  test("the walk actually found the Wave modules", () => {
    // A guard that scans nothing passes vacuously, which is the failure shape
    // this whole file exists to avoid.
    const relative = files.map((f) => path.relative(FUNCTIONS_DIR, f));
    expect(relative).toContain(path.join("wave", "customers.js"));
    expect(relative).toContain(path.join("wave", "triggers.js"));
    expect(relative).toContain(path.join("wave", "worker.js"));
    expect(files.length).toBeGreaterThan(20);
  });

  test("no other production module calls toWaveCustomerInput", () => {
    const offenders = [];
    for (const file of files) {
      const relative = path.relative(FUNCTIONS_DIR, file);
      if (ALLOWED.has(relative)) continue;
      const source = fs.readFileSync(file, "utf8");
      // Strip comments: several modules NAME the function while explaining
      // why they no longer call it, and a prose mention is not a call site.
      const code = source
          .replace(/\/\*[\s\S]*?\*\//g, "")
          .replace(/(^|[^:])\/\/.*$/gm, "$1");
      if (code.includes("toWaveCustomerInput")) offenders.push(relative);
    }
    expect(offenders).toEqual([]);
  });

  test("upsertCustomer builds through buildCustomerPayload", () => {
    const source = fs.readFileSync(
        path.join(FUNCTIONS_DIR, "wave", "customers.js"), "utf8");
    expect(source).toContain("buildCustomerPayload(data)");
  });

  test("the enqueue trigger asks the contract before queueing anything", () => {
    const source = fs.readFileSync(
        path.join(FUNCTIONS_DIR, "wave", "triggers.js"), "utf8");
    const gate = source.indexOf("buildCustomerPayload(after)");
    const refuse = source.indexOf("if (!contract.ok)");
    const enqueue = source.indexOf("enqueueCustomerUpsert(clientId");
    expect(gate).toBeGreaterThan(-1);
    expect(refuse).toBeGreaterThan(-1);
    // The refusal has to come FIRST, or a refused client is queued anyway.
    expect(gate).toBeLessThan(refuse);
    expect(refuse).toBeLessThan(enqueue);
  });
});
