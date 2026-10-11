# 0177. CarPlay rows: time in the text, avatar for admins only

**Date:** 2026-09-10 · **Rules file:** `ios/CLAUDE.md`

## Context
CarPlay rows first gave technicians a time tile. Once both roles led the row text with the 12-hour time,
the tile repeated it and was deleted. An all-day block stores a midnight start, so any clock time on it
read "12:00 AM".

## Decision
Both roles lead the row text with the 12-hour time; only an admin row gets an image (the crew avatar). An
all-day block shows no clock time anywhere: `CarPlayStrings.startedAt` returns `String?` so the Now header
cannot say "Started 12:00 AM", and the detail's When row drops any tail that would only name the start.

## Consequences
A re-added technician tile shows the time twice; a non-optional `startedAt` brings back "Started 12:00 AM".
