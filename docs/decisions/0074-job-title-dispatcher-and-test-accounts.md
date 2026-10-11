# 0074. Job title is not role; dispatchers and test accounts leave lists, never lookups

**Date:** 2026-08-24 (dispatcher not assignable), 2026-09-13 (`isTestAccount`, for the Apple App Review account) · **Rules file:** `.claude/rules/employees.md`

## Context
`role` is the access flag `firestore.rules` gates on; `jobTitle` (Lead tech · Technician · Apprentice ·
Dispatcher) describes the work. Conflating them would make picking "Dispatcher" grant or revoke admin. A
dispatcher schedules work rather than going out on it; read from the raw stream they sat at a permanent zero on
the workload list and added their `maxJobsPerDay` to every capacity bar. A review asked whether a dispatcher could
be offered on a personal block or day off; owner call 2026-08-24: no — the exclusion is about the person. The App
Review account needed to disappear from teammate surfaces without breaking jobs already assigned to it.

## Decision
`JobTitle.isAssignable` is false for `dispatcher`; `EmployeeRecord.isAssignable` forwards it and adds
`!isTestAccount`; `assignableEmployeesProvider` (`employees_providers.dart`) is DERIVED from
`employeesStreamProvider`, because `_resolveActiveEmployees` (`event_details_controller.dart`) reads
`watchEmployees()` for the retain check and a stored dispatcher must still read as active or removing them is
undone on every save. `isAssignable` removes the account from `assignableEmployeesProvider` (both assignee pickers, the dashboard's workload, capacity and availability flags, the picker's availability reducer), the calendar crew filter, the time-off clash swap pool and a book-again crew; `LiveMapAggregator` (`join`/`groupTeam`) is the second owner, removing it from the map, its sheet and the drawer's on-the-clock badge. Lookups keep it: `employeeColorMapProvider`/`employeeNameMapProvider`, the detail sheet's and My details' own-record reads, `usedColors` (a tester's colour is still taken), the clash dialog's `_rosterName`, `offerableAssignees` (a tester stored on a job) and `neverSetUpAccountsProvider`. `isTestAccount` is an admin field (switch on
`edit_person_sheet.dart`, in `updateEmployee`'s patch and `toMap()`, absent from `kSelfServiceUserFields` and the
`hasOnly`); no rules change was needed since `isValidUserData` is per-key. History, the tester's own session and
every server-side push are untouched.

## Consequences
Assignees are required and an employee sees only jobs whose `employeeIds` contain them, so a dispatcher has
nothing on their own calendar — the accepted shape. Their visibility is unchanged and the edit picker still
offers one already on a job (`offerableAssignees`). Filtering a lookup blanks crew names and colours on jobs
already assigned; `neverSetUpAccountsProvider` is a security flag about a starting password, not a teammate list.
