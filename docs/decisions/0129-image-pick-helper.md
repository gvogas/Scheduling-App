# 0129. Forms add photos through `pickAndAddAppointmentImages`

**Date:** 2026-09-07 · **Rules file:** `.claude/rules/frontend.md`

## Context
The pick is the longest await in the app (an OS action sheet, then camera or Photos), so the form can be
gone when it returns. Two hosts spelled the post-await `mounted` check separately and had drifted on which
`mounted` they checked. Camera is gated by `MediaPermissionService` (`permission_handler`); the gallery
uses the OS photo picker and needs no permission. The read-only carousel uses `smooth_page_indicator`.

## Decision
A form uses `pickAndAddAppointmentImages`, which owns the pick, the `context.mounted` re-check and the
notice naming what the per-job cap dropped.

## Consequences
The crew path (`DetailsFieldRecordView._addPhotos`) deliberately differs: it clamps against the stored count
as well and uploads in the background instead of staging into form state.
