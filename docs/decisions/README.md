# Architecture decision records

Why a rule in `.claude/rules/` or a `CLAUDE.md` has its shape. The rules file
states WHAT to do, plus one clause of why where the obvious "fix" is wrong; the
ADR it cites as `(ADR-NNNN)` records the dates, the incident behind it and what
not to "fix". Number sequentially from one counter; never renumber.

| ADR | Title | Rules file |
|---|---|---|
| 0001 | Photos render from bytes; no download URL is ever minted | `.claude/rules/images.md` |
| 0002 | Legacy photo `url` retired | `.claude/rules/images.md` |
| 0003 | Offline photos via a disk cache keyed on `storagePath` | `.claude/rules/images.md` |
| 0004 | Disk-cache write generation is read where the fetch starts | `.claude/rules/images.md` |
| 0005 | Uploaded photos use `cacheControl: private` | `.claude/rules/images.md` |
| 0006 | Photos moved to `appointments/{id}/images`; the `pictures` array retired | `.claude/rules/images.md` |
| 0007 | Server-side image cascade and a debounced, always-on recount | `.claude/rules/images.md` |
| 0008 | Offline upload queue entries are owned | `.claude/rules/images.md` |
| 0009 | One serialized drain path and serialized queue mutations | `.claude/rules/images.md` |
| 0010 | Photo strip and detail-sheet render gates | `.claude/rules/images.md` |
