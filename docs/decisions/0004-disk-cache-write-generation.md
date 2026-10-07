# 0004. Disk-cache write generation is read where the fetch starts

**Date:** 2026-08-19 (S2) · **Rules file:** `.claude/rules/images.md`

## Context
The loader's write-back is unawaited, so a fetch resolving just after sign-out would re-seed the
just-emptied cache — on disk, where it outlives the process, for whoever signs in next on a shared
handset. `clear()` bumps a generation to drop such writes. Capturing the generation inside `write` was
a no-op for exactly the case the guard exists for: the loader only calls `write` after the Storage
fetch resolves, so the captured value already equalled the current one and the bytes landed anyway.
`write`'s generation also defaulted to the cache's own current value, which always passes, making the
protecting parameter opt-in.

## Decision
`AppointmentImageLoader._resolve` reads `_disk.generation` BEFORE `await _fetch(...)` and passes it to
`write(key, bytes, {required int generation})`; the parameter is required so a call site cannot opt
out.

## Consequences
Pinned by `test/core/images/appointment_image_disk_cache_test.dart` ("a write already in flight when
the session ends is dropped" / "a write started after the session ended is kept"). Don't give the
parameter a default or move the read into `write`.
