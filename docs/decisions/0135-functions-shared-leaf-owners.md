# 0135. Shared `functions/` rules have one owner module, extracted from drifted copies

**Date:** 2026-07-19, 2026-08-22, 2026-09-06 · **Rules file:** `functions/CLAUDE.md`

## Context
Every shared module in `functions/` was extracted from copies that had already drifted:
- `optionalString` lived as a private copy in the retired `invites.js` and was carried verbatim into
  `employee_accounts.js` before being hoisted into `security.js`. `requireDocId` replaced the
  `isValidDocIdField` check restated at three call sites, two byte-identical down to the comment.
- 2026-08-22: `admin_firestore.js` (`adminFirestore()`) replaced a byte-identical lazy
  `require("firebase-admin/firestore")` in four modules whose JSDocs disagreed on whether `Timestamp`
  came with it. `appointment_scan.js` (`scanAppointmentWindow`) replaced the window scan all three
  scheduled sweeps spelled out (status-`in`, two range `where`s, `orderBy`, `limit`, warn-at-cap, map); `travel_utils.js` had re-spelled the record mapper inline twice rather
  than using `recordOf`. Its options had defaults (`descending`/`loOp`/`hiOp`) or were merely read
  (`logger`/`label`/`consequence`), so a caller could omit the ordering and keep the wrong jobs, or omit
  the logger and lose the truncation warn. `reclaimDecision` moved out of `worker.js`'s
  `runTransaction` closure into the pure `wave/retry_policy.js` (now called from `wave/outbox_core.js`).
- `client_address_utils.js` (`streetFromAddress`/`composeFullAddress`) lived in `wave/mappers.js` and
  moved out when `client_propagation.js` needed the same answer.
- `sendToActiveAdmins` was justified as the fan-out P6's time-off requests would reuse; P6 was cancelled
  2026-09-06, so it has one caller. It was the last unbounded collection query in the push stack until
  `ADMIN_FANOUT_MAX` (100) bounded it; it seeds `sendToEmployee`'s recipient `cache` from the docs it
  read, so `_loadRecipient` doesn't re-`get()` a users doc already in hand.
- The parallel `functions/test/` directory was merged into `functions/__tests__/` 2026-07-19.

## Decision
Shared guards live in `security.js`, secrets in `params.js`, and each named leaf owns its rule; callers
import it rather than re-spelling it. `scanAppointmentWindow` throws on a missing ordering
(`descending`/`loOp`/`hiOp`) or warn contract (`logger`/`label`/`consequence`), the same
enforcement as `pageToCap`'s required `onCapReached` on the Dart side. `requireDocId` throws
`invalid-<key>` so each call site keeps its own code; `notification_policy.js`'s `toIdList` filters a
list instead of throwing and does not use it.

## Consequences
A second copy of any of these is how two answers drift apart. `appointment_scan`'s ordering is
load-bearing: the overdue and digest sweeps look backward and keep the newest, the travel sweep looks
forward and keeps the soonest. All three `reclaimDecision` outcomes destroy something, which is why it
must stay reachable without a Firestore-transaction mock. The rule against a second inlined role/status
admin query stands even with one caller.
