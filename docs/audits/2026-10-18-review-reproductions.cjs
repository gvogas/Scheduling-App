"use strict";

// Local-only demonstrations of defects found in the accompanying review.
// These assert the CURRENT faulty behavior, not the desired regression contract.
// Once a defect is fixed, convert its scenario into a test of correct behavior.
// No credentials, emulator, network requests, or production writes are used.
const assert = require("node:assert/strict");
const search = require("../../functions/search_tokens");
const {relevantClientChange, buildAppointmentPatch} =
  require("../../functions/client_propagation");
const {recountOne} = require("../../functions/client_job_count");
const {claimJob} = require("../../functions/wave/outbox_core");

async function main() {
  const rows = [
    ...Array.from({length: 200}, (_, i) => ({name: `Alice ${i}`})),
    {name: "Zoe Alice Target"},
  ];
  const query = "Alice Target";
  const tokens = search.searchQueryTokens(query);
  const candidates = rows.filter((row) => search.clientSearchTokens(row)
    .some((token) => tokens.includes(token)));
  assert.equal(candidates.filter((row) =>
    search.recordMatchesQuery(row, query)).length, 1);
  assert.equal(candidates.slice(0, 200).filter((row) =>
    search.recordMatchesQuery(row, query)).length, 0);
  console.log("REPRODUCED: search cap hides the only full match.");

  const first = relevantClientChange({phone: "111"}, {phone: "222"});
  const second = relevantClientChange({phone: "222"}, {phone: "333"});
  let appointment = {clientPhone: "111"};
  appointment = {...appointment, ...buildAppointmentPatch(second, appointment)};
  appointment = {...appointment, ...buildAppointmentPatch(first, appointment)};
  assert.equal(appointment.clientPhone, "222");
  console.log("REPRODUCED: reversed events replace latest phone 333 with 222.");

  let sourceTotal = 1;
  let storedTotal = 0;
  let releaseFirst;
  let signalStarted;
  const gate = new Promise((resolve) => { releaseFirst = resolve; });
  const started = new Promise((resolve) => { signalStarted = resolve; });
  function countQuery(filtered = false) {
    return {
      where() { return countQuery(true); },
      count() {
        return {get: async () => ({data: () => ({
          count: filtered ? 0 : sourceTotal,
        })})};
      },
    };
  }
  const countDb = {
    collection(name) {
      if (name === "appointments") {
        return {where() { return countQuery(); }};
      }
      return {doc() { return {async update(value) {
        if (value.jobCount === 1) {
          signalStarted();
          await gate;
        }
        storedTotal = value.jobCount;
      }}; }};
    },
  };
  const older = recountOne(countDb, "example-client");
  await started;
  sourceTotal = 2;
  await recountOne(countDb, "example-client");
  releaseFirst();
  await older;
  assert.equal(storedTotal, 1);
  console.log("REPRODUCED: older recount overwrites count 2 with 1.");

  const now = new Date("2026-10-18T12:00:00Z");
  let claimUpdate;
  const queueDb = {async runTransaction(work) {
    await work({
      get: async () => ({exists: true, data: () => ({
        status: "queued",
        attempts: 2,
        nextAttemptAt: new Date("2026-10-18T13:00:00Z"),
      })}),
      update: (_ref, patch) => { claimUpdate = patch; },
    });
  }};
  const claimed = await claimJob(
    {db: queueDb, logger: {warn() {}}},
    {id: "example-job", ref: {}},
    now,
  );
  assert.equal(claimed, true);
  assert.equal(claimUpdate.status, "inflight");
  console.log("REPRODUCED: stale query can claim a job before its new retry time.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
