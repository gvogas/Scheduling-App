# 0117. CarPlay reads the Siri snapshot (v4), bypasses the app lock, fails fast offline

**Date:** 2026-09-09 (built), 2026-09-19 (app-lock bypass, audit S1) · **Rules file:** `.claude/rules/notifications.md`

## Context
CarPlay (`ios/Runner/CarPlay` + `lib/core/app/carplay_bridge.dart`) is a fourth off-app surface reading
the same `schedule_snapshot`. Schema v4 made `_appointment()` (`schedule_snapshot.dart`) emit the flags
`displayStatusAt` branches on, `isPersonal`/`isDayOff`, and for admins `crew` (`{'n': name, 'c': storedArgb}`,
no id, phone or email) and `viewer`, the first time the locked-readable file names a person;
the owner accepted a name as far from the notes, phones and photos still excluded. Since 2026-08-11 a
personal block can carry a real address (a clinic, a school). A driver's phone is locked almost all the
time CarPlay runs, and offline is normal in a moving vehicle.

## Decision
The Swift decoder accepts version 3 OR 4: the on-disk snapshot stays v3 until the app runs after the
update, and a strict v4 gate makes Siri answer "no appointments". `isPersonal`/`isDayOff` are omitted
when false while `isAllDay` is always present, deliberately. An admin's snapshot blanks another person's
personal `address`; an empty `viewerDocId` withholds every personal address. `crew` names by INDEX
against the raw `employeeIds` (the lists pair positionally), and `c` is the STORED light ARGB, never a
lifted value (the car lifts it; omitted with no colour). `viewer` prefers the
denormalized name on the viewer's own job (the car matches it against `crew`, stamped at booking) over
`users.name`. Phone numbers come on demand over the method channel (`dialableNumberFor`), never from the
file. `setAppointmentStatus` and `dialableNumberFor` never consult `AppLockController`. The status write
returns `false` offline and logs under `CARPLAY`.

## Consequences
An app-lock gate makes Start/Complete/Call dead for every app-lock user; writes stay bounded by Firestore
rules. Without the offline guard the awaited write never resolves and the driver gets no feedback.
