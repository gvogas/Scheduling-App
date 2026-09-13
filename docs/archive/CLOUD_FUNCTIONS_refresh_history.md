# `docs/CLOUD_FUNCTIONS.md` — refresh history before 2026-09-05

Trimmed out of the header of `docs/CLOUD_FUNCTIONS.md` on 2026-09-06, where the
stacked "Previously refreshed ..." block had reached nine entries. The four most
recent stayed there; these six are the older ones, frozen as written. They cover
2026-08-19 through 2026-08-29, across which the export list sat at 25.

**Added 2026-09-13** by the docs sweep, when the stack had grown back to seven:
the three entries from 2026-09-01 through 2026-09-04 (releases 1.55.0+84 to
1.57.0+86, across which the export list went 25 -> 29), frozen as written and
placed above the 2026-09-06 trim, newest first.

Previously refreshed 2026-09-04 (release 1.57.0+86 — **the export list GREW 25 -> 29**,
the first change since 2026-08-13. Four callables were added: `searchClients`,
`searchHistory` and `findAppointmentConflicts` (`indexed_search.js`), which move
client search, appointment-history search and the pre-save conflict check off
capped client-side scans onto indexed queries; and `restoreAppointmentStatus`
(`appointment_actions.js`), the Undo behind the mobile "mark complete". Two new
composite indexes serve them (`clients` searchTokens+name, `appointments`
historySearchScopes+status+startTime) and **both must be READY, and
`functions/scripts/backfill-search-tokens.js` must have run, before the app
build that calls them ships** — an unbackfilled document is invisible to the
search that replaced the scan. Also here: `placesAutocomplete` moved from the
in-memory limiter to `enforceDurableRateLimit`, and a self-service composed
guard `assertActiveCall` joined `assertAdminCall` in `security.js`. Rules gained
bounded `searchTokens` / `historySearchScopes` list fields and a
`locationSharingEnabled` bool on `/users`; the crew-signal rules removed on
2026-09-03 stay removed.)
Previously refreshed 2026-09-02 (release 1.56.0+85 — **the export list is unchanged at 25
and no row below moved**. The security-relevant change is that every ADMIN-ONLY
callable now opens with the composed `assertAdminCall(req, allowedKeys)`
(`security.js`) instead of re-deciding auth → `assertAdmin` →
`assertPayloadShape` at each site — `deleteClient`, `createEmployeeAccount`,
`deleteEmployeeAccount` and all three `places.js` callables, six in all.
It returns the caller's uid, which every one of them needs next for its
rate limiter. It exists because on 2026-09-01 three of those `assertAdmin` gates
turned out to be DELETABLE with the whole suite green — on the callables that
mint and delete real Firebase Auth accounts. The composition and its ORDER are
proved against the real `assertAdmin` in `assert_admin.test.js`; the callable
suites stub the COMPOSER, because stubbing `assertAdmin` alone intercepts
nothing (the composer holds a module-internal reference) and every gate
assertion would pass vacuously — the same shape that hid the original gap. NOT
for a self-service callable: `changeEmployeeEmail` keeps
`resolveEmailChangeCaller`. Two other server-side changes:
`assertPayloadShape`'s 4 KB cap now measures BYTES
(`Buffer.byteLength`) rather than UTF-16 code units, which accented and CJK
text could exceed by 3-4x under a constant and an error code that both said
bytes; and `notifyAppointmentChanges` additionally stamps the server-owned
`startedAt`/`completedAt` job time record on the status transition and pushes
an assignee's On-my-way / Running-late signal to active admins not on the job.
Rules WIDENED — the crew branches now admit an assignee's `fieldNotes` and
their photo writes to the `images` subcollection.)
Previously refreshed 2026-09-01 (release 1.55.0+84 — **the export list is unchanged at 25
and no row below moved**. Three server-side changes, all inside existing
functions: `waveUpsertCustomer` now records `wave.problems` from the new
customer contract (report-only — see below the summary table);
`notifyAppointmentChanges` wraps its per-recipient loop so one transient
failure no longer drops recipients 2..N on a function registered WITHOUT
`retry: true`; and all three `places.js` callables abort their upstream
request at 8 s, deliberately under the client's own 10 s callable timeout, so
an abandoned lookup stops burning a billed Places call and its rate-limit
slot. `runWaveDaily` also guards its connection read, making its documented
"never throws" contract true on its own terms. Rules unchanged; one composite
index RESTORED — see `sendUpcomingJobReminders`.)

Previously refreshed 2026-08-29 (release 1.54.0+83 — **the export list is unchanged at 25
and no row below moved**. The one server-side change is the retirement of
`createEmployeeAccount`'s `#compat-1.47.0` carve-out: `isAdmin` is out of the
`assertPayloadShape` allowlist and is now refused as `unexpected-field`. It was
deployed on its own on 2026-08-29 — a `functions`-only deploy, because retiring
a compat key is a backend change and cannot ride along with the app build that
stopped sending the field. The rest of the release is Flutter-only: the
calendar's holiday markers compute in Dart and reach no function, rule or
index. See `createEmployeeAccount` below for the full reasoning.)
Previously refreshed 2026-08-28 (release 1.53.0+82 — **the export list is unchanged at 25
and no row below moved**, but two behaviour changes here matter: the client
`jobCount` recount is now DEBOUNCED through the shared `recount_claim.js`
ledger and GATED on `mayShareABatch`, because a per-day run lands up to 16
writes carrying one `clientId`; and `client_address_utils.js` is a new pure
module owning `streetFromAddress`, which moved out of `wave/mappers.js` now
that `client_propagation.js` and the address backfill read it too. A
`firestore.rules` change rides with them — see the deployment-status note
below, it is NOT a ride-along deploy).
Previously refreshed 2026-08-25 (the 2026-08-25 audit — **no export, trigger, schedule,
secret or guard changed, and no row below moved**: the edits were dead-code
removal (`isOvernightRecord`, `TOKEN_TTL_MS`/`activityTokenExpiry`,
`IMPORT_FIELD_CAPS`'s export), the `{enforceAppCheck: true}` block lifted into
`security.js` as the shared `APP_CHECK` that `clients.js` and
`employee_accounts.js` now spread, and new jest coverage for `assertAdmin` —
the gate on 8 of 14 callables, which had been `jest.mock`'d in every suite, so
its real predicate had never once executed. Export list unchanged at 25).
Previously refreshed 2026-08-22 (the photo-subcollection CONTRACT step: `pictures[]`
retired, `appointment_image_tokens.js` and its deactivation-time token rotation
DELETED, `cascadeDeleteAppointmentImages` now deleting the Storage bytes as
well as the photo documents, the legacy `url` retired on a prod count of zero,
and `generateStartingPassword` given the symbol class that had account creation
down — export list unchanged at 25). Previously refreshed 2026-08-21
(simplified auth: `completeEmployeeSetup` lost its
`email_verified` guard and `createEmployeeAccount` stopped reading a role,
keeping `isAdmin` only as an accepted-and-ignored compatibility key — export
list unchanged at 25). Previously refreshed 2026-08-19 by auditing the source
against the app's call sites and
the live deployment (the iOS Live Activity stack added behind
`notifyAppointmentChanges` / `sendUpcomingJobReminders` — APNs secrets, direct
HTTP/2 client; `purgeExpiredHistory`'s timeout corrected to the 1800s scheduled
-trigger max; `sendUpcomingJobReminders` previously rebuilt into the
travel-aware "time to leave" sweep — `travel_utils.js`, Routes API,
`GOOGLE_MAP_API_KEY` shared via `params.js`).
