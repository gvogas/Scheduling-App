# 0080. Never delete an employee; revoking a permission deletes nothing

**Date:** 2026-08-02 (owner decision, withdrew a shipped delete), 2026-08-08 (privacy-policy audit), 2026-09-04 (sharing opt-in), 2026-09-13/14 (presence cutoff added, then removed) · **Rules file:** `.claude/rules/employees.md`, `.claude/rules/notifications.md`

## Context
A shipped employee delete orphaned every past appointment's `employeeIds` link; disable already does strictly more
through `syncUsersByUid`. The privacy policy promised that revoking the OS permission deleted the stored location and
removed the pin; it did neither — `_stop()` only cancels the subscription and timers. Owner call was to correct the
TEXT rather than the code. A 2 h `presenceHiddenAfter` cutoff (2026-09-13) was removed 2026-09-14 by owner call, so
`LiveMapAggregator.groupTeam` pins a fix at any age (`staff_marker_icon.dart` has no staleness branch) and only the sheet row shows its age. Without the
`locationSharingEnabled` gate, presence docs written before sharing became opt-in (2026-09-04) would reappear for
people who never turned it on, and a failed `unregister()` delete would pin someone who switched sharing off. NOT
SEEN means sharing on with no fix yet.

## Decision
Disable is the only removal; `allow delete` is withdrawn from `/users`. Presence and FCM rows are deleted only by
`PresenceSyncController.unregister()` and `unregisterCurrentDevice()`, reached from sign-out, self-service account deletion and the server-side disable/delete bridge. `docs/legal/privacy-policy.html`
§2, §6 and §8 describe this exactly and move in step with it.

## Consequences
Wiring revocation into a delete, reintroducing an age cutoff or dropping the sharing gate without updating and
republishing those sections leaves the site describing old behaviour.

## Functions side
`deactivateEmployee` only flips the Firestore field; `syncUsersByUid` makes it real, after the auth-critical bridge
write, idempotently (`retry: true`). It swallows `auth/user-not-found` because account deletion removes the Auth
user before the doc, and a rethrow would retry forever. The bridge doc is retained for `disabled` users, so
`isAssignedEmployee` (`firestore.rules`) and `isAssignedToAppointment` (`storage.rules`) gate on
`status == 'active'`; an existence-only check left a terminated tech reading client PII and job photos. Two lessons
from the retired token-rotation pass (ADR-0001, ADR-0002; its raised `timeoutSeconds` went with it): a `deps` field
resolved after entry is a branch no test can reach (the bucket landed in a local while the callee
read `deps.bucket`, so the control reported "nothing rotated" while rotating nothing, 2026-08-16); and a per-appointment parent write fans out to
`notifyAppointmentChanges`, a no-op only because `diffAppointmentForNotifications` emits nothing for a photo-only
diff ("a pictures-only rewrite emits nothing", `notification_utils.test.js`).
