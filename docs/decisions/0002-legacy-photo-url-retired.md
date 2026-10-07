# 0002. Legacy photo `url` retired

**Date:** 2026-08-22 (subcollection), 2026-08-27 (parent arrays; S1 closed) · **Rules file:** `.claude/rules/images.md`

## Context
Deleting `rotateAssignedImageTokens` (ADR-0001) rested on "there is no stored link left to
invalidate", which for a while was true of new photos only. A legacy `appointments/*/images` row with
no `storagePath` kept its `url`, and three things kept it alive: the backfill preserved it
deliberately, `firestore.rules` accepted the field up to 1000 chars, and `AppointmentImageLoader` had
a `refFromURL` fallback documented as permanent. Each was a rules-free, non-expiring, transferable
link surviving deactivation. `functions/scripts/count-legacy-image-urls.js` counted the subcollection
on 2026-08-22: 14 image documents, 0 with a url and no storagePath. So the rules allowlist became
`['storagePath', 'fileName', 'uploadedAt']`, the loader keyed on `storagePath` alone, the session
cache's second `'url:<url>'` key space went, `AppointmentImagesStore` stopped writing the field, and
the backfill skipped a url-only array entry instead of copying a document that could never render.

That count was only ever about the SUBCOLLECTION. The parent `pictures[]` arrays were the larger set,
and a pre-CONTRACT upload wrote a `url` ALONGSIDE the `storagePath` into every entry, so they were
never url-ONLY and a url-only scan could not see them; each was a permanent rules-free link readable
off the appointment by any assigned employee and surviving deactivation. S1 was closed by the CLEAR
SCRIPT, not by retiring the field — the distinction this rule got wrong three times:
`clear-appointment-picture-arrays.js` ran on prod 2026-08-27 and cleared 14 entries across 11
appointments (67 scanned). `countArrayUrls` in the count script was the read-only re-check. Both
scripts were deleted 2026-09-28 and are in git history.

## Decision
No photo document or array carries a `url`; the rules reject the field. If a url-only row ever
reappears, re-home its bytes under a real `storagePath` — never re-add the field to make a write pass.

## Consequences
"No rules-free link remains" is a statement about the DATABASE, not every copy that ever left it: a
URL captured under a pre-1.49 build is still live on its object unless rotated by hand. To re-check,
recover the count script from git history (read-only); it scans rather than queries on purpose,
because `images.url` is index-exempt in `firestore.indexes.json` and a `where("url", ...)` fails.
