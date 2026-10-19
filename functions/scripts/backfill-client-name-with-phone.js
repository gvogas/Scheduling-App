#!/usr/bin/env node
// One-off: makes each PERSON's `name` their phone number and nothing else, so
// the Wave customer reads "(514) 555-1234". A BUSINESS is left alone.
//
// WHY: `name` is synced VERBATIM as the Wave CUSTOMER name
// (`toWaveCustomerInput`, `wave/mappers.js`), and the invoicing workflow there
// identifies people by number. Owner call 2026-08-14. This supersedes both the
// "<name> <number>" shape this script wrote before and
// `backfill-client-phone-from-name.js`, which ran against prod on 2026-08-08.
// The rule lives in `ClientNamePolicy`, hand-mirrored as
// `client_name_utils.js`; this is the data half of it.
//
// THE RULE, per doc:
//   1. Skip any client created ON OR AFTER --since (default 2026-08-08, the
//      day the first rename ran). "Don't touch the ones that were just added" —
//      owner call. A doc with NO `createdAt` is treated as OLD and patched:
//      the field is backfilled lazily, so its absence means legacy, not new.
//   2. Skip any client with no phone AND no mobile. There is no number to be
//      named after, and nothing about the doc is wrong.
//   3. SKIP ANY BUSINESS — its name IS its identity in Wave ("3101-5696 qc
//      inc.", "1505 Village de Bergerac"), a number in its place is
//      unrecognisable on an invoice, and unlike a person there is usually no
//      first/last for the app to fall back on.
//   4. Otherwise set `name` to the phone (or the mobile). Trivially IDEMPOTENT:
//      a second run computes the same number, finds it already stored, and
//      writes nothing.
//
// RULE 3 IS A HEURISTIC AND THE DRY RUN LISTS EVERY DOC IT MATCHED. The Wave
// import sets no `type`, so an imported business can only be recognised by its
// NAME — a leading digit, or a company token like "inc"/"ltée"/"enr". Read
// that list before going live: a PERSON wrongly matched keeps their name (no
// harm), but a BUSINESS wrongly missed is renamed on live invoices.
//
// The clients it renames that had NO first/last on file are listed too, and
// that list needs reading for a different reason: their stored `name` was the
// only copy of the person's name, so the patch SPLITS it into the two halves
// in the same write rather than overwriting it away. The split is mechanical
// — last whitespace token is the surname — so only a human can spot a
// mis-split. (This used to be silent data loss; docs renamed before that was
// fixed are repaired by `restore-client-name-halves.js`.)
//
// TWO TRIGGERS FIRE ON EVERY PATCHED DOC, both wanted, neither free:
//   - `propagateClientEdits` fans the name onto that client's FUTURE
//     appointments. Harmless here and worth having: it writes the DISPLAY name
//     (`clientDisplayName` strips the number back off), so the appointment
//     copies converge on the same clean name the app writes at booking.
//   - `waveUpsertCustomer` enqueues an outbox job AND DRAINS IT IN THE SAME
//     INVOCATION (the 5-minute `waveSyncWorker` was deleted 2026-08-13). That
//     is the point of this script — but it means a few hundred Wave GraphQL
//     mutations fire within seconds of the last batch, against Wave's
//     60-calls/min ceiling. RUN THIS WHEN THE QUEUE IS QUIET and let it settle
//     before the next import; jobs that get rejected back off and are picked
//     up by the daily `runWaveDaily` drain, so nothing is lost, but a run in
//     the middle of a sync will be slow and noisy.
//
// Usage:
//   For prod:
//     export GOOGLE_APPLICATION_CREDENTIALS=/path/to/prod-service-account.json
//     node functions/scripts/backfill-client-name-with-phone.js --dry-run
//     node functions/scripts/backfill-client-name-with-phone.js
//
//   For the local emulator:
//     export FIRESTORE_EMULATOR_HOST=localhost:8080
//     export GCLOUD_PROJECT=schedulingapp-88727
//     node functions/scripts/backfill-client-name-with-phone.js
//
//   Options:
//     --dry-run          report what would change, write nothing
//     --since=YYYY-MM-DD skip clients created on or after this date
//                        (default 2026-08-08; pass --since=9999-01-01 to
//                        include every client regardless of age)
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR, and that is about `--dry-run`
// specifically: it is matched exactly, so `--dryrun` or `--dry_run` would
// otherwise read as false and take the run LIVE. Every typo of the safety flag
// now fails before a document is read.
//
// It prints the TARGET PROJECT before reading anything — running this against
// the wrong project is the other unrecoverable mistake, and that banner is the
// only thing standing in the way.
//
// A crash mid-run leaves the earlier batches committed. That is safe: the
// rename is idempotent, so re-running finishes the job and re-writes nothing
// it already did.
//
// ALWAYS dry-run against prod first and READ THE SAMPLE plus the two warning
// lists at the end. This rewrites the customer name in Wave; it is not
// reversible from here.


const {
  composeStored,
  isBusiness,
  looksLikeBusinessName,
  stripPhone,
} = require("../client_name_utils");
// `toMillis` rather than a local parser: it finite-checks, so a NaN/Infinity
// `createdAt` reads as "no usable date" and the doc is SKIPPED by --since
// rather than renamed. This script rewrites live Wave customers.
const {toMillis} = require("../time_utils");
const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {bootstrapScript} = require("./_project");
// The batched-write loop, shared so `--dry-run` cannot be forgotten at a
// call site — see `_batch.js`.
const {commitInBatches} = require("./_batch");
// The document-id paging loop, shared so a bulk run cannot read the whole
// collection in one `.get()` — see `_scan.js`.
const {scanByName} = require("./_scan");

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;
const SAMPLE_SIZE = 25;

/** Clients created on or after this instant are left alone. */
const DEFAULT_SINCE = "2026-08-08";

/**
 * Bare switches, matched EXACTLY — the same way the code that reads them
 * matches. A prefix test here would accept `--dry-run=true`, which
 * `argv.includes("--dry-run")` then reads as false: the guard would wave
 * through the precise input it exists to catch.
 */
const EXACT_FLAGS = ["--dry-run"];

/** Flags that carry a value, matched by their `--name=` prefix. */
const PREFIX_FLAGS = ["--since="];

/**
 * Rejects any argument that is not a flag this script knows.
 *
 * THE POINT IS `--dry-run` ITSELF. It is matched exactly, so `--dryrun`,
 * `--dry_run` or `-dry-run` silently evaluate to FALSE and the run goes
 * LIVE — a mistyped safety flag becoming a live bulk rename of Wave customer
 * names is the worst failure this script has. Refusing unknown arguments
 * converts every one of those typos into an error before a document is read.
 *
 * The rejection rule itself lives in the shared `_flags.js` — this wrapper
 * only supplies THIS script's flag list.
 *
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS, prefixes: PREFIX_FLAGS});
}

/**
 * Reads `--since=YYYY-MM-DD` off argv.
 *
 * Throws rather than falling back on an unparseable value: silently widening
 * the scope of a bulk rename to "every client ever" is exactly the mistake
 * this flag exists to prevent.
 *
 * @param {!Array<string>} argv Process arguments.
 * @return {number} Epoch ms; docs created at or after this are skipped.
 */
function parseSince(argv) {
  const arg = argv.find((a) => a.startsWith("--since="));
  const raw = arg ? arg.slice("--since=".length) : DEFAULT_SINCE;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    throw new Error(`--since must be YYYY-MM-DD, got "${raw}"`);
  }
  const ms = Date.parse(`${raw}T00:00:00Z`);
  if (Number.isNaN(ms)) throw new Error(`--since is not a real date: "${raw}"`);
  return ms;
}

/**
 * Whether this client is left alone because it is an ORGANIZATION.
 *
 * A business's NAME is its identity in Wave — "3101-5696 qc inc.", "1505
 * Village de Bergerac" — so replacing it with a phone number makes the
 * customer unrecognisable on a real invoice, and unlike a person there is
 * usually no first/last for the app to fall back on. `looksLikeBusinessName`
 * is what catches the imported ones, which carry no `type` at all.
 *
 * @param {!Object} data Client document fields.
 * @param {{phone: string, mobile: string}} numbers The doc's stored numbers.
 * @return {boolean}
 */
function isBusinessClient(data, numbers) {
  return isBusiness(data) ||
    looksLikeBusinessName(stripPhone(data.name, numbers));
}

/**
 * The patch for one client doc, or null when it needs no change.
 *
 * THE PATCH CARRIES THE HALVES when it would otherwise destroy the only copy
 * of a person's name. On a doc with neither `firstName` nor `lastName`, the
 * stored `name` IS that copy — `backfill-client-phone-from-name.js`
 * deliberately left `name` alone for exactly those docs — and overwriting it
 * with the number loses it for good, since Firestore keeps no history. The
 * halves are where the app reads a person's name from, so landing it there
 * costs nothing and changes no Wave identity (Wave carries its own first/last
 * fields beside the customer name). This mirrors
 * `ClientNamePolicy.composeSave`, which is the same guarantee on the app's
 * save paths; `restore-client-name-halves.js` repairs the docs written before
 * either existed.
 *
 * @param {!Object} data The stored client document.
 * @param {number} sinceMs Docs created at or after this are skipped.
 * @return {?{name: string, firstName: (string|undefined),
 *   lastName: (string|undefined)}} A field patch, or null to skip the doc.
 */
function patchFor(data, sinceMs) {
  const created = toMillis(data.createdAt);
  // A doc with no createdAt is legacy, not new — `createdAt` is backfilled
  // lazily by the Wave import, so plenty of real old docs lack it.
  if (created !== null && created >= sinceMs) return null;

  const phone = String(data.phone || "").trim();
  const mobile = String(data.mobile || "").trim();
  if (!phone && !mobile) return null;

  const name = composeStored({
    baseName: data.name,
    phone,
    mobile,
    type: data.type,
    businessName: data.businessName,
  });
  if (!name || name === String(data.name || "").trim()) return null;

  // A half already there is a name that survives the rewrite, so there is
  // nothing to rescue — and on a BUSINESS the halves are the CONTACT PERSON,
  // which must never be overwritten with the company's name.
  const hasHalf = Boolean(
      String(data.firstName || "").trim() ||
      String(data.lastName || "").trim());
  const base = stripPhone(data.name, {phone, mobile});
  // `name === base` means `composeStored` did NOT replace the name — this is a
  // BUSINESS (typed, legacy `businessName`, or caught by the heuristic), and
  // the only thing that changed is the trailing number coming off. Nothing was
  // destroyed, so there is nothing to rescue, and splitting here would invent a
  // CONTACT PERSON out of the company's own name and push it to Wave
  // ("Vogas Plumbing" -> first "Vogas", last "Plumbing"). This is the guard
  // `ClientNamePolicy.composeSave` spells as `stored == base`.
  if (hasHalf || !base || name === base) return {name};

  return {name, ...splitName(base)};
}

/**
 * Splits a person's name into the two stored halves.
 *
 * Deliberately dumb — the last whitespace token is the surname and everything
 * before it is the given name. `restore-client-name-halves.js` IMPORTS this
 * one rather than copying it — it repairs the docs this script wrote, so two
 * splits of the same name is the one divergence that matters here.
 * Hand-mirrored by `ClientNamePolicy.splitPersonName`, which shares its worked
 * examples.
 *
 * @param {string} name A person's name.
 * @return {{firstName: string, lastName: string}}
 */
function splitName(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return {firstName: "", lastName: ""};
  if (parts.length === 1) return {firstName: parts[0], lastName: ""};
  return {
    firstName: parts.slice(0, -1).join(" "),
    lastName: parts[parts.length - 1],
  };
}

/**
 * Puts every eligible client's phone number back into its name.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const sinceMs = parseSince(argv);

  let scanned = 0;
  let patched = 0;
  let skippedRecent = 0;
  let skippedNoPhone = 0;
  let skippedAlreadyDone = 0;
  const sample = [];
  const nameless = [];
  const businesses = [];
  let unlinked = 0;

  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});

  // Paged, never one `.get()` of the whole collection: a run that dies
  // part-way leaves a HALF-renamed collection, which from the app's side is
  // indistinguishable from one that was never backfilled at all.
  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: PAGE_SIZE})) {
    scanned += 1;
    const data = doc.data();
    const patch = patchFor(data, sinceMs);

    if (!patch) {
      // Re-derived only to report WHY, so the operator can sanity-check the
      // scope from the dry run instead of trusting one number.
      const created = toMillis(data.createdAt);
      const phone = String(data.phone || "").trim();
      const mobile = String(data.mobile || "").trim();
      if (created !== null && created >= sinceMs) {
        skippedRecent += 1;
      } else if (!phone && !mobile) {
        skippedNoPhone += 1;
      } else if (isBusinessClient(data, {phone, mobile})) {
        // Reported in FULL: this is a HEURISTIC on every doc that carries no
        // `type`, and the operator is the only one who can tell a real company
        // from a person the pattern happened to match.
        businesses.push({id: doc.id, name: String(data.name || "").trim()});
      } else {
        skippedAlreadyDone += 1;
      }
      continue;
    }

    patched += 1;
    if (sample.length < SAMPLE_SIZE) {
      sample.push({id: doc.id, from: data.name || "", to: patch.name});
    }
    // Reported in FULL, not sampled: this doc had NO first or last name, so
    // its stored `name` was the only copy of it.
    //
    // THIS USED TO BE DATA LOSS, and an earlier version of this comment
    // claimed it was not ("nothing is lost that was not already missing").
    // That was wrong for exactly this set: `backfill-client-phone-from-name.js`
    // deliberately left `name` alone on a doc with NEITHER half, so renaming
    // it in place destroyed the only copy and Firestore keeps no history.
    // `patchFor` now splits that name into the halves in the SAME patch, so
    // nothing is lost — but the split is mechanical (last token is the
    // surname), so the operator still has to read the list and check it.
    // Docs renamed BEFORE this changed are repaired from their settled
    // appointments by `restore-client-name-halves.js`.
    const hasOtherName = Boolean(
        String(data.firstName || "").trim() ||
        String(data.lastName || "").trim());
    if (!hasOtherName) {
      nameless.push({
        id: doc.id,
        to: patch.name,
        first: patch.firstName || "",
        last: patch.lastName || "",
      });
    }
    // A client Wave has never seen is CREATED by the upsert this write
    // triggers, not patched. That is almost certainly wanted, but it is a
    // different action from renaming an existing customer and the operator
    // should know the count before it happens.
    if (!data.waveCustomerId) unlinked += 1;

    await writer.stage(doc.ref, patch);
  }
  await writer.flush();

  const tag = dryRun ? "[dry-run] " : "";
  if (sample.length) {
    console.log(`${tag}sample (first ${sample.length}):`);
    for (const s of sample) {
      console.log(`  ${s.id}`);
      console.log(`    "${s.from}"`);
      console.log(`    -> "${s.to}"`);
    }
    console.log("");
  }
  console.log(
      `${tag}clients: ${scanned} scanned, ${patched} renamed, ` +
      `${businesses.length} skipped (business), ` +
      `${skippedRecent} skipped (created on/after ${
        new Date(sinceMs).toISOString().slice(0, 10)}), ` +
      `${skippedNoPhone} skipped (no phone), ` +
      `${skippedAlreadyDone} skipped (already correct)`);

  if (businesses.length > 0) {
    console.log(
        `\n${tag}${businesses.length} client(s) kept their name because they ` +
        "read as a BUSINESS — its name is what identifies it in Wave. This " +
        "is a heuristic on any doc with no `type`, so check the list for a " +
        "PERSON that should have been renamed:");
    for (const b of businesses) console.log(`  ${b.id}  "${b.name}"`);
  }

  if (unlinked > 0) {
    console.log(
        `\n${tag}${unlinked} of those are not linked to a Wave customer yet, ` +
        "so the upsert will CREATE them in Wave rather than rename one.");
  }

  if (nameless.length > 0) {
    console.log(
        `\n${tag}${nameless.length} client(s) had NO first/last name, so the ` +
        "typed name was the only copy. It is SPLIT into the halves in the " +
        "same write rather than destroyed — but the split is mechanical " +
        "(last token is the surname), so READ THIS LIST: only you can tell a " +
        "mis-split from a real name:");
    for (const n of nameless) {
      console.log(`  ${n.id}  -> name "${n.to}"` +
        `  first "${n.first}"  last "${n.last}"`);
    }
  }

  if (!dryRun && patched > 0) {
    console.log(
        `\n${patched} Wave customer pushes are now draining. Let them settle ` +
        "before running an import — see this file's header.");
  }
}

// Only run when invoked directly, so the rules here that can destroy data are
// requirable by jest without the script reaching for prod credentials.
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {
  assertKnownFlags,
  parseSince,
  patchFor,
};
