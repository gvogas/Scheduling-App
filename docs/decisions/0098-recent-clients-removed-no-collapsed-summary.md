# 0098. Recent clients removed; the collapsed match summary not built

**Date:** 2026-09-06 (recents removed, owner call) · **Rules file:** `.claude/rules/clients.md`

## Context
Recents were free — built from appointments' denormalized `clientId`/`clientName`/`clientPhone`, not client
reads — and returned empty for a non-admin, because the query carries no `employeeIds` constraint and adding
one needs a new composite. The design doc names a focus-collapsed match summary; it was left out because a
focus-driven collapse can rebuild under a tap already in flight, and no widget test can catch that.

## Decision
Search is the only path to a client on the booking form. `recentClientsProvider`, `RecentClient`,
`AppointmentsRepository.fetchRecentClientBookings` and `ClientPicker.recentClients`/`onSelectRecent` are gone;
don't restore them from an older copy. `ClientPicker` is stateless and always renders its list;
`clients_tapToCarryOn` was removed from both ARBs — re-add it with the state, not before.

## Consequences
Bringing recents back for technicians needs the `employeeIds` constraint and its index.
