---
paths:
  - "firestore.indexes.json"
  - "firestore.rules"
  - "functions/maintenance*.js"
---

# Firestore TTL policies and index exemptions

Loaded when editing `firestore.indexes.json` / `firestore.rules`. Root
context: `../../CLAUDE.md`. This lived in `functions/CLAUDE.md`, which does
NOT load when you are editing `firestore.indexes.json` at the repo root — the
one file every rule below is about.

**Firestore TTL policies are declared in `firestore.indexes.json`**, as
`fieldOverrides` entries with `"ttl": true` on `expiresAt`. They are NOT
console-only state: `firebase deploy --only firestore:indexes` treats any prod
field override missing from that file as drift and DELETES it (this removed all
5 live TTL policies once, on 2026-07-21 — never pass `--force` to a deploy).
Keep real single-field indexes on those entries rather than the Firebase docs'
`"indexes": []` example — `live_activity_registry.js` `_pruneExpired` queries
`.where("expiresAt", "<=", now)`, and the token sweep is a **collection-group**
query, so `liveActivityTokens.expiresAt` needs a `COLLECTION_GROUP`-scoped index
or the reaper fails `FAILED_PRECONDITION` into a swallowed no-op. The live
map's admin `presence` collection-group read orders by `updatedAt`, so the
`COLLECTION_GROUP`-scoped `presence.updatedAt` override stays too.

**`fieldOverrides` also carries the single-field index EXEMPTIONS** (added
2026-08-13, entries with `"indexes": []`). Firestore indexes every field of
every document ascending AND descending by default, and every element of an
array — including each subfield of every map inside it. On `appointments` that
meant `pictures` alone generating four indexed subfields per photo per doc,
forever, for a field nothing has ever queried; the free-text and denormalized
fields (`title`, `notes`, `materialsNeeded`, `address`, `clientName`,
`clientPhone`, `employeeNames`, `seriesOpId`) and the `clients` name/address
family plus `contacts` are the same shape. Entity search queries the `searchTokens` /
`historySearchScopes` token arrays (see `.claude/rules/search.md`), never these
fields, so none of these is ever a query constraint — the exemptions cut index storage and shorten every
write without changing a single query. **Adding a `where`/`orderBy` on an
exempted field means removing its override first**, and the rebuild is not
instant; check this list before writing a new query rather than debugging a
`FAILED_PRECONDITION`. Deliberately NOT exempted, though nothing queries them
today: `createdAt`/`updatedAt` (the fields you reach for when investigating
something in the console) and the low-cardinality flags.

**A TTL policy only deletes docs that HAVE the field**, exactly like the
`where("expiresAt", ...)` sweeps — Firestore excludes documents missing the
filter field. So any client-writable TTL field must be **required** in the
rules, not merely bounded when present, or a modified client can mint rows no
reaper can ever reach (see the `liveActivityTokens` rule).

**Firestore TTL policies must use expiration offset `0`.** Every collection that
writes an `expiresAt` (all EIGHT of `appointmentReminders`, `appointmentOverduePrompts`,
`appointmentSeriesNotices`, `liveActivityTokens`, `liveActivityCards`,
`rateLimits`, `appointmentRecountClaims`, `clientRecountClaims`) stores
the *absolute* deletion instant — the lifetime is already baked in by
`LEDGER_TTL_MS` / `CARD_TTL_MS` / the limiter window. The
console's "expiration offset" ADDS to that value, so any non-zero offset
silently multiplies retention (the ledgers ran at ~14 days instead of 7 until
2026-07-20). An offset is **immutable once set**: correcting one means delete →
wait for the policy to disappear from the list → recreate, or the create fails
`400: Cannot modify TTL offset`. A policy can only be created for a collection
group that already holds documents. TTL is housekeeping only — every one of
these is also swept in-code, so a missing policy is never a correctness bug.


**A composite index is NOT redundant just because another index starts with the
same fields — Firestore appends `__name__` to the ordered fields, and that
lands at the END.** `appointments (employeeIds CONTAINS, endTime ASC)` was
deleted on 2026-08-28 as a "redundant prefix" of
`(employeeIds CONTAINS, endTime ASC, startTime ASC)`. It is not one: the
surviving index really reads `(employeeIds, endTime, startTime, __name__)`, so
no prefix of it ever puts `__name__` directly after `endTime` — which is
exactly what `travel_utils.js`'s `decideOrigin` context query needs
(`array-contains` + two `endTime` bounds + `orderBy("endTime")` + `limit`).
The query began failing `FAILED_PRECONDITION` immediately and **every travel
reminder silently degraded to the fixed 30-minute kind for two days**, because
that path is best-effort: it logs `travel: context query failed` and falls
through, so nothing surfaced it in the app or in Crashlytics. It was found
only by reading `functions_get_logs`, where it was 60 of 60 warnings in a
2.5-hour window. **Restored 2026-08-31; do not delete it again.** Before
removing any composite as a prefix, check what `orderBy` the query ends on —
and prefer confirming against the logs over reasoning about it.

**A `fieldOverrides` exemption is not free reach — `createdAt`/`updatedAt` stay
INDEXED on purpose** (restated 2026-08-31 after a pass exempted them for write
cost and had to be reverted). They are what you sort and filter by in the
Firebase console when investigating a live doc, which is worth more than the
two index writes each costs. The exemptions above are for free-text,
denormalized and array-of-object fields that no query and no human ever sorts
on — `wave.problems` (added 2026-08-31) is the array-of-objects shape, the
same case as `clients/contacts`.
