# 0091. `jobCount` is an absolute recount that excludes cancelled visits

**Date:** 2026-09-11 (cancelled excluded) · **Rules file:** `.claude/rules/clients.md`

## Context
`recountClientJobs` runs `retry: true`, so an increment would double-count. Excluding cancelled took two
halves: the arithmetic, and `clientsToRecount` firing on a cancelled-ness flip — cancelling leaves `clientId`
alone, so the trigger returned `[]`. Without the fourth term, one live plus one cancelled 5-day run computes
`10 − 8 − 5 = −3`; the answer is 1. A console-written `"Cancelled"` still counts (a `where` cannot
lowercase); `isValidAppointmentStatus` holds client writes to lowercase. `canDeleteClient` (`jobCount == 0`)
now disagrees with the callable's unfiltered live count for a client whose only visits were cancelled; the
owner default is to keep the gate and change the message if it ever becomes a complaint.

## Decision
`countJobsFor` is the one owner: `total − laterRunDays(dayIndex > 1) − cancelled + cancelledLaterRunDays`,
written with `update()`. It subtracts cancelled rather than allowlisting live statuses, so legacy `confirmed`
and status-less docs still count (the `countFutureAssignments` trap). `recount-client-jobs.js` shares it and
is a release prerequisite.

## Consequences
A second copy of the arithmetic disagrees with the trigger on whichever clients it touched last. Clamping at
0 is wrong. Gating the trigger on "status changed" loses the zero-read property of a `pending → done` edit.
